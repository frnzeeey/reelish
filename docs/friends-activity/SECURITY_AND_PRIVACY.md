# Friends & Activity: security and privacy

The Worker is the only party that reads or writes social data. The app
never names the acting account; it is always the session's user. Every
read of another user's data goes through one relationship check.

## Threat model

| Threat | Mitigation |
|---|---|
| Enumerating users | "Taken" answers to handle claims limited to 10 an hour per account. Exact handle or code only; no prefix search, no listing. A lookup of an unknown, hidden or blocked handle answers the same "not found". `SOCIAL_LIMITER` per user, plus a stricter lookup limit (e.g. 10 a minute). Codes are 8 characters from a 32-letter alphabet (~10¹² combinations). |
| Learning someone's Trakt identity | The Trakt username and avatar are never returned by social routes (decision D2). Only the handle, the optional display name and preset avatar the user chose. |
| Fake friendship | Friendships are created only by the receiver accepting, or by matching requests, inside the Worker. No route accepts a friendship body. |
| Accepting or cancelling for someone else | Accept and decline act only on requests where `receiver_id = me`; cancel only where `sender_id = me`. |
| Reading private activity | Returned only when `share_activity = 1`, the viewer is a friend, there is no block, and `expires_at > now`. |
| Stale activity | The server sets `expires_at`; reads filter on it; the cron deletes expired rows. Turning sharing off deletes the row in the same request. |
| Reading private collections | Friends' reads filter `visibility = 'friends' AND deleted = 0` on the collection row, then read titles only of those collections. Titles have no visibility of their own, so they cannot leak separately. |
| Access after unfriending or blocking | Every read checks the friendship and blocks at that moment; nothing is cached server-side, and the app drops its cache for that friend. |
| Sending recommendations to strangers | Each recipient must be a current friend, have `allow_recommendations = 1`, and have no block either way; checked per recipient in the Worker. |
| Spam | Daily counters (20 requests, 50 recommendation recipients), unique constraints (one pending request per pair, one row per sender/recipient/title), 30 pending outgoing requests, 10 recipients per send, rate-limit bindings. |
| Abusive content in messages and names | Length limits, no links accepted in messages or names (rejected), control characters stripped. Block and report are always available. |
| Replay or double send | `client_id` idempotency on recommendations; request and friendship primary keys. |
| Request forgery from other sites | Bearer tokens in headers, not cookies, so CSRF does not apply. |
| Injection | Prepared statements only (existing practice). |
| Leaking through timing or errors | Uniform "not found" for missing, hidden and blocked profiles; generic 403 for relationship failures on writes. |
| Logs | Audit events carry ids and event kinds only, never handles, messages, titles or collection names. The request log masks handles and record ids in Friends paths (`:handle`, `:id`), as it masks party codes. |
| An ex-friend keeps seeing changes | Old recommendations show the other person's display name and avatar only while the two are friends; after that, the handle alone. |
| Passing as the app | Handles and display names containing "reelish" are refused (names after NFKC normalisation). |

## Privacy defaults

| Data | Default |
|---|---|
| Social profile | None until the user turns Friends on |
| Found by handle | Off |
| Found by code | On (sharing the code is a deliberate act) |
| Display name and avatar to friends | Not shared |
| Watching activity | Off |
| Collections | Private, including all existing ones |
| Recommendations from friends | On |

## Revocation behaviour

| Event | Effect, immediately on the server |
|---|---|
| Share activity off | Current activity row deleted |
| Collection set to Private | Next friend read excludes it and its titles |
| Remove friend | Friendship row deleted; both sides lose friends-only access; received recommendations stay with their recipients |
| Block | Friendship and requests both ways deleted; the blocked user's recommendations removed from the blocker's inbox; all future requests, recommendations and reads refused both ways |
| Unblock | Nothing restored; they may send a new request |
| Friends off | Profile, friendships, requests, blocks made by the user, activity and received recommendations deleted; collections set private |
| Delete account | Everything removed by `ON DELETE CASCADE` |

## Testing approach (Phase 1 and on)

Tests run in the Workers runtime with real D1
(`@cloudflare/vitest-pool-workers`), signing accounts in one after another
(`backend/test/helpers.ts`). Each privacy rule gets a direct-request test,
not only a happy path:

- reads of another user's activity, collections, inbox and requests as a
  stranger, a friend, a removed friend, a blocker and a blocked user;
- writes on someone else's behalf (accept, cancel, settings, collections);
- duplicate and concurrent requests (both sides at once);
- limits and idempotency;
- expiry of activity;
- account deletion and Friends off leaving nothing behind.

## Privacy policy

The policy needs a section before release: what a social profile contains,
who can see what, what is sent while watching (only with sharing on),
retention, and how to turn it off. Handles and display names are user text
and are treated as personal data.
