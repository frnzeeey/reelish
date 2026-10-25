# Windows

Reelish for Windows 10 and 11: its own desktop interface over the shared
core, driven by mouse, keyboard and game controller. Install, use, build
and release steps are in [`docs/windows.md`](../windows.md); this page maps
the architecture to the code.

## Where the code is

| Concern | Location |
|---|---|
| Shell | [`desktop_shell.dart`](../../lib/src/desktop/desktop_shell.dart): `DesktopShell`, the hover-open glass sidebar, Continue watching (`DesktopResumeShelf`), Ctrl+F |
| Home | [`desktop_pages.dart`](../../lib/src/desktop/desktop_pages.dart) (`DesktopHomePage`), [`desktop_hero.dart`](../../lib/src/desktop/desktop_hero.dart) (Spotlight and its rail), [`desktop_top_ten.dart`](../../lib/src/desktop/desktop_top_ten.dart) |
| Catalog, Search, Library | [`desktop_pages.dart`](../../lib/src/desktop/desktop_pages.dart): `DesktopCatalogPage`, `DesktopSearchPage`, `DesktopLibraryPage` |
| Details | [`desktop_details_screen.dart`](../../lib/src/desktop/desktop_details_screen.dart) (episode panel from 1180 px wide) |
| Settings, Plugins | [`desktop_settings_page.dart`](../../lib/src/desktop/desktop_settings_page.dart), [`desktop_plugins_page.dart`](../../lib/src/desktop/desktop_plugins_page.dart), [`desktop_update_section.dart`](../../lib/src/desktop/desktop_update_section.dart) |
| Provider search panel | [`desktop_provider_search.dart`](../../lib/src/desktop/desktop_provider_search.dart) |
| Shared building blocks | [`desktop_widgets.dart`](../../lib/src/desktop/desktop_widgets.dart): `DesktopMetrics`, `DesktopSurfaces`, `desktopMotion`, `posterDecodeWidth`, `DesktopPosterCard`, `DesktopMediaRow` |
| Window and keys | [`desktop_window.dart`](../../lib/src/platform/desktop_window.dart): `DesktopWindow` (fullscreen), `DesktopShortcuts` (F11, Escape, Backspace) |
| Game controller | [`desktop_gamepad.dart`](../../lib/src/platform/desktop_gamepad.dart) |
| Installation and updates | [`windows_installation.dart`](../../lib/src/platform/windows_installation.dart), [`windows_update_controller.dart`](../../lib/src/services/windows_update_controller.dart), [`desktop_update_dialogs.dart`](../../lib/src/desktop/desktop_update_dialogs.dart) |
| Runner (C++) | [`windows/runner/`](../../windows/runner): `flutter_window.cpp` (`reelish/window`), `gamepad_channel.cpp` (`reelish/gamepad`), `app_update_channel.cpp` (`reelish/app_update`) |
| Wiring | `HomeScreen._buildDesktop` in [`home_screen.dart`](../../lib/src/screens/home_screen.dart) |

## Interface and input

- **Sidebar.** An 80 px icon rail that opens to 248 px over the page when
  the pointer rests on it or keyboard focus enters it, without rebuilding
  the page. "Keep sidebar open" pins it beside the page (preference
  `reelish.desktop.sidebarPinned`). Continue watching sits in the rail.
- **Pages** stay alive once visited (offstage, `TickerMode` off).
- **Spotlight.** A full-bleed backdrop with text on the left and a looping
  "In the Spotlight" rail; rotates every 8 s while Home is shown and the
  pointer is not over it.
- **Sizes.** `DesktopMetrics` derives poster sizes from the space available
  (960 px to 4K); images are decoded at bucketed widths
  (`posterDecodeWidth`), so window resizes reuse decodes.
- **Keyboard.** Ctrl+F search; Escape leaves fullscreen, then goes back;
  Backspace goes back unless typing; F11 fullscreen. In the player: Space,
  Left/Right, Up/Down (volume), M, F, and the mouse wheel for volume.
- **Controller.** XInput through `reelish/gamepad`: the D-pad and stick
  move focus like the arrow keys, A activates, B goes back; the first press
  lands on the sidebar.
- **Motion** goes through `desktopMotion`, which honours reduced motion.

## Playback

libmpv is the only engine (`media_kit_libs_windows_video` bundles it), with
its own networking. No torrents, picture-in-picture, rotation or brightness.
The player's lock takes keys and the controller. Provider scripts run on
QuickJS from `quickjs_c_bridge.dll` (built by
[`tool/build_quickjs_bridge_windows.ps1`](../../tool/build_quickjs_bridge_windows.ps1)),
with the same memory limit and interrupt as Android.

## Packaging and updates

`.github/workflows/release-windows.yml` builds `Reelish-Setup-x64.exe`
(Inno Setup, per user, no administrator rights) and the portable
`Reelish-Windows-x64.zip`, each with a `.sha256`, and test-installs the
installer. `WindowsInstallation.usesInstaller` tells which kind is running:

- **Installed copies** download the installer. Before it may run it must
  match the release's SHA-256, be a Windows executable whose version
  resource names Reelish at exactly the offered version, and carry no
  invalid signature; it is checked against the SHA-256 again just before
  it starts. The runner launches it with fixed arguments and Reelish exits;
  the installer waits, replaces the files and relaunches.
- **Portable copies** get the verified ZIP in Downloads; Reelish never
  modifies a portable folder.

The app is not code-signed yet, so SmartScreen may ask before the first
launch.

## Tests

`desktop_ui_test`, `desktop_redesign_test`, `desktop_home_top_ten_test`,
`desktop_gamepad_test`, `desktop_settings_plugins_test`,
`desktop_remove_favorites_test`, `desktop_top_ten_test`,
`windows_update_test` in [`test/`](../../test); on Windows,
`windows_playback_test`, `windows_player_ui_test`, `windows_soak_test`,
`windows_update_channel_test` in [`integration_test/`](../../integration_test).
