// The Reelish Supporters Program. Buy Me a Coffee's signed webhooks are the only
// way a badge is earned, apart from the owner's reviewed grant
// (scripts/grant-supporter.mjs). The app can read its status and ask for a
// review, and can never set it.
//
// Buy Me a Coffee has no custom metadata and Reelish accounts have no email, so
// a donation names its account through a code the donor pastes into their
// message. docs/backend/supporters.md explains the flow.

import type { Env } from './env';
import { ApiError, json, readJsonBody, shortText } from './http';
import { audit, log } from './audit';
import { sha256 } from './crypto';
import { requireLiveSession, type Principal } from './sessions';

const provider = 'buymeacoffee';
const maxWebhookBytes = 64 * 1024;
const publicListLimit = 200;

/** No I, L, O, U, 0 or 1: a code is often copied by hand from a TV. */
const codeAlphabet = '23456789ABCDEFGHJKMNPQRSTVWXYZ';
const codePattern = new RegExp(
  `\\bRS[\\s-]*([${codeAlphabet}]{4})[\\s-]*([${codeAlphabet}]{4})\\b`,
  'i',
);

const now = () => Math.floor(Date.now() / 1000);

export function newSupportCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  // 30 divides 240 evenly, so dropping higher bytes leaves no bias.
  const chars: string[] = [];
  while (chars.length < 8) {
    for (const byte of bytes) {
      if (byte < 240 && chars.length < 8) chars.push(codeAlphabet[byte % 30]);
    }
    crypto.getRandomValues(bytes);
  }
  return `RS-${chars.slice(0, 4).join('')}-${chars.slice(4).join('')}`;
}

/** The code in a donor's message, however they typed its spacing or case. */
export function findSupportCode(note: unknown): string | null {
  if (typeof note !== 'string') return null;
  const match = codePattern.exec(note);
  return match ? `RS-${match[1].toUpperCase()}-${match[2].toUpperCase()}` : null;
}

function hexBytes(text: string): Uint8Array | null {
  if (!/^[0-9a-f]{64}$/i.test(text)) return null;
  return Uint8Array.from(text.match(/../g)!, (pair) => parseInt(pair, 16));
}

/** HMAC-SHA256 of the raw body, compared in constant time. */
async function signatureValid(secret: string, body: Uint8Array, header: string | null): Promise<boolean> {
  const signature = header ? hexBytes(header.trim()) : null;
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  );
  return crypto.subtle.verify('HMAC', key, signature, body);
}

type Kind = 'donation' | 'recurring' | 'membership';

/** Events that make someone a supporter; a shop purchase is not a donation. */
const earning: Record<string, Kind> = {
  'donation.created': 'donation',
  'recurring_donation.started': 'recurring',
  'membership.started': 'membership',
};

const donationReference = (kind: Kind, id: string) => sha256(`${provider}:${kind}:${id}`);

/** The provider's id for this payment or subscription. */
function paymentId(data: Record<string, unknown>): string | null {
  if (typeof data.id === 'number' && Number.isSafeInteger(data.id) && data.id > 0) {
    return String(data.id);
  }
  return typeof data.id === 'string' && /^[\w-]{1,64}$/.test(data.id) ? data.id : null;
}

const timestamp = (value: unknown, fallback: number) =>
  typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : fallback;

async function recordDonation(env: Env, kind: Kind, data: Record<string, unknown>): Promise<string> {
  const id = paymentId(data);
  if (!id) return 'ignored';
  if (kind === 'donation' && (data.status !== 'succeeded' || String(data.refunded) === 'true')) {
    return 'ignored';
  }
  const received = now();
  const donatedAt = timestamp(data.created_at ?? data.started_at, received);
  const code = findSupportCode(data.support_note);
  const owner = code
    ? await env.DB.prepare(`SELECT user_id FROM supporter_profiles WHERE support_code = ?`)
        .bind(code)
        .first<{ user_id: string }>()
    : null;
  const inserted = await env.DB.prepare(
    `INSERT INTO donations (provider, reference, kind, user_id, status, donated_at, received_at)
     VALUES (?, ?, ?, ?, 'verified', ?, ?)
     ON CONFLICT (provider, reference) DO NOTHING`,
  )
    .bind(provider, await donationReference(kind, id), kind, owner?.user_id ?? null, donatedAt, received)
    .run();
  // A retry, or a refund that arrived first: nothing changes.
  if (inserted.meta.changes === 0) return 'duplicate';
  if (!owner) return 'unattributed';
  await env.DB.prepare(
    `UPDATE supporter_profiles
     SET supporter_since = COALESCE(supporter_since, ?), claim_requested_at = NULL, updated_at = ?
     WHERE user_id = ?`,
  )
    .bind(donatedAt, received, owner.user_id)
    .run();
  await audit(env, 'supporter_verified', { userId: owner.user_id });
  return 'verified';
}

