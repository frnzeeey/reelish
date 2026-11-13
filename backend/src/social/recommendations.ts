// Recommendations: a title sent privately from one person to friends, with an
// optional short message. Each recipient must be a friend who accepts
// recommendations, with no block either way, checked here per recipient at
// the moment of sending. The card is a snapshot (title, year, TMDB artwork),
// so the inbox needs no TMDB request. A retry with the same clientId never
// sends twice; sending the same title to the same friend again refreshes it.
// docs/friends-activity/SECURITY_AND_PRIVACY.md.

import type { Env } from '../env';
import { audit } from '../audit';
import { artworkPattern } from '../collections';
import { ApiError, json, readJsonBody } from '../http';
import { requireLiveSession, type Principal } from '../sessions';
import { publicView } from './friends';
import { linkPattern, requireProfile } from './profiles';

/** Friends one send may name. */
export const maxRecipients = 10;
/** Recipients (across sends) one account may send to in a UTC day. */
export const dailyRecommendationLimit = 50;
/** Inbox items per page. */
export const inboxPageSize = 30;
const maxMessage = 200;
const maxTitle = 300;

const handlePattern = /^[A-Za-z][A-Za-z0-9_]{2,19}$/;
const clientIdPattern = /^[A-Za-z0-9-]{8,64}$/;
const idPattern = /^[0-9a-f-]{36}$/;
const tmdbIdPattern = /^[1-9]\d{0,9}$/;
const yearPattern = /^\d{4}$/;
const day = 24 * 60 * 60 * 1000;

const invalid = (message: string) => new ApiError(400, 'invalid_recommendation', message);

/** Text shown to someone else: control and direction characters removed. */
function clean(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁩]/g, '').trim();
}

export interface Media {
  key: string;
  title: string;
  year: string | null;
  poster: string | null;
}

export function parseMedia(value: unknown): Media {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw invalid('media is required.');
  const media = value as Record<string, unknown>;
  if (media.type !== 'movie' && media.type !== 'series') throw invalid('media.type is movie or series.');
  const id = String(media.id ?? '');
  if (!tmdbIdPattern.test(id)) throw invalid('media.id is a TMDB number.');
  const title = typeof media.title === 'string' ? clean(media.title) : '';
  if (!title || title.length > maxTitle) throw invalid('media.title is required.');
  const year = media.year === undefined || media.year === null || media.year === '' ? null : String(media.year);
  if (year !== null && !yearPattern.test(year)) throw invalid('media.year is a year.');
  const poster = media.poster === undefined || media.poster === null || media.poster === '' ? null : media.poster;
  if (poster !== null && (typeof poster !== 'string' || !artworkPattern.test(poster))) {
    throw invalid('media.poster must be TMDB artwork.');
  }
  return { key: `${media.type}:${id}`, title, year, poster: poster as string | null };
}

function parseMessage(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') throw invalid('message must be text.');
  const text = clean(value);
  if (!text) return null;
  if (text.length > maxMessage) throw invalid(`A message is at most ${maxMessage} characters.`);
  if (linkPattern.test(text)) throw invalid('A message cannot contain a link.');
  return text;
}

interface RecipientRow {
  user_id: string;
  handle: string;
  handle_key: string;
  allow_recommendations: number;
  friend: number;
  blocked: number;
}

/**
 * POST /social/recommendations `{recipients: [handle], media, message?, clientId}`
 * → `{sent: [handle], notSent: [handle]}`. Someone it could not be sent to
 * (not a friend, not accepting, blocked, unknown) is in notSent, all alike.
 */
