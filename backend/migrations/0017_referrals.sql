-- Reelish Connect invitations: each account's invite code, and who joined
-- through whose invitation (backend/src/referrals.ts,
-- docs/features/reelish-connect.md). No rewards hang on either.
--
-- A code is made the first time its owner asks for it. An account can be
-- credited to one inviter only, once, never to itself. Both tables cascade
-- from users, so deleting an account removes its code and its referrals.
-- Times are server milliseconds.

CREATE TABLE referral_codes (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  code TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);

CREATE TABLE referrals (
  referred_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  referrer_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  CHECK (referred_id <> referrer_id)
);
CREATE INDEX referrals_referrer ON referrals (referrer_id, created_at);
