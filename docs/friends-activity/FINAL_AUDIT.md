# Friends & Activity: final security and cost audit

Phase 7, 2026-11-13. A review of every Friends route and app path after
Phases 1–6, the fixes it led to, the risks accepted, and a cost check
against the code as built and the staging database.

## Routes reviewed

All 24 Friends routes sit behind `authenticate` and call
`requireLiveSession`, so a signed-out or revoked session is refused even
with an unexpired access token. `backend/test/social-audit.test.ts` sends
every route a request with no session and with an ended session (all 401),
and a non-JSON body to every route that reads one.

| Area | Routes | Acts only on | Another person named by | Checked at that moment |
|---|---|---|---|---|
| Profile | `/social/profile`, `/profile/code` | The caller | — | — |
| Requests | `/social/requests`, `/{handle}/accept`, `/decline`, `DELETE /{handle}` | Rows where the caller is the receiver (accept, decline) or sender (cancel) | Handle (or code) | Discoverability, blocks both ways, limits |
| Friends | `/social/friends`, `/{handle}`, `DELETE /{handle}` | The caller's friendships | Handle | Friendship |
| Blocks, reports | `/social/blocks`, `/{handle}`, `/social/reports` | People the caller knows (friend, request either way, own block) | Handle | Relationship; anyone else is 404 |
| Recommendations | `/social/recommendations`, `/sent`, `/read`, `/{id}` | Rows where the caller is the recipient (read, remove) | Handle (recipients) | Each recipient: friend, accepts, no block |
| Shared collections | `/social/friends/{handle}/collections/{id}` | Shared, undeleted collections of a current friend | Handle | Friendship, visibility |
| Watching now | `/social/activity` | The caller's own row; friends who share | — | Sharing on, friendship, expiry |

No route takes an account id from the client, and none returns one.

## Findings and fixes

| # | Finding | Severity | Fix | Test |
|---|---|---|---|---|
| 1 | The request log wrote paths such as `/social/friends/{handle}` to Workers Logs, so handles (personal data) reached the logs | Medium | `maskPath` replaces handles and record ids in Friends paths, as the party code already was | `social-audit`: the masked forms, and the real log line for a friend page has no handle |
| 2 | After unfriending, old recommendations (inbox and sent list) showed the other person's *current* display name and avatar, so an ex-friend kept seeing changes | Low | Name and avatar only while the two are friends; the handle alone after | `social-audit`: before and after unfriending, both directions |
| 3 | A display name could read "Reelish Support" (handles already refused it) | Low | Names containing "reelish" (after NFKC normalisation, so full-width letters too) are refused | `social-audit` |

Deployed to staging (Worker `4ce5c7be`). No migration.

## Risks, and the follow-up that narrowed them

The review first accepted five risks; the owner asked for the four fixable
ones to be fixed (follow-up, same day, staging Worker `36b7a3b2`).

| Risk | Now |
|---|---|
| Claiming a handle answers whether it is taken, even for a hidden one | **Narrowed.** "Taken" answers are limited to 10 an hour per account (counted in the security log as `social.handle_taken`), on top of 10 claims a minute per account and per address; then 429 `too_many_attempts` for an hour. Closing it fully would need non-unique handles (`name#1234`) |
| A report keeps the reported account's id after that account is deleted | **Fixed.** Account deletion leaves only the reason and date on reports about it: id, handle, name and the note are removed |
| An older app version editing a shared collection makes it private | **Fixed.** The app now always sends `visibility`; a collection change without it (only older versions) keeps what is stored, in the column and in the body the owner's devices pull |
| Activity can show for a while after a crash | **Mostly fixed.** A publish is noted on the device until cleared; the next launch clears it. Left: an app never opened again, where the server's expiry (at most the remaining time plus 10 minutes, 15 minutes at least) ends it. Removing that would need check-ins during playback (18–45% of the free daily requests at 1,500 daily users), so it is not done |
| A block deletes recommendations both ways, including the blocker's sent copies | **By design** (decision D10): after a block nothing between the two remains |

## Cost review

### Requests per action, from the code as built

| Action | Worker requests |
|---|---|
| Open Profile | 0 when Friends is off or the counts are under 2 minutes old; else 1 |
| Open Friends | 3–4 (profile when stale, friends and requests, inbox, watching now) |
| Open a friend | 1; a shared collection 1 per 200 titles |
| Open Recommendations | 3 (inbox, sent, mark read) |
| Share a title | 1 (plus the friends list if not loaded) |
| Play with sharing on | 2 (publish, clear), at most one publish a minute |
| Change a collection's visibility | 0 extra (rides the existing collection sync) |

A daily user as assumed in [the cost analysis](FREE_TIER_COST_ANALYSIS.md)
comes to about 10–11 requests, against the estimate of 9: Friends now also
asks for *Watching now*, and Recommendations reads the sent list. At 5,000
registered users (1,500 a day) that is about 16,000 requests a day, 16% of
the Workers free allowance shared with every other route.

### Indexes

Every frequent query was checked with `EXPLAIN QUERY PLAN` on staging:
friend counts (multi-index OR over both friendship columns), waiting
requests, unread recommendations, shared collections (the partial index),
Watching now (both friendship indexes, then primary keys) and code lookup
all search an index; none scans a table. D1 bills rows scanned, so this is
what keeps reads near the rows returned.

### Staging

On 2026-11-13 staging had one account and no social rows yet (Friends not
yet turned on there), 318 read and 74 write queries in 24 hours, 332 kB.
That is too little to confirm per-user figures; measure again after a
two-account trial, and check total Worker requests in the Cloudflare
dashboard before the production release.

### If requests ever approach the free allowance

Fold *Watching now* and the first inbox page into `GET /social/friends`
(Friends would take 2 requests instead of 4), and load the sent list only
when it is scrolled to. Neither is needed at the scale above.
