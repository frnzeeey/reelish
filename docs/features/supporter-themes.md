# Supporter profile themes

Verified Reelish Supporters can dress their profile card in one of five themes.
A theme restyles that card only: its backdrop, the ring around the avatar, the
glow, the Manage account button and the activity counts. The accent the user
picked for the rest of the app is untouched, and text stays white on a dark
surface, so no theme costs readability.

| Theme | Character | Ornament |
|---|---|---|
| Royal Violet | Violet and indigo; the default for a new supporter | A soft diagonal sheen |
| Celestial | Midnight blue | A fixed field of faint stars |
| Aurora | Teal into violet | Two blurred ribbons of light |
| Rose Luxe | Muted rose | Sheen |
| Golden Hour | Champagne and amber | Sheen |

Classic is the usual card, for a supporter who prefers it. The themes and their
painter are in `lib/src/theme/supporter_themes.dart`; the picker is
`lib/src/widgets/supporter_theme_picker.dart`, shown on the profile
(`profile_screen.dart`) under PROFILE THEME.

## Who sees a theme

A theme is drawn only when `SupporterController` reports a verified donation:
the same server record that allows hosting a Watch Party
([supporters](../backend/supporters.md)). A donation waiting for review does not
count. The picker is shown only to supporters.

The choice is saved with the rest of the profile, per account on the device
(`ProfileController.themeId`, the `theme` field of `onfeed.profile.v1`). Saving
it grants nothing: a non-supporter with a theme in their preferences still sees
the usual card. When support ends, the card goes back to the usual one and the
saved choice is kept, so it returns if they support again.

A theme is seen only by its owner on their own screen. It is not sent anywhere,
so there is nothing for the server to check, and changing local data can at most
change one person's own view.

## Rendering

Each backdrop is one `CustomPainter` inside a `RepaintBoundary`: two radial
lights over a tinted base, plus its ornament, with fixed star positions. It has
no animation and no `BackdropFilter`, so it is painted once. Changing theme
fades one backdrop into the next over `AppMotion.emphasized`, through
`AppMotion.resolve`, so reduced motion makes it instant.

The picker lays out six swatches in even columns: all six in a row where they
fit (Windows, TV), otherwise three or two. Each swatch is a `TvFocusable`, so it
takes touch, the remote, mouse, keyboard and game controller.

## Not yet

- The choice does not sync between devices.
- Themes are not shown to others (for example in Watch Party).
- Supporter chibi avatars were deferred.

Tests: `test/supporter_themes_test.dart`.
