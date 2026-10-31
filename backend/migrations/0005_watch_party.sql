-- The watch party each user hosts, at most one: creating another ends the
-- old room first, so one account cannot hold many rooms open. The room's
-- state lives in its Durable Object; this row only points at it.
CREATE TABLE party_hosts (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
