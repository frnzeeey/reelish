# Reelish for Windows

Reelish runs on Windows 10 and 11 (x64) as a native desktop app built from
the same Flutter code as Android. It has its own desktop interface (a
collapsible side menu, a featured banner, poster rows, and desktop details
and search pages) built for a mouse and keyboard, and plays through libmpv.

## Install and update

**Installer (recommended).** Download `Reelish-Setup-x64.exe` from the
[latest release](https://github.com/frnzeeey/reelish/releases/latest) and
run it. It installs for your user only, into
`%LOCALAPPDATA%\Programs\Reelish`, without administrator rights, and adds a
Start menu entry. Installed copies update themselves (below).

**Portable.** Download `Reelish-Windows-x64.zip`, extract it anywhere you can
write to and run `Reelish\Reelish.exe`. Portable copies are never modified by
Reelish: updates are downloaded for you to extract.

Each asset has a `.sha256` next to it. The app isn't code-signed yet, so
Windows SmartScreen may warn the first time. Choose **More info → Run
anyway** if you downloaded it from the release page.

Settings, library, history and installed plugins are kept in
`%APPDATA%\frnzeeey\Reelish`, outside the app folder. The window's size and
position are stored in `HKCU\Software\frnzeeey\Reelish`. Installing,
updating and uninstalling never touch either.

### In-app updates

**Settings → About → Application updates** shows the installed version, the
update status, when GitHub was last checked, and the action for the current
state. Reelish checks automatically about 20 seconds after it starts (and on
resume), at most every 6 hours; the switch there turns that off. **Check for
updates** always asks GitHub. **Later** on an update prompt means that
version is not offered automatically again; About still shows it.

For an **installed** copy, **Update now**:

1. downloads `Reelish-Setup-x64.exe` in the background (progress, size and
   speed in the dialog and in About; it can be cancelled, and the dialog
   closed while it continues);
2. checks its size and SHA-256 (GitHub's asset digest, or the release's
   `.sha256` when GitHub reports none; no SHA-256 means no update);
3. checks that it is a Windows executable whose version resource says
   Reelish by frnzeeey at exactly the offered version, and that it has no
   broken signature;
4. on **Restart and install** (refused while a video is open), checks the
   SHA-256 again, starts it with fixed arguments and closes Reelish
   normally.

The installer waits for Reelish to exit before changing any file, moves the
old app folder aside, installs into a clean folder and opens the new
Reelish. If installing fails or is cancelled, the old folder is put back and
the old Reelish reopens; if Reelish never closes, Setup gives up after a
minute without changes. A verified download that wasn't installed is kept
in `%TEMP%\Reelish\updates` and reused.

For a **portable** copy, the update ZIP is verified the same way, saved to
Downloads and shown in File Explorer; close Reelish, extract it and replace
the folder.

**Trust.** The download URL, the asset digest and the `.sha256` all come
from the same GitHub release, so the checksum proves the file is intact and
is the release's file, not that the release itself is genuine: someone who
can publish releases on `frnzeeey/reelish` could publish a malicious one.
Until the installer is code-signed (then publisher identity can be checked
too), that GitHub account and its Actions secrets are the root of trust.
Downgrades are not offered, and the installer must name the offered version.

## Using Reelish with a mouse and keyboard

| Input | Action |
|---|---|
| Click | Select (and focus) a title, button or menu item |
| Hover | Highlights cards; shows scroll arrows on rows |
| Mouse wheel, trackpad | Scroll pages; Shift+wheel or a trackpad scrolls rows sideways |
| Arrow keys, Enter | Move focus and select, as with a TV remote |
| Tab / Shift+Tab | Move between controls |
| Escape | Leave fullscreen, otherwise go back or close a dialog |
| Backspace | Go back (not while typing) |
| F11 | Toggle fullscreen anywhere |
| Ctrl+F | Open Search |

The button at the bottom of the side menu collapses it to icons (with
tooltips) or expands it; Reelish remembers the choice.

**In the player:**

| Input | Action |
|---|---|
| Move the mouse | Show the controls; they and the cursor hide when idle |
| Space | Play or pause |
| Left / Right | Seek 10 s (repeated presses add up) |
| Up / Down | Volume ±5% (when no control is focused) |
| Mouse wheel | Volume ±5% |
| M | Mute or restore the volume |
| F, or the button in the controls | Toggle fullscreen |

The window can be resized down to 960 × 600 logical pixels, maximized, and
made fullscreen on whichever monitor it's on.

## What's different from Android

- **P2P / torrent playback** is Android-only. The setting says so on
  Windows.
- **Picture-in-picture, rotation lock, touch lock and brightness gestures**
  are phone and TV features and don't appear on Windows.
- **Search** has a regular text box. Some fields in Settings and Plugins
  still open a small entry dialog, as on TV; type there and press Enter.

## How it's built

| Area | Windows | Shared with Android |
|---|---|---|
| Interface | `DeviceCapabilities.isDesktop` selects the desktop interface in `lib/src/desktop/` (`DesktopShell`, `DesktopHero`, the desktop pages and `DesktopDetailsScreen`). Windows isn't treated as a TV: `isTv` stays false, so TV-hardware behaviour (low glass quality, Back revealing player controls) is off | Catalog data (`TvCatalog`), Settings and Plugins screens, player chrome |
| Mouse and keyboard | Hover, click and keyboard focus in the desktop widgets; `DesktopShortcuts` (`lib/src/platform/desktop_window.dart`); desktop keys in the player | TV focus traversal |
| Window | `windows/runner/flutter_window.cpp`: `reelish/window` channel (fullscreen), minimum size, saved placement | — |
| Playback | `PlayerEngineFactory` selects `MpvPlayerEngine` (libmpv via media_kit); `media_kit_libs_windows_video` bundles libmpv | libmpv engine, headers, subtitles |
| Providers | `quickjs_c_bridge.dll` with QuickJS's memory-limit and interrupt exports (`third_party/flutter_js/REELISH_PATCH.md`) | Provider bridge, sandbox, network policy |
| Updates | `WindowsUpdateController` and the desktop update dialogs and About section; `reelish/app_update` channel (`windows/runner/app_update_channel.cpp`: installer inspection, Authenticode check, launch); `ReelishAppMutex` (`main.cpp`); Inno Setup script `windows/installer/reelish.iss`. Portable copies keep the verified-ZIP handoff | Release check, version comparison, download, verification |

Android keeps its engine order (Media3 first, libmpv fallback), its
interfaces, and its APK updater. The Windows libmpv package has no Android
code; a controlled build comparison found `classes.dex`, the manifest,
resources and every native library unchanged.

**Change to the vendored media_kit bridge:**
`packages/video_player_media_kit/lib/src/media_kit_video_player.dart` asks
for a frame after creating its `VideoController` on Windows. The controller
creates its video output after the next frame, and opening a stream waits
for that, so a still screen could otherwise wait forever.

## Build from source

You need Visual Studio 2022 or newer with **Desktop development with C++**,
and the Flutter version pinned in `.github/workflows/release.yml`.

```sh
flutter build windows --release
```

The app is in `build\windows\x64\runner\Release\`. Ship the whole folder,
not just `Reelish.exe`.

To rebuild the QuickJS bridge DLL, run
`powershell -File tool\build_quickjs_bridge_windows.ps1` (see
`third_party/flutter_js/REELISH_PATCH.md`).

### Tests

```sh
flutter test test/quickjs_windows_limits_test.dart
flutter test integration_test/provider_runtime_test.dart -d windows
flutter test integration_test/windows_playback_test.dart -d windows
flutter test integration_test/windows_player_ui_test.dart -d windows
```

The two `windows_*` integration tests play public test media: Mux's HLS
stream, Akamai's DASH reference stream and Big Buck Bunny clips. They need a
network connection.

## Releases

`.github/workflows/release-windows.yml` runs on the same `vX.Y.Z` tags as
the Android release, on a Windows runner. It:

1. checks the QuickJS bridge's hash and exports;
2. runs the Windows tests;
3. builds an obfuscated release with the same build tag and commit as the
   APK;
4. verifies the output (files, identity, version, obfuscation);
5. packages `Reelish-Windows-x64.zip`, builds `Reelish-Setup-x64.exe` with
   Inno Setup (checking its name, publisher and version), writes their
   `.sha256` files, and encrypts the debug symbols;
6. installs the installer silently on the runner, checks the installed
   files, and uninstalls it;
7. waits for `release.yml` to publish the release, then attaches the four
   Windows assets.

It never creates or edits a release or the APK. If the Android release
fails, nothing is published. Run it from the Actions tab
(`workflow_dispatch`) to build the ZIP as an artifact without publishing.

To build the installer locally (Inno Setup 6.3 or newer):

```sh
ISCC /DAppVersion=1.12.0 /DSourceDir=build\windows\x64\runner\Release windows\installer\reelish.iss
```

To check the updater's native channel against a real installer:

```sh
flutter test integration_test/windows_update_channel_test.dart -d windows ^
  --dart-define=REELISH_TEST_INSTALLER=<path>\Reelish-Setup-x64.exe ^
  --dart-define=REELISH_TEST_INSTALLER_VERSION=1.12.0 ^
  --dart-define=REELISH_TEST_SIGNED=<any Authenticode-signed .exe>
```

**Not done yet:** code signing (needs a certificate; the updater already
rejects a broken signature and would accept a valid one), MSIX, and ARM64
builds (the QuickJS bridge is x64-only).
