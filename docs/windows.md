# Reelish for Windows

Reelish runs on Windows 10 and 11 (x64) as a native desktop app built from
the same Flutter code as Android. It uses the Android TV interface, driven
by mouse and keyboard, and plays through libmpv.

## Install and update

1. Download `Reelish-Windows-x64.zip` from the
   [latest release](https://github.com/frnzeeey/reelish/releases/latest).
   Optionally check it against `Reelish-Windows-x64.zip.sha256`.
2. Extract it anywhere you can write to, for example
   `%LOCALAPPDATA%\Programs\Reelish`, and run `Reelish\Reelish.exe`.

The app isn't code-signed yet, so Windows SmartScreen may warn the first
time. Choose **More info → Run anyway** if you downloaded it from the
release page.

Settings, library, history and installed plugins are kept in
`%APPDATA%\frnzeeey\Reelish`, outside the app folder. The window's size and
position are stored in `HKCU\Software\frnzeeey\Reelish`.

**Updating:** **Settings → About → Check for updates** finds a newer release.
It then:

1. downloads the ZIP;
2. checks its size and SHA-256 against what GitHub reports;
3. saves it to your Downloads folder and shows it in File Explorer.

Close Reelish, extract the new ZIP and replace the old folder. Reelish never
runs or unpacks downloaded files itself.

## Using Reelish with a mouse and keyboard

| Input | Action |
|---|---|
| Click | Select (and focus) a title, button or menu item |
| Hover | Highlights cards; opens the side menu |
| Mouse wheel, trackpad | Scroll pages; Shift+wheel or a trackpad scrolls rows sideways |
| Arrow keys, Enter | Move focus and select, as with a TV remote |
| Tab / Shift+Tab | Move between controls |
| Escape | Leave fullscreen, otherwise go back or close a dialog |
| Backspace | Go back (not while typing) |
| F11 | Toggle fullscreen anywhere |

**In the player:**

| Input | Action |
|---|---|
| Move the mouse | Show the controls; they and the cursor hide when idle |
| Space | Play or pause |
| Left / Right | Seek 10 s (repeated presses add up) |
| Up / Down | Show the controls and move between them |
| F, or the button in the controls | Toggle fullscreen |

The window can be resized down to 960 × 600 logical pixels, maximized, and
made fullscreen on whichever monitor it's on.

## What's different from Android

- **P2P / torrent playback** is Android-only. The setting says so on
  Windows.
- **Picture-in-picture, rotation lock, touch lock and brightness gestures**
  are phone and TV features and don't appear on Windows.
- **Text fields in the TV interface** open a small entry dialog, as on TV.
  Type there and press Enter.

## How it's built

| Area | Windows | Shared with Android |
|---|---|---|
| Interface | `DeviceCapabilities.layoutMode == desktop` selects the TV interface (`usesTvLayout`). Windows isn't treated as a TV: `isTv` stays false, so TV-hardware behaviour (low glass quality, Back revealing player controls) is off | TV shell, rows, details, player chrome |
| Mouse and keyboard | Hover and click focus in `TvFocusable` and the rail; `DesktopShortcuts` (`lib/src/platform/desktop_window.dart`); desktop keys in the player | TV focus traversal |
| Window | `windows/runner/flutter_window.cpp`: `reelish/window` channel (fullscreen), minimum size, saved placement | — |
| Playback | `PlayerEngineFactory` selects `MpvPlayerEngine` (libmpv via media_kit); `media_kit_libs_windows_video` bundles libmpv | libmpv engine, headers, subtitles |
| Providers | `quickjs_c_bridge.dll` with QuickJS's memory-limit and interrupt exports (`third_party/flutter_js/REELISH_PATCH.md`) | Provider bridge, sandbox, network policy |
| Updates | `Reelish-Windows-x64.zip` asset; verified, then shown in Explorer | Release check, version comparison, verification |

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
5. packages `Reelish-Windows-x64.zip` and its `.sha256`, and encrypts the
   debug symbols;
6. waits for `release.yml` to publish the release, then attaches the two
   Windows assets.

It never creates or edits a release or the APK. If the Android release
fails, nothing is published. Run it from the Actions tab
(`workflow_dispatch`) to build the ZIP as an artifact without publishing.

**Not done yet:** code signing (needs a certificate), an installer or MSIX,
and ARM64 builds (the QuickJS bridge is x64-only).
