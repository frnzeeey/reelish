// Friends: finding someone by friend code or exact handle, requests (send,
// accept, decline, cancel), the friends list, a friend's profile, removing,
// blocking and reporting. Another person is always named by handle, never by
// account id, and every action is checked here against the relationship at
// that moment. docs/friends-activity/SECURITY_AND_PRIVACY.md.

import type { Env } from '../env';
import { audit } from '../audit';
import { ApiError, json, readJsonBody, shortText } from '../http';
import { requireLiveSession, type Principal } from '../sessions';
import { reporterHash } from '../support';
import { codeAlphabet, codeLength, requireProfile, type ProfileRow } from './profiles';
import { orderedPair, relationship } from './relationship';
import { sharedCollectionsOf } from './shared-collections';

/** Most friends an account may have. */
export const maxFriends = 500;
/** Most requests an account may have waiting for an answer. */
export const maxOutgoing = 30;
/** Most requests waiting for one account; more are refused. */
export const maxIncoming = 100;
/** New requests one account may send in a UTC day. */
export const dailyRequestLimit = 20;
/** Friends per page. */
export const friendsPageSize = 50;
/** Requests listed each way. */
export const requestsShown = 30;
/** Reports (bugs, feedback and people together) one account may send a day. */
const dailyReportLimit = 5;

const handleParam = /^[A-Za-z][A-Za-z0-9_]{2,19}$/;
const reasons = new Set(['spam', 'harassment', 'impersonation', 'inappropriate', 'other']);
const day = 24 * 60 * 60 * 1000;

/** The same answer for unknown, hidden and blocked people, so none can be told apart. */
const notFound = () => new ApiError(404, 'not_found', 'No one was found. Check it and try again.');

/** What anyone allowed to see a person gets: never an account id or Trakt data. */
export function publicView(row: Pick<ProfileRow, 'handle' | 'display_name' | 'avatar_preset'>) {
  return { handle: row.handle, displayName: row.display_name, avatar: row.avatar_preset };
}

/** The handle in a route, checked; an impossible one is simply not found. */
export function handleFrom(value: string): string {
  if (!handleParam.test(value)) throw notFound();
  return value.toLowerCase();
}

async function profileByHandle(env: Env, handle: string): Promise<ProfileRow | null> {
  return env.DB.prepare(`SELECT * FROM social_profiles WHERE handle_key = ?`)
    .bind(handle.toLowerCase()).first<ProfileRow>();
}

/** A friend code as people type it: case, spaces and dashes ignored. */
export function normaliseCode(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const code = value.toUpperCase().replace(/[\s-]/g, '');
  if (code.length !== codeLength || [...code].some((c) => !codeAlphabet.includes(c))) return null;
  return code;
}

async function pendingBetween(env: Env, sender: string, receiver: string): Promise<boolean> {
  return (await env.DB.prepare(`SELECT 1 FROM friend_requests WHERE sender_id = ? AND receiver_id = ?`)
    .bind(sender, receiver).first()) !== null;
}

async function friendCount(env: Env, userId: string): Promise<number> {
  return (await env.DB.prepare(`SELECT COUNT(*) AS n FROM friendships WHERE user_a = ?1 OR user_b = ?1`)
    .bind(userId).first<{ n: number }>())!.n;
}

/** Statements that make two accounts friends and remove their requests. */
function befriend(env: Env, one: string, other: string, now: number): D1PreparedStatement[] {
  const [a, b] = orderedPair(one, other);
  return [
    env.DB.prepare(`INSERT OR IGNORE INTO friendships (user_a, user_b, created_at) VALUES (?, ?, ?)`).bind(a, b, now),
    env.DB.prepare(
      `DELETE FROM friend_requests WHERE (sender_id = ?1 AND receiver_id = ?2) OR (sender_id = ?2 AND receiver_id = ?1)`,
    ).bind(one, other),
  ];
}

/**
 * POST /social/requests `{code}` or `{handle}`: asks to be friends. When the
 * other person has already asked, this accepts instead.
 */
