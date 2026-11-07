// The badges on an account, always worked out here. Each has its own source, and
// none grants any permission: they say who someone is, never what they may do.
//
//   founder    the Trakt account named by the FOUNDER_TRAKT_UUID secret
//   supporter  a verified donation (supporters.ts)
//
// Founder lives in a Worker secret rather than a row so that nothing reachable
// from an API request can write it. It uses Trakt's uuid, which stays the same
// when the username changes, and which comes back if the account is deleted and
// signed up again.

import type { Env } from './env';

export type AccountBadge = 'founder' | 'supporter';

const isFounderUuid = (env: Env, uuid: string | undefined): boolean =>
  !!env.FOUNDER_TRAKT_UUID && uuid === env.FOUNDER_TRAKT_UUID;

/** The account's badges, in display order. */
export async function badgesOf(env: Env, userId: string): Promise<AccountBadge[]> {
  const row = await env.DB.prepare(
    `SELECT u.trakt_uuid, s.supporter_since
     FROM users u LEFT JOIN supporter_profiles s ON s.user_id = u.id
     WHERE u.id = ?`,
  )
    .bind(userId)
    .first<{ trakt_uuid: string; supporter_since: number | null }>();
  if (!row) return [];
  return [
    ...(isFounderUuid(env, row.trakt_uuid) ? (['founder'] as const) : []),
    ...(row.supporter_since !== null ? (['supporter'] as const) : []),
  ];
}

/** For a Watch Party, where others see the badge next to a name. */
export async function isFounder(env: Env, userId: string): Promise<boolean> {
  if (!env.FOUNDER_TRAKT_UUID) return false;
  const row = await env.DB.prepare(`SELECT trakt_uuid FROM users WHERE id = ?`)
    .bind(userId)
    .first<{ trakt_uuid: string }>();
  return isFounderUuid(env, row?.trakt_uuid);
}
