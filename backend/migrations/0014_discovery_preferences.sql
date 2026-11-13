-- Discovery preferences synced across an account's devices
-- (backend/src/discovery-preferences.ts, docs/discovery/DISCOVERY_IMPLEMENTATION_REPORT.md).
--
-- One row per account: whether the genre step was completed or skipped, the
-- TMDB genre ids picked, and whether personalised rows are wanted. body is
-- the preferences as the server validated and re-serialised them, never the
-- device's raw JSON. Viewing activity and feedback stay on the device.
--
-- The row is replaced only by a newer change, as in playback_progress: from
-- the same device, a higher seq; from another device, a later client_at (the
-- device clock corrected by its measured offset, clamped to the server's
-- time), ties broken by device_id.
CREATE TABLE discovery_preferences (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  body TEXT NOT NULL,
  device_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  client_at INTEGER NOT NULL,
  changed_at INTEGER NOT NULL
);
