# Friends & Activity: feature requirements

Scope agreed for the first release, in priority order. Friends,
recommendations and shared collections stay useful when nobody is watching;
"now watching" is the smallest and comes last.

## Principles

- **Opt in.** Nothing is visible to anyone until the user turns on Friends
  and creates a social profile. Activity sharing is off by default, and
  every collection is private until the user chooses otherwise.
- **Friends, not followers.** Mutual, accepted friendships only. No follower
  counts, no public directory, no algorithmic feed.
- **The server enforces privacy.** The app shows what the API returns; the
  API decides what each account may see.
- **Never in the way.** Browsing, playback, the Library and collections work
  when social requests fail. Playback never waits on a social call.

## F1. Social profile (opt-in)

- *Turn on Friends* in Profile creates the profile:
  - a **handle**: 3–20 characters, `a–z 0–9 _ .`, unique, case-insensitive
    (stored normalised), changeable at most once every 30 days;
  - a **display name** (optional, up to 40 characters), entered or copied
    from the device profile;
  - a **built-in avatar** preset (optional). Photos are never uploaded.
- *Turn off Friends* deletes the profile, friendships, requests, blocks,
  activity and received recommendations, and makes every shared collection
  private.
- The Trakt username is not shown to other users unless decided otherwise
  (decision D2).

## F2. Friends

- **Find**: by friend code (8 characters, random, regenerable) or by exact
  handle. No prefix search, no lists of users. Each can be turned off.
- **Requests**: send, cancel (sender), accept or decline (receiver). No
  self-requests, no duplicates, no request while a block exists either way.
  A request to someone who already sent one accepts theirs.
- **Friends list**: friends, incoming requests, outgoing requests, a filter
  for large lists, and empty, loading, error and offline states.
- **Remove friend**: ends friends-only access both ways at once.
- **Block**: removes the friendship and pending requests both ways, and
  stops requests, recommendations and visibility. A blocked account is not
  told. Blocked list in privacy settings, with Unblock.
- **Report**: a user report through the existing support reports (kind
  `user`), with a reason and an optional note.
- **Limits**: 20 requests sent a day; at most 30 pending outgoing; 500
  friends.

## F3. Recommendations

- *Share with friends* on every details page (phone, TV, Windows): choose
  one or more friends (up to 10 at once), add an optional message (up to
  200 characters), send.
- The recipient's **inbox**: sender, title card, message, time; open the
  title, mark read, remove. Unread count shown on the Friends entry.
- Only to accepted friends who allow recommendations, never across a block.
- **Limits**: 50 recipients a day; the same title to the same friend once a
  week (sending again refreshes it instead of duplicating it).
- Private: visible only to sender (in their sent list) and recipient.
- After a friend is removed: received recommendations stay in the
  recipient's inbox (they are the recipient's). After a block: the
  blocked sender's recommendations are removed from the blocker's inbox.

## F4. Shared collections

- Each collection gains a **visibility**: *Private* (default) or *Friends*.
  Existing collections stay private.
- A friend's profile lists their *Friends* collections; opening one shows
  its titles (from the stored cards; no TMDB requests), sortable as in the
  Library. Titles open the normal details page.
- Visibility changes take effect on the next read; nothing is cached on the
  server for friends.
- *Public* (anyone with a link) is **not** in this release: it needs a
  public web page or link handling, and a directory is out of scope
  (decision D4).

## F5. Now watching (last, optional)

- Off by default; *Share what I'm watching* with *Friends only*.
- When on, starting a movie or episode publishes one small record: kind,
  TMDB id, season and episode, title, poster, start time. No position,
  source, provider, plugin, URL or device.
- Updated on episode change; cleared when the player closes, when sharing
  is turned off, and on sign-out. Every record carries a server-set expiry
  (the remaining running time plus 15 minutes, at most 4 hours), so a crash
  or lost connection cannot leave it showing.
- Friends see it on the Friends page ("Watching now · 5 min"), fetched when
  the page opens or is refreshed. No live connection, no history.

## F6. Privacy settings

One *Friends & privacy* page:

| Setting | Values | Default |
|---|---|---|
| Friends | On / Off | Off |
| Found by friend code | On / Off | On (when Friends is on) |
| Found by handle | On / Off | Off |
| Recommendations from friends | On / Off | On |
| Share what I'm watching | Off / Friends | Off |
| Collections | Per collection: Private / Friends | Private |
| Profile shown to friends | Handle (always), display name, avatar | Handle only |
| Blocked accounts | List, Unblock | Empty |

Every setting is stored by the API and enforced there.

## F7. Indicators, not push

- One summary request on app start and return to the app (at most every
  few minutes): pending requests and unread recommendations. A dot on the
  Friends entry and on Profile.
- No push notifications in this release (no FCM). The existing background
  episode check is not extended (decision D7).

## Out of scope

Public collections and profiles, a global directory, comments, likes,
chat, activity history, follower counts, push notifications, contact
import, Trakt friends import.
