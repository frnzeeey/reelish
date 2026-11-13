-- Friends: social profiles, friend requests, friendships, blocks,
-- recommendations and the one current activity a user may share
-- (backend/src/social/, docs/friends-activity/DATABASE_SCHEMA.md).
--
-- Nothing here exists for an account until its owner turns Friends on (a
-- social_profiles row). Every table cascades from users, so deleting an
-- account removes its social data. Times are server milliseconds.

-- A user's social profile. No row: Friends is off, and nothing about the
-- account can be found or seen.
CREATE TABLE social_profiles (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  handle TEXT NOT NULL,
  handle_key TEXT NOT NULL UNIQUE,
  handle_changed_at INTEGER NOT NULL,
  friend_code TEXT NOT NULL UNIQUE,
  display_name TEXT,
  avatar_preset TEXT,
  find_by_code INTEGER NOT NULL DEFAULT 1,
  find_by_handle INTEGER NOT NULL DEFAULT 0,
  allow_recommendations INTEGER NOT NULL DEFAULT 1,
  share_activity INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- A handle given up (changed, Friends turned off, account deleted) is held
-- for 30 days so nobody else can take it and pass as its owner. The same
-- account may take it back. No foreign key: the account may be gone.
CREATE TABLE released_handles (
  handle_key TEXT PRIMARY KEY,
  user_id TEXT,
  released_at INTEGER NOT NULL
);

-- Pending requests only; accepted ones become friendships, declined and
-- cancelled ones are deleted.
CREATE TABLE friend_requests (
  sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  receiver_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (sender_id, receiver_id),
  CHECK (sender_id <> receiver_id)
);
CREATE INDEX friend_requests_receiver ON friend_requests (receiver_id, created_at);

-- One row per friendship, stored once with user_a < user_b.
CREATE TABLE friendships (
  user_a TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_b TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_a, user_b),
  CHECK (user_a < user_b)
);
CREATE INDEX friendships_b ON friendships (user_b);

CREATE TABLE blocks (
  blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);
CREATE INDEX blocks_blocked ON blocks (blocked_id);

-- Private, sender to recipient. The card is a snapshot (title, year, TMDB
-- artwork URL), so the inbox needs no TMDB requests. Re-sending the same
-- title to the same friend refreshes the row instead of adding one.
CREATE TABLE recommendations (
  id TEXT PRIMARY KEY,
  sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  recipient_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_key TEXT NOT NULL,
  title TEXT NOT NULL,
  year TEXT,
  poster TEXT,
  message TEXT,
  client_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  read_at INTEGER,
  UNIQUE (sender_id, client_id, recipient_id),
  UNIQUE (sender_id, recipient_id, media_key)
);
CREATE INDEX recommendations_inbox ON recommendations (recipient_id, created_at);
CREATE INDEX recommendations_sent ON recommendations (sender_id, created_at);

-- At most one current activity per user, never a history. expires_at is set
-- by the server; a row past it is never returned.
CREATE TABLE current_activity (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  media_key TEXT NOT NULL,
  season INTEGER,
  episode INTEGER,
  title TEXT NOT NULL,
  poster TEXT,
  started_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX current_activity_expiry ON current_activity (expires_at);

-- Daily send counters, one row per user and UTC day. Kept when Friends is
-- turned off, so switching it off and on does not reset a limit.
CREATE TABLE social_counters (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  day INTEGER NOT NULL,
  requests INTEGER NOT NULL DEFAULT 0,
  recommendations INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day)
);

-- Collections: who may see one, as a real column so a friend's read is an
-- indexed WHERE. Every existing collection is private.
ALTER TABLE collection_records ADD COLUMN visibility TEXT NOT NULL DEFAULT 'private'
  CHECK (visibility IN ('private', 'friends'));
CREATE INDEX collection_records_shared
  ON collection_records (user_id, kind, visibility) WHERE deleted = 0;
