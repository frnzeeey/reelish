# Android TV and Google TV

Reelish runs on phones, tablets, Android TV and Google TV from one APK and one
codebase. On a TV it shows an interface built for a remote, not the phone
layout stretched to fit: a side rail, a browse hero that follows focus, poster
rows, and remote control of the player. Services, models, the provider
runtime, the TMDB cache and both playback engines are the same on every device.

## How TV detection works

`MainActivity.deviceCapabilities()` (channel `onfeed/device`) reports:

| Key | Source |
|---|---|
| `isTelevision` | `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION` **or** `PackageManager.FEATURE_LEANBACK` |
| `hasTouchscreen` | `FEATURE_TOUCHSCREEN` |
| `supportsPictureInPicture` | API 26+ and `FEATURE_PICTURE_IN_PICTURE` |

`DeviceCapabilities.load()` (`lib/src/platform/device_capabilities.dart`) reads
this once, during the splash gate, alongside the two preference reads that
already run there, so startup does not get any longer. Screen size is never
used: a large tablet stays mobile, and a small TV stays a TV. If the query
fails or times out (2 s), the app keeps the mobile interface.

On a TV, `load()` also:

- sets `LiquidGlass.qualityCeiling` to `low`, so no glass surface uses a
  backdrop blur;
- sets `FocusManager.highlightStrategy` to `alwaysTraditional`, so focus is
  drawn even before the first key press.

`ReelishApp` then switches to `GlassTheme.tv`, which adds coral focus tints and
rings to buttons and `InkWell`s, and registers `TvPopupFocusObserver` (see
below).

Sliders are wrapped in `TvSliderNavigation`, which gives them
`NavigationMode.directional`: Left/Right change the value, Up/Down move on.
This is applied per slider, not app-wide. App-wide directional mode also makes
*disabled* controls focusable, and Material draws no focus on a disabled
control. On the first-run consent screen, focus disappeared onto the disabled
agreement checkboxes.

Everything TV-specific is behind `DeviceCapabilities.isTv`. Phones and tablets
take the code paths they took before this change.

**Testing the TV interface without a TV:**
`flutter run --dart-define=REELISH_FORCE_TV=true` forces it on any device.

## Android configuration

`android/app/src/main/AndroidManifest.xml`:

- `android.software.leanback` and `android.hardware.touchscreen` are declared
  with `required="false"`, so Play does not filter out TVs (which have no
  touchscreen) and phones install as before.
- A second launcher intent filter with `LEANBACK_LAUNCHER` puts Reelish on the
  TV home screen. Phones ignore it.
- `android:banner="@drawable/tv_banner"`: a 320 × 180 xhdpi banner
  (`res/drawable-xhdpi/tv_banner.png`) built from the app icon and the
  Montserrat wordmark.

The activity already handles orientation and screen configuration changes, and
does not lock orientation, so nothing else changes. The native splash is
centered and works in landscape.

> Declaring TV support does not make the app pass Google Play's TV quality
> review. That review also covers things like content policy and the required
> TV screenshots. Reelish ships through GitHub Releases, so the review does
> not apply today.

## Interface structure

| Area | Mobile | TV |
|---|---|---|
| Navigation | `SoftGlassDock` (Home, Plugins, Library, Settings) | `TvHomeShell` rail: Home, Movies, Series, Search, My library, Plugins, Settings |
| Home | `HomeScreen._home()` | `TvHomePage`: browse hero + rows |
| Movies / Series | category chips | `TvCatalogPage`: paging grid |
| Search | header field | `TvSearchPage`: TV keyboard, paging grid |
| Library | `LibraryScreen` | `TvLibraryPage`: Continue watching, My list, Watch history |
| Details | `MediaDetailsScreen` | `TvMediaDetailsScreen` |
| Plugins, Settings | full width | the same screens, limited to a readable width (`TvReadableWidth`, and inside `SettingsPage`) |
| Player | `CustomVideoPlayer` | the same player, with remote handling |

`HomeScreen` keeps all state and business logic: feeds, favourites, history,
and the play flow (`_openItem`, provider search, source selection, episode
hand-off). On TV its `build` returns `_buildTv`, which passes the same
controllers to the TV pages through `TvCatalog`. Code:

```
lib/src/platform/device_capabilities.dart   detection and TV app settings
lib/src/widgets/tv/tv_focus.dart            TvFocusable, TvTextField, TvReadableWidth
lib/src/widgets/tv/tv_poster_card.dart      poster cards, Top 10 numeral
lib/src/screens/tv/tv_home_shell.dart       rail, pages, Back handling
lib/src/screens/tv/tv_browse.dart           hero, rows, grids
lib/src/screens/tv/tv_pages.dart            Home, Movies/Series, Search, Library
lib/src/screens/tv/tv_details_screen.dart   details, seasons, episodes
```