/**
 * A refund undoes the donation. The badge never expires, but it stands for a
 * donation that stands, so it goes when none is left.
 */
async function recordRefund(env: Env, data: Record<string, unknown>): Promise<string> {
  const id = paymentId(data);
  if (!id) return 'ignored';
  const reference = await donationReference('donation', id);
  const received = now();
  const row = await env.DB.prepare(
    `INSERT INTO donations (provider, reference, kind, status, donated_at, received_at)
     VALUES (?, ?, 'donation', 'refunded', ?, ?)
     ON CONFLICT (provider, reference) DO UPDATE SET status = 'refunded'
     RETURNING user_id`,
  )
    .bind(provider, reference, timestamp(data.created_at, received), received)
    .first<{ user_id: string | null }>();
  if (!row?.user_id) return 'refunded';
  await env.DB.prepare(
    `UPDATE supporter_profiles SET supporter_since = NULL, public_listed = 0, updated_at = ?2
     WHERE user_id = ?1 AND NOT EXISTS (
       SELECT 1 FROM donations WHERE user_id = ?1 AND status = 'verified'
     )`,
  )
    .bind(row.user_id, received)
    .run();
  await audit(env, 'supporter_refund', { userId: row.user_id });
  return 'refunded';
}

/**
 * POST /webhooks/buymeacoffee. Anything signed and understood answers 200, so
 * a harmless event never counts towards Buy Me a Coffee's automatic disabling
 * of a failing webhook. Nothing from the payload is logged.
 */
export async function buyMeACoffeeWebhook(env: Env, request: Request, requestId: string): Promise<Response> {
  const secret = env.BMC_WEBHOOK_SECRET;
  if (!secret) {
    throw new ApiError(503, 'supporters_unavailable', 'Webhooks are not configured.');
  }
  const body = new Uint8Array(await request.arrayBuffer());
  if (body.byteLength === 0 || body.byteLength > maxWebhookBytes) {
    throw new ApiError(400, 'invalid_webhook', 'Unexpected body.');
  }
  if (!(await signatureValid(secret, body, request.headers.get('x-signature-sha256')))) {
    log('warn', 'bmc_webhook_rejected', { requestId });
    throw new ApiError(401, 'invalid_signature', 'Signature does not match.');
  }
  let event: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(body));
    if (typeof parsed !== 'object' || parsed === null) throw new Error('not an object');
    event = parsed as Record<string, unknown>;
  } catch {
    throw new ApiError(400, 'invalid_webhook', 'Unexpected body.');
  }
  const type = typeof event.type === 'string' ? event.type : '';
  const data = event.data;
  // "Send test event" must never make a real supporter.
  const allowed = event.live_mode === true || env.SUPPORTERS_ACCEPT_TEST_EVENTS === 'true';
  let result = 'ignored';
  if (allowed && typeof data === 'object' && data !== null) {
    const fields = data as Record<string, unknown>;
    if (type in earning) result = await recordDonation(env, earning[type], fields);
    if (type === 'donation.refunded') result = await recordRefund(env, fields);
  }
  log('info', 'bmc_webhook', { requestId, type: type.slice(0, 40), result });
  return json({ received: true }, requestId);
}

interface ProfileRow {
  support_code: string;
  supporter_since: number | null;
  claim_requested_at: number | null;
  public_listed: number;
  public_name: string | null;
}

const profileColumns =
  'support_code, supporter_since, claim_requested_at, public_listed, public_name';

