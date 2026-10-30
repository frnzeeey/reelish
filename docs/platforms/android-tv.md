# Android TV

The remote-first interface for Android TV. Google TV uses exactly the same
code (see [Google TV](google-tv.md)). The detailed guide to TV detection,
focus rules, testing and limitations is
[`docs/android_tv.md`](../android_tv.md); this page maps it to the code.

## How Reelish knows it is on a TV

`ReelishActivity.deviceCapabilities()` reports a TV when the UI mode is
`UI_MODE_TYPE_TELEVISION` or the device declares the `leanback` feature.
`DeviceCapabilities.load` reads it over `onfeed/device` during startup,
before the first screen, so the TV theme (`GlassTheme.tv`) and remote focus
are in place from the start. Screen size is never used.

To try the TV interface on a phone or a regular emulator:
`flutter run --dart-define=REELISH_FORCE_TV=true`.

## Where the code is

| Concern | Location |
|---|---|
| Shell and rail | [`tv_home_shell.dart`](../../lib/src/screens/tv/tv_home_shell.dart) (`TvHomeShell`, `TvDestination` from [`app_destination.dart`](../../lib/src/navigation/app_destination.dart)) |
| Pages | [`tv_pages.dart`](../../lib/src/screens/tv/tv_pages.dart): `TvHomePage`, `TvCatalogPage`, `TvSearchPage`, `TvLibraryPage` |
| Browsing blocks | [`tv_browse.dart`](../../lib/src/screens/tv/tv_browse.dart): `TvBrowseFrame`, `TvMediaRow`, `TvMediaGrid`, `TvFeaturedController` |
| Details | [`tv_details_screen.dart`](../../lib/src/screens/tv/tv_details_screen.dart) |
| Focus and remote | [`tv_focus.dart`](../../lib/src/widgets/tv/tv_focus.dart): `TvFocusable`, `TvSafeArea`, `TvPopupFocusObserver`, `TvKeyScroll`, `TvTextEntryDialog`; [`tv_poster_card.dart`](../../lib/src/widgets/tv/tv_poster_card.dart) |
| Plugins and Settings | The phone screens: `PluginsScreen` (inside `TvReadableWidth`) and `SettingsScreen` |
| Wiring | `HomeScreen._buildTv` in [`home_screen.dart`](../../lib/src/screens/home_screen.dart) |

## Interface and input

- A left rail for Home, Movies, Series, Search, My library, Plugins and
  Settings; visited pages stay alive (offstage) and keep their place.
- The featured title above the rows follows focus (`TvFeaturedController`
  waits for focus to settle, so a held D-pad does not decode a backdrop per
  poster). There is no automatic rotation on TV.
- Everything is reachable with the D-pad; focus is always visible
  (`TvFocusable`); dialogs and sheets get a focused control
  (`TvPopupFocusObserver`); text entry uses `TvTextEntryDialog`.
- Overscan-safe margins (`TvSafeArea`) apply only when `isTv`.
- `LiquidGlass` quality is capped to low.

## Playback

The same engines as phones (Media3, libmpv fallback). In the player, Back
shows the controls first instead of leaving; the remote keys are handled in
`CustomVideoPlayer._onRemoteKey`, and focus is kept inside the player while
it is on top. Brightness gestures are not offered; picture in picture is
offered from the player button only where the TV supports it (leaving the
app never starts it, as it does on phones).
Many TV devices (such as Chromecast with Google TV) run 32-bit Android, so
torrent sources are neither requested nor offered there
(`TorrentSupport`).

## Build, install, update

The phone APK; see [Android](android.md). Sideloading and testing on a TV
emulator are in [`docs/android_tv.md`](../android_tv.md). Updates use the
same `GitHubUpdateService` flow as phones.

## Tests

`tv_home_test`, `tv_layout_test`, `tv_support_test` in [`test/`](../../test)
(they use `DeviceCapabilities.debugOverride`).
