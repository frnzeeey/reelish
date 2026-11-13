// The daily cleanup of social rows past their retention
// (docs/friends-activity/DATABASE_SCHEMA.md, Retention and deletion).

import type { Env } from '../env';
import { handleHoldMs } from './profiles';

const day = 24 * 60 * 60 * 1000;
export const requestRetentionMs = 30 * day;
export const recommendationRetentionMs = 180 * day;
const batch = 5000;

/** Deletes held handles, old requests and recommendations, expired activity and old counters. */
export async function pruneSocial(env: Env, now = Date.now()): Promise<number> {
  const today = Math.floor(now / day);
  const results = await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM released_handles WHERE handle_key IN
         (SELECT handle_key FROM released_handles WHERE released_at <= ? LIMIT ${batch})`,
    ).bind(now - handleHoldMs),
    env.DB.prepare(
      `DELETE FROM friend_requests WHERE rowid IN
         (SELECT rowid FROM friend_requests WHERE created_at < ? LIMIT ${batch})`,
    ).bind(now - requestRetentionMs),
    env.DB.prepare(
      `DELETE FROM recommendations WHERE rowid IN
         (SELECT rowid FROM recommendations WHERE created_at < ? LIMIT ${batch})`,
    ).bind(now - recommendationRetentionMs),
    env.DB.prepare(
      `DELETE FROM current_activity WHERE user_id IN
         (SELECT user_id FROM current_activity WHERE expires_at <= ? LIMIT ${batch})`,
    ).bind(now),
    env.DB.prepare(
      `DELETE FROM social_counters WHERE rowid IN
         (SELECT rowid FROM social_counters WHERE day < ? LIMIT ${batch})`,
    ).bind(today - 2),
  ]);
  return results.reduce((sum, result) => sum + (result.meta.changes ?? 0), 0);
}
