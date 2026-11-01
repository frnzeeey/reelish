-- The daily retention job deletes audit events by age.
CREATE INDEX audit_events_created ON audit_events(created_at);
