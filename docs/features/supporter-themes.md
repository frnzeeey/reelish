# App themes

Accounts with the supporter perks (supporters, and the Founder) can choose an
app theme in Settings > Appearance, under THEMES. A theme sets the accent across
Reelish and dresses the profile card: its backdrop, the ring around the avatar,
the glow, the Manage account button and the activity counts. Text stays white on
a dark surface. Each theme's accent goes through the same contrast rule as a
custom accent (`AccentPalette.custom`), so no theme costs readability.

| Theme | Character | Ornament on the profile card |
|---|---|---|
| Royal Violet | Violet and indigo | A soft diagonal sheen |
| Celestial | Midnight blue | A fixed field of faint stars |
| Aurora | Teal into violet | Two blurred ribbons of light |
| Rose Luxe | Muted rose | Sheen |
| Golden Hour | Champagne and amber | Sheen |

Classic means no theme: the accent picked under ACCENT COLOR. The accents stay
free for everyone. Picking an accent turns a theme off, since the theme would
hide it.

The themes and their painter are in `lib/src/theme/supporter_themes.dart`
(`SupporterTheme.accent` gives the accent). The picker is
`lib/src/widgets/supporter_theme_picker.dart`, shown on the Appearance page
(`AppearanceSettingsScreen` in `playback_settings_screen.dart`) on phone, TV and
Windows.

## Who gets one

`AccentSettingsController` applies a theme only while the signed-in account has
the `appThemes` perk (`SupporterController.has`, from the server's
[entitlement](../backend/entitlements.md)). A donation waiting for review does
not count. Others see the themes with a small lock, and a tap explains them
with a way to the Supporters page.

The theme is saved on the device, like the accent (the
`onfeed.appearance.theme` setting, beside `onfeed.appearance.accent`). Saving it
grants nothing: without the perk, the picked accent shows. When support ends, or
someone without the perk signs in, the picked accent returns and the saved theme
waits for an account that has the perk.

At launch, the saved supporter status is read from the device before the first
screen (`SupporterController.restoreSaved`), so a theme's accent is right from
the start. The server is asked once Home has drawn, and its answer replaces the
saved one.

A theme is cosmetic and local: it is not sent anywhere, so there is nothing for
the server to enforce. Changing local data can at most change one person's own
screen.

## Rendering

Each profile backdrop is one `CustomPainter` inside a `RepaintBoundary`: two
radial lights over a tinted base, plus its ornament, with fixed star positions.
It has no animation and no `BackdropFilter`, so it is painted once. Changing
theme fades one backdrop into the next over `AppMotion.emphasized`, through
`AppMotion.resolve`, so reduced motion makes it instant. The accent change
rebuilds the app as an accent change always has.

The picker lays out swatches in even columns: all in one row where they fit
(Windows, TV), otherwise three or two. Each swatch is a `TvFocusable`, so it
takes touch, the remote, mouse, keyboard and game controller.

## Not yet

- The choice does not sync between devices.
- Themes change the accent and the profile card, not the page backgrounds.

Tests: `test/supporter_themes_test.dart`.
