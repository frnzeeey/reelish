-- Private messages (docs/messaging/README.md). Messages themselves are not
-- in D1: each account's mailbox Durable Object holds only those not yet
-- delivered. D1 keeps the daily send count, beside the other social limits,
-- so turning Friends off and on resets nothing; the daily cron prunes it.
ALTER TABLE social_counters ADD COLUMN messages INTEGER NOT NULL DEFAULT 0;
