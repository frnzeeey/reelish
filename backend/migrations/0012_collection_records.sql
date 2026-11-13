-- Custom collections synced across an account's devices (backend/src/collections.ts,
-- docs/custom-collections/COLLECTION_SYNC_STRATEGY.md).
--
-- One row per record per account: a folder or a collection (record_key is its
-- id) or a title in a collection (record_key 'collectionId|movie:<tmdb>' or
-- 'collectionId|series:<tmdb>'). body is the record's fields as the server
-- validated and re-serialised them, never the device's raw JSON. deleted keeps
-- a deletion so an older copy cannot bring the record back.
--
-- A row is replaced only by a newer change, as in playback_progress: from the
-- same device, a higher seq; from another device, a later client_at (the
-- device clock corrected by its measured offset, clamped to the server's
-- time), ties broken by device_id. changed_at is the server's time of the last
-- accepted change, the cursor devices pull from.
CREATE TABLE collection_records (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('folder', 'collection', 'entry')),
  record_key TEXT NOT NULL,
  body TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  device_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  client_at INTEGER NOT NULL,
  changed_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, kind, record_key)
);

CREATE INDEX collection_records_changed ON collection_records (user_id, changed_at);
