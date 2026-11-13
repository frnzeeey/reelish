// Watching now: at most one current activity per account, only while its
// owner shares activity, never a history. The server sets the expiry, so a
// device that crashes or loses its connection cannot leave it showing; the
// daily cron deletes expired rows. Friends read it on demand: nothing
// streams and nothing polls. docs/friends-activity/SECURITY_AND_PRIVACY.md.

import type { Env } from '../env';
import { ApiError, json, readJsonBody } from '../http';
import { requireLiveSession, type Principal } from '../sessions';
import { publicView } from './friends';
import { requireProfile } from './profiles';
import { parseMedia } from './recommendations';

const minute = 60 * 1000;
/** Shortest and longest an activity lasts without another update. */
export const minExpiryMs = 15 * minute;
export const maxExpiryMs = 4 * 60 * minute;
/** Without a remaining time from the device. */
export const defaultExpiryMs = 3 * 60 * minute;
/** After the end the device reported, so a pause does not end it early. */
const graceMs = 10 * minute;
/** Friends listed as watching. */
export const maxWatching = 100;

const invalid = (message: string) => new ApiError(400, 'invalid_activity', message);

function episodeNumber(value: unknown, field: string): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isSafeInteger(value) || (value as number) < 0 || (value as number) > 9999) {
    throw invalid(`${field} must be a whole number.`);
  }
  return value as number;
}

/**
 * PUT /social/activity `{media, season?, episode?, remainingMs?}`: what I am
 * watching now. 409 `sharing_off` unless I share activity.
 */
export async function publish(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  const media = parseMedia(body.media);
  const season = episodeNumber(body.season, 'season');
  const episode = episodeNumber(body.episode, 'episode');
  const remaining = body.remainingMs;
  if (remaining !== undefined && (!Number.isSafeInteger(remaining) || (remaining as number) < 0)) {
    throw invalid('remainingMs must be a whole number.');
  }
  await requireLiveSession(env, principal);
  const profile = await requireProfile(env, principal.userId);
  if (profile.share_activity !== 1) {
    throw new ApiError(409, 'sharing_off', 'Turn on "Share what I\'m watching" first.');
  }
  const now = Date.now();
  const lasts = remaining === undefined
    ? defaultExpiryMs
    : Math.min(maxExpiryMs, Math.max(minExpiryMs, (remaining as number) + graceMs));
  // The same title and episode keeps when it started; anything else starts now.
  await env.DB.prepare(
    `INSERT INTO current_activity (user_id, media_key, season, episode, title, poster, started_at, updated_at, expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?8)
     ON CONFLICT (user_id) DO UPDATE SET
       started_at = CASE
         WHEN current_activity.media_key = excluded.media_key
          AND current_activity.season IS excluded.season
          AND current_activity.episode IS excluded.episode
          AND current_activity.expires_at > excluded.updated_at
         THEN current_activity.started_at ELSE excluded.started_at END,
       media_key = excluded.media_key, season = excluded.season, episode = excluded.episode,
       title = excluded.title, poster = excluded.poster,
       updated_at = excluded.updated_at, expires_at = excluded.expires_at`,
  ).bind(principal.userId, media.key, season, episode, media.title, media.poster, now, now + lasts).run();
  return json({ expiresAt: now + lasts }, requestId);
}

/** DELETE /social/activity: I stopped watching. */
export async function clear(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  await env.DB.prepare(`DELETE FROM current_activity WHERE user_id = ?`).bind(principal.userId).run();
  return json({ ok: true }, requestId);
}

interface WatchingRow {
  handle: string;
  display_name: string | null;
  avatar_preset: string | null;
  media_key: string;
  season: number | null;
  episode: number | null;
  title: string;
  poster: string | null;
  started_at: number;
}

/**
 * GET /social/activity: friends watching something now, latest first. Only
 * friends who share activity, with an activity not yet expired.
 */
export async function friendsWatching(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  const me = principal.userId;
  await requireProfile(env, me);
  const { results } = await env.DB.prepare(
    `SELECT p.handle, p.display_name, p.avatar_preset,
            a.media_key, a.season, a.episode, a.title, a.poster, a.started_at
       FROM friendships f
       JOIN social_profiles p ON p.user_id = CASE WHEN f.user_a = ?1 THEN f.user_b ELSE f.user_a END
       JOIN current_activity a ON a.user_id = p.user_id
      WHERE (f.user_a = ?1 OR f.user_b = ?1) AND p.share_activity = 1 AND a.expires_at > ?2
      ORDER BY a.updated_at DESC LIMIT ${maxWatching}`,
  ).bind(me, Date.now()).all<WatchingRow>();
  return json({
    watching: results.map((row) => {
      const [type, id] = row.media_key.split(':');
      return {
        person: publicView(row),
        media: { type, id, title: row.title, poster: row.poster },
        season: row.season,
        episode: row.episode,
        startedAt: row.started_at,
      };
    }),
  }, requestId);
}
