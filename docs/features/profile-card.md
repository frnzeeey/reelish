# Profile card and viewing statistics

Two additions to the Profile page, on phone, TV and Windows: **Profile > Profile
card**, which sets the look of the identity card at the top of the page, and
**Profile > Viewing statistics**, the viewer's own numbers.

## Profile card

The card can take its own background, its own colour and an animated accent.
Only its owner sees it. Watch Party, friends and the rest of the app never read
it, and the app theme, the accent across the app and the player are untouched.

| Part | Choices | Who |
|---|---|---|
| Background | Standard (the theme's backdrop, or Classic's accent glow, as before) | Everyone |
| | Essentials: Graphite, Midnight, Aubergine, Pine (solid) | Everyone |
| | Gradients: Dusk, Tide, Cinder, Moss | Everyone |
| | Cinematic: Spotlight, Neon Noir, Starlight, Projector, Film Reel, Northern Mist | Supporters and the Founder |
| Colour | Standard (the theme's light, else the app accent) or any of the app's accent presets | Everyone |
| | A colour of one's own (hue and vividness) | Supporters and the Founder |
| Effect | None | Everyone |
| | Drift (lights wander, 24 s loop), Sheen (a light passes every 9 s) | Supporters and the Founder |

The card's colour lights its avatar ring (when no frame is worn), the edit
button, the counts, the "Add a display name" link and a glow on the background.
An [avatar frame](avatar-frames.md) still replaces the ring. Under an app theme,
choosing no background keeps the theme's backdrop.

### Code

- `lib/src/theme/profile_styles.dart`: `ProfileBackdropStyle` (the catalog),
  `ProfileEffect`, and `ProfileStyle`, the choice and its JSON. Never rename an id.
- `lib/src/widgets/profile_card_backdrop.dart`: `ProfileCardBackdrop` (one
  `CustomPainter` in a `RepaintBoundary`, painted once) and `ProfileCardEffect`.
- `lib/src/screens/profile_style_screen.dart`: the page. The preview is the
  profile's own card (`_IdentityCard`, built by `ProfileScreen._identity`), drawn
  without its fade so quick choices never overlap.
- `_IdentityCard` in `profile_screen.dart` draws the card.

### Draft and apply

Choices are a draft. Apply saves; Discard, Standard card, or leaving the page
keep the card as it was. Those buttons come and go with the draft, so with a
remote or keyboard in use, pressing one moves focus to the background now
selected rather than losing it. On TV the page opens on the current background. Everyone can preview every part. When the draft
includes a supporter part and the account lacks the perk, Apply becomes "Become
a Supporter".

### Entitlement

One supporter perk, `profileStyles` / `profile_styles`
([entitlements](../backend/entitlements.md)). The Founder inherits it with the
Supporter entitlement. It is checked twice in the app:

- `ProfileController.setStyle(style, perk:)` refuses a style with supporter parts
  without the perk, so the check is where the choice is saved, not only in the
  screen.
- The card shows `style.allowed(perk:)`: without the perk the supporter parts
  fall back to Standard and the free parts stay. The saved choice is kept, so a
  lapsed supporter's card returns if support does.

A colour of one's own needs the perk whatever its value, so typing a preset's own
hex as a custom colour does not get past the gate. As with app themes, the card
is seen only by its owner, so the server has nothing to enforce: editing local
data can at most change one person's own screen.

Free accounts can already set the app-wide accent to any colour (Settings >
Appearance), and a Standard card follows that accent. That behaviour is
unchanged.

### Saved

On the device, per Trakt account, in the existing profile entry
(`onfeed.profile.v1`, `{userId: {..., style: {backdrop?, color?, effect?}}}`),
beside the display name and avatar. Entries saved before this have no `style`
and show the Standard card. Unknown ids, malformed colours and unknown effects
are dropped one by one. Like the display name, the style does not sync between
devices, and nothing is sent to the Reelish API.

### Rendering and motion

Backgrounds and effects are drawn in code: no images, downloads or cache.
`test/profile_customization_test.dart` checks that every background keeps
white text above 12:1 and every preset colour above 4.5:1 on its base. An
effect is its own layer in its own `RepaintBoundary`, with one controller. It
stops under reduced motion, in the background, on a covered page (TickerMode),
when the card is scrolled out of view, and always on TV hardware, where the card
stays still.

## Viewing statistics

`ProfileStatsScreen` (`lib/src/screens/profile_stats_screen.dart`) shows counts
from `ViewingStats` (`lib/src/models/viewing_stats.dart`): movies and episodes
finished, series watched, titles in progress, an estimated watch time, the top
five genres and finished titles in each of the last six months. It is free for
everyone.

### Where the numbers come from

Only what the app already keeps for the account: the watch history (the last 50
titles) and per-episode progress (the last 100 series), which sync between the
account's devices and are kept on the server for a year. Nothing new is recorded,
and the page makes no network request. So the page describes recent activity,
not a lifetime, and says so.

- **Finished:** 90% of a known length (`ViewingRules.completedShare`, as
  discovery uses). **Started:** 90 seconds (`ViewingRules.minimumPosition`). An
  unknown length can be started but never finished.
- **No double counting:** storage keeps one entry per movie and per episode, and
  sync replaces an entry rather than adding one. A series' own history entry
  (its place in Continue watching) only lends its genres; its episodes are what
  count.
- **Watch time is an estimate:** the furthest point reached in each title, added
  up. Skipping ahead adds to it and rewatches do not. Measured time is not
  recorded anywhere, so it is not offered.
- **Months:** from each finish's save time. Entries saved before times were
  kept are counted but sit in no month.
- **Genres:** from the history's TMDB genre ids. Series whose history entry has
  dropped out of the last 50 still count their episodes but have no genres.

Not available, so not shown: actors and directors, lifetime totals, measured
watch time. A finished movie started again counts as in progress until it is
finished again, since only the latest position is kept.

### Words shared with the profile card

The profile card's counts are the library's: **Watched** is the watch history
and **In progress** what Continue watching offers (`ResumeSummary.continues`:
a movie short of 90%, a series with an episode to go on with), as the Windows
library header counts them. The statistics page uses the same 90% for
finished, and calls its own count of started movies and episodes "Started,
not finished", so the two never show different numbers under one name.

### Privacy

Counted on the device and never sent. Friends cannot see them, and no setting is
needed because nothing leaves the device. An empty history shows a line saying
what will appear, not zeros.

### TV and Windows

Each panel takes focus with the remote or keyboard, so the page scrolls, and a
screen reader reads it as one sentence. On the wide layout, Your viewing sits
under Personalize, beside Account.

Tests: `test/profile_customization_test.dart`, `test/viewing_stats_test.dart`.
