// Trakt's OAuth endpoints and account lookup, and custody of each user's
// Trakt tokens (encrypted in D1, refreshed with optimistic locking since
// Trakt returns a new refresh token on every refresh).

import { decrypt, encrypt } from './crypto';
import type { Env } from './env';
import { ApiError } from './http';
import { audit, log } from './audit';

const timeoutMs = 10_000;
/** Trakt rate limits in bursts; a short Retry-After is waited out. */
const maxAttempts = 3;
const maxRetryWaitMs = 3_000;
/** Refresh this long before Trakt's expiry. */
const refreshMarginSeconds = 5 * 60;

export interface TraktTokens {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  created_at: number;
  scope?: string;
}

export interface DeviceCode {
  device_code: string;
  user_code: string;
  verification_url: string;
  expires_in: number;
  interval: number;
}

export interface TraktIdentity {
  uuid: string;
  username: string;
}

export type DevicePoll =
  | { kind: 'authorized'; tokens: TraktTokens }
  | { kind: 'pending' }
  | { kind: 'slow_down' }
  | { kind: 'invalid' | 'used' | 'expired' | 'denied' };

export interface TraktDeps {
  fetch?: typeof fetch;
  wait?: (ms: number) => Promise<void>;
}

async function call(
  env: Env,
  path: string,
  init: { method: 'GET' | 'POST'; body?: unknown; accessToken?: string; retryRateLimit?: boolean },
  deps: TraktDeps,
): Promise<Response> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'User-Agent': 'Reelish-API/1.0',
    'trakt-api-version': '2',
    'trakt-api-key': env.TRAKT_CLIENT_ID,
  };
  if (init.accessToken) headers.Authorization = `Bearer ${init.accessToken}`;
  const wait = deps.wait ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  for (let attempt = 1; ; attempt++) {
    let response: Response;
    try {
      response = await (deps.fetch ?? fetch)(`${env.TRAKT_API_URL}${path}`, {
        method: init.method,
        headers,
        body: init.body === undefined ? undefined : JSON.stringify(init.body),
        redirect: 'manual',
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (error) {
      log('warn', 'trakt.unreachable', { path, message: String(error) });
      throw new ApiError(502, 'trakt_unavailable', 'Trakt is not responding.');
    }
    // A rate-limited request was refused before Trakt acted on it (an
    // authorization code stays unused), so it is safe to send again.
    if (response.status !== 429 || init.retryRateLimit === false || attempt >= maxAttempts) {
      return response;
    }
    const retryAfter = Number(response.headers.get('Retry-After') ?? '1');
    const delay = Math.max(Number.isFinite(retryAfter) ? retryAfter : 1, 1) * 1000;
    if (delay > maxRetryWaitMs) {
      log('warn', 'trakt.rate_limited_long', { path, retryAfterMs: delay });
      return response;
    }
    log('info', 'trakt.rate_limited', { path, attempt, retryAfterMs: delay });
    await response.body?.cancel();
    await wait(delay);
  }
}

async function jsonOf<T>(response: Response, path: string): Promise<T> {
  try {
    return (await response.json()) as T;
  } catch {
    log('warn', 'trakt.unreadable', { path, status: response.status });
    throw new ApiError(502, 'trakt_unavailable', 'Trakt sent an unreadable response.');
  }
}

export async function startDeviceCode(env: Env, deps: TraktDeps = {}): Promise<DeviceCode> {
  const response = await call(env, '/oauth/device/code', {
    method: 'POST',
    body: { client_id: env.TRAKT_CLIENT_ID },
  }, deps);
  if (!response.ok) {
    log('warn', 'trakt.device_code_failed', { status: response.status });
    throw new ApiError(502, 'trakt_unavailable', 'Could not start Trakt sign-in.');
  }
  const code = await jsonOf<DeviceCode>(response, '/oauth/device/code');
  if (
    typeof code.device_code !== 'string' || typeof code.user_code !== 'string' ||
    typeof code.verification_url !== 'string' || !/^https:\/\/([a-z0-9-]+\.)*trakt\.tv\//.test(code.verification_url) ||
    !(code.expires_in > 0) || !(code.interval > 0)
  ) {
    throw new ApiError(502, 'trakt_unavailable', 'Trakt sent an unexpected response.');
  }
  return code;
}

/** Trakt's documented device-token statuses, mapped to outcomes. */
export async function pollDeviceToken(env: Env, deviceCode: string, deps: TraktDeps = {}): Promise<DevicePoll> {
  const response = await call(env, '/oauth/device/token', {
    method: 'POST',
    body: { code: deviceCode, client_id: env.TRAKT_CLIENT_ID, client_secret: env.TRAKT_CLIENT_SECRET },
    // Here 429 is Trakt's "slow down" answer to the app's polling.
    retryRateLimit: false,
  }, deps);
  switch (response.status) {
    case 200:
      return { kind: 'authorized', tokens: validTokens(await jsonOf<TraktTokens>(response, '/oauth/device/token')) };
    case 400: return { kind: 'pending' };
    case 404: return { kind: 'invalid' };
    case 409: return { kind: 'used' };
    case 410: return { kind: 'expired' };
    case 418: return { kind: 'denied' };
    case 429: return { kind: 'slow_down' };
    default:
      log('warn', 'trakt.device_token_failed', { status: response.status });
      throw new ApiError(502, 'trakt_unavailable', 'Trakt is not available right now.');
  }
}

/**
 * Exchanges a browser sign-in's authorization code (with its PKCE
 * verifier and the client secret). Null when Trakt rejects the code:
 * used, expired, or issued for another redirect or verifier.
 */
export async function exchangeAuthorizationCode(
  env: Env,
  code: string,
  verifier: string,
  redirectUri: string,
  deps: TraktDeps = {},
): Promise<TraktTokens | null> {
  const response = await call(env, '/oauth/token', {
    method: 'POST',
    body: {
      code,
      client_id: env.TRAKT_CLIENT_ID,
      client_secret: env.TRAKT_CLIENT_SECRET,
      redirect_uri: redirectUri,
      grant_type: 'authorization_code',
      code_verifier: verifier,
    },
  }, deps);
  if (response.status === 200) {
    return validTokens(await jsonOf<TraktTokens>(response, '/oauth/token'));
  }
  log('warn', 'trakt.code_exchange_failed', { status: response.status });
  if (response.status === 400 || response.status === 401) return null;
  throw new ApiError(502, 'trakt_unavailable', 'Trakt is not available right now.');
}

function validTokens(tokens: TraktTokens): TraktTokens {
  if (
    typeof tokens.access_token !== 'string' || typeof tokens.refresh_token !== 'string' ||
    !(tokens.expires_in > 0) || !(tokens.created_at > 0)
  ) {
    throw new ApiError(502, 'trakt_unavailable', 'Trakt sent an unexpected response.');
  }
  return tokens;
}

/** The signed-in Trakt account; its UUID is the stable identity key. */
export async function fetchIdentity(env: Env, accessToken: string, deps: TraktDeps = {}): Promise<TraktIdentity> {
  const response = await call(env, '/users/settings', { method: 'GET', accessToken }, deps);
  if (!response.ok) {
    log('warn', 'trakt.identity_failed', { status: response.status });
    throw new ApiError(502, 'trakt_unavailable', 'Could not read the Trakt account.');
  }
  const settings = await jsonOf<{ user?: { username?: unknown; ids?: { uuid?: unknown } } }>(response, '/users/settings');
  const uuid = settings.user?.ids?.uuid;
  const username = settings.user?.username;
  // Without Trakt's stable id the account cannot be keyed safely.
  if (typeof uuid !== 'string' || !/^[A-Za-z0-9-]{8,64}$/.test(uuid) || typeof username !== 'string') {
    throw new ApiError(502, 'trakt_identity_unavailable', 'Trakt did not return an account id.');
  }
  return { uuid, username: username.slice(0, 100) };
}

const aadFor = (userId: string, field: string) => `trakt:${userId}:${field}`;

/** Stores (or replaces) the user's Trakt tokens, encrypted. */
/** The redirect URI device grants are refreshed with. */
export const outOfBand = 'urn:ietf:wg:oauth:2.0:oob';

/**
 * Stores a new grant. [redirectUri] is the one it was issued for (the
 * API's callback for browser sign-ins, [outOfBand] for device sign-ins);
 * refreshing names it.
 */
export async function saveTraktTokens(env: Env, userId: string, tokens: TraktTokens, redirectUri: string): Promise<void> {
  const at = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `INSERT INTO trakt_credentials (user_id, access_token_enc, refresh_token_enc, expires_at, scope, version,
       updated_at, redirect_uri)
     VALUES (?, ?, ?, ?, ?, 1, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET access_token_enc = excluded.access_token_enc,
       refresh_token_enc = excluded.refresh_token_enc, expires_at = excluded.expires_at,
       scope = excluded.scope, version = trakt_credentials.version + 1, updated_at = excluded.updated_at,
       redirect_uri = excluded.redirect_uri`,
  ).bind(
    userId,
    await encrypt(env.TOKEN_ENCRYPTION_KEY, tokens.access_token, aadFor(userId, 'access')),
    await encrypt(env.TOKEN_ENCRYPTION_KEY, tokens.refresh_token, aadFor(userId, 'refresh')),
    tokens.created_at + tokens.expires_in,
    tokens.scope ?? '',
    at,
    redirectUri,
  ).run();
}

/** Calls Trakt's API as the user, with their access token. */
export async function traktApi(
  env: Env,
  accessToken: string,
  path: string,
  init: { method: 'GET' | 'POST'; body?: unknown },
  deps: TraktDeps = {},
): Promise<Response> {
  return call(env, path, { ...init, accessToken }, deps);
}

interface CredentialRow {
  access_token_enc: string;
  refresh_token_enc: string;
  expires_at: number;
  version: number;
  redirect_uri: string;
}

/**
 * The redirect URIs to refresh a grant with, the one it was issued for
 * first. Grants saved before that was recorded try the API's callback and
 * then out-of-band.
 */
function refreshRedirects(env: Env, stored: string): string[] {
  const callback = env.PUBLIC_URL ? `${env.PUBLIC_URL.trim()}/api/v1/auth/web/callback` : '';
  return [...new Set([stored, callback, outOfBand].filter(Boolean))];
}

/**
 * A valid Trakt access token for [userId], refreshing it when close to
 * expiry. Concurrent refreshes are settled by the row version: the loser
 * re-reads the winner's token instead of using a spent refresh token.
 */
export async function traktAccessToken(env: Env, userId: string, deps: TraktDeps = {}): Promise<string> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const row = await env.DB.prepare(
      `SELECT access_token_enc, refresh_token_enc, expires_at, version, redirect_uri
       FROM trakt_credentials WHERE user_id = ?`,
    ).bind(userId).first<CredentialRow>();
    if (!row) throw reauthRequired();
    const now = Math.floor(Date.now() / 1000);
    if (row.expires_at - refreshMarginSeconds > now) {
      return decrypt(env.TOKEN_ENCRYPTION_KEY, row.access_token_enc, aadFor(userId, 'access'));
    }
    const refreshToken = await decrypt(env.TOKEN_ENCRYPTION_KEY, row.refresh_token_enc, aadFor(userId, 'refresh'));
    // A redirect URI Trakt does not accept for this grant is refused before
    // the refresh token is used, so the next one can be tried.
    let response: Response | undefined;
    let redirectUri = '';
    for (const candidate of refreshRedirects(env, row.redirect_uri)) {
      redirectUri = candidate;
      response = await call(env, '/oauth/token', {
        method: 'POST',
        body: {
          refresh_token: refreshToken,
          client_id: env.TRAKT_CLIENT_ID,
          client_secret: env.TRAKT_CLIENT_SECRET,
          redirect_uri: candidate,
          grant_type: 'refresh_token',
        },
      }, deps);
      if (response.status !== 400 && response.status !== 401) break;
    }
    if (!response) throw reauthRequired();
    if (response.status === 400 || response.status === 401) {
      // Revoked at Trakt, or the refresh token was already spent elsewhere.
      const current = await env.DB.prepare(`SELECT version FROM trakt_credentials WHERE user_id = ?`)
        .bind(userId).first<{ version: number }>();
      if (current && current.version !== row.version) continue;
      await env.DB.prepare(`DELETE FROM trakt_credentials WHERE user_id = ? AND version = ?`)
        .bind(userId, row.version).run();
      await audit(env, 'trakt.reauth_required', { userId });
      throw reauthRequired();
    }
    if (!response.ok) {
      log('warn', 'trakt.refresh_failed', { status: response.status });
      throw new ApiError(502, 'trakt_unavailable', 'Trakt is not available right now.');
    }
    const tokens = validTokens(await jsonOf<TraktTokens>(response, '/oauth/token'));
    const result = await env.DB.prepare(
      `UPDATE trakt_credentials SET access_token_enc = ?, refresh_token_enc = ?, expires_at = ?,
         scope = ?, version = version + 1, updated_at = ?, redirect_uri = ?
       WHERE user_id = ? AND version = ?`,
    ).bind(
      await encrypt(env.TOKEN_ENCRYPTION_KEY, tokens.access_token, aadFor(userId, 'access')),
      await encrypt(env.TOKEN_ENCRYPTION_KEY, tokens.refresh_token, aadFor(userId, 'refresh')),
      tokens.created_at + tokens.expires_in,
      tokens.scope ?? '',
      now,
      redirectUri,
      userId,
      row.version,
    ).run();
    if ((result.meta.changes ?? 0) === 1) return tokens.access_token;
    // Another request refreshed first; use its token on the next pass.
  }
  throw new ApiError(503, 'trakt_busy', 'Trakt sign-in is being refreshed; try again.');
}

/** Revokes the stored Trakt token at Trakt (best effort) and forgets it. */
export async function forgetTraktTokens(env: Env, userId: string, deps: TraktDeps = {}): Promise<void> {
  const row = await env.DB.prepare(`SELECT access_token_enc FROM trakt_credentials WHERE user_id = ?`)
    .bind(userId).first<{ access_token_enc: string }>();
  if (row) {
    try {
      const token = await decrypt(env.TOKEN_ENCRYPTION_KEY, row.access_token_enc, aadFor(userId, 'access'));
      const response = await call(env, '/oauth/revoke', {
        method: 'POST',
        body: { token, client_id: env.TRAKT_CLIENT_ID, client_secret: env.TRAKT_CLIENT_SECRET },
      }, deps);
      if (!response.ok) log('warn', 'trakt.revoke_failed', { status: response.status });
    } catch (error) {
      log('warn', 'trakt.revoke_failed', { message: String(error) });
    }
  }
  await env.DB.prepare(`DELETE FROM trakt_credentials WHERE user_id = ?`).bind(userId).run();
}

function reauthRequired(): ApiError {
  return new ApiError(401, 'trakt_reauth_required', 'Sign in to Trakt again.');
}
