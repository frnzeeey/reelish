-- Hosting a watch party is free for everyone (November 2026), so room
-- creation gets its own budget and room lookups their own index, keeping the
-- Workers Free plan's daily Durable Object limits for real parties.

-- The hosting quota: how many rooms the account created in the hour that
-- started at window_start (unix seconds). Checked and counted by createParty.
ALTER TABLE party_hosts ADD COLUMN window_start INTEGER NOT NULL DEFAULT 0;
ALTER TABLE party_hosts ADD COLUMN window_count INTEGER NOT NULL DEFAULT 0;

-- Every live room's code. A lookup for a code not here (a guess, a typo, a
-- room that ended) is answered from D1 without waking a Durable Object. The
-- room deletes its row when it ends; the daily cron removes rows older than
-- a room's 12-hour lifetime.
CREATE TABLE party_codes (
  code TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL
);

-- Rooms open while this migration runs: each host's latest room.
INSERT OR IGNORE INTO party_codes (code, created_at)
  SELECT code, created_at FROM party_hosts;