On TV, Home puts the rows that load first (New movies, Series) at the top.
Top 10 and New releases load only when the list nears them, so a cold start
costs three TMDB requests: Movies, Series and Trending (covered by
`test/tv_home_test.dart`).

## How focus management works

- **Remote input.** D-pad arrows move focus through Flutter's directional
  traversal. Select / Enter / gamepad A activate (`ActivateIntent`, a default
  shortcut). Back is the system back.
- **Focus targets.** Posters, rail items, seasons and episodes use
  `TvFocusable`: a slight scale-up, a coral ring and a glow, painted only on
  the focused item. Material buttons and `InkWell`s get their focus style from
  `GlassTheme.tv`.
- **Rows** (`TvMediaRow`) keep the focused poster at the start of the row and
  scroll the row to the top of the list, so focus stays in one place on
  screen. Each row remembers its last focused poster. Coming back with Up or
  Down returns to it, not to whichever poster happens to be nearest. Rows and
  grids scroll themselves; their `FocusTraversalGroup` uses
  `tvSelfScrollingTraversal`, so Flutter's own nudge-into-view does not fight
  that scroll.
- **Pages.** Each rail page has its own `FocusScope`, so returning to a page
  restores its last focused control. Pages that aren't shown are offstage,
  wrapped in `ExcludeFocus`, and run no tickers.
- **Rail.** Left past a page's leftmost control focuses the rail, which widens
  to show labels. Moving through the rail switches pages; Right or Select
  enters the page.
- **Back.** Page → rail → Home → exit the app. Pushed screens (details,
  settings) pop as usual, and Flutter returns focus to the control that
  opened them.
- **Initial focus.** Home autofocuses its first row (or "Add a source" when no
  provider is installed). Details focuses Play. Sheets focus the selected
  option. The episode panel focuses the current episode.
- **Dialogs and sheets** are modal routes, so focus stays inside them until
  they close. `TvPopupFocusObserver` (registered on TV in `main.dart`)
  focuses the first control in reading order when a dialog or sheet opens
  with nothing focused. In Material dialogs that is the leftmost action
  (Cancel, Later, Not now), so Select never confirms by accident. It runs
  after the route's own autofocus has been applied, and leaves it alone.
- **Text with nothing to focus.** `SettingsPage` (all settings pages and the
  legal documents) uses `TvKeyScroll`: Up/Down move focus when there is
  somewhere to go, and otherwise scroll most of a screen. Without this, the
  first-run privacy policy and terms, which must be scrolled to the end,
  could not be completed with a remote.
- **Ink behind decorations.** An `InkWell`/`ListTile` draws its focus
  highlight on the nearest `Material`. Inside a plain `DecoratedBox` or
  `Container` it is hidden behind the decoration. Such containers need a
  transparent `Material` (as `ReelishGlassCard` and `SettingsSection` already
  have; added to the consent screen's document tiles).
- **Text.** `TvTextField` does not open the keyboard when it gains focus (the
  keyboard would otherwise pop up whenever focus passed over it). Select opens
  `TvTextEntryDialog`, where the system TV keyboard edits the text. Once the
  keyboard is dismissed, Up and Down leave the field, so the caret can't trap
  the remote. Search updates live (450 ms debounce) and right away on the
  keyboard's search key. Repository URLs use the URL keyboard. Paste still
  works where the TV has a clipboard.

## Playback on TV

There is no separate TV player. `CustomVideoPlayer` adds remote handling when
`isTv`. The engines are unchanged: Media3 (ExoPlayer) first, libmpv
(media_kit) as fallback and for non-HTTPS URLs and torrents. Both use the
device's MediaCodec hardware decoders. Codec support (HEVC, 4K, HDR, audio
passthrough) depends on the TV's SoC, not the app. Engine fallback, stream
headers, redirects, HLS/DASH and provider sources work as they do on mobile.

| Key | Controls hidden | Controls shown |
|---|---|---|
| Left / Right | seek ∓10 s (quick presses add up) | move between controls |
| Up / Down / Select | show controls, focus Play | move / activate |
| Progress bar, Left/Right | | scrub: 10 s steps, 30 s then 60 s when held; one seek when keys rest or on Select |
| Play/Pause, Play, Pause | play/pause | play/pause |
| Fast forward / Rewind | seek ±10 s | seek ±10 s |
| Next track | next episode (series) | next episode |
| Captions | subtitle picker | subtitle picker |
| Menu / Info | playback settings | playback settings |
| Back | shows controls | leaves the player |

