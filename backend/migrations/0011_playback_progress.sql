-- Playback progress synced across an account's devices (backend/src/progress.ts,
-- docs/intelligent-continue-watching/CROSS_DEVICE_SYNC_STRATEGY.md).
--
-- One row per title per account: a movie ('movie:<tmdb>'), an episode
-- ('episode:<tmdb>:<season>:<episode>') or a series' place in Continue watching
-- ('series:<tmdb>'). A row is replaced only by a newer change: from the same
-- device, a higher seq; from another device, a later client_at (the device's
-- clock corrected by its measured offset, clamped by the server to its own
-- time), ties broken by device_id. changed_at is the server's time of the last
-- accepted change, the cursor devices pull from.
CREATE TABLE playback_progress (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_key TEXT NOT NULL,
  position_ms INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  -- Episodes: the episode after this one, once it is watched.
  next_season INTEGER,
  next_episode INTEGER,
  -- 1: removed from Continue watching on some device.
  removed INTEGER NOT NULL DEFAULT 0,
  -- Movies and series: what a card needs (TMDB artwork URLs only).
  title TEXT,
  year TEXT,
  poster TEXT,
  backdrop TEXT,
  device_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  client_at INTEGER NOT NULL,
  changed_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, media_key)
);

CREATE INDEX playback_progress_changed ON playback_progress (user_id, changed_at);
