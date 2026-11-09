// What an account may use, decided here and nowhere else.
//
//   free       everything open to everyone
//   supporter  free + every supporter perk: a verified, unrefunded donation
//   founder    supporter + the Founder identity: the Trakt account named by the
//              FOUNDER_TRAKT_UUID secret, with or without a donation
//
// The Founder inherits the Supporter entitlement as a whole, never perk by
// perk, so a new perk reaches the Founder without anyone remembering to add it.
// Badges (badges.ts) stay display only: nothing checks a badge; checks call
// requirePerk.
//
// Adding a supporter perk: name it in SupporterPerk, call requirePerk where the
// server enforces it, and check SupporterController.has in the app
// (lib/src/account/supporter_controller.dart). docs/backend/entitlements.md.

import { isFounderUuid } from './badges';
import type { Env } from './env';
import { ApiError } from './http';

export type Entitlement = 'free' | 'supporter' | 'founder';

/** Every supporter perk, by the name the app uses too. */
export type SupporterPerk = 'host_watch_party' | 'app_themes' | 'app_icons' | 'avatar_frames';

/**
 * The Founder's own perks: the Founder Collection's cosmetics (a theme, a
 * launcher icon and the Founder avatar frame), which no donation unlocks. The
 * theme and icon are only ever seen by their owner, so there is nothing to
 * enforce; the app reads the entitlement from /supporters/me. The frame is seen
 * by others, so frames.ts enforces it. Named here so both sides list the same
 * perks.
 */
export type FounderPerk = 'founder_themes' | 'founder_icons' | 'founder_frames';

const refusals: Record<SupporterPerk, string> = {
  host_watch_party: 'Hosting a Watch Party is for Reelish Supporters.',
  app_themes: 'App themes are for Reelish Supporters.',
  app_icons: 'The supporter icons are for Reelish Supporters.',
  avatar_frames: 'Avatar frames are for Reelish Supporters.',
};

/** The account's entitlement, read fresh: a refund or a new secret applies at once. */
export async function entitlementOf(env: Env, userId: string): Promise<Entitlement> {
  const row = await env.DB.prepare(
    `SELECT u.trakt_uuid, s.supporter_since
     FROM users u LEFT JOIN supporter_profiles s ON s.user_id = u.id
     WHERE u.id = ?`,
  )
    .bind(userId)
    .first<{ trakt_uuid: string; supporter_since: number | null }>();
  if (!row) return 'free';
  if (isFounderUuid(env, row.trakt_uuid)) return 'founder';
  return row.supporter_since !== null ? 'supporter' : 'free';
}

/** Whether [entitlement] includes the supporter perks. */
export const hasSupporterPerks = (entitlement: Entitlement): boolean => entitlement !== 'free';

/** Whether [entitlement] includes the Founder's own perks: the Founder only. */
export const hasFounderPerks = (entitlement: Entitlement): boolean => entitlement === 'founder';

/** Throws 403 supporter_required unless the account has [perk]. */
export async function requirePerk(env: Env, userId: string, perk: SupporterPerk): Promise<void> {
  if (!hasSupporterPerks(await entitlementOf(env, userId))) {
    throw new ApiError(403, 'supporter_required', refusals[perk]);
  }
}
