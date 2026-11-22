// Reelish Connect invitations: an account's invite code, how many people
// joined through it, and crediting a new account to the friend who invited
// it. Nothing is rewarded, so the rules only keep the count honest: a new
// account (14 days at most) is credited once, to one inviter, never to
// itself, and an inviter gains at most [dailyCreditLimit] a day.
// docs/features/reelish-connect.md.

import type { Env } from './env';
import { log } from './audit';
import { ApiError, json, readJsonBody } from './http';
import { requireLiveSession, type Principal } from './sessions';
import { codeLength, newFriendCode } from './social/profiles';

/** How new an account must be to be credited to an inviter. */
export const claimWindowMs = 14 * 24 * 60 * 60 * 1000;
/** Most new accounts one inviter is credited with in a UTC day. */
export const dailyCreditLimit = 25;

const day = 24 * 60 * 60 * 1000;
const createAttempts = 5;

/** The same answer for a code that does not exist and one never made. */
const notFound = () => new ApiError(404, 'invite_not_found', 'That invite code wasn’t found. Check it and try again.');

/** An invite code as people type it: case, spaces and dashes ignored. */
export function normaliseInviteCode(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const code = value.toUpperCase().replace(/[\s-]/g, '');
  return /^[A-HJ-NP-Z2-9]+$/.test(code) && code.length === codeLength ? code : null;
}

/** The caller's code, made now if they never asked for one. */
async function codeOf(env: Env, userId: string): Promise<string> {
  const existing = await env.DB.prepare(`SELECT code FROM referral_codes WHERE user_id = ?`)
    .bind(userId).first<{ code: string }>();
  if (existing) return existing.code;
  for (let attempt = 0; attempt < createAttempts; attempt++) {
    const code = newFriendCode();
    // A clash with another account's code just tries again; a race with
    // this account's own first request keeps whichever was saved.
    const saved = await env.DB.prepare(
      `INSERT INTO referral_codes (user_id, code, created_at) VALUES (?, ?, ?)
       ON CONFLICT DO NOTHING RETURNING code`,
    ).bind(userId, code, Date.now()).first<{ code: string }>();
    if (saved) return saved.code;
    const mine = await env.DB.prepare(`SELECT code FROM referral_codes WHERE user_id = ?`)
      .bind(userId).first<{ code: string }>();
    if (mine) return mine.code;
  }
  throw new ApiError(503, 'invite_code_unavailable', 'Couldn’t make an invite code. Try again.');
}

/** GET /referrals/me: the caller's invite code and how many joined with it. */
export async function myInvites(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  const code = await codeOf(env, principal.userId);
  const counts = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM referrals WHERE referrer_id = ?`,
  ).bind(principal.userId).first<{ n: number }>();
  const mine = await env.DB.prepare(
    `SELECT 1 AS yes FROM referrals WHERE referred_id = ?`,
  ).bind(principal.userId).first<{ yes: number }>();
  return json({ code, joined: counts?.n ?? 0, invited: mine !== null }, requestId);
}

/**
 * POST /referrals/claim {code}: credits the caller's account to the owner of
 * [code]. 201 when credited now, 200 when it already was to the same person.
 */
export async function claimInvite(env: Env, principal: Principal, request: Request, requestId: string) {
  await requireLiveSession(env, principal);
  const body = await readJsonBody(request);
  const code = normaliseInviteCode(body.code);
  if (!code) throw notFound();
  const owner = await env.DB.prepare(`SELECT user_id FROM referral_codes WHERE code = ?`)
    .bind(code).first<{ user_id: string }>();
  if (!owner) throw notFound();
  if (owner.user_id === principal.userId) {
    throw new ApiError(409, 'own_invite', 'That’s your own invite code. Share it with a friend instead.');
  }
  const existing = await env.DB.prepare(`SELECT referrer_id FROM referrals WHERE referred_id = ?`)
    .bind(principal.userId).first<{ referrer_id: string }>();
  if (existing) {
    if (existing.referrer_id === owner.user_id) return json({ credited: true }, requestId);
    throw new ApiError(409, 'already_invited', 'Your account already joined through another invitation.');
  }
  const account = await env.DB.prepare(`SELECT created_at FROM users WHERE id = ?`)
    .bind(principal.userId).first<{ created_at: number }>();
  const now = Date.now();
  // users.created_at is in seconds.
  if (!account || account.created_at * 1000 < now - claimWindowMs) {
    throw new ApiError(409, 'invite_too_late', 'Invitations count only for new accounts.');
  }
  const today = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM referrals WHERE referrer_id = ? AND created_at > ?`,
  ).bind(owner.user_id, now - day).first<{ n: number }>();
  if ((today?.n ?? 0) >= dailyCreditLimit) {
    log('warn', 'referrals.daily_limit', {});
    throw new ApiError(429, 'invite_limit', 'This invitation can’t be accepted right now. Try again tomorrow.');
  }
  // The primary key keeps one inviter per account, even in a race.
  const saved = await env.DB.prepare(
    `INSERT INTO referrals (referred_id, referrer_id, created_at) VALUES (?, ?, ?)
     ON CONFLICT DO NOTHING RETURNING referrer_id`,
  ).bind(principal.userId, owner.user_id, now).first<{ referrer_id: string }>();
  if (!saved) {
    throw new ApiError(409, 'already_invited', 'Your account already joined through another invitation.');
  }
  return json({ credited: true }, requestId, 201);
}
