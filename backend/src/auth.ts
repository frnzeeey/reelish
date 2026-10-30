// Account routes: Trakt device sign-in, session refresh and logout, the
// signed-in user's sessions, and account deletion.

import { decrypt, encrypt, randomToken, sha256 } from './crypto';
import type { Env } from './env';
import { ApiError, json, readJsonBody, shortText } from './http';
import { audit } from './audit';
import {
  createSession, refreshSession, requireLiveSession, revokeAllSessions,
  revokeSession, type Principal, type SessionTokens,
} from './sessions';
import {
  fetchIdentity, forgetTraktTokens, pollDeviceToken, saveTraktTokens,
  startDeviceCode, type TraktDeps,
} from './trakt';

const platforms = new Set(['android', 'android_tv', 'windows']);
const now = () => Math.floor(Date.now() / 1000);

function deviceFrom(body: Record<string, unknown>) {
  const platform = shortText(body.platform, 20);
  if (!platforms.has(platform)) {
    throw new ApiError(400, 'invalid_platform', 'Unknown platform.');
  }
  return { name: shortText(body.deviceName, 60), platform };
}

function sessionBody(tokens: SessionTokens) {
  return {
    sessionId: tokens.sessionId,
    accessToken: tokens.accessToken,
    accessExpiresAt: tokens.accessExpiresAt,
    refreshToken: tokens.refreshToken,
    refreshExpiresAt: tokens.refreshExpiresAt,
  };
}

