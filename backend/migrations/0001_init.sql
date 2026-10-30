-- Reelish accounts. Trakt is the identity; Reelish keeps only what it needs
-- to issue sessions and act for the user on Trakt.

-- One row per Trakt account. trakt_uuid is Trakt's stable id; the
-- username can change and is kept for display only.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  trakt_uuid TEXT NOT NULL UNIQUE,
  trakt_username TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- The user's Trakt OAuth tokens, AES-GCM encrypted. version guards
-- concurrent refreshes, since Trakt hands back a new refresh token.
CREATE TABLE trakt_credentials (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  access_token_enc TEXT NOT NULL,
  refresh_token_enc TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  scope TEXT NOT NULL DEFAULT '',
  version INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL
);

-- One row per signed-in device. Only the SHA-256 of the refresh token is
-- stored; previous_refresh_hash catches reuse of a rotated token.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  refresh_hash TEXT NOT NULL UNIQUE,
  previous_refresh_hash TEXT,
  device_name TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  refresh_expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX sessions_user ON sessions(user_id);
CREATE INDEX sessions_previous_refresh ON sessions(previous_refresh_hash);

-- Pending Trakt device sign-ins. The app holds only poll_hash's token;
-- Trakt's device_code never leaves the backend.
CREATE TABLE device_authorizations (
  poll_hash TEXT PRIMARY KEY,
  device_code_enc TEXT NOT NULL,
  interval_seconds INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  next_poll_at INTEGER NOT NULL,
  device_name TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX device_authorizations_expiry ON device_authorizations(expires_at);

-- Security-relevant events, without tokens or personal data beyond ids.
CREATE TABLE audit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT,
  session_id TEXT,
  event TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX audit_events_user ON audit_events(user_id, created_at);