export async function sendRequest(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  const me = principal.userId;
  await requireLiveSession(env, principal);
  await requireProfile(env, me);

  let target: ProfileRow | null = null;
  if (body.code !== undefined) {
    const code = normaliseCode(body.code);
    if (!code) throw notFound();
    target = await env.DB.prepare(`SELECT * FROM social_profiles WHERE friend_code = ? AND find_by_code = 1`)
      .bind(code).first<ProfileRow>();
  } else if (typeof body.handle === 'string') {
    target = await profileByHandle(env, handleFrom(body.handle.replace(/^@/, '')));
    if (target && target.find_by_handle !== 1) target = null;
  } else {
    throw new ApiError(400, 'invalid_request', 'Send a friend code or a handle.');
  }
  if (!target) throw notFound();
  if (target.user_id === me) throw new ApiError(400, 'that_is_you', 'That is you.');
  const relation = await relationship(env, me, target.user_id);
  if (relation === 'blocked') throw notFound();
  const person = publicView(target);
  if (relation === 'friend') return json({ status: 'friends', person }, requestId);

  const now = Date.now();
  // They asked first: this is an acceptance.
  if (await pendingBetween(env, target.user_id, me)) {
    await acceptFrom(env, me, target.user_id, now);
    await audit(env, 'social.friend_added', { userId: me });
    return json({ status: 'friends', person }, requestId);
  }
  if (await pendingBetween(env, me, target.user_id)) return json({ status: 'requested', person }, requestId);

  const today = Math.floor(now / day);
  const limits = await env.DB.prepare(
    `SELECT
       (SELECT requests FROM social_counters WHERE user_id = ?1 AND day = ?3) AS today,
       (SELECT COUNT(*) FROM friend_requests WHERE sender_id = ?1) AS outgoing,
       (SELECT COUNT(*) FROM friend_requests WHERE receiver_id = ?2) AS incoming,
       (SELECT COUNT(*) FROM friendships WHERE user_a = ?1 OR user_b = ?1) AS friends`,
  ).bind(me, target.user_id, today).first<{ today: number | null; outgoing: number; incoming: number; friends: number }>();
  if ((limits?.today ?? 0) >= dailyRequestLimit) {
    throw new ApiError(429, 'request_limit', 'You have sent many requests today. Try again tomorrow.');
  }
  if ((limits?.outgoing ?? 0) >= maxOutgoing) {
    throw new ApiError(409, 'too_many_pending', 'You have many requests waiting. Cancel some first.');
  }
  if ((limits?.friends ?? 0) >= maxFriends) {
    throw new ApiError(409, 'friend_limit', `You can have up to ${maxFriends} friends.`);
  }
  if ((limits?.incoming ?? 0) >= maxIncoming) {
    throw new ApiError(409, 'request_limit', 'This request could not be sent. Try again later.');
  }

  // One transaction: if the other side asked in the meantime, this becomes a
  // friendship instead of a second request.
  const [a, b] = orderedPair(me, target.user_id);
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT OR IGNORE INTO friendships (user_a, user_b, created_at)
         SELECT ?1, ?2, ?3 WHERE EXISTS (SELECT 1 FROM friend_requests WHERE sender_id = ?4 AND receiver_id = ?5)`,
    ).bind(a, b, now, target.user_id, me),
    env.DB.prepare(
      `DELETE FROM friend_requests WHERE sender_id = ?1 AND receiver_id = ?2
         AND EXISTS (SELECT 1 FROM friendships WHERE user_a = ?3 AND user_b = ?4)`,
    ).bind(target.user_id, me, a, b),
    env.DB.prepare(
      `INSERT OR IGNORE INTO friend_requests (sender_id, receiver_id, created_at)
         SELECT ?1, ?2, ?3 WHERE NOT EXISTS (SELECT 1 FROM friendships WHERE user_a = ?4 AND user_b = ?5)`,
    ).bind(me, target.user_id, now, a, b),
    env.DB.prepare(
      `INSERT INTO social_counters (user_id, day, requests) VALUES (?, ?, 1)
       ON CONFLICT (user_id, day) DO UPDATE SET requests = requests + 1`,
    ).bind(me, today),
  ]);
  if ((results[0].meta.changes ?? 0) > 0) {
    await audit(env, 'social.friend_added', { userId: me });
    return json({ status: 'friends', person }, requestId);
  }
  await audit(env, 'social.request_sent', { userId: me });
  return json({ status: 'requested', person }, requestId, 201);
}

async function acceptFrom(env: Env, me: string, sender: string, now: number) {
  if (await friendCount(env, me) >= maxFriends || await friendCount(env, sender) >= maxFriends) {
    throw new ApiError(409, 'friend_limit', `Friends are limited to ${maxFriends}.`);
  }
  await env.DB.batch(befriend(env, me, sender, now));
}

/** The pending request from [handle] to me, or 404. */
async function incomingFrom(env: Env, me: string, handle: string): Promise<ProfileRow> {
  const sender = await profileByHandle(env, handleFrom(handle));
  if (!sender || !(await pendingBetween(env, sender.user_id, me))) throw notFound();
  return sender;
}

/** POST /social/requests/{handle}/accept */
export async function acceptRequest(env: Env, principal: Principal, handle: string, requestId: string) {
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  const sender = await incomingFrom(env, principal.userId, handle);
  await acceptFrom(env, principal.userId, sender.user_id, Date.now());
  await audit(env, 'social.friend_added', { userId: principal.userId });
  return json({ status: 'friends', person: publicView(sender) }, requestId);
}

/** POST /social/requests/{handle}/decline: the sender is not told. */
export async function declineRequest(env: Env, principal: Principal, handle: string, requestId: string) {
  await requireLiveSession(env, principal);
  const sender = await incomingFrom(env, principal.userId, handle);
  await env.DB.prepare(`DELETE FROM friend_requests WHERE sender_id = ? AND receiver_id = ?`)
    .bind(sender.user_id, principal.userId).run();
  return json({ ok: true }, requestId);
}

/** DELETE /social/requests/{handle}: withdraws my request. */
export async function cancelRequest(env: Env, principal: Principal, handle: string, requestId: string) {
  await requireLiveSession(env, principal);
  const receiver = await profileByHandle(env, handleFrom(handle));
  if (!receiver) throw notFound();
  const result = await env.DB.prepare(`DELETE FROM friend_requests WHERE sender_id = ? AND receiver_id = ?`)
    .bind(principal.userId, receiver.user_id).run();
  if ((result.meta.changes ?? 0) === 0) throw notFound();
  return json({ ok: true }, requestId);
}

interface PersonRow {
  handle: string;
  handle_key: string;
  display_name: string | null;
  avatar_preset: string | null;
  created_at: number;
}

const person = (row: PersonRow) => ({ ...publicView(row), since: row.created_at });

/**
 * GET /social/friends?cursor=<handle>: friends in handle order, 50 a page;
 * the first page also lists requests both ways, newest first.
 */
export async function listFriends(env: Env, principal: Principal, url: URL, requestId: string) {
  await requireLiveSession(env, principal);
  const me = principal.userId;
  await requireProfile(env, me);
  const cursorText = url.searchParams.get('cursor') ?? '';
  if (cursorText !== '' && !handleParam.test(cursorText)) {
    throw new ApiError(400, 'invalid_cursor', 'cursor is a handle from a previous page.');
  }
  const cursor = cursorText.toLowerCase();
  const { results } = await env.DB.prepare(
    `SELECT p.handle, p.handle_key, p.display_name, p.avatar_preset, f.created_at
       FROM friendships f
       JOIN social_profiles p ON p.user_id = CASE WHEN f.user_a = ?1 THEN f.user_b ELSE f.user_a END
      WHERE (f.user_a = ?1 OR f.user_b = ?1) AND p.handle_key > ?2
      ORDER BY p.handle_key LIMIT ?3`,
  ).bind(me, cursor, friendsPageSize + 1).all<PersonRow>();
  const more = results.length > friendsPageSize;
  const friends = results.slice(0, friendsPageSize);
  const body: Record<string, unknown> = {
    friends: friends.map(person),
    cursor: more ? friends.at(-1)!.handle_key : null,
  };
  if (cursor === '') {
    const [incoming, outgoing, counts] = await env.DB.batch([
      env.DB.prepare(
        `SELECT p.handle, p.handle_key, p.display_name, p.avatar_preset, r.created_at
           FROM friend_requests r JOIN social_profiles p ON p.user_id = r.sender_id
          WHERE r.receiver_id = ? ORDER BY r.created_at DESC LIMIT ${requestsShown}`,
      ).bind(me),
      env.DB.prepare(
        `SELECT p.handle, p.handle_key, p.display_name, p.avatar_preset, r.created_at
           FROM friend_requests r JOIN social_profiles p ON p.user_id = r.receiver_id
          WHERE r.sender_id = ? ORDER BY r.created_at DESC LIMIT ${requestsShown}`,
      ).bind(me),
      env.DB.prepare(
        `SELECT (SELECT COUNT(*) FROM friendships WHERE user_a = ?1 OR user_b = ?1) AS friends,
                (SELECT COUNT(*) FROM friend_requests WHERE receiver_id = ?1) AS incoming`,
      ).bind(me),
    ]);
    body.incoming = (incoming.results as unknown as PersonRow[]).map(person);
    body.outgoing = (outgoing.results as unknown as PersonRow[]).map(person);
    body.counts = counts.results[0];
  }
  return json(body, requestId);
}

/** GET /social/friends/{handle}: a friend's profile and shared collections; anyone else is not found. */
export async function getFriend(env: Env, principal: Principal, handle: string, requestId: string) {
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  const other = await profileByHandle(env, handleFrom(handle));
  if (!other || (await relationship(env, principal.userId, other.user_id)) !== 'friend') throw notFound();
  const [a, b] = orderedPair(principal.userId, other.user_id);
  const since = await env.DB.prepare(`SELECT created_at FROM friendships WHERE user_a = ? AND user_b = ?`)
    .bind(a, b).first<{ created_at: number }>();
  return json({
    friend: { ...publicView(other), since: since?.created_at ?? null },
    collections: await sharedCollectionsOf(env, other.user_id),
  }, requestId);
}

/** DELETE /social/friends/{handle}: ends the friendship for both. */
export async function removeFriend(env: Env, principal: Principal, handle: string, requestId: string) {
  await requireLiveSession(env, principal);
  const other = await profileByHandle(env, handleFrom(handle));
  if (!other) throw notFound();
  const [a, b] = orderedPair(principal.userId, other.user_id);
  const result = await env.DB.prepare(`DELETE FROM friendships WHERE user_a = ? AND user_b = ?`).bind(a, b).run();
  if ((result.meta.changes ?? 0) === 0) throw notFound();
  await audit(env, 'social.friend_removed', { userId: principal.userId });
  return json({ ok: true }, requestId);
}

/**
 * Someone the caller may block or report: a friend, or a request either way.
 * Anyone else is not found, so neither action reveals whether a handle exists.
 */
async function someoneKnown(env: Env, me: string, handle: string): Promise<ProfileRow> {
  const other = await profileByHandle(env, handleFrom(handle));
  if (!other || other.user_id === me) throw notFound();
  const [a, b] = orderedPair(me, other.user_id);
  const known = await env.DB.prepare(
    `SELECT EXISTS (SELECT 1 FROM friendships WHERE user_a = ?1 AND user_b = ?2)
         OR EXISTS (SELECT 1 FROM friend_requests
                     WHERE (sender_id = ?3 AND receiver_id = ?4) OR (sender_id = ?4 AND receiver_id = ?3))
         OR EXISTS (SELECT 1 FROM blocks WHERE blocker_id = ?3 AND blocked_id = ?4) AS known`,
  ).bind(a, b, me, other.user_id).first<{ known: number }>();
  if (!known?.known) throw notFound();
  return other;
}

/**
 * POST /social/blocks `{handle}`: ends any friendship and requests both ways,
 * removes recommendations both ways, and refuses all contact from then on.
 */
export async function block(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  if (typeof body.handle !== 'string') throw new ApiError(400, 'invalid_request', 'Send a handle.');
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  const me = principal.userId;
  const other = await someoneKnown(env, me, body.handle);
  const [a, b] = orderedPair(me, other.user_id);
  await env.DB.batch([
    env.DB.prepare(`INSERT OR IGNORE INTO blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)`)
      .bind(me, other.user_id, Date.now()),
    env.DB.prepare(`DELETE FROM friendships WHERE user_a = ? AND user_b = ?`).bind(a, b),
    env.DB.prepare(
      `DELETE FROM friend_requests WHERE (sender_id = ?1 AND receiver_id = ?2) OR (sender_id = ?2 AND receiver_id = ?1)`,
    ).bind(me, other.user_id),
    env.DB.prepare(
      `DELETE FROM recommendations WHERE (sender_id = ?1 AND recipient_id = ?2) OR (sender_id = ?2 AND recipient_id = ?1)`,
    ).bind(me, other.user_id),
  ]);
  await audit(env, 'social.blocked', { userId: me });
  return json({ ok: true }, requestId);
}

/** GET /social/blocks: the people I blocked who still have a profile. */
export async function listBlocks(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  const { results } = await env.DB.prepare(
    `SELECT p.handle, p.handle_key, p.display_name, p.avatar_preset, k.created_at
       FROM blocks k JOIN social_profiles p ON p.user_id = k.blocked_id
      WHERE k.blocker_id = ? ORDER BY k.created_at DESC LIMIT 500`,
  ).bind(principal.userId).all<PersonRow>();
  return json({ blocked: results.map(person) }, requestId);
}

/** DELETE /social/blocks/{handle}: nothing is restored; they may ask again. */
export async function unblock(env: Env, principal: Principal, handle: string, requestId: string) {
  await requireLiveSession(env, principal);
  const other = await profileByHandle(env, handleFrom(handle));
  if (!other) throw notFound();
  const result = await env.DB.prepare(`DELETE FROM blocks WHERE blocker_id = ? AND blocked_id = ?`)
    .bind(principal.userId, other.user_id).run();
  if ((result.meta.changes ?? 0) === 0) throw notFound();
  return json({ ok: true }, requestId);
}

/**
 * When [userId]'s account is deleted, reports about it keep only their reason
 * and date: the account id, handle, name and the reporter's note go.
 */
export async function forgetReportsAbout(env: Env, userId: string): Promise<void> {
  await env.DB.prepare(
    `UPDATE support_reports SET title = '@(deleted account)', description = '(account deleted)', diagnostics = '{}'
      WHERE kind = 'person' AND json_extract(diagnostics, '$.reportedUser') = ?`,
  ).bind(userId).run();
}

/**
 * POST /social/reports `{handle, reason, note?}`: a report about someone the
 * caller knows, kept with bug reports for the developer to read. The reported
 * account's id is kept so it can be acted on; the reporter only as a hash.
 */
export async function reportPerson(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  if (typeof body.handle !== 'string') throw new ApiError(400, 'invalid_request', 'Send a handle.');
  const reason = typeof body.reason === 'string' && reasons.has(body.reason) ? body.reason : null;
  if (!reason) throw new ApiError(400, 'invalid_report', 'Choose a reason.');
  const note = shortText(body.note, 500);
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  const other = await someoneKnown(env, principal.userId, body.handle);
  const reporter = await reporterHash(principal.userId);
  const nowSeconds = Math.floor(Date.now() / 1000);
  const recent = await env.DB.prepare(
    `SELECT COUNT(*) AS count FROM support_reports WHERE reporter_hash = ? AND created_at > ?`,
  ).bind(reporter, nowSeconds - 24 * 60 * 60).first<{ count: number }>();
  if ((recent?.count ?? 0) >= dailyReportLimit) {
    throw new ApiError(429, 'report_limit', 'You have sent several reports today. Try again tomorrow.');
  }
  const id = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO support_reports (id, reporter_hash, kind, category, title, description, platform, diagnostics, created_at)
     VALUES (?, ?, 'person', ?, ?, ?, 'other', ?, ?)`,
  ).bind(
    id, reporter, reason, `@${other.handle}`.slice(0, 120), note || '(no note)',
    JSON.stringify({ reportedUser: other.user_id, handle: other.handle, displayName: other.display_name ?? '' }),
    nowSeconds,
  ).run();
  await audit(env, 'social.reported', { userId: principal.userId, detail: reason });
  return json({ id }, requestId, 201);
}
