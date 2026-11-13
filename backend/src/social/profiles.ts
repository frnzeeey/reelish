// The social profile: turning Friends on and off, the handle, the friend code
// and the privacy settings. An account has no social presence until its owner
// turns Friends on; turning it off deletes every social row of the account.
// Nothing here returns another user's data.
// docs/friends-activity/SECURITY_AND_PRIVACY.md.

import type { Env } from '../env';
import { audit } from '../audit';
import { ApiError, json, readJsonBody } from '../http';
import { requireLiveSession, type Principal } from '../sessions';

/**
 * "Taken" answers one account may get in an hour. Only those reveal anything
 * (that a handle exists), so only those are counted, in the security log.
 */
export const takenAnswersPerHour = 10;

/** A given-up handle is held this long for anyone but its last owner. */
export const handleHoldMs = 30 * 24 * 60 * 60 * 1000;
/**
 * How often a handle may change. A new profile starts with
 * handle_changed_at = 0, so a typo in the first handle can be fixed at once.
 */
export const handleChangeIntervalMs = 7 * 24 * 60 * 60 * 1000;

/** 3–20 characters: a letter, then letters, digits or underscores. */
const handlePattern = /^[A-Za-z][A-Za-z0-9_]{2,19}$/;
const reservedHandles = new Set([
  'admin', 'administrator', 'api', 'everyone', 'founder', 'friends', 'help',
  'me', 'mod', 'moderator', 'null', 'official', 'root', 'staff', 'supporter',
  'support', 'system', 'tmdb', 'trakt', 'undefined', 'you',
]);
/** Friend codes: no 0/O or 1/I, so a code read aloud cannot be mistyped. */
export const codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const codeLength = 8;
const avatarPattern = /^avatar[1-8]$/;
/** Names that look like links are refused: they are shown to other people. */
export const linkPattern = /(https?:|www\.|\.(com|net|org|io|gg|tv|me|ly|xyz|app|co|link|site)\b)/i;
const maxDisplayName = 40;

export interface ProfileRow {
  user_id: string;
  handle: string;
  handle_key: string;
  handle_changed_at: number;
  friend_code: string;
  display_name: string | null;
  avatar_preset: string | null;
  find_by_code: number;
  find_by_handle: number;
  allow_recommendations: number;
  share_activity: number;
  created_at: number;
  updated_at: number;
}

const invalid = (code: string, message: string) => new ApiError(400, code, message);
const handleTaken = () => new ApiError(409, 'handle_taken', 'That handle is taken. Try another.');

export async function profileOf(env: Env, userId: string): Promise<ProfileRow | null> {
  return env.DB.prepare(`SELECT * FROM social_profiles WHERE user_id = ?`).bind(userId).first<ProfileRow>();
}

/** The caller's profile, or 409 when Friends is off. */
export async function requireProfile(env: Env, userId: string): Promise<ProfileRow> {
  const profile = await profileOf(env, userId);
  if (!profile) throw new ApiError(409, 'friends_off', 'Turn on Friends first.');
  return profile;
}

/** The owner's own view of their profile and settings. */
function ownView(row: ProfileRow) {
  return {
    handle: row.handle,
    friendCode: row.friend_code,
    displayName: row.display_name,
    avatar: row.avatar_preset,
    findByCode: row.find_by_code === 1,
    findByHandle: row.find_by_handle === 1,
    allowRecommendations: row.allow_recommendations === 1,
    shareActivity: row.share_activity === 1,
    handleChangeableAt: row.handle_changed_at + handleChangeIntervalMs,
    createdAt: row.created_at,
  };
}

/** A handle as typed, checked; returns it with its lookup key. */
export function parseHandle(value: unknown): { handle: string; key: string } {
  if (typeof value !== 'string' || !handlePattern.test(value)) {
    throw invalid('invalid_handle', 'A handle is 3 to 20 letters, digits or underscores, starting with a letter.');
  }
  const key = value.toLowerCase();
  if (reservedHandles.has(key) || key.includes('reelish')) {
    throw invalid('handle_reserved', 'That handle is reserved. Try another.');
  }
  return { handle: value, key };
}