/** POST /auth/device/start: asks Trakt for a code the user enters at trakt.tv. */
export async function startDevice(env: Env, request: Request, requestId: string, deps: TraktDeps = {}) {
  const device = deviceFrom(await readJsonBody(request));
  const code = await startDeviceCode(env, deps);
  const pollToken = randomToken();
  const pollHash = await sha256(pollToken);
  const at = now();
  // Clear abandoned sign-ins as new ones start.
  await env.DB.prepare(`DELETE FROM device_authorizations WHERE expires_at < ?`).bind(at).run();
  await env.DB.prepare(
    `INSERT INTO device_authorizations (poll_hash, device_code_enc, interval_seconds,
       expires_at, next_poll_at, device_name, platform, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    pollHash,
    await encrypt(env.TOKEN_ENCRYPTION_KEY, code.device_code, `device:${pollHash}`),
    Math.min(Math.max(Math.round(code.interval), 1), 60),
    at + Math.min(code.expires_in, 30 * 60),
    at + code.interval,
    device.name,
    device.platform,
    at,
  ).run();
  return json({
    pollToken,
    userCode: code.user_code,
    verificationUrl: code.verification_url,
    expiresIn: Math.min(code.expires_in, 30 * 60),
    interval: code.interval,
  }, requestId);
}

interface PendingRow {
  device_code_enc: string;
  interval_seconds: number;
  expires_at: number;
  next_poll_at: number;
  device_name: string;
  platform: string;
}

/**
 * POST /auth/device/poll: checks once with Trakt. Pending answers 202; on
 * approval the Trakt account becomes (or resolves to) a Reelish user and
 * a session is issued. A sign-in completes once; its poll token is then
 * deleted, so it cannot be replayed.
 */
export async function pollDevice(env: Env, request: Request, requestId: string, deps: TraktDeps = {}) {
  const body = await readJsonBody(request);
  const pollToken = shortText(body.pollToken, 64);
  if (!/^[A-Za-z0-9_-]{43}$/.test(pollToken)) {
    throw new ApiError(400, 'invalid_poll_token', 'Unknown sign-in.');
  }
  const pollHash = await sha256(pollToken);
  const row = await env.DB.prepare(
    `SELECT device_code_enc, interval_seconds, expires_at, next_poll_at, device_name, platform
     FROM device_authorizations WHERE poll_hash = ?`,
  ).bind(pollHash).first<PendingRow>();
  if (!row) throw new ApiError(404, 'unknown_sign_in', 'Sign-in not found; start again.');
  const at = now();
  const remove = () => env.DB.prepare(`DELETE FROM device_authorizations WHERE poll_hash = ?`).bind(pollHash).run();
  if (row.expires_at <= at) {
    await remove();
    throw new ApiError(410, 'sign_in_expired', 'The code expired; start again.');
  }
  if (at < row.next_poll_at) {
    return json({ status: 'pending', interval: row.interval_seconds }, requestId, 202,
      { 'Retry-After': String(row.next_poll_at - at) });
  }

  const deviceCode = await decrypt(env.TOKEN_ENCRYPTION_KEY, row.device_code_enc, `device:${pollHash}`);
  const result = await pollDeviceToken(env, deviceCode, deps);
  switch (result.kind) {
    case 'pending':
    case 'slow_down': {
      const interval = result.kind === 'slow_down'
        ? Math.min(row.interval_seconds + 5, 60)
        : row.interval_seconds;
      await env.DB.prepare(
        `UPDATE device_authorizations SET interval_seconds = ?, next_poll_at = ? WHERE poll_hash = ?`,
      ).bind(interval, at + interval, pollHash).run();
      return json({ status: 'pending', interval }, requestId, 202, { 'Retry-After': String(interval) });
    }
    case 'denied':
      await remove();
      throw new ApiError(403, 'sign_in_denied', 'Sign-in was declined on Trakt.');
    case 'expired':
    case 'invalid':
    case 'used':
      await remove();
      throw new ApiError(410, 'sign_in_expired', 'The code is no longer valid; start again.');
    case 'authorized':
      break;
  }

  // Claim the sign-in before using it: a concurrent poll finds nothing.
  const claimed = await remove();
  if ((claimed.meta.changes ?? 0) !== 1) {
    throw new ApiError(410, 'sign_in_expired', 'The code is no longer valid; start again.');
  }
  const identity = await fetchIdentity(env, result.tokens.access_token, deps);
  const userId = await upsertUser(env, identity.uuid, identity.username);
  await saveTraktTokens(env, userId, result.tokens);
  const tokens = await createSession(env, userId, { name: row.device_name, platform: row.platform });
  await audit(env, 'auth.signed_in', { userId, sessionId: tokens.sessionId, detail: row.platform });
  return json({
    status: 'authorized',
    session: sessionBody(tokens),
    user: { id: userId, username: identity.username },
  }, requestId);
}

async function upsertUser(env: Env, traktUuid: string, username: string): Promise<string> {
  const at = now();
  const row = await env.DB.prepare(
    `INSERT INTO users (id, trakt_uuid, trakt_username, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(trakt_uuid) DO UPDATE SET trakt_username = excluded.trakt_username,
       updated_at = excluded.updated_at
     RETURNING id`,
  ).bind(crypto.randomUUID(), traktUuid, username, at, at).first<{ id: string }>();
  if (!row) throw new ApiError(500, 'internal', 'Could not save the account.');
  return row.id;
}

/** POST /auth/refresh */
export async function refresh(env: Env, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  const tokens = await refreshSession(env, shortText(body.refreshToken, 64));
  return json({ session: sessionBody(tokens) }, requestId);
}

/** POST /auth/logout: ends this device's session. */
export async function logout(env: Env, principal: Principal, requestId: string) {
  await revokeSession(env, principal.sessionId);
  await audit(env, 'auth.logged_out', principal);
  return json({ ok: true }, requestId);
}

/** POST /auth/logout-all: ends every session of the account. */
export async function logoutAll(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  await revokeAllSessions(env, principal.userId);
  await audit(env, 'auth.logged_out_all', principal);
  return json({ ok: true }, requestId);
}

/** GET /me */
export async function me(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  const user = await env.DB.prepare(`SELECT id, trakt_username, created_at FROM users WHERE id = ?`)
    .bind(principal.userId).first<{ id: string; trakt_username: string; created_at: number }>();
  if (!user) throw new ApiError(401, 'session_revoked', 'Sign in again.');
  const trakt = await env.DB.prepare(`SELECT 1 AS linked FROM trakt_credentials WHERE user_id = ?`)
    .bind(principal.userId).first();
  return json({
    user: { id: user.id, username: user.trakt_username, createdAt: user.created_at },
    traktLinked: !!trakt,
    sessionId: principal.sessionId,
  }, requestId);
}

/** GET /sessions: this account's signed-in devices. */
export async function listSessions(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  const { results } = await env.DB.prepare(
    `SELECT id, device_name, platform, created_at, last_used_at FROM sessions
     WHERE user_id = ? AND revoked_at IS NULL AND refresh_expires_at > ?
     ORDER BY last_used_at DESC LIMIT 50`,
  ).bind(principal.userId, now()).all<{ id: string; device_name: string; platform: string; created_at: number; last_used_at: number }>();
  return json({
    sessions: results.map((row) => ({
      id: row.id,
      deviceName: row.device_name,
      platform: row.platform,
      createdAt: row.created_at,
      lastUsedAt: row.last_used_at,
      current: row.id === principal.sessionId,
    })),
  }, requestId);
}

/** DELETE /sessions/:id: signs out one of the account's own devices. */
export async function deleteSession(env: Env, principal: Principal, sessionId: string, requestId: string) {
  await requireLiveSession(env, principal);
  const result = await env.DB.prepare(
    `UPDATE sessions SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL`,
  ).bind(now(), sessionId, principal.userId).run();
  // Another account's session id answers exactly like an unknown one.
  if ((result.meta.changes ?? 0) !== 1) throw new ApiError(404, 'not_found', 'Session not found.');
  await audit(env, 'auth.session_revoked', { userId: principal.userId, sessionId });
  return json({ ok: true }, requestId);
}

/** DELETE /me: revokes Trakt access and deletes the account and sessions. */
export async function deleteAccount(env: Env, principal: Principal, requestId: string, deps: TraktDeps = {}) {
  await requireLiveSession(env, principal);
  await forgetTraktTokens(env, principal.userId, deps);
  await env.DB.prepare(`DELETE FROM users WHERE id = ?`).bind(principal.userId).run();
  await audit(env, 'account.deleted', { userId: principal.userId });
  return json({ ok: true }, requestId);
}
