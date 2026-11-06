-- The Reelish Supporters Program (backend/src/supporters.ts).
--
-- supporter_profiles: one row per account that opened the Supporters page.
-- support_code is opaque and carries nothing about the account; it is what a
-- donor pastes into their Buy Me a Coffee message. supporter_since is set only
-- by a verified donation, and never by the app.
CREATE TABLE supporter_profiles (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  support_code TEXT NOT NULL UNIQUE,
  supporter_since INTEGER,
  claim_requested_at INTEGER,
  public_listed INTEGER NOT NULL DEFAULT 0,
  public_name TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX supporter_profiles_public ON supporter_profiles(public_listed, supporter_since);

-- One row per donation, for idempotency and for refunds. reference is a hash
-- of the provider's payment id. No amount, email, name, note or card detail is
-- stored: only what is needed to know that a donation stands. user_id stays
-- null for a donation that named no account.
CREATE TABLE donations (
  provider TEXT NOT NULL,
  reference TEXT NOT NULL,
  kind TEXT NOT NULL,
  user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  donated_at INTEGER NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (provider, reference)
);
CREATE INDEX donations_user ON donations(user_id, status);
