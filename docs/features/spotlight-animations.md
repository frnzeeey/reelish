# Spotlight animations

The Spotlight at the top of Home can move in one of six ways, chosen in
Settings › Appearance › Spotlight Experience. Two are free for everyone, and
four are a supporter perk (`SupporterPerk.spotlightMotion`).

| Preset | Id (stored) | Who | Phone carousel | Windows hero |
|---|---|---|---|---|
| Cinematic Depth (default) | `cinematic_depth` | Everyone | Cards in 3D depth. The shown card is in front, its neighbours scaled and turned slightly away (about 12°) and dimmed. The artwork settles from 1.06 to 1.0, and the title rises in. Shadow and a faint accent glow. | The new backdrop zooms from 1.06 to 1.0 as it fades in |
| Minimal Motion | `minimal` | Everyone | Full-width cards, a plain slide with a soft fade and a 3% scale. No depth, zoom, shadow or glow. | Plain crossfade, as before |
| Classic Cover Flow | `cover_flow` | Supporters | Narrow cards. The neighbours turn about 49° to face the centre and are drawn in towards it. Only the card facing forward shows its words. | The backdrop slides 6% sideways as it fades |
| Spotlight Reveal | `spotlight_reveal` | Supporters | Full width. Each card opens over the last, which stays behind, shrinking and fading. The artwork settles from 1.1, and the label, title, details, synopsis and buttons appear one after another. | Stronger zoom from 1.1, and the title rises further |
| Floating Atmosphere | `floating_atmosphere` | Supporters | Flat cards drifting gently (±5 px, 6 s cycle, each on its own phase). The shown card is lifted on a soft shadow and the neighbours sit lower. | The backdrop rises slightly as it fades in |
| Stacked Motion | `stacked_motion` | Supporters | A pile. Earlier cards slide under the shown one, smaller and turned a little, and peek out on the left. A new card is laid on top and straightens as it lands. | The new backdrop slides over the old one, which sinks back |

Android TV and Google TV have no Spotlight. TV Home's hero follows the
focused poster and never rotates, so the setting is not shown on TV.

## How it works

| Part | Where | Role |
|---|---|---|
| `SpotlightMotion`, `SpotlightMotionStyle` | `lib/src/spotlight/spotlight_motion.dart` | The presets. A style is a pure function from a card's distance to the centre (in pages) to its transform, opacity, shadow strength, artwork zoom and text reveal. On Windows it gives the backdrop transition and how far the title rises. |
| `SpotlightDeck`, `SpotlightZoom`, `SpotlightReveal` | `lib/src/spotlight/spotlight_deck.dart` | The phone carousel: a `PageView` whose cards a style places. |
| `SpotlightMotionController` | `lib/src/spotlight/spotlight_motion_controller.dart` | The saved preset, the one in effect, and the perk check. |
| `SpotlightPreview` | `lib/src/spotlight/spotlight_preview.dart` | The settings preview: the real deck on made-up cards. |
| `SpotlightExperienceScreen` | `lib/src/screens/spotlight_experience_screen.dart` | The picker: preview, the list with locks, and Use this. |
| Home (phone) | `home_screen.dart` `_featuredCarousel`, `_featured` | Builds the deck; the card content is unchanged, wrapped in `SpotlightZoom` and `SpotlightReveal`. |
| Home (Windows) | `desktop/desktop_hero.dart` | The backdrop `AnimatedSwitcher` and the title rise use the style. |

- **Motion follows the scroll position.** A swipe, a fling and an automatic
  turn all drive the same frames. There is no controller or timer per card,
  so rapid swipes cannot start overlapping transitions. Each card works out
  its frame once per tick. Inside the card, only the zoom and reveal
  wrappers rebuild. The card content (artwork, buttons) is built once:
  - The same widgets always wrap it, with only their values changing. A
    shadow or fade added mid-swipe once made Flutter rebuild each card
    three times per swipe; a test now checks that each card is created
    once.
  - A neighbour is dimmed by a page-coloured overlay, not made transparent.
    Transparency drew the whole card off-screen every frame. On the solid
    page the two look the same.
- **The one ticker of its own** is Floating's 6 s bob, created only while
  that preset shows and disposed when it changes. Tickers pause off screen.