/** An optional display name: trimmed, control characters removed, no links. */
export function parseDisplayName(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string') throw invalid('invalid_display_name', 'The name must be text.');
  const clean = value.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁩]/g, '').trim();
  if (clean.length === 0) return null;
  if (clean.length > maxDisplayName) {
    throw invalid('invalid_display_name', `A name is at most ${maxDisplayName} characters.`);
  }
  if (linkPattern.test(clean)) throw invalid('invalid_display_name', 'A name cannot contain a link.');
  // A name like "Reelish Support" would pass as the app speaking.
  if (/reelish/i.test(clean.normalize('NFKC'))) {
    throw invalid('invalid_display_name', 'A name cannot contain "Reelish".');
  }
  return clean;
}

function parseAvatar(value: unknown): string | null {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value !== 'string' || !avatarPattern.test(value)) throw invalid('invalid_avatar', 'Unknown avatar.');
  return value;
}

function flag(body: Record<string, unknown>, field: string): number | undefined {
  const value = body[field];
  if (value === undefined) return undefined;
  if (typeof value !== 'boolean') throw invalid('invalid_setting', `${field} must be true or false.`);
  return value ? 1 : 0;
}

/** A fresh random friend code (each byte's low 5 bits pick a letter, so no bias). */
export function newFriendCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(codeLength));
  return Array.from(bytes, (byte) => codeAlphabet[byte & 31]).join('');
}

/** Whether [key] is held for someone other than [userId]. */
async function heldForOther(env: Env, key: string, userId: string, now: number): Promise<boolean> {
  const row = await env.DB.prepare(
    `SELECT user_id FROM released_handles WHERE handle_key = ? AND released_at > ?`,
  ).bind(key, now - handleHoldMs).first<{ user_id: string | null }>();
  return row !== null && row.user_id !== userId;
}

const isUnique = (error: unknown, column: string) =>
  String(error).includes('UNIQUE') && String(error).includes(column);

/**
 * GET /social/profile: the caller's profile, or null while Friends is off.
 * With a profile, `counts` gives friends, requests waiting for an answer and
 * unread recommendations, for the Profile page's dot, so it needs no second
 * request.
 */
export async function getProfile(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  const row = await profileOf(env, principal.userId);
  if (!row) return json({ profile: null }, requestId);
  const counts = await env.DB.prepare(
    `SELECT (SELECT COUNT(*) FROM friendships WHERE user_a = ?1 OR user_b = ?1) AS friends,
            (SELECT COUNT(*) FROM friend_requests WHERE receiver_id = ?1) AS incoming,
            (SELECT COUNT(*) FROM recommendations WHERE recipient_id = ?1 AND read_at IS NULL) AS unread`,
  ).bind(principal.userId).first<{ friends: number; incoming: number; unread: number }>();
  return json({ profile: ownView(row), counts }, requestId);
}

/**
 * PUT /social/profile: turns Friends on (a handle is then required) or
 * changes the handle, name, avatar or settings. Fields left out keep their
 * value; null clears the name or avatar.
 */
