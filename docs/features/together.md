# Together

The social home of Reelish: the people you watch with, movie night, messages
and what friends send you. A place in the navigation on every interface (the
phone dock, the TV rail, the Windows sidebar), and the same page as Friends
opened from Profile.

Code: `lib/src/screens/social/together_screen.dart` (the page and its
sections), `lib/src/screens/social/friends_screen.dart` (the shared page body,
dialogs and sub-pages), `lib/src/widgets/social/social_widgets.dart` (people
and recommendation tiles).

## Audit (before this redesign)

The page was the Friends page with a Watch Party row on top: a stack of
identical outlined settings sections (WATCH PARTY, MESSAGES, WATCHING NOW,
RECOMMENDED TO YOU, ADD A FRIEND, REQUESTS, SENT, FRIENDS, then a block of
Recommendations, Blocked people and Friends & privacy rows).

- It read as a settings list: every feature in the same card, people as
  rows among utilities, nothing leading the eye.
- People came late: friends were the right column on wide screens and the
  last list on phones; nobody's face showed before scrolling.
- Watch Party was one row, "Join a watch party"; starting a party was only
  described ("Hosts start a party from a title's page"), with no way there.
- Recommendations were rows of tiny posters, three at most.
- The friend code sat in Add a friend with no way to copy it there (copying
  lived in Friends & privacy).
- Blocked people and Friends & privacy sat beside the social features, at
  the same weight.

What the data supports, verified in code:

| Brief asks for | Exists? | Used as |
|---|---|---|
| Online presence | No: no online status anywhere (`FriendsController`, `MessagesController`, the API) | Not shown. "Watching now" is the real signal: friends who share what they watch (`FriendsController.watching`) |
| Recent social activity | Watching now; new recommendations; unread messages | Shown, each from its controller |
| Active Watch Parties | Only this device's own (`WatchPartyController.active`) | Not listed: there is no list of friends' parties |
| Pending invitations | No: invites travel as a code or link (`PartyLinks`), there is no inbox | Not shown; Join with a code is the way in |
| Friends hosting | No | Not shown |
| Start a Watch Party | Yes, from a title (`CreatePartyScreen` needs content); any signed-in account can host | "Pick a title" opens search |
| Friend code sharing | Copy, in Friends & privacy; no share sheet (no share package) | Copy on the page itself |
| Recently watched together | No | Not shown |

Nothing on the page is placeholder or invented.

## Information architecture

| Order | Section | What it holds |
|---|---|---|
| 1 | Greeting and your people | "Good evening, Name"; the friends strip (avatars, those watching now first, with what they watch); Messages as a shortcut with its unread count |
| 2 | Movie night | Join with a code; Pick a title to host |
| 3 | Requests | Friend requests waiting on an answer (accept, decline), only when there are some |
| 4 | Messages | The latest conversations, only once there are some |
| 5 | Shared discoveries | Titles friends sent you, as posters; All recommendations |
| 6 | Your people | Add a friend (code or @handle) with your code beside it, copyable; your friends; requests you sent |
| 7 | Privacy and people | Friends & privacy (handle, discoverability, code), Blocked people |

TV and Windows show two columns from 720 dp: the left column holds Movie night,
Messages and Shared discoveries; the right holds Requests, Your people and
Privacy. The phone shows one column in the order above.

### Where every feature went

| Existing feature | Placement |
|---|---|
| Join Watch Party | Movie night |
| Messages | Shortcut beside the greeting, and the Messages section |
| Add a Friend | Your people |
| Friend Code | Your people, beside Add a friend (the add flow), copyable |
| Friends | The strip at the top and the list in Your people |
| Recommendations | Shared discoveries |
| Blocked People | Privacy and people |
| Friends & Privacy | Privacy and people |
| Friend requests (in and sent) | Requests; sent ones in Your people |
| Watching now | The friends strip |
| Turn on Friends | The page while Friends is off (Movie night stays) |

## States

| State | What shows |
|---|---|
| Friends off | Movie night, then "Turn on Friends" with what it is for |
| No friends yet | A welcome that says what Together is for, Add a friend first, your code to copy |
| No messages | The Messages section is absent; the shortcut says Open a friend to start |
| No recommendations | One line: how titles arrive here and how to send one |
| Loading, offline | The saved lists with a note; a spinner only before anything is known |

## Look

Colours come from the theme (`GlassTheme`), never fixed values, so Supporter
and Sovereign themes dress Together like every other page. Movie night is lit
with the theme's accent; people are avatars, not rows; the privacy rows sit
last and quieter. The brief's palette (terracotta `#D17B5B` on `#211D1B`) is
close to the Living Room theme's (`#BA725A` on `#14110E`, from the emblem);
the page shows whichever theme is in use and changes no theme's colours.

## TV remote and verification

On TV the friends strip and the Shared discoveries posters are each one
focus group (`FocusTraversalGroup`), so Left and Right move along the row.
Without it, Left from a face jumped to a poster lower on the page and focus
started on Messages, past the strip.

`integration_test/together_layout_test.dart` draws the page with a full set
of data (friends, two watching now, a request each way, discoveries with
notes) in the real engine and the app's fonts, on a 360 dp phone, a phone
at 200 % text, Windows at 1280 and 1920 px, and TV, failing on any
overflow; with `--dart-define=SAVE_SHOTS=<folder>` it saves each layout as
a picture. On TV it then plays a remote session with key presses only:
along the strip and back, down through Messages and Movie night into the
posters, across to the people and down to Blocked people. It runs on
Windows (`flutter test integration_test/together_layout_test.dart -d windows`).