- **Neighbours.** A card counts as shown when it is more than half in the
  centre. Only the shown card's controls take taps, and only its words are
  read out. A tap on a peeking neighbour brings it to the centre.
- **Card width.** Each style has its own `viewportFraction`. When it
  changes, Home makes a new `PageController` at the same page and disposes
  the old one after the frame.
- **Automatic turns.** The 6 s turn now takes 650 ms (it was 480 ms). A
  swipe restarts the wait, so the Spotlight never moves on just after the
  person moved it. As before, it does not turn under reduced motion, on
  another tab or category, or while Home is scrolled. Windows keeps its own
  8 s rotation and hover/focus pause.
- **The header** is its own row above the Spotlight, not laid over the
  card's artwork. It once sat over a full-width card, but it cannot line up
  with cards that turn, scale or lift. Other categories show the same row.
  From left to right, in rising importance:
  - The bare Reelish mark (`logo_icon.png` through `ReelishMark`, 26 px) in
    the page's text colour: white on dark themes, ink on the light theme.
  - One liquid-glass capsule (`LiquidGlass`, as the dock) holding Join party
    (icon and label, muted) and Search (full contrast), split by a
    hairline. Both icons are 20 px; the hierarchy comes from colour and the
    label.
  - The account's own avatar in one ring: the accent's, or a supporter's
    equipped frame colour instead, never both.

  The mark and the ring's outer edge sit on the page's 18 px gutter, like
  the chips, titles and rows below. The capsule and the ring are both
  44 px, on one centre line with the mark. Touch areas are at least
  44 × 48. The header test checks all of this.

  The card is 62 px shorter to make room (`_headerRoom`), so everything
  below starts where it did.
- **Reduced motion.** When the system asks for it, Minimal Motion shows
  whatever is chosen. The Windows durations are also cut to nothing by
  `desktopMotion`.
- **Images.** The artwork is the same `ArtworkImage` at the same decode
  size. Zoom is a transform, so nothing is decoded again. The preview uses
  colour fields and loads nothing.

## Entitlement and storage

- The choice is a device setting, `onfeed.appearance.spotlight_motion`,
  read through `StorageService`, like the app theme. Nothing goes to the
  Reelish API or Firebase.
- What applies is the saved preset if it is free or the account has the
  perk, and Cinematic Depth otherwise. The perk comes from
  `SupporterController`, which reads the entitlement the Reelish API
  decides (`/supporters/me`). The stored id only says what was chosen, so
  writing an exclusive id into the settings by hand changes nothing (tested).
- Unknown or retired ids open as Cinematic Depth.
- When the perk lapses (refund, or not yet confirmed on a new device), the
  Spotlight switches to Cinematic Depth at once. The saved choice waits and
  returns with the perk. The picker says so.
- The Founder has the perk through the supporter entitlement. There is no
  separate rule. "Sovereign Edition" is the Founder's profile card, not a
  tier.
- Like app themes, this cosmetic is only ever seen by its owner, so the
  server has nothing to enforce. `spotlight_motion` is named in
  `backend/src/entitlements.ts` only so both sides list the same perks.

## Adding a preset

1. Add a value to `SpotlightMotion` with a new, permanent id, a name, a
   description and `exclusive`.
2. Write a `SpotlightMotionStyle`: `viewportFraction`, `frame`, and
   optionally `floats`, `staggered`, `lifted`, `backdropTransition` and
   `textRise`.
3. Give it an icon in `_MotionTile._icon`. The switch there is exhaustive.

The tests in `test/spotlight_motion_test.dart` cover every preset
automatically: the shown card is whole, presets differ from each other, and
swipes and rapid turns work.

## Tests

`test/spotlight_motion_test.dart` (23 tests):
- Ids and which presets are free.
- The shown card is whole in every preset, and the presets differ.
- Which presets are flat, which float, and staggering.
- A free account refused an exclusive preset.
- A hand-edited setting ignored, and unknown ids.
- A supporter's choice kept across a restart, and the Founder.
- The perk lost and regained.
- For every preset: swipe, rapid overlapping turns, and disposal.
- A neighbour taking no taps, and a tap bringing it forward.
- Reduced motion.
- The picker for a free account (locks, explanation, applying a free preset)
  and for a supporter.
- The Appearance entry on a phone, and not on TV.
