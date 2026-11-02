-- Bug reports and feedback sent from Help & Support in the app.
-- The reporter is stored as a hash of the account id (for the daily limit and
-- for deleting a person's reports with their account), never the id itself.
-- Rows are deleted after 180 days by the daily retention job.
CREATE TABLE support_reports (
  id TEXT PRIMARY KEY,
  reporter_hash TEXT NOT NULL,
  kind TEXT NOT NULL,
  category TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  steps TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL,
  diagnostics TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);
CREATE INDEX support_reports_reporter ON support_reports(reporter_hash, created_at);
CREATE INDEX support_reports_created ON support_reports(created_at);
