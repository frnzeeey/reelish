-- Avatar frames (backend/src/frames.ts). The frame an account chose to wear,
-- by its stable id; NULL is the default (the Founder frame for the Founder,
-- none for everyone else) and 'none' a choice of no frame. Whether the account
-- may still wear it is decided each time it is read, so a lapsed entitlement
-- simply shows no frame, and the choice comes back if it returns.
ALTER TABLE users ADD COLUMN avatar_frame TEXT;

-- Limited editions an account collected by wearing one while it was open.
CREATE TABLE collected_frames (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  frame_id TEXT NOT NULL,
  collected_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, frame_id)
);
