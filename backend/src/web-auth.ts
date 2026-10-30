// Browser sign-in: Trakt's authorization-code flow with PKCE. The app
// opens Trakt in the browser, Trakt returns the browser to this Worker's
// callback, and the app collects its session by polling, as with a code.
// The Trakt code and tokens never reach the device.

import { decrypt, encrypt, randomToken, sha256 } from './crypto';
import type { Env } from './env';
import { ApiError, json, readJsonBody, shortText } from './http';
import { audit, log } from './audit';
import { createSession } from './sessions';
import { deviceFrom, sessionBody, upsertUser } from './auth';
import { exchangeAuthorizationCode, fetchIdentity, saveTraktTokens, type TraktDeps } from './trakt';

const now = () => Math.floor(Date.now() / 1000);
const lifetimeSeconds = 10 * 60;
/** Polls per minute stay well inside AUTH_LIMITER's 20. */
const pollIntervalSeconds = 4;
const tokenPattern = /^[A-Za-z0-9_-]{43}$/;

export const callbackPath = '/api/v1/auth/web/callback';

function callbackUrl(env: Env): string {
  const origin = env.PUBLIC_URL?.trim();
  if (!origin || !/^https:\/\/[a-z0-9.-]+$/.test(origin)) {
    throw new ApiError(503, 'web_sign_in_unavailable', 'Browser sign-in is not available; use a code.');
  }
  return `${origin}${callbackPath}`;
}

