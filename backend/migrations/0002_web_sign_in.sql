-- Pending browser sign-ins (Trakt's authorization-code flow). Trakt sends
-- the browser back to the API's callback, never to the app: the app holds
-- only the poll token, the backend keeps the PKCE verifier, and the Trakt
-- code is exchanged server-side with the client secret.
--
-- status: pending → exchanging (callback claimed it) → authorized | denied
-- | failed. An authorized row is deleted when the app collects its session.
CREATE TABLE web_authorizations (
  state_hash TEXT PRIMARY KEY,
  poll_hash TEXT NOT NULL UNIQUE,
  verifier_enc TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  device_name TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT '',
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX web_authorizations_expiry ON web_authorizations(expires_at);
