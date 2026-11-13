# Friends & Activity: testing report

## Phase 7 — final audit (2026-11-13)

### Results

| Check | Result |
|---|---|
| `npm run typecheck` (backend) | Passed |
| `npm test` (backend, Workers runtime, real D1) | 276 passed, 24 files; 7 new in `backend/test/social-audit.test.ts` |
| `EXPLAIN QUERY PLAN` on staging | The six most frequent Friends queries all search an index ([final audit](FINAL_AUDIT.md#indexes)) |
| Staging | Worker `4ce5c7be` deployed |

### Audit tests (`backend/test/social-audit.test.ts`)

- Every one of the 24 Friends routes: 401 without a session, 401 with a
  signed-out session.
- Every route that reads a body refuses one that is not JSON (or answers
  as any other request would when Friends is off).
- The request log: handles, collection ids and recommendation ids are
  masked in Friends paths; the real log line for a friend page has no
  handle.
- Old recommendations show an ex-friend's handle only, in both the inbox
  and the sent list.
- Display names containing "Reelish", including in full-width letters, are
  refused.

### Not verified

- The Worker request totals on Cloudflare (the dashboard, not available to
  the tools here); staging's D1 figures were read, but staging has no social
  activity yet to measure.
- Production: not deployed.

### Follow-up: the fixable risks

| Check | Result |
|---|---|
| `npm run typecheck` and `npm test` (backend) | Passed; 278 tests, 24 files |
| `flutter test` (whole app) | 1,473 passed, 4 skipped (as before) |
| `flutter analyze lib test integration_test test_driver` | No warnings or errors; 15 info notes (baseline) |
| `dart run tool/docs/docs_tool.dart check` | Passed |
| `flutter build windows --release` | Built `Reelish.exe` |
| Staging | Worker `36b7a3b2` deployed |

New and changed tests:

- `social-audit`: with nine "taken" answers this hour (and one older), the
  tenth is still answered and the eleventh is 429 `too_many_attempts`, for
  any handle, while other Friends requests carry on; a report about an
  account that is then deleted keeps only reason, category and date (no id,
  handle or note).
- `social-shared-collections`: an older app's edit (no `visibility`)
  keeps a shared collection shared, renamed, and the owner's pull still says
  `friends`; an explicit `private` hides it.
- `watching_now_test`: a publish is noted on the device and the note goes
  when the clear succeeds; the next launch clears a leftover for the
  signed-in account; another account's leftover is left alone.
- `collection_sync_test`: making a collection private sends `private`.

## Phase 6 — polish and platforms (2026-11-13)

### Results

| Check | Result |
|---|---|
| `flutter test` (whole app) | 1,470 passed, 4 skipped (as before) |
| `flutter test test/friends_polish_test.dart` | 10 passed |
| `flutter analyze lib test integration_test test_driver` | No warnings or errors; 15 info notes (baseline) |
| `dart run tool/docs/docs_tool.dart check` | Passed |
| `flutter build windows --release` | Built `Reelish.exe` |
| Backend | Unchanged; not redeployed |

### Tests (`test/friends_polish_test.dart`)

- Profile's Friends row: requests first ("2 requests") with the dot, spoken
  as "2 friend requests, 1 new recommendation"; then new recommendations;
  nothing new shows the friend count and no dot; with Friends off as last
  known, opening Profile sends no request at all.
- Long names and large text: Friends, a friend's page, Recommendations and
  Friends & privacy on a 320-pixel phone at 200% text, a phone and a TV, with
  the longest names, handles and texts the server accepts: no overflow.
- Screen readers: a friend row is one item with name and handle; Accept and
  Decline stay separate buttons.
- Phone: pull to refresh reads the profile again within two minutes.
- TV: no pull to refresh; Down through the left column, Right to the
  friends list, Select opens the friend.

Two of these failed at first for reasons in the tests, not the app: a date
written for UTC (the machine is ahead of UTC), and a TV path that pressed
Down at the bottom of the left column instead of Right. Both tests were
corrected; the app was not changed for them.

### Not verified

- A real TV remote and a real screen reader (TalkBack, Narrator).
- Pull to refresh on a physical phone.
- Return-to-app reloading after two minutes (it uses Flutter's lifecycle
  listener; not driven in a test).

## Phase 5 — watching now (2026-11-13)

### Results

| Check | Result |
|---|---|
| `npm run typecheck` (backend) | Passed |
| `npm test` (backend, Workers runtime, real D1) | 269 passed, 23 files; 8 new in `backend/test/social-activity.test.ts` |
| `flutter test` (whole app) | 1,460 passed, 4 skipped (as before) |
| `flutter test test/watching_now_test.dart` | 10 passed |
| Every test that builds the player (`episode_selection_test`, `intelligent_continue_watching_test`, `player_session_test`) | 53 passed with the hook in place |
| `flutter analyze lib test integration_test test_driver` | No warnings or errors; 15 info notes (baseline) |
| `dart run tool/docs/docs_tool.dart check` | Passed |
| `flutter build windows --release` | Built `Reelish.exe` |
| Staging | Worker `dd3ee015` deployed; `GET /api/v1/social/activity` without a session answers 401 |

### Server tests (`backend/test/social-activity.test.ts`)

| Rule | Test |
|---|---|
| Off by default | Publishing without sharing is 409 `sharing_off` and stores nothing; Friends off: publish and read 409 |
| Friends only | A friend sees the title, season and episode with the handle only (no account id); a stranger and the owner see nothing; clearing ends it |
| Server-set expiry | No remaining time: 3 hours; 0: 15 minutes; a very long one: 4 hours; the time is the server's |
| Stale activity | An expired row is never returned |
| One current state | The same episode keeps its start; another episode starts again |
| Revocation | Sharing off deletes it at once; a row with sharing off is never shown |
| Relationship | A removed friend and a blocked person stop seeing it |
| Input | Missing media, unknown type, non-TMDB artwork, negative or fractional episode numbers, negative remaining time: 400, nothing stored |

### App tests (`test/watching_now_test.dart`)

- Publisher (in fake time): nothing at all while sharing is off; a non-TMDB
  title is never published; one PUT with the card (no year) and remaining
  time, a repeat sends nothing, the clear comes 20 seconds after stopping and
  only once; a series names its episode; the next episode starting within the
  grace replaces it with no clear in between; at most one update a minute
  with the latest state winning; a server that never answers leaves playback
  untouched (calls return at once) and the clear still follows the timed-out
  publish; failures throw nothing.
- Friends page: *Watching now* lists the friend and the episode; opening it
  goes to the title.
- Friends & privacy: the switch sends only `shareActivity`.

### Not verified

- A real stream on a device with sharing on: the publish at the first frame
  and the clear after closing (the hook is covered by the publisher's tests
  and the player tests run with it inert, not with a live stream).
- Two accounts on staging seeing each other's activity.
- Production: not deployed.

## Phase 4 — shared collections (2026-11-13)

### Results

| Check | Result |
|---|---|
| `npm run typecheck` (backend) | Passed |
| `npm test` (backend, Workers runtime, real D1) | 261 passed, 22 files; 8 new in `backend/test/social-shared-collections.test.ts` |
| `flutter test` (whole app) | 1,450 passed, 4 skipped (as before) |
| `flutter test test/shared_collections_test.dart` | 11 passed |
| `flutter test test/collection_sync_test.dart` | 10 passed (1 new) |
| `flutter analyze lib test integration_test test_driver` | No warnings or errors; 15 info notes (baseline) |
| `dart run tool/docs/docs_tool.dart check` | Passed |
| `flutter build windows --release` | Built `Reelish.exe` |
| Staging | Worker `de7ff37f` deployed; the shared collection route without a session answers 401 |

### Server tests (`backend/test/social-shared-collections.test.ts`)

| Rule | Test |
|---|---|
| Only what is shared | A friend's page lists the shared collection with its count and posters (chosen cover first), not the private one; its titles page has the snapshot fields and no account or device ids |
| Titles cannot leak | A private collection's titles are 404 even by id; unknown and malformed ids 404; a malformed cursor 400 |
| Friends only, now | A stranger 404; a removed friend 404 at once; a friend sees it until blocked, then 404 |
| Revocation | An edit without visibility (as older apps send) makes it private at once; deleting a shared collection hides it |
| Only collections | Visibility on a folder or a title, or an unknown value, is stored private |
| Owner's devices | The owner's pull carries `visibility` only for the shared one |
| Friends off | Shared collections become private as a newer server change (`at` after the switch, not the owner's device) that the owner's pull returns; the friend's page is then 404 |
| Paging | 205 titles: 200 then 5; `collection` only on the first page |

### App tests

- `test/shared_collections_test.dart`: a collection is private unless
  shared, an older saved copy and unknown values read private; sharing is a
  change the sync sends (and sharing twice sends nothing); the options offer
  sharing only while Friends is on and *Make private* always; the cover badge
  and its screen-reader label; a friend's page lists the shared collection
  (count and description), opens it read-only, titles sorted by name and
  opening details; nothing shared says so; no longer shared when opened says
  so; artwork from someone else is TMDB only; TV focuses the first title.
- `test/collection_sync_test.dart`: shared on Android, seen shared on
  Windows; made private on Windows, seen private on Android; the server's
  Friends-off change reaches the other device.

### Not verified

- Two real accounts on staging: share a collection on one, browse it on the
  other, then make it private and see it disappear.
- D1 on Cloudflare itself running `json_remove` and the window function
  (they ran in the local Workers runtime's SQLite, the same engine).
- Production: not deployed.

## Phase 3 — recommendations (2026-11-13)

### Results

| Check | Result |
|---|---|
| `npm run typecheck` (backend) | Passed |
| `npm test` (backend, Workers runtime, real D1) | 253 passed, 21 files; 11 new in `backend/test/social-recommendations.test.ts` |
| `flutter test` (whole app) | 1,438 passed, 4 skipped (as before) |
| `flutter test test/recommendations_test.dart` | 14 passed |
| `flutter test test/details_screens_test.dart` | 22 passed (2 new: Share on phone, TV and Windows; none while Friends is off) |
| `flutter analyze lib test integration_test test_driver` | No warnings or errors; 15 info notes (baseline) |
| `dart run tool/docs/docs_tool.dart check` | Passed |
| `flutter build windows --release` | Built `Reelish.exe` |
| Staging | Worker `e63f7cc0` deployed; `GET /api/v1/social/recommendations` without a session answers 401 |

### Server tests (`backend/test/social-recommendations.test.ts`)

| Rule | Test |
|---|---|
| Delivery | A friend gets the card and the cleaned note; `unread` in the inbox and in the profile counts; nothing in the sender's own inbox |
| Recipients checked at sending | Strangers, a friend who turned recommendations off, a friend who blocked the sender and unknown handles are all `notSent` alike, and nothing is stored for them |
| Idempotency | The same `clientId` twice: one row, counted once |
| No duplicates | The same title again refreshes the one card (new note, unread again) |
| Input | Empty and too many recipients, bad handles, unknown type, id 0, empty title, bad year, non-TMDB artwork, long note, links in the note, short `clientId`: all 400, nothing stored |
| Spam | 50 recipients a day (429 `recommendation_limit`) |
| Opt-in | Friends off: send and inbox are 409 |
| Ownership | The sender can neither mark read nor remove the recipient's copy; malformed ids are 400 or 404 |
| Read state | One, then all; unread count follows |
| D10 | Kept after unfriending; `from` becomes null once the sender turns Friends off |
| Paging | 32 items: 30 then 2, newest first, no repeats even with equal times; a malformed cursor is 400 |
| Sent list | Names the friend, never whether it was read, no account ids |

### App tests (`test/recommendations_test.dart`)

- A card: only a TMDB title, a four-digit year and `image.tmdb.org`
  artwork; IMDb-style ids and unknown types are not shareable. The one-line
  summary of a send.
- Controller: inbox and unread; opening one marks only it, opening the inbox
  marks all and then asks nothing more; remove fixes the count; a send names
  friends, card, key and trimmed note; a non-TMDB title sends nothing; offline
  shows the saved inbox, never to another account; turning Friends off
  forgets it.
- Share dialog: Send is off until a friend is ticked, "Send to 2", note
  sent, summary shown; a dropped connection keeps the dialog open and the
  retry reuses the same key; TV has friends to tick and no note.
- Friends page: *Recommended to you · 2 new*, sender and note shown; opening
  one goes to the title (through `SocialTitles.open`) and the count drops.
- Recommendations page: everything marked read on open, *You sent* listed,
  Remove works.

### Not verified

- End to end with two accounts on staging (share from one device, open from
  the other).
- Opening a recommended title from Friends on a real device (in tests the
  opener is a stand-in; on devices it is Home's own `_showDetails`).
- TV focus order inside the share dialog on a real remote.
- Production: not deployed.

## Phase 2 — friends (2026-11-13)

### Results

| Check | Result |
|---|---|
| `npm run typecheck` (backend) | Passed |
| `npm test` (backend, Workers runtime, real D1) | 242 passed, 20 files; 19 new in `backend/test/social-friends.test.ts` |
| `flutter test` (whole app) | 1,422 passed, 4 skipped (as before) |
| `flutter test test/friends_test.dart` | 17 passed |
| `flutter analyze lib test integration_test test_driver` | No warnings or errors; 15 info notes (baseline) |
| `dart run tool/docs/docs_tool.dart check` | Passed |
| `flutter build windows --release` | Built `Reelish.exe` |
| Staging | Worker `82a3944a` deployed; `POST /api/v1/social/requests` without a session answers 401 |

### Server tests (`backend/test/social-friends.test.ts`)

| Rule | Test |
|---|---|
| Finding | A code typed with lower case, a dash and a trailing space works; asking twice changes nothing |
| Handle discovery is opt-in | By handle 404 until the owner allows it; `@` and any case accepted then |
| No enumeration | Unknown code, malformed code, unknown handle, hidden code, blocked either way: one identical 404 body |
| Self and opt-in | Yourself is refused; an account with Friends off gets 409 `friends_off` |
| Lookup limit | The 11th find in a minute is 429 |
| Spam limits | 20 a day (429 `request_limit`); 30 waiting (409 `too_many_pending`) |
| Acting for someone else | The sender cannot accept; a third person cannot accept, decline or cancel; the receiver cannot cancel |
| Answers | Cancel and decline remove the request on both sides; accept makes both friends once and a second accept is 404 |
| Mutual requests | Asking someone who asked you makes one friendship and removes both requests; asking at the same moment still ends as one |
| Friend-only reads | A friend's page is 404 to strangers and to a third person |
| Removal | Ends the friendship on both sides; the page then 404s |
| Friends off | Removes you from your friends' lists |
| Paging | 53 friends: 50 then 3, in handle order, requests only on the first page; a malformed cursor is 400 |
| Counts | Friends and waiting requests in `GET /social/profile` |
| Identity | No Trakt username or account id in any find or list answer |
| Block | Ends the friendship, requests and recommendations both ways; the blocked person cannot find, ask or open the blocker; only the blocker sees and can undo it; unblock restores nothing |
| Block and report scope | A pending request can be blocked; a stranger cannot be blocked or reported (404) |
| Report | Reason required; stored as `kind = person` with the reported account; control characters removed; the reporter's id is not stored |

### App tests (`test/friends_test.dart`)

- What Add friend sends: codes typed any way, handles with or without `@`,
  look-alikes that cannot be codes, nonsense refused before sending.
- Controller: loading; a request waits; adding someone who asked accepts
  and fixes the counts; the server's 404 message; accept, decline, cancel and
  remove update lists and counts; block takes the person off every list;
  blocked list and unblock; a person already gone on the server is dropped;
  report sends reason and trimmed note and blocks when asked; offline shows
  the last list; another account never sees it; turning Friends off forgets
  it.
- Phone page: accept from the list, add with a refusal kept in the dialog,
  then a request sent; decline asks first and Cancel changes nothing.
- A friend's page: block after confirming closes the page; report needs a
  reason, and "Also block" can be switched off.
- Windows (`TargetPlatformVariant`): adding and requests beside the list.
- TV (`DeviceCapabilities.debugOverride`): two columns; Accept is reached by
  focus and pressed with Select.
- Friends off: one way to turn it on, nothing else.

### Not verified

- Two real accounts against staging (sign one in on the emulator and another
  on Windows to try requests, accept, block and report end to end).
- TV text entry for Add friend with the on-screen keyboard.
- The Profile row's dot and count in a widget test (covered through the
  controller and the layout test only).
- Production: not deployed.

## Phase 1 — foundation (2026-11-13)

### Results

| Check | Result |
|---|---|
| `npm run typecheck` (backend) | Passed |
| `npm test` (backend, Workers runtime, real D1) | 223 passed, 19 files; 19 new in `backend/test/social-profiles.test.ts` |
| `flutter test` (whole app) | 1,405 passed, 4 skipped (as before) |
| `flutter test test/friends_privacy_test.dart` | 14 passed |
| `flutter analyze lib test integration_test test_driver` | No warnings or errors; 15 info notes (baseline) |
| `dart run tool/docs/docs_tool.dart check` | Passed |
| `flutter build windows --release` | Built `Reelish.exe` |
| Staging | Migration `0013` applied, Worker deployed; `GET /api/v1/social/profile` without a session answers 401 |

### Server tests (`backend/test/social-profiles.test.ts`)

Each is a direct request, not only the happy path.

| Rule | Test |
|---|---|
| No social presence until opted in | Friends is off until the owner turns it on |
| Private defaults | Turning on needs a handle; code found, handle not, recommendations on, activity off |
| Trakt identity never exposed | The response holds neither the Trakt username nor the account id |
| Handle rules | Malformed, reserved and `reelish` look-alikes refused; one owner whatever the case |
| Impersonation after a handle is given up | Old handle held from others, reclaimable by its owner; held after Friends off and after account deletion |
| Handle churn | First change free, then once a week; a case-only change always allowed |
| Names shown to others | Too long, links and non-text refused; control and direction characters removed; avatar must be a preset |
| Settings | Booleans only; only the sent ones change |
| Acting for someone else | `userId`/`user_id` in the body ignored: only the caller changes |
| Revocation | Activity sharing off deletes the current activity at once |
| Friend code | A new code replaces the old; needs Friends on (409 otherwise) |
| Sessions | No session and a logged-out session both get 401 |
| Enumeration | Handle claims limited to 10 a minute per account (11th → 429) |
| Friends off | Removes profile, friendships and requests both ways, own blocks, activity, received recommendations; collections private; keeps other people's blocks and friendships, recommendations already sent, and counters |
| Account deletion | No social row left in any table, either side |
| Relationship check | Self, none, friend, blocked both ways; a block wins over a friendship; a pending request is not a friendship |
| Data integrity | A friendship is stored once, smaller id first (reverse and duplicate rows refused) |
| Retention | Prune removes only rows past each retention |

### App tests (`test/friends_privacy_test.dart`)

- Controller: off until asked; turn on, change settings, clear the name,
  set an avatar, turn off; new code; a refused handle returns the server's
  message and changes nothing; offline shows the saved copy and a plain
  message; another account never sees the saved copy; a malformed answer is
  not taken as "off"; the Trakt username is never sent.
- Page, phone: the handle is checked before sending (nothing sent), a
  server refusal stays in the dialog, turning on shows the handle and code,
  Cancel on Turn off changes nothing, confirming turns it off; a switch
  sends only its setting; offline with nothing saved offers Try again.
- Page, Windows (`TargetPlatformVariant`): the code can be copied.
- Page, TV (`DeviceCapabilities.debugOverride`): the code shows with no
  Copy action.
- The app's handle check matches the server's.

### Not verified

- On a real device or TV remote: turning Friends on and editing it against
  staging (the apps were relaunched on staging for this).
- TV text entry with the on-screen keyboard (`TvTextEntryDialog` loop).
- Edge rate limiting on Cloudflare itself (the tests use the local
  simulation of the same bindings).
- Production: not deployed.
