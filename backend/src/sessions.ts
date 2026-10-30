// Reelish sessions: short-lived signed access tokens (checked without a
// database read) and rotating opaque refresh tokens stored only as hashes.

import { hmacKey, hmacSign, hmacVerify, randomToken, sha256, base64url, fromBase64url } from './crypto';
import type { Env } from './env';
import { ApiError } from './http';
import { audit } from './audit';

export const accessTokenTtlSeconds = 15 * 60;
export const refreshTokenTtlSeconds = 30 * 24 * 60 * 60;

export interface SessionTokens {
  sessionId: string;
  accessToken: string;
  accessExpiresAt: number;
  refreshToken: string;
  refreshExpiresAt: number;
}

export interface Principal {
  userId: string;
  sessionId: string;
}

interface AccessPayload {
  sid: string;
  uid: string;
  iat: number;
  exp: number;
}

const prefix = 'ra1';
const now = () => Math.floor(Date.now() / 1000);

async function keyId(secret: string): Promise<string> {
  return (await sha256(`kid:${secret}`)).slice(0, 8);
}

async function signAccess(env: Env, payload: AccessPayload): Promise<string> {
  const body = base64url(new TextEncoder().encode(JSON.stringify(payload)));
  const kid = await keyId(env.SESSION_SIGNING_KEY);
  const signed = `${prefix}.${kid}.${body}`;
  return `${signed}.${await hmacSign(await hmacKey(env.SESSION_SIGNING_KEY), signed)}`;
}

/** The session behind a `Bearer` access token, or a 401. */
export async function authenticate(env: Env, request: Request): Promise<Principal> {
  const header = request.headers.get('Authorization') ?? '';
  const match = /^Bearer ([A-Za-z0-9._-]{20,1024})$/.exec(header);
  if (!match) throw unauthorized('missing_token', 'Sign in to continue.');
  const parts = match[1].split('.');
  if (parts.length !== 4 || parts[0] !== prefix) {
    throw unauthorized('invalid_token', 'Session is not valid.');
  }
  const [, kid, body, signature] = parts;
  const secrets = [env.SESSION_SIGNING_KEY, env.SESSION_SIGNING_KEY_PREVIOUS]
    .filter((secret): secret is string => !!secret);
  let verified = false;
  for (const secret of secrets) {
    if ((await keyId(secret)) !== kid) continue;
    verified = await hmacVerify(await hmacKey(secret), `${prefix}.${kid}.${body}`, signature);
    break;
  }
  if (!verified) throw unauthorized('invalid_token', 'Session is not valid.');
  let payload: AccessPayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(fromBase64url(body)));
  } catch {
    throw unauthorized('invalid_token', 'Session is not valid.');
  }
  if (typeof payload.exp !== 'number' || payload.exp <= now()) {
    throw unauthorized('token_expired', 'Session expired.');
  }
  if (typeof payload.sid !== 'string' || typeof payload.uid !== 'string') {
    throw unauthorized('invalid_token', 'Session is not valid.');
  }
  return { userId: payload.uid, sessionId: payload.sid };
}

async function issueAccess(env: Env, userId: string, sessionId: string) {
  const iat = now();
  const exp = iat + accessTokenTtlSeconds;
  return { token: await signAccess(env, { sid: sessionId, uid: userId, iat, exp }), exp };
}

export async function createSession(
  env: Env,
  userId: string,
  device: { name: string; platform: string },
): Promise<SessionTokens> {
  const sessionId = crypto.randomUUID();
  const refreshToken = randomToken();
  const issuedAt = now();
  const refreshExpiresAt = issuedAt + refreshTokenTtlSeconds;
  await env.DB.prepare(
    `INSERT INTO sessions (id, user_id, refresh_hash, device_name, platform,
       created_at, last_used_at, refresh_expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(sessionId, userId, await sha256(refreshToken), device.name, device.platform,
      issuedAt, issuedAt, refreshExpiresAt)
    .run();
  const access = await issueAccess(env, userId, sessionId);
  await audit(env, 'session.created', { userId, sessionId, detail: device.platform });
  return { sessionId, accessToken: access.token, accessExpiresAt: access.exp, refreshToken, refreshExpiresAt };
}

/**
 * Swaps a refresh token for new tokens. A refresh token works once; a
 * rotated one coming back means it leaked, so its session is revoked.
 */
export async function refreshSession(env: Env, refreshToken: string): Promise<SessionTokens> {
  if (!/^[A-Za-z0-9_-]{43}$/.test(refreshToken)) {
    throw unauthorized('invalid_refresh', 'Sign in again.');
  }
  const hash = await sha256(refreshToken);
  const at = now();
  const session = await env.DB.prepare(
    `SELECT id, user_id, refresh_expires_at, revoked_at FROM sessions WHERE refresh_hash = ?`,
  ).bind(hash).first<{ id: string; user_id: string; refresh_expires_at: number; revoked_at: number | null }>();

  if (!session) {
    const reused = await env.DB.prepare(
      `SELECT id, user_id FROM sessions WHERE previous_refresh_hash = ? AND revoked_at IS NULL`,
    ).bind(hash).first<{ id: string; user_id: string }>();
    if (reused) {
      await revokeSession(env, reused.id);
      await audit(env, 'session.refresh_reuse', { userId: reused.user_id, sessionId: reused.id });
    }
    throw unauthorized('invalid_refresh', 'Sign in again.');
  }
  if (session.revoked_at !== null || session.refresh_expires_at <= at) {
    throw unauthorized('invalid_refresh', 'Sign in again.');
  }

  const next = randomToken();
  const refreshExpiresAt = at + refreshTokenTtlSeconds;
  // Conditional on the old hash, so two concurrent refreshes cannot both win.
  const result = await env.DB.prepare(
    `UPDATE sessions SET refresh_hash = ?, previous_refresh_hash = ?,
       last_used_at = ?, refresh_expires_at = ?
     WHERE id = ? AND refresh_hash = ? AND revoked_at IS NULL`,
  ).bind(await sha256(next), hash, at, refreshExpiresAt, session.id, hash).run();
  if ((result.meta.changes ?? 0) !== 1) {
    throw unauthorized('refresh_conflict', 'Sign in again.');
  }
  const access = await issueAccess(env, session.user_id, session.id);
  return {
    sessionId: session.id,
    accessToken: access.token,
    accessExpiresAt: access.exp,
    refreshToken: next,
    refreshExpiresAt,
  };
}

export async function revokeSession(env: Env, sessionId: string): Promise<void> {
  await env.DB.prepare(`UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`)
    .bind(now(), sessionId).run();
}

export async function revokeAllSessions(env: Env, userId: string): Promise<void> {
  await env.DB.prepare(`UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL`)
    .bind(now(), userId).run();
}

/** A revoked or expired session's access token still works until it expires
 * (at most [accessTokenTtlSeconds]); account routes check the row too. */
export async function requireLiveSession(env: Env, principal: Principal): Promise<void> {
  const row = await env.DB.prepare(
    `SELECT revoked_at, refresh_expires_at FROM sessions WHERE id = ? AND user_id = ?`,
  ).bind(principal.sessionId, principal.userId).first<{ revoked_at: number | null; refresh_expires_at: number }>();
  if (!row || row.revoked_at !== null || row.refresh_expires_at <= now()) {
    throw unauthorized('session_revoked', 'Sign in again.');
  }
}

function unauthorized(code: string, message: string): ApiError {
  return new ApiError(401, code, message, { 'WWW-Authenticate': 'Bearer' });
}
