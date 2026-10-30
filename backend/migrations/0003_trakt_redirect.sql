-- The redirect URI a Trakt grant was issued for. Trakt's refresh request
-- names one, and browser sign-ins (the API's callback) and device
-- sign-ins (out-of-band) differ. '' for grants saved before this column:
-- refreshing tries the known redirect URIs in turn.
ALTER TABLE trakt_credentials ADD COLUMN redirect_uri TEXT NOT NULL DEFAULT '';
