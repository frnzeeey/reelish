-- A per-session token for background new-episode checks. The app's
-- background task cannot safely refresh the session (refresh tokens rotate,
-- and a reused one revokes the session), so it carries this instead. Only
-- its SHA-256 is stored; it opens only the episode-check route, and stops
-- working when its session is revoked or expires.
ALTER TABLE sessions ADD COLUMN notify_hash TEXT;
CREATE UNIQUE INDEX sessions_notify ON sessions(notify_hash);