export async function sendRecommendation(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  const raw = body.recipients;
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > maxRecipients) {
    throw invalid(`Choose 1 to ${maxRecipients} friends.`);
  }
  const handles = [...new Set(raw.map((value) => {
    if (typeof value !== 'string' || !handlePattern.test(value)) throw invalid('recipients are handles.');
    return value.toLowerCase();
  }))];
  const media = parseMedia(body.media);
  const message = parseMessage(body.message);
  const clientId = body.clientId;
  if (typeof clientId !== 'string' || !clientIdPattern.test(clientId)) throw invalid('clientId is required.');
  await requireLiveSession(env, principal);
  const me = principal.userId;
  await requireProfile(env, me);

  const { results } = await env.DB.prepare(
    `SELECT p.user_id, p.handle, p.handle_key, p.allow_recommendations,
            EXISTS (SELECT 1 FROM friendships
                     WHERE (user_a = ?1 AND user_b = p.user_id) OR (user_a = p.user_id AND user_b = ?1)) AS friend,
            EXISTS (SELECT 1 FROM blocks
                     WHERE (blocker_id = ?1 AND blocked_id = p.user_id) OR (blocker_id = p.user_id AND blocked_id = ?1)) AS blocked
       FROM social_profiles p
      WHERE p.handle_key IN (${handles.map((_, index) => `?${index + 2}`).join(', ')})`,
  ).bind(me, ...handles).all<RecipientRow>();
  const eligible = results.filter((row) => row.friend === 1 && row.blocked === 0 && row.allow_recommendations === 1);
  const eligibleKeys = new Set(eligible.map((row) => row.handle_key));
  const notSent = handles.filter((handle) => !eligibleKeys.has(handle));

  // A retry of this very send: those rows exist already and count once.
  const repeated = eligible.length === 0 ? new Set<string>() : new Set(
    (await env.DB.prepare(
      `SELECT recipient_id FROM recommendations WHERE sender_id = ? AND client_id = ?`,
    ).bind(me, clientId).all<{ recipient_id: string }>()).results.map((row) => row.recipient_id),
  );
  const fresh = eligible.filter((row) => !repeated.has(row.user_id));
  const now = Date.now();
  const today = Math.floor(now / day);
  if (fresh.length > 0) {
    const used = await env.DB.prepare(`SELECT recommendations FROM social_counters WHERE user_id = ? AND day = ?`)
      .bind(me, today).first<{ recommendations: number }>();
    if ((used?.recommendations ?? 0) + fresh.length > dailyRecommendationLimit) {
      throw new ApiError(429, 'recommendation_limit', 'You have sent many recommendations today. Try again tomorrow.');
    }
    await env.DB.batch([
      ...fresh.map((row) => env.DB.prepare(
        `INSERT INTO recommendations (id, sender_id, recipient_id, media_key, title, year, poster, message, client_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (sender_id, recipient_id, media_key) DO UPDATE SET
           title = excluded.title, year = excluded.year, poster = excluded.poster, message = excluded.message,
           client_id = excluded.client_id, created_at = excluded.created_at, read_at = NULL`,
      ).bind(crypto.randomUUID(), me, row.user_id, media.key, media.title, media.year, media.poster, message, clientId, now)),
      env.DB.prepare(
        `INSERT INTO social_counters (user_id, day, recommendations) VALUES (?, ?, ?)
         ON CONFLICT (user_id, day) DO UPDATE SET recommendations = recommendations + excluded.recommendations`,
      ).bind(me, today, fresh.length),
    ]);
    await audit(env, 'social.recommended', { userId: me, detail: String(fresh.length) });
  }
  return json({ sent: eligible.map((row) => row.handle), notSent }, requestId, fresh.length > 0 ? 201 : 200);
}

interface InboxRow {
  id: string;
  media_key: string;
  title: string;
  year: string | null;
  poster: string | null;
  message: string | null;
  created_at: number;
  read_at: number | null;
  handle: string | null;
  display_name: string | null;
  avatar_preset: string | null;
  friend: number;
}

function card(row: InboxRow) {
  const [type, id] = row.media_key.split(':');
  return { type, id, title: row.title, year: row.year, poster: row.poster };
}

/**
 * The other person on a card. Their chosen name and avatar only while the
 * two are friends: after that, the handle alone, so an ex-friend does not
 * keep seeing what they change.
 */
const person = (row: InboxRow) =>
  row.handle === null
    ? null
    : publicView({
      handle: row.handle,
      display_name: row.friend === 1 ? row.display_name : null,
      avatar_preset: row.friend === 1 ? row.avatar_preset : null,
    });

/**
 * GET /social/recommendations?cursor=: what friends sent me, newest first,
 * 30 a page. `from` is null when the sender has since turned Friends off.
 * The first page adds the number unread.
 */
