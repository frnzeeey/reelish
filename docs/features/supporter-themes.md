# App themes

Accounts with the supporter perks (supporters, and the Founder) can choose an
app theme in Settings > Appearance, under THEMES. A theme is a whole look: the
colours of every page (background, surfaces, text, borders, glass), the accent,
and the profile card's lights, avatar ring and ornament. Everyone else keeps
Classic, the original Reelish look, with any accent colour they like.

| Theme | Character | Profile ornament |
|---|---|---|
| Velvet Cinema (flagship) | Midnight and deep violet, lit in lavender | Sheen |
| Aurora | Northern lights in teal and emerald | Aurora ribbons |
| Ember | A dark theatre in warm, glowing light | Sheen |
| Arctic | Deep navy and clear, icy blue | Stars |
| Obsidian Gold | Obsidian black with champagne gold | Sheen |
| Rosé Noir | Dark plum with muted rose and mauve | Sheen |
| Ivory Studio (light) | Warm ivory and bronze, in daylight | Sheen, on a dark card |

Ivory Studio is a light theme: ivory pages and dark text. Two of its colours
are a step deeper than its palette so small text keeps AA contrast on ivory:
the accent (`#856D4C`, with the palette's `#B49B78` as its light partner) and
the captions (`#6F685C` for `#777064`).

## Design tokens

Every colour a theme changes is a token, so no screen names a theme:

- `ThemeSurfaces` (`lib/src/theme/theme_tokens.dart`): `background`,
  `surface` (cards, fields), `raised` (dialogs, sheets, menus), `textPrimary`,
  `textSecondary`, and derived `disabled`, `border`, `divider`, `glassTint`,
  `glassBackground`, `glassStrong` and `sidebar`. `ThemeSurfaces.classic`
  keeps the original values exactly.
- `GlassTheme` (`lib/src/theme/glass_theme.dart`) exposes the active set as
  getters (`GlassTheme.background`, `.surface`, `.elevatedSurface`,
  `.textPrimary`, `.muted`, `.border`, `.glassTint`, ...) beside the accent
  (`primary`, `coralBright`, `coralDark`). Status colours (`warning`, `danger`,
  `success`, `info`) stay fixed whatever the theme.
- `GlassTheme.build(accent, surfaces)` and `buildTv(...)` make the Material
  theme from tokens: the full `ColorScheme`, buttons (the glass finish), menus,
  dialogs, sheets, cards, chips, tooltips, tabs, progress, text selection,
  navigation bar and fields. `GlassTheme.dark` and `.tv` build it for the
  active look.
- Windows surfaces (`DesktopSurfaces.sidebar`, `.glass`, `.hairline`), glass
  panels (`LiquidGlass`'s default tint), the background scrims that fade
  artwork into the page, settings and party cards follow the tokens.
- The video player keeps dark chrome in every theme, as it sits over video:
  `ThemeSurfaces.forPlayer` is the theme's own colours on a dark theme and a
  dark counterpart on a light one, `GlassTheme.playerPrimary` the accent that
  reads on it (a light theme's lighter partner), and `PlayerScreen` wraps the
  player in `GlassTheme.player`, so its sheets and dialogs are dark too.
- The native splash colour (`SplashSpec.background`) stays fixed, since the
  system launch screen cannot follow a theme.

Adding a theme is one `SupporterTheme` entry in
`lib/src/theme/supporter_themes.dart`: its surfaces, accent (`primary`,
`light`, `deepAccent`), profile lights (`glow`, `second`, `deep`, `ink`) and
ornament, then adding it to `SupporterTheme.all`.
`test/supporter_themes_test.dart` checks every offered theme's contrast:
text AAA on the page, captions AA on the page and on dialogs, the accent AA
on the page and the page colour AA on the accent.

## Who gets one

`AccentSettingsController` applies a theme only while the signed-in account has
the `appThemes` perk (`SupporterController.has`, from the server's
[entitlement](../backend/entitlements.md)); the Founder inherits it. A donation
waiting for review does not count. Others see every theme with a small
Supporters mark and can open its preview; the preview offers "Learn more"
(which explains the perk and links to the Supporters page) instead of
"Apply theme".

A theme is cosmetic and local: it is not sent anywhere, so there is nothing for
the server to enforce. Changing local data can at most change one person's own
screen.

## Saved choices

The theme is saved on the device beside the accent: `onfeed.appearance.theme`
(the theme id) and `onfeed.appearance.accent`. Saving grants nothing: without
the perk, Classic and the picked accent show, and the saved theme waits for an
account that has the perk.

Retired themes keep working: `SupporterTheme.byId` opens a saved
`royal_violet` as Velvet Cinema, `celestial` as Arctic, `rose_luxe` as Rosé
Noir and `golden_hour` as Obsidian Gold (`SupporterTheme.replaces`). Aurora
kept its id.

Under a theme the accent picker still works: a picked accent replaces only the
theme's accent (`onfeed.appearance.theme_accent` = `0`), and the "Theme" choice
at the start of ACCENT COLOR returns to the theme's own. Choosing a theme always
starts with its own accent. Devices saved before this setting existed have no
value, which means the theme's accent, as before.

At launch, the saved supporter status is read from the device before the first
screen (`SupporterController.restoreSaved`), so the theme is right from the
start. The server is asked once Home has drawn, and its answer replaces the
saved one.

## Applying a theme

Screens read colours through `GlassTheme` as they build, not only through
`Theme.of`. So when the look changes, `ReelishApp` (`lib/main.dart`) rebuilds
the app with the new Material theme and then marks every element for one
rebuild after that frame. Navigation, scroll positions and state are kept;
nothing is recreated. Material's own theme change fades in over
`kThemeAnimationDuration`, or at once under reduced motion.

## The picker and preview

`lib/src/widgets/supporter_theme_picker.dart`, on the Appearance page
(`AppearanceSettingsScreen` in `playback_settings_screen.dart`) on phone, TV
and Windows:

- Classic, then the seven themes, each a card drawn from that theme's own
  tokens (its page, a poster, a card, the accent button), with its name and
  one-line description. Cards lay out in even columns: four on Windows and TV
  where they fit, otherwise three or two. Each card is a `TvFocusable`, so it
  takes touch, the remote, mouse, keyboard and game controller.
- Choosing a theme opens `ThemePreview`: a small Reelish screen (header and
  avatar ring, search, category chips, posters with progress, the glass Play
  and Details buttons, a dialog surface and the dock) made of real Material
  components inside `GlassTheme.build` for that theme, so it is the theme as
  the app draws it. The sample is not interactive; the remote moves between
  Apply and Close, with Apply focused.
- Classic applies directly.

## Rendering

Each profile backdrop is one `CustomPainter` inside a `RepaintBoundary`: two
radial lights over a tinted base, plus its ornament, with fixed star positions.
It has no animation and no `BackdropFilter`, so it is painted once. Theme cards
are plain decorations; no theme adds a blur or an animation.

## Light themes and artwork

Interface text and overlays read `GlassTheme.textPrimary` (and its tints), so
they turn dark on a light theme. White stays white only where it sits on
artwork, video or an accent fill: titles over heroes and detail backdrops,
icons and badges over posters and stills, check marks on the accent, the
player. Masks (`ShaderMask` gradients) keep white, as it is not a colour there.

Artwork areas use `GlassTheme.artworkScrim`: the page colour in dark themes, so
artwork fades into the page, and a deep ink in light themes, so those areas
stay dark and their white titles read. Titles and labels there take
`GlassTheme.onArtwork` (white on a light theme, the theme's text colour on a
dark one), never the inherited page text, which is dark on a light theme. A
hero whose actions sit at its foot (the phone Spotlight, Windows details)
ends in the scrim, not the page colour. The TV backdrops are the exception:
the hero text and the rows sit on their fade into the page, so they fade in
`GlassTheme.background` (a light wash on a light theme) and their text uses
the page colours there (`GlassTheme.isLight`). The Windows sidebar is a step deeper
than the page (darker on dark themes, a deeper cream on light ones), with a
lighter shadow on light pages. The Reelish wordmark turns to ink and crimson on
light pages, and the status bar icons turn dark (`main.dart`).

## Ambient light

Each theme casts a soft light across the main pages (`ThemeSurfaces.ambient`,
the theme's glow): `AmbientBackdrop` paints one glow from the upper left and a
fainter one from the lower right behind phone Home, the TV shell and the
Windows shell. It is painted once in a `RepaintBoundary`, with no animation or
blur, and is weaker on light pages. Classic has none, so its pages stay flat.
Pages pushed on top of the shells (details, settings on phone) are flat.

## Not yet

- The choice does not sync between devices.

Tests: `test/supporter_themes_test.dart`.
