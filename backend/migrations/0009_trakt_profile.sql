-- The Trakt avatar beside the username, so every device of an account shows
-- the same profile. Trakt stays the source of truth: both are refreshed from
-- it at sign-in and at most once a day after (backend/src/profile.ts).
-- trakt_avatar_url is NULL when the account has no avatar of its own.
ALTER TABLE users ADD COLUMN trakt_avatar_url TEXT;

-- When the username and avatar were last read from Trakt (Unix seconds).
-- NULL makes the next GET /me read them, which fills the avatar in for
-- accounts made before this column.
ALTER TABLE users ADD COLUMN trakt_profile_checked_at INTEGER;
