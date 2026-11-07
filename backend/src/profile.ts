// The Trakt username and avatar shown on every device of an account. Trakt is
// the source of truth: sign-in stores what it says, and GET /me reads it again
// at most once a day. Only the avatar's URL is kept; the image is never copied.

import type { Env } from './env';
import { log } from './audit';
import { fetchIdentity, traktAccessToken, type TraktDeps } from './trakt';
import { ApiError } from './http';

/** How long a profile read from Trakt is trusted before reading it again. */
export const profileMaxAgeSeconds = 24 * 60 * 60;

/** After a failed read, how long until the next try (not every request). */
export const profileRetrySeconds = 60 * 60;

const now = () => Math.floor(Date.now() / 1000);

/**
 * Reads the username and avatar from Trakt again when the stored ones are
 * older than a day. One device claims the read, so two asking at once cost
 * one Trakt call. A failure keeps what is stored, so a bad answer never
 * blanks a profile, and waits an hour before trying again.
 */
export async function refreshProfileIfStale(env: Env, userId: string, deps: TraktDeps = {}): Promise<void> {
  const at = now();
  const claim = await env.DB.prepare(
    `UPDATE users SET trakt_profile_checked_at = ?
     WHERE id = ? AND (trakt_profile_checked_at IS NULL OR trakt_profile_checked_at < ?)`,
  ).bind(at, userId, at - profileMaxAgeSeconds).run();
  if ((claim.meta.changes ?? 0) !== 1) return;
  try {
    const identity = await fetchIdentity(env, await traktAccessToken(env, userId, deps), deps);
    // Only the Trakt account this row belongs to may change it, and only a
    // real change is written.
    await env.DB.prepare(
      `UPDATE users SET trakt_username = ?, trakt_avatar_url = ?, updated_at = ?
       WHERE id = ? AND trakt_uuid = ?
         AND (trakt_username IS NOT ? OR trakt_avatar_url IS NOT ?)`,
    ).bind(identity.username, identity.avatarUrl, at, userId, identity.uuid,
      identity.username, identity.avatarUrl).run();
  } catch (error) {
    log('warn', 'trakt.profile_refresh_failed', {
      code: error instanceof ApiError ? error.code : 'internal',
    });
    await env.DB.prepare(`UPDATE users SET trakt_profile_checked_at = ? WHERE id = ?`)
      .bind(at - profileMaxAgeSeconds + profileRetrySeconds, userId).run();
  }
}
