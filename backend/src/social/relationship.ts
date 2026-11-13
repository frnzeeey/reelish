// How two accounts relate, checked on the server at the moment of every read
// or write that involves another user's social data. Nothing is cached: a
// removed friend or a new block takes effect on the next request.
// docs/friends-activity/SECURITY_AND_PRIVACY.md.

import type { Env } from '../env';

/** self: the same account; blocked: a block either way; friend: an accepted friendship. */
export type Relationship = 'self' | 'friend' | 'blocked' | 'none';

/** The pair as friendships stores it, smaller id first. */
export function orderedPair(one: string, other: string): [string, string] {
  return one < other ? [one, other] : [other, one];
}

/** How [viewer] relates to [owner]. A block wins over a friendship. */
export async function relationship(env: Env, viewer: string, owner: string): Promise<Relationship> {
  if (viewer === owner) return 'self';
  const [a, b] = orderedPair(viewer, owner);
  const row = await env.DB.prepare(
    `SELECT
       EXISTS (SELECT 1 FROM blocks
                WHERE (blocker_id = ?1 AND blocked_id = ?2) OR (blocker_id = ?2 AND blocked_id = ?1)) AS blocked,
       EXISTS (SELECT 1 FROM friendships WHERE user_a = ?3 AND user_b = ?4) AS friend`,
  ).bind(viewer, owner, a, b).first<{ blocked: number; friend: number }>();
  if (row?.blocked) return 'blocked';
  if (row?.friend) return 'friend';
  return 'none';
}
