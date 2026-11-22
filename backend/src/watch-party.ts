// Watch party routes: create a room, preview it by code, and open a
// participant's WebSocket. The Worker authenticates the Reelish session;
// the room (a Durable Object per code) only ever sees the verified user id.

import { isFounder } from './badges';
import { equippedFrame } from './frames';
import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { log } from './audit';
import { invalidLinkPage, linkPage } from './links';
import { requireLiveSession, type Principal } from './sessions';
import { cleanContent, cleanProfile, maxCapacity, roomLifetimeMs, type JoinCheck, type WatchPartyRoom } from './party-room';

export const codePattern = /^\d{8}$/;
const createAttempts = 5;
/**
 * Rooms one account may create per hour. Far above a real movie night (a
 * wrong title, a restart), and it keeps one account from spending the Free
 * plan's daily Durable Object budget that every party shares.
 */
export const hostQuotaPerHour = 12;
const quotaWindowSeconds = 60 * 60;
const roomLifetimeSeconds = roomLifetimeMs / 1000;

/** A uniformly random 8-digit code (leading zeros allowed). */
export function newCode(): string {
  const limit = 4_200_000_000; // a multiple of 10^8 below 2^32: no modulo bias
  const buffer = new Uint32Array(1);
  for (;;) {
    crypto.getRandomValues(buffer);
    if (buffer[0] < limit) return String(buffer[0] % 100_000_000).padStart(8, '0');
  }
}

function room(env: Env, code: string): DurableObjectStub<WatchPartyRoom> {
  return env.PARTY_ROOMS.get(env.PARTY_ROOMS.idFromName(`party:${code}`));
}

/** Room calls fail when a Free plan daily limit is spent; say so plainly. */
async function guarded<T>(work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof ApiError) throw error;
    log('warn', 'party.room_unavailable', { message: String(error).slice(0, 200) });
    throw new ApiError(503, 'party_unavailable', 'Watch Party is unavailable right now. Try again later.', {
      'Retry-After': '300',
    });
  }
}

/**
 * POST /party: a new room hosted by the caller, ending their previous one.
 * Hosting, like joining (connectParty), is open to every signed-in account:
 * no entitlement is checked.
 */