/** POST /auth/web/start: the Trakt page to open, and a token to poll with. */
export async function startWeb(env: Env, request: Request, requestId: string) {
  const redirectUri = callbackUrl(env);
  const device = deviceFrom(await readJsonBody(request));
  const state = randomToken();
  const pollToken = randomToken();
  const verifier = randomToken();
  const stateHash = await sha256(state);
  const at = now();
  await env.DB.prepare(`DELETE FROM web_authorizations WHERE expires_at < ?`).bind(at).run();
  await env.DB.prepare(
    `INSERT INTO web_authorizations (state_hash, poll_hash, verifier_enc, device_name,
       platform, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    stateHash,
    await sha256(pollToken),
    await encrypt(env.TOKEN_ENCRYPTION_KEY, verifier, `web:${stateHash}`),
    device.name,
    device.platform,
    at + lifetimeSeconds,
    at,
  ).run();
  const authorize = new URL(env.TRAKT_AUTHORIZE_URL);
  authorize.search = new URLSearchParams({
    response_type: 'code',
    client_id: env.TRAKT_CLIENT_ID,
    redirect_uri: redirectUri,
    state,
    // S256: the challenge is the verifier's SHA-256, base64url.
    code_challenge: await sha256(verifier),
    code_challenge_method: 'S256',
  }).toString();
  return json({
    pollToken,
    authorizeUrl: authorize.toString(),
    expiresIn: lifetimeSeconds,
    interval: pollIntervalSeconds,
  }, requestId);
}

interface WebRow {
  state_hash: string;
  verifier_enc: string;
  status: string;
  user_id: string | null;
  device_name: string;
  platform: string;
  expires_at: number;
}

/**
 * GET /auth/web/callback: where Trakt returns the browser. Answers with a
 * small page, never JSON, and never echoes the query back. Each state is
 * claimed once, so a replayed or reloaded link does nothing.
 */
export async function webCallback(env: Env, url: URL, deps: TraktDeps = {}): Promise<Response> {
  const state = url.searchParams.get('state') ?? '';
  const code = url.searchParams.get('code') ?? '';
  if (!tokenPattern.test(state)) return page('expired');
  const stateHash = await sha256(state);
  const at = now();
  const claimed = await env.DB.prepare(
    `UPDATE web_authorizations SET status = 'exchanging'
     WHERE state_hash = ? AND status = 'pending' AND expires_at > ?
     RETURNING state_hash, verifier_enc, status, user_id, device_name, platform, expires_at`,
  ).bind(stateHash, at).first<WebRow>();
  if (!claimed) return page('expired');
  const finish = (status: 'authorized' | 'denied' | 'failed', userId: string | null = null) =>
    env.DB.prepare(`UPDATE web_authorizations SET status = ?, user_id = ? WHERE state_hash = ?`)
      .bind(status, userId, stateHash).run();

  if (url.searchParams.has('error') || !code || code.length > 512) {
    await finish('denied');
    return page('denied');
  }
  try {
    const verifier = await decrypt(env.TOKEN_ENCRYPTION_KEY, claimed.verifier_enc, `web:${stateHash}`);
    const tokens = await exchangeAuthorizationCode(env, code, verifier, callbackUrl(env), deps);
    if (!tokens) {
      await finish('failed');
      return page('failed');
    }
    const identity = await fetchIdentity(env, tokens.access_token, deps);
    const userId = await upsertUser(env, identity.uuid, identity.username);
    await saveTraktTokens(env, userId, tokens, callbackUrl(env));
    await finish('authorized', userId);
    await audit(env, 'auth.web_approved', { userId, detail: claimed.platform });
    return page('approved');
  } catch (error) {
    log('warn', 'auth.web_callback_failed', {
      code: error instanceof ApiError ? error.code : 'internal',
    });
    await finish('failed');
    return page('failed');
  }
}

/** POST /auth/web/poll: pending until the browser comes back, then a session. */
export async function pollWeb(env: Env, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  const pollToken = shortText(body.pollToken, 64);
  if (!tokenPattern.test(pollToken)) {
    throw new ApiError(400, 'invalid_poll_token', 'Unknown sign-in.');
  }
  const pollHash = await sha256(pollToken);
  const row = await env.DB.prepare(
    `SELECT state_hash, verifier_enc, status, user_id, device_name, platform, expires_at
     FROM web_authorizations WHERE poll_hash = ?`,
  ).bind(pollHash).first<WebRow>();
  if (!row) throw new ApiError(404, 'unknown_sign_in', 'Sign-in not found; start again.');
  const remove = () => env.DB.prepare(`DELETE FROM web_authorizations WHERE poll_hash = ?`).bind(pollHash).run();

  if (row.status === 'denied') {
    await remove();
    throw new ApiError(403, 'sign_in_denied', 'Sign-in was declined on Trakt.');
  }
  if (row.status === 'failed') {
    await remove();
    throw new ApiError(502, 'sign_in_failed', 'Trakt sign-in did not complete; start again.');
  }
  if (row.status !== 'authorized' || !row.user_id) {
    if (row.expires_at <= now()) {
      await remove();
      throw new ApiError(410, 'sign_in_expired', 'The sign-in expired; start again.');
    }
    return json({ status: 'pending', interval: pollIntervalSeconds }, requestId, 202,
      { 'Retry-After': String(pollIntervalSeconds) });
  }

  // Claim before issuing: a concurrent poll finds nothing.
  const claimed = await env.DB.prepare(
    `DELETE FROM web_authorizations WHERE poll_hash = ? AND status = 'authorized'`,
  ).bind(pollHash).run();
  if ((claimed.meta.changes ?? 0) !== 1) {
    throw new ApiError(410, 'sign_in_expired', 'The sign-in expired; start again.');
  }
  const user = await env.DB.prepare(`SELECT id, trakt_username FROM users WHERE id = ?`)
    .bind(row.user_id).first<{ id: string; trakt_username: string }>();
  if (!user) throw new ApiError(410, 'sign_in_expired', 'The sign-in expired; start again.');
  const tokens = await createSession(env, user.id, { name: row.device_name, platform: row.platform });
  await audit(env, 'auth.signed_in', { userId: user.id, sessionId: tokens.sessionId, detail: `${row.platform}:web` });
  return json({
    status: 'authorized',
    session: sessionBody(tokens),
    user: { id: user.id, username: user.trakt_username },
  }, requestId);
}

type Outcome = 'approved' | 'denied' | 'expired' | 'failed';

const pages: Record<Outcome, { title: string; body: string }> = {
  approved: {
    title: 'You’re signed in',
    body: 'Go back to Reelish to continue. You can close this tab.',
  },
  denied: {
    title: 'Sign-in cancelled',
    body: 'Reelish was not given access. Go back to Reelish to try again.',
  },
  expired: {
    title: 'This link has expired',
    body: 'It was already used or is too old. Start again in Reelish.',
  },
  failed: {
    title: 'Sign-in didn’t finish',
    body: 'Trakt could not complete the sign-in. Go back to Reelish and try again.',
  },
};

/** A fixed page per outcome: no scripts, no links, nothing from the request. */
function page(outcome: Outcome): Response {
  const { title, body } = pages[outcome];
  const accent = outcome === 'approved' ? '#3ddc97' : '#ff4d6d';
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Reelish · ${title}</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0b0f;color:#f4f4f6;
font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;padding:24px;box-sizing:border-box}
main{max-width:420px;text-align:center;padding:32px 28px;border-radius:24px;background:#16161d;border:1px solid #2a2a33}
.brand{letter-spacing:.18em;font-weight:800;font-size:14px;color:#ff4d6d;margin-bottom:20px}
.dot{width:12px;height:12px;border-radius:50%;background:${accent};margin:0 auto 16px;box-shadow:0 0 24px ${accent}}
h1{font-size:24px;margin:0 0 8px}p{margin:0;color:#a6a6b2}
</style></head><body><main><div class="brand">REELISH</div><div class="dot"></div>
<h1>${title}</h1><p>${body}</p></main></body></html>`;
  return new Response(html, {
    status: outcome === 'approved' ? 200 : 400,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      'X-Frame-Options': 'DENY',
      'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    },
  });
}
