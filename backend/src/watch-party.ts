// Watch party routes: create a room, preview it by code, and open a
// participant's WebSocket. The Worker authenticates the Reelish session;
// the room (a Durable Object per code) only ever sees the verified user id.

import { isFounder } from './badges';
import { equippedFrame } from './frames';
import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { log } from './audit';
import { requireLiveSession, type Principal } from './sessions';
import { requirePerk } from './entitlements';
import { cleanContent, cleanProfile, maxCapacity, type JoinCheck, type WatchPartyRoom } from './party-room';

export const codePattern = /^\d{8}$/;
const createAttempts = 5;

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
 * Hosting is for Reelish Supporters; joining (connectParty) is for everyone.
 */
export async function createParty(env: Env, principal: Principal, request: Request, requestId: string) {
  // As for joining: a signed-out or deleted account cannot host either.
  await requireLiveSession(env, principal);
  // A supporter perk, so the Founder has it too; decided from the account,
  // never the request. A room already open keeps going if support ends.
  await requirePerk(env, principal.userId, 'host_watch_party');
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

  const previous = await env.DB.prepare(`SELECT code FROM party_hosts WHERE user_id = ?`)
    .bind(principal.userId).first<{ code: string }>();
  if (previous) await guarded(() => room(env, previous.code).endIfHost(principal.userId));

  for (let attempt = 0; attempt < createAttempts; attempt++) {
    const code = newCode();
    const created = await guarded(() =>
      room(env, code).create({ code, hostUserId: principal.userId, host, content, settings }));
    if (!created.ok) continue;
    await env.DB.prepare(
      `INSERT INTO party_hosts (user_id, code, created_at) VALUES (?, ?, ?)
       ON CONFLICT(user_id) DO UPDATE SET code = excluded.code, created_at = excluded.created_at`,
    ).bind(principal.userId, code, Math.floor(Date.now() / 1000)).run();
    log('info', 'party.created', { requestId });
    return json({ code, expiresAt: created.expiresAt, settings }, requestId, 201);
  }
  throw new ApiError(503, 'party_unavailable', 'Could not create a party. Try again.');
}

const notFound = () => new ApiError(404, 'party_not_found', 'No party has that code. Check it and try again.');

/** GET /party/{code}: what the room plays and who hosts it, before joining. */
export async function previewParty(env: Env, code: string, requestId: string) {
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
export function invitePage(code: string): Response {
  const valid = codePattern.test(code);
  const shown = valid ? `${code.slice(0, 4)} ${code.slice(4)}` : '';
  const body = valid
    ? `<h1>You’re invited to a watch party</h1>
<p>Open the invitation in Reelish, or open Reelish, choose Join a party and enter the code.</p>
<div class="code">${shown}</div>
<a class="open" href="reelish://party/${code}">Open in Reelish</a>
<p class="small">Reelish checks the party when it opens. If it has ended, Reelish says so.</p>`
    : `<h1>This invitation isn’t valid</h1>
<p>Ask for the code instead, then open Reelish and choose Join a party.</p>`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Reelish · Watch party</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0b0f;color:#f4f4f6;
font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;padding:24px;box-sizing:border-box}
main{max-width:420px;text-align:center;padding:32px 28px;border-radius:24px;background:#16161d;border:1px solid #2a2a33}
.brand{letter-spacing:.18em;font-weight:800;font-size:14px;color:#ff4d6d;margin-bottom:20px}
h1{font-size:24px;margin:0 0 8px}p{margin:0 0 16px;color:#a6a6b2}
.code{font-size:36px;font-weight:800;letter-spacing:.12em;color:#ff4d6d;margin:8px 0 20px;font-variant-numeric:tabular-nums}
.open{display:inline-block;background:#ff4d6d;color:#0b0b0f;font-weight:800;text-decoration:none;padding:14px 28px;border-radius:999px;margin-bottom:20px}
.small{font-size:13px;margin:0}
</style></head><body><main><div class="brand">REELISH</div>${body}</main></body></html>`;
  return new Response(html, {
    status: valid ? 200 : 404,
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
  const stub = room(env, code);
  const verdict = await guarded(() => stub.check(principal.userId));
  if (verdict !== 'ok') throw joinErrors[verdict]();
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
  return guarded(() => stub.fetch('https://party.internal/socket', { headers }));
}