export async function createParty(env: Env, principal: Principal, request: Request, requestId: string) {
  // As for joining: a signed-out or deleted account cannot host either.
  await requireLiveSession(env, principal);
  const body = await readJsonBody(request);
  const content = cleanContent(body.content);
  if (!content) throw new ApiError(400, 'invalid_content', 'Choose a movie or an episode.');
  const raw = (body.settings && typeof body.settings === 'object' ? body.settings : {}) as Record<string, unknown>;
  const max = maxCapacity(env);
  const capacity = typeof raw.capacity === 'number' && Number.isInteger(raw.capacity)
    ? Math.min(Math.max(raw.capacity, 2), max)
    : max;
  const settings = {
    capacity,
    guestControl: raw.guestControl === true,
    waitForAll: raw.waitForAll !== false,
  };
  const host = cleanProfile(body.profile);

  const now = Math.floor(Date.now() / 1000);
  const previous = await env.DB.prepare(
    `SELECT code, window_start, window_count FROM party_hosts WHERE user_id = ?`,
  ).bind(principal.userId).first<{ code: string; window_start: number; window_count: number }>();
  // Before anything changes: a refused request ends nothing.
  if (previous && now < previous.window_start + quotaWindowSeconds && previous.window_count >= hostQuotaPerHour) {
    const wait = previous.window_start + quotaWindowSeconds - now;
    log('info', 'party.quota_reached', { requestId });
    throw new ApiError(
      429,
      'party_quota',
      `You’ve started a lot of parties this hour. Try again in ${Math.ceil(wait / 60)} min.`,
      { 'Retry-After': String(wait) },
    );
  }
  if (previous) await guarded(() => room(env, previous.code).endIfHost(principal.userId));

  for (let attempt = 0; attempt < createAttempts; attempt++) {
    const code = newCode();
    const created = await guarded(() =>
      room(env, code).create({ code, hostUserId: principal.userId, host, content, settings }));
    if (!created.ok) continue;
    // The code is indexed only now, but nobody has it before this response.
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO party_hosts (user_id, code, created_at, window_start, window_count) VALUES (?1, ?2, ?3, ?3, 1)
         ON CONFLICT(user_id) DO UPDATE SET
           code = excluded.code,
           created_at = excluded.created_at,
           window_count = CASE WHEN ?3 >= party_hosts.window_start + ?4 THEN 1 ELSE party_hosts.window_count + 1 END,
           window_start = CASE WHEN ?3 >= party_hosts.window_start + ?4 THEN ?3 ELSE party_hosts.window_start END`,
      ).bind(principal.userId, code, now, quotaWindowSeconds),
      env.DB.prepare(
        `INSERT INTO party_codes (code, created_at) VALUES (?, ?)
         ON CONFLICT(code) DO UPDATE SET created_at = excluded.created_at`,
      ).bind(code, now),
    ]);
    log('info', 'party.created', { requestId });
    return json({ code, expiresAt: created.expiresAt, settings }, requestId, 201);
  }
  throw new ApiError(503, 'party_unavailable', 'Could not create a party. Try again.');
}

const notFound = () => new ApiError(404, 'party_not_found', 'No party has that code. Check it and try again.');

/**
 * Whether [code] belongs to a room that may still be open. Answered from D1,
 * so a guess, a typo or an ended room never wakes a Durable Object.
 */
async function issued(env: Env, code: string): Promise<boolean> {
  const row = await env.DB.prepare(`SELECT 1 AS found FROM party_codes WHERE code = ? AND created_at > ?`)
    .bind(code, Math.floor(Date.now() / 1000) - roomLifetimeSeconds)
    .first<{ found: number }>();
  return row !== null;
}

/** Daily cron: forgets codes older than a room's lifetime; returns how many. */
export async function prunePartyCodes(env: Env, nowSeconds = Math.floor(Date.now() / 1000)): Promise<number> {
  const result = await env.DB.prepare(`DELETE FROM party_codes WHERE created_at <= ?`)
    .bind(nowSeconds - roomLifetimeSeconds)
    .run();
  const deleted = result.meta.changes ?? 0;
  log('info', 'retention.party_codes_pruned', { deleted });
  return deleted;
}

/** GET /party/{code}: what the room plays and who hosts it, before joining. */
export async function previewParty(env: Env, code: string, requestId: string) {
  if (!await issued(env, code)) throw notFound();
  const preview = await guarded(() => room(env, code).preview());
  if (!preview) throw notFound();
  return json(preview, requestId);
}

const joinErrors: Record<Exclude<JoinCheck, 'ok'>, () => ApiError> = {
  not_found: notFound,
  full: () => new ApiError(409, 'party_full', 'This party is full.'),
  removed: () => new ApiError(403, 'party_removed', 'The host removed you from this party.'),
};

/**
 * GET /join/{code}: the page an invitation link opens. Public and fixed: it
 * never asks the room anything, so it reveals nothing about which codes are
 * in use and costs no room request. Its button opens `reelish://party/{code}`,
 * where the app checks the room and asks before joining, as for a typed code.
 */
export function invitePage(code: string, userAgent: string | null = null): Response {
  // The same page as Reelish Connect's /party/{code} link (src/links.ts).
  return codePattern.test(code)
    ? linkPage({ kind: 'party', code }, userAgent)
    : invalidLinkPage();
}

/**
 * GET /party/{code}/socket: upgrades to the room's WebSocket. Only the
 * verified user id is passed on; anything else the client sent is dropped.
 */
export async function connectParty(env: Env, principal: Principal, request: Request, code: string) {
  if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
    throw new ApiError(426, 'upgrade_required', 'Expected a WebSocket.', { Upgrade: 'websocket' });
  }
  // A signed-out or deleted account cannot join with a still-valid token.
  await requireLiveSession(env, principal);
  if (!await issued(env, code)) throw notFound();
  const stub = room(env, code);
  const headers = new Headers();
  for (const name of ['Upgrade', 'Connection', 'Sec-WebSocket-Key', 'Sec-WebSocket-Version', 'Sec-WebSocket-Extensions']) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  headers.set('X-Party-User', principal.userId);
  // Built here, from the account: the room trusts nothing a client sends.
  if (await isFounder(env, principal.userId)) headers.set('X-Party-Founder', '1');
  // The frame the account wears now, checked against its entitlement.
  const frame = await equippedFrame(env, principal.userId);
  if (frame) headers.set('X-Party-Frame', frame);
  // One room request: the room checks the join itself and answers a refusal
  // with its verdict, so no separate check() call is needed first.
  const response = await guarded(() => stub.fetch('https://party.internal/socket', { headers }));
  if (response.status === 101) return response;
  const verdict = (await response.text()) as Exclude<JoinCheck, 'ok'>;
  throw (joinErrors[verdict] ?? notFound)();
}