export async function putProfile(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  if (body.handle !== undefined) {
    const since = Math.floor(Date.now() / 1000) - 60 * 60;
    const taken = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM audit_events WHERE user_id = ? AND event = 'social.handle_taken' AND created_at > ?`,
    ).bind(principal.userId, since).first<{ n: number }>();
    if ((taken?.n ?? 0) >= takenAnswersPerHour) {
      throw new ApiError(429, 'too_many_attempts', 'Too many handles tried. Try again in an hour.', {
        'Retry-After': '3600',
      });
    }
  }
  try {
    return await savePutProfile(env, principal, body, requestId);
  } catch (error) {
    if (error instanceof ApiError && error.code === 'handle_taken') {
      await audit(env, 'social.handle_taken', { userId: principal.userId, sessionId: principal.sessionId });
    }
    throw error;
  }
}

async function savePutProfile(env: Env, principal: Principal, body: Record<string, unknown>, requestId: string) {
  const handle = body.handle === undefined ? undefined : parseHandle(body.handle);
  const displayName = 'displayName' in body ? parseDisplayName(body.displayName) : undefined;
  const avatar = 'avatar' in body ? parseAvatar(body.avatar) : undefined;
  const settings = {
    find_by_code: flag(body, 'findByCode'),
    find_by_handle: flag(body, 'findByHandle'),
    allow_recommendations: flag(body, 'allowRecommendations'),
    share_activity: flag(body, 'shareActivity'),
  };
  await requireLiveSession(env, principal);
  const userId = principal.userId;
  const now = Date.now();
  const existing = await profileOf(env, userId);

  if (!existing) {
    if (!handle) throw invalid('handle_required', 'Choose a handle to turn on Friends.');
    if (await heldForOther(env, handle.key, userId, now)) throw handleTaken();
    for (let attempt = 0; ; attempt++) {
      try {
        await env.DB.batch([
          env.DB.prepare(
            `INSERT INTO social_profiles (user_id, handle, handle_key, handle_changed_at, friend_code,
               display_name, avatar_preset, find_by_code, find_by_handle, allow_recommendations,
               share_activity, created_at, updated_at)
             VALUES (?1, ?2, ?3, 0, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?4, ?4)`,
          ).bind(
            userId, handle.handle, handle.key, now, newFriendCode(),
            displayName ?? null, avatar ?? null,
            settings.find_by_code ?? 1, settings.find_by_handle ?? 0,
            settings.allow_recommendations ?? 1, settings.share_activity ?? 0,
          ),
          env.DB.prepare(`DELETE FROM released_handles WHERE handle_key = ?`).bind(handle.key),
        ]);
        break;
      } catch (error) {
        if (isUnique(error, 'handle_key')) throw handleTaken();
        if (isUnique(error, 'user_id')) throw new ApiError(409, 'conflict', 'Try again.');
        if (!isUnique(error, 'friend_code') || attempt >= 4) throw error;
      }
    }
    await audit(env, 'social.enabled', { userId, sessionId: principal.sessionId });
    return json({ profile: ownView((await profileOf(env, userId))!) }, requestId, 201);
  }

  const statements: D1PreparedStatement[] = [];
  const changingHandle = handle !== undefined && handle.key !== existing.handle_key;
  if (changingHandle) {
    if (now < existing.handle_changed_at + handleChangeIntervalMs) {
      throw new ApiError(429, 'handle_change_too_soon', 'A handle can change once a week.');
    }
    if (await heldForOther(env, handle.key, userId, now)) throw handleTaken();
    // The old handle is held for this account, so nobody else can take it at once.
    statements.push(
      env.DB.prepare(
        `INSERT INTO released_handles (handle_key, user_id, released_at) VALUES (?, ?, ?)
         ON CONFLICT (handle_key) DO UPDATE SET user_id = excluded.user_id, released_at = excluded.released_at`,
      ).bind(existing.handle_key, userId, now),
      env.DB.prepare(`DELETE FROM released_handles WHERE handle_key = ?`).bind(handle.key),
    );
  }
  const next = {
    handle: handle?.handle ?? existing.handle,
    handle_key: handle?.key ?? existing.handle_key,
    handle_changed_at: changingHandle ? now : existing.handle_changed_at,
    display_name: displayName === undefined ? existing.display_name : displayName,
    avatar_preset: avatar === undefined ? existing.avatar_preset : avatar,
    find_by_code: settings.find_by_code ?? existing.find_by_code,
    find_by_handle: settings.find_by_handle ?? existing.find_by_handle,
    allow_recommendations: settings.allow_recommendations ?? existing.allow_recommendations,
    share_activity: settings.share_activity ?? existing.share_activity,
  };
  statements.unshift(env.DB.prepare(
    `UPDATE social_profiles SET handle = ?, handle_key = ?, handle_changed_at = ?, display_name = ?,
       avatar_preset = ?, find_by_code = ?, find_by_handle = ?, allow_recommendations = ?,
       share_activity = ?, updated_at = ?
     WHERE user_id = ?`,
  ).bind(
    next.handle, next.handle_key, next.handle_changed_at, next.display_name, next.avatar_preset,
    next.find_by_code, next.find_by_handle, next.allow_recommendations, next.share_activity, now, userId,
  ));
  // Turning activity sharing off removes what friends could see, at once.
  if (next.share_activity === 0) {
    statements.push(env.DB.prepare(`DELETE FROM current_activity WHERE user_id = ?`).bind(userId));
  }
  try {
    await env.DB.batch(statements);
  } catch (error) {
    if (isUnique(error, 'handle_key')) throw handleTaken();
    throw error;
  }
  if (changingHandle) await audit(env, 'social.handle_changed', { userId, sessionId: principal.sessionId });
  return json({ profile: ownView((await profileOf(env, userId))!) }, requestId);
}

/** POST /social/profile/code: a new friend code; the old one stops working. */
export async function resetFriendCode(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  for (let attempt = 0; ; attempt++) {
    try {
      await env.DB.prepare(`UPDATE social_profiles SET friend_code = ?, updated_at = ? WHERE user_id = ?`)
        .bind(newFriendCode(), Date.now(), principal.userId).run();
      break;
    } catch (error) {
      if (!isUnique(error, 'friend_code') || attempt >= 4) throw error;
    }
  }
  await audit(env, 'social.code_reset', { userId: principal.userId, sessionId: principal.sessionId });
  return json({ profile: ownView((await profileOf(env, principal.userId))!) }, requestId);
}

/**
 * Every statement that removes [userId]'s social presence: the profile (its
 * handle held), friendships and requests both ways, the blocks it made, its
 * activity and the recommendations it received; its collections become
 * private. Counters stay, so turning Friends off and on resets no limit.
 */
export function removalStatements(env: Env, userId: string, now: number): D1PreparedStatement[] {
  return [
    env.DB.prepare(
      `INSERT INTO released_handles (handle_key, user_id, released_at)
         SELECT handle_key, user_id, ?2 FROM social_profiles WHERE user_id = ?1
       ON CONFLICT (handle_key) DO UPDATE SET user_id = excluded.user_id, released_at = excluded.released_at`,
    ).bind(userId, now),
    env.DB.prepare(`DELETE FROM social_profiles WHERE user_id = ?`).bind(userId),
    env.DB.prepare(`DELETE FROM friend_requests WHERE sender_id = ?1 OR receiver_id = ?1`).bind(userId),
    env.DB.prepare(`DELETE FROM friendships WHERE user_a = ?1 OR user_b = ?1`).bind(userId),
    env.DB.prepare(`DELETE FROM blocks WHERE blocker_id = ?`).bind(userId),
    env.DB.prepare(`DELETE FROM current_activity WHERE user_id = ?`).bind(userId),
    env.DB.prepare(`DELETE FROM recommendations WHERE recipient_id = ?`).bind(userId),
    // Shared collections become private as a change of the server's own, so
    // the account's devices pull it (they keep the newer of two changes).
    env.DB.prepare(
      `UPDATE collection_records
          SET visibility = 'private', body = json_remove(body, '$.visibility'),
              device_id = 'reelish-server', seq = 0, client_at = ?2, changed_at = ?2
        WHERE user_id = ?1 AND visibility <> 'private'`,
    ).bind(userId, now),
  ];
}

/** DELETE /social/profile: turns Friends off and removes everything social. */
export async function deleteProfile(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  const existed = (await profileOf(env, principal.userId)) !== null;
  await env.DB.batch(removalStatements(env, principal.userId, Date.now()));
  if (existed) await audit(env, 'social.disabled', { userId: principal.userId, sessionId: principal.sessionId });
  return json({ ok: true }, requestId);
}

/**
 * Before an account is deleted: holds its handle. The rest goes with the
 * account (ON DELETE CASCADE).
 */
export async function holdHandleOf(env: Env, userId: string, now = Date.now()): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO released_handles (handle_key, user_id, released_at)
       SELECT handle_key, NULL, ?2 FROM social_profiles WHERE user_id = ?1
     ON CONFLICT (handle_key) DO UPDATE SET user_id = NULL, released_at = excluded.released_at`,
  ).bind(userId, now).run();
}