Back while watching only brings the controls up, so one stray press never
ends playback. Sheets and the subtitle position panel close before the player
does. Controls stay up for 5 s after the last key press (3.5 s on mobile) and
stay up while paused.

Hidden controls, the center buttons the pause screen covers, and the
next-episode card while the controls are up are all excluded from focus. A
remote never lands on something invisible. When the controls hide, focus
returns to the player itself (`_keepRemoteFocus`), so keys keep reaching it.

TV hides touch-only controls: the lock, the rotation lock, and picture in
picture where the TV does not support it. Swipe and double-tap gestures need
a touchscreen and are simply never triggered. Subtitles, subtitle delay and
position, audio tracks, aspect ratio, speed, quality, source switching and
engine switching all use the existing sheets, which work with the remote.

## Build and install

```sh
# Debug, for development (phone, tablet or TV):
flutter run -d <device>
flutter run -d <device> --dart-define=REELISH_FORCE_TV=true   # TV UI anywhere

# Release (needs the ONFEED_RELEASE_* signing values; see releasing.md):
flutter build apk --release
adb connect <tv-ip>:5555        # enable Developer options → USB/network debugging on the TV
adb install -r build/app/outputs/flutter-apk/reelish.apk
```

The release APK is the same file for phones and TVs. It contains
`armeabi-v7a` and `arm64-v8a` code, which covers TV hardware (Chromecast with
Google TV, Shield, Mi Box, most TVs are ARM). Release builds leave out x86_64
(see `android/app/build.gradle.kts`).

In-app updates work on TV too, as long as "Install unknown apps" is allowed
for Reelish in the TV's settings.

## Testing

- `test/tv_support_test.dart`: detection, `TvFocusable`, row focus memory,
  rail and page focus hand-off, Back order, D-pad scrubbing, focus exclusion
  under the pause screen, TV text entry.
- `test/tv_home_test.dart`: the real `HomeScreen` in TV mode on a fake TMDB:
  the shell, the cold-start request budget, details and back with focus
  restored, the rail into Movies and Search.
- The mobile suites run unchanged.

**Checked on the Android TV emulator** (Television 1080p, Android 16,
leanback, 960 × 540 dp, ARMv7 profile build, D-pad keys only):

- Reelish appears under the TV launcher's Installed Apps with its banner and
  launches from `LEANBACK_LAUNCHER`.
- First-run consent: Read, scroll both documents to the end, agree to both,
  continue.
- Home: the hero follows the focused poster, rows keep focus at the left,
  Back from details restores the poster, the rail opens with labels.
- Details: Play focused. Play with no providers shows the notice; Down reaches
  its PLUGINS action, which opens the Plugins page with focus on it.
- Search: the TV keyboard opens from the field, the search key submits,
  results appear and focus returns to the field.
- The update dialog opens with Later focused. The provider installer opens
  with the URL field focused.

Device testing found five problems that the widget tests had not caught
(invisible focus on disabled controls, unreadable must-read documents, ink
hidden behind a decoration, dialogs with no focus, and the popup observer
overriding autofocus). All are fixed, and each has a regression test in
`tv_support_test.dart`.

**Emulator.** Use an Android TV or Google TV system image. Recent x86 TV
images run the ARM libraries under binary translation, so debug (JIT) builds
are very slow to start there. A profile build is a better check:
`flutter build apk --profile --target-platform android-arm`.

## Known limitations

- **Player remote keys are untested** (`_onRemoteKey`): not in widget tests,
  because the player opens a real Media3 or libmpv engine that they can't
  host, and not on the emulator, because playing needs an installed provider.
  Check them on a device with a provider: hidden-controls seeking, Back, media
  keys, the pause screen focus, subtitle position, and the error view.
- **Media keys** reach the app only when no other app holds an active media
  session.
- **Snackbars** are not focused automatically. Their action is reached by
  moving focus down (checked on the details page: Down reaches PLUGINS), but
  not every layout guarantees a path to it.
- **Left on reused screens** (Plugins, Settings) follows Flutter's geometric
  rule: from a control at the top right, the nearest target to the left may
  be a tile below, not the rail. Left from a control at the left edge always
  reaches the rail. Back always does too.
- **External links** (such as "Project page & support") open another app.
  Most TVs have no browser, so they may open nothing useful.
- **Library on TV** has no "remove from history" action yet; the mobile
  Library still offers it.
- **No companion workflow** for entering repository URLs (QR code or a phone
  page). URLs are typed on the TV keyboard, or pasted where the TV has a
  clipboard.
- **Performance** has been checked against the design (no backdrop blur on
  TV, one decoded image per poster at display size, a backdrop decode only
  after focus settles for 260 ms, deferred rows). Frame timing has not been
  measured on low-end TV hardware.
