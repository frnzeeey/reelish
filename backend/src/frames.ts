// Avatar frames: collectible cosmetics around a profile's avatar. The server is
// the authority on which frame an account wears and which it may equip, so a
// frame syncs across devices and neither edited local data nor a forged request
// can wear one. docs/backend/frames.md.
//
//   supporter frames  the supporter perk `avatar_frames` (the Founder inherits it)
//   founder frames    the Founder alone (hasFounderPerks)
//   limited editions  collected by equipping one while its window is open; a
//                     collected frame stays the account's after the window, as
//                     long as it has the perk. The Founder has every frame.
//
// The app draws each frame from the same id (lib/src/theme/avatar_frames.dart).
// Ids are stored; never rename one.

import { entitlementOf, hasFounderPerks, hasSupporterPerks, type Entitlement } from './entitlements';
import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { requireLiveSession, type Principal } from './sessions';

export interface FrameSpec {
  id: string;
  /** Who may wear it: supporters (and the Founder), or the Founder alone. */
  access: 'supporter' | 'founder';
  /** A limited edition: collectable between these Unix seconds only. */
  limited?: { from: number; until: number };
}

const utc = (date: string) => Math.floor(Date.parse(`${date}T00:00:00Z`) / 1000);

export const frames: readonly FrameSpec[] = [
  { id: 'aurora', access: 'supporter' },
  { id: 'celestial', access: 'supporter' },
  { id: 'royal', access: 'supporter' },
  { id: 'rose_gold', access: 'supporter' },
  { id: 'eclipse', access: 'supporter' },
  { id: 'nebula', access: 'supporter' },
  { id: 'prism', access: 'supporter' },
  { id: 'obsidian', access: 'supporter' },
  { id: 'supporter', access: 'supporter' },
  // The first limited edition, for the launch of avatar frames.
  { id: 'premiere_2026', access: 'supporter', limited: { from: utc('2026-11-01'), until: utc('2027-02-01') } },
  { id: 'founder', access: 'founder' },
];

/** Stored when an account chose to wear no frame (NULL means the default). */
const noFrame = 'none';

export const frameById = (id: unknown): FrameSpec | undefined =>
  typeof id === 'string' ? frames.find((frame) => frame.id === id) : undefined;

const nowSeconds = () => Math.floor(Date.now() / 1000);

/** Whether [frame] is collectable now (always, unless a closed limited edition). */
export const isOpen = (frame: FrameSpec, now = nowSeconds()): boolean =>
  !frame.limited || (now >= frame.limited.from && now < frame.limited.until);

/** Whether an account with [entitlement] and [collected] may wear [frame] now. */
export function mayWear(
  frame: FrameSpec,
  entitlement: Entitlement,
  collected: ReadonlySet<string>,
  now = nowSeconds(),
): boolean {
  if (hasFounderPerks(entitlement)) return true;
  if (frame.access === 'founder' || !hasSupporterPerks(entitlement)) return false;
  return isOpen(frame, now) || collected.has(frame.id);
}

async function collectedBy(env: Env, userId: string): Promise<Set<string>> {
  const { results } = await env.DB.prepare(`SELECT frame_id FROM collected_frames WHERE user_id = ?`)
    .bind(userId).all<{ frame_id: string }>();
  return new Set(results.map((row) => row.frame_id));
}

export interface FrameState {
  /** The frame worn now: the chosen one while the account may wear it. */
  equipped: string | null;
  /** Every frame the account may equip now. */
  available: string[];
  /** Limited editions the account has collected. */
  collected: string[];
}

/** The account's frames, read fresh: a refund or a closed window applies at once. */
export async function frameState(env: Env, userId: string, now = nowSeconds()): Promise<FrameState> {
  const [entitlement, collected, row] = await Promise.all([
    entitlementOf(env, userId),
    collectedBy(env, userId),
    env.DB.prepare(`SELECT avatar_frame FROM users WHERE id = ?`).bind(userId)
      .first<{ avatar_frame: string | null }>(),
  ]);
  const available = frames.filter((frame) => mayWear(frame, entitlement, collected, now)).map((f) => f.id);
  const chosen = row?.avatar_frame ?? null;
  // Never chosen: the Founder wears the Founder frame, everyone else none.
  const wanted = chosen === null ? (hasFounderPerks(entitlement) ? 'founder' : null) : chosen;
  const equipped = wanted !== null && wanted !== noFrame && available.includes(wanted) ? wanted : null;
  return { equipped, available, collected: [...collected] };
}

/** The frame others see in a Watch Party: the one the account wears now. */
export const equippedFrame = async (env: Env, userId: string) => (await frameState(env, userId)).equipped;

/** PUT /me/frame {frame: id | null}: wears a frame, or none. */
export async function setFrame(env: Env, principal: Principal, request: Request, requestId: string) {
  await requireLiveSession(env, principal);
  const body = await readJsonBody(request);
  const userId = principal.userId;
  if (body.frame === null) {
    await env.DB.prepare(`UPDATE users SET avatar_frame = ? WHERE id = ?`).bind(noFrame, userId).run();
    return json({ frames: await frameState(env, userId) }, requestId);
  }
  const frame = frameById(body.frame);
  if (!frame) throw new ApiError(400, 'unknown_frame', 'That frame does not exist.');
  const now = nowSeconds();
  const [entitlement, collected] = await Promise.all([entitlementOf(env, userId), collectedBy(env, userId)]);
  if (frame.access === 'founder' && !hasFounderPerks(entitlement)) {
    throw new ApiError(403, 'founder_only', 'That frame belongs to the Founder.');
  }
  if (!hasSupporterPerks(entitlement)) {
    throw new ApiError(403, 'supporter_required', 'Avatar frames are for Reelish Supporters.');
  }
  if (!mayWear(frame, entitlement, collected, now)) {
    throw new ApiError(409, 'frame_unavailable', 'That limited edition can no longer be collected.');
  }
  // Wearing a limited edition while it is open collects it for good.
  if (frame.limited && isOpen(frame, now)) {
    await env.DB.prepare(
      `INSERT OR IGNORE INTO collected_frames (user_id, frame_id, collected_at) VALUES (?, ?, ?)`,
    ).bind(userId, frame.id, now).run();
  }
  await env.DB.prepare(`UPDATE users SET avatar_frame = ? WHERE id = ?`).bind(frame.id, userId).run();
  return json({ frames: await frameState(env, userId, now) }, requestId);
}