export async function inbox(env: Env, principal: Principal, url: URL, requestId: string) {
  await requireLiveSession(env, principal);
  const me = principal.userId;
  await requireProfile(env, me);
  const cursorText = url.searchParams.get('cursor') ?? '';
  const cursor = /^(\d{1,16})_([0-9a-f-]{36})$/.exec(cursorText);
  if (cursorText !== '' && !cursor) throw new ApiError(400, 'invalid_cursor', 'cursor is from a previous page.');
  const { results } = await env.DB.prepare(
    `SELECT r.id, r.media_key, r.title, r.year, r.poster, r.message, r.created_at, r.read_at,
            p.handle, p.display_name, p.avatar_preset,
            EXISTS (SELECT 1 FROM friendships
                     WHERE (user_a = ?1 AND user_b = p.user_id) OR (user_a = p.user_id AND user_b = ?1)) AS friend
       FROM recommendations r LEFT JOIN social_profiles p ON p.user_id = r.sender_id
      WHERE r.recipient_id = ?1
        AND (?2 IS NULL OR r.created_at < ?2 OR (r.created_at = ?2 AND r.id < ?3))
      ORDER BY r.created_at DESC, r.id DESC LIMIT ?4`,
  ).bind(me, cursor ? Number(cursor[1]) : null, cursor ? cursor[2] : '', inboxPageSize + 1).all<InboxRow>();
  const more = results.length > inboxPageSize;
  const rows = results.slice(0, inboxPageSize);
  const last = rows.at(-1);
  const body: Record<string, unknown> = {
    items: rows.map((row) => ({
      id: row.id,
      from: person(row),
      media: card(row),
      message: row.message,
      createdAt: row.created_at,
      read: row.read_at !== null,
    })),
    cursor: more && last ? `${last.created_at}_${last.id}` : null,
  };
  if (!cursor) {
    body.unread = (await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM recommendations WHERE recipient_id = ? AND read_at IS NULL`,
    ).bind(me).first<{ n: number }>())!.n;
  }
  return json(body, requestId);
}

/** GET /social/recommendations/sent: my last 30 sends; never whether they were read. */
export async function sent(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  const { results } = await env.DB.prepare(
    `SELECT r.id, r.media_key, r.title, r.year, r.poster, r.message, r.created_at, NULL AS read_at,
            p.handle, p.display_name, p.avatar_preset,
            EXISTS (SELECT 1 FROM friendships
                     WHERE (user_a = ?1 AND user_b = p.user_id) OR (user_a = p.user_id AND user_b = ?1)) AS friend
       FROM recommendations r LEFT JOIN social_profiles p ON p.user_id = r.recipient_id
      WHERE r.sender_id = ?1 ORDER BY r.created_at DESC LIMIT ${inboxPageSize}`,
  ).bind(principal.userId).all<InboxRow>();
  return json({
    items: results.map((row) => ({
      id: row.id,
      to: person(row),
      media: card(row),
      message: row.message,
      createdAt: row.created_at,
    })),
  }, requestId);
}

/** POST /social/recommendations/read `{ids?}`: marks mine read (all when no ids). */
export async function markRead(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  const ids = body.ids;
  if (ids !== undefined && (!Array.isArray(ids) || ids.length > 100 ||
      ids.some((id) => typeof id !== 'string' || !idPattern.test(id)))) {
    throw invalid('ids lists recommendation ids.');
  }
  await requireLiveSession(env, principal);
  const list = (ids as string[] | undefined) ?? null;
  const result = await env.DB.prepare(
    `UPDATE recommendations SET read_at = ?1
      WHERE recipient_id = ?2 AND read_at IS NULL
        ${list ? `AND id IN (${list.map((_, index) => `?${index + 3}`).join(', ')})` : ''}`,
  ).bind(Date.now(), principal.userId, ...(list ?? [])).run();
  return json({ marked: result.meta.changes ?? 0 }, requestId);
}

/** DELETE /social/recommendations/{id}: the recipient removes one. */
export async function removeRecommendation(env: Env, principal: Principal, id: string, requestId: string) {
  if (!idPattern.test(id)) throw new ApiError(404, 'not_found', 'Not found.');
  await requireLiveSession(env, principal);
  const result = await env.DB.prepare(`DELETE FROM recommendations WHERE id = ? AND recipient_id = ?`)
    .bind(id, principal.userId).run();
  if ((result.meta.changes ?? 0) === 0) throw new ApiError(404, 'not_found', 'Not found.');
  return json({ ok: true }, requestId);
}