/** The account's row, created with its code the first time. */
async function ensureProfile(env: Env, userId: string): Promise<ProfileRow> {
  const read = () =>
    env.DB.prepare(`SELECT ${profileColumns} FROM supporter_profiles WHERE user_id = ?`)
      .bind(userId)
      .first<ProfileRow>();
  const existing = await read();
  if (existing) return existing;
  const time = now();
  // A code collision leaves no row; a concurrent request leaves one.
  for (let attempt = 0; attempt < 3; attempt++) {
    await env.DB.prepare(
      `INSERT OR IGNORE INTO supporter_profiles (user_id, support_code, created_at, updated_at)
       VALUES (?, ?, ?, ?)`,
    )
      .bind(userId, newSupportCode(), time, time)
      .run();
    const row = await read();
    if (row) return row;
  }
  throw new ApiError(500, 'internal', 'Could not prepare your supporter code.');
}

const statusBody = (row: ProfileRow) => ({
  code: row.support_code,
  status:
    row.supporter_since !== null
      ? 'verified'
      : row.claim_requested_at !== null
        ? 'pending'
        : 'none',
  since: row.supporter_since,
  recognition: { listed: row.public_listed === 1, name: row.public_name ?? '' },
});

/** GET /supporters/me */
export async function getStatus(env: Env, principal: Principal, requestId: string): Promise<Response> {
  return json(statusBody(await ensureProfile(env, principal.userId)), requestId);
}

/**
 * POST /supporters/claim: asks for a review of a donation made without the
 * code. It only ever shows as pending; the owner checks the donation and grants
 * the badge, so a claim proves nothing by itself.
 */
export async function requestReview(env: Env, principal: Principal, requestId: string): Promise<Response> {
  await requireLiveSession(env, principal);
  await ensureProfile(env, principal.userId);
  const time = now();
  await env.DB.prepare(
    `UPDATE supporter_profiles SET claim_requested_at = COALESCE(claim_requested_at, ?), updated_at = ?
     WHERE user_id = ? AND supporter_since IS NULL`,
  )
    .bind(time, time, principal.userId)
    .run();
  await audit(env, 'supporter_review_requested', principal);
  return json(statusBody(await ensureProfile(env, principal.userId)), requestId);
}

/** PUT /supporters/recognition: the opt-in place on the public list. */
export async function setRecognition(
  env: Env,
  principal: Principal,
  request: Request,
  requestId: string,
): Promise<Response> {
  await requireLiveSession(env, principal);
  const body = await readJsonBody(request);
  const listed = body.listed === true;
  const name = shortText(body.name, 40);
  if (listed && (name.length < 2 || /https?:|www\.|[@<>]/i.test(name))) {
    throw new ApiError(400, 'invalid_name', 'Choose a name of at least two characters.');
  }
  const profile = await ensureProfile(env, principal.userId);
  if (profile.supporter_since === null) {
    throw new ApiError(409, 'not_a_supporter', 'Only supporters appear on the list.');
  }
  await env.DB.prepare(
    `UPDATE supporter_profiles SET public_listed = ?, public_name = ?, updated_at = ? WHERE user_id = ?`,
  )
    .bind(listed ? 1 : 0, listed ? name : null, now(), principal.userId)
    .run();
  return json(statusBody(await ensureProfile(env, principal.userId)), requestId);
}

/** GET /supporters/public: only people who chose to appear, by chosen name. */
export async function publicList(env: Env, requestId: string): Promise<Response> {
  const { results } = await env.DB.prepare(
    `SELECT public_name, supporter_since FROM supporter_profiles
     WHERE public_listed = 1 AND supporter_since IS NOT NULL AND public_name IS NOT NULL
     ORDER BY supporter_since ASC LIMIT ?`,
  )
    .bind(publicListLimit)
    .all<{ public_name: string; supporter_since: number }>();
  return json(
    {
      supporters: results.map((row) => ({
        name: row.public_name,
        // The month is enough; an exact time could be matched to a donation.
        since: new Date(row.supporter_since * 1000).toISOString().slice(0, 7),
      })),
    },
    requestId,
  );
}
