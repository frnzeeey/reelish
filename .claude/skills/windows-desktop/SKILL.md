---
name: windows-desktop
description: Work on Reelish's Windows build — the C++ runner, window and fullscreen, keyboard shortcuts, game controllers, libmpv playback setup, the QuickJS DLL, the Inno Setup installer and the in-app updater. Use for Windows-only bugs, desktop input, packaging or update issues, and for Windows builds and integration tests.
---

# Windows desktop

## Purpose
Change or debug Windows-specific behaviour without affecting Android, and
prove it on a real Windows build. Outcome: the Windows path fixed, Android
untouched, and the release build plus Windows integration tests passing.

## Activation
- Anything under `windows/`, `lib/src/platform/` (desktop parts),
  `lib/src/desktop/desktop_update_*.dart`, `windows_update_controller.dart`,
  `windows_installation.dart`.
- Window size/placement, fullscreen, Esc/Backspace, F11, gamepad,
  installer "files in use", update download/verification, libmpv or
  QuickJS DLL loading.
- Pure layout/visual work on desktop pages belongs to `ui-refinement`.

## Codebase context
- Runner (`windows/runner/`): `main.cpp` (`ReelishAppMutex` single
  instance, used by the installer), `flutter_window.cpp` (`reelish/window`
  channel: fullscreen, minimum size, saved `WindowPlacement`),
  `gamepad_channel.cpp` (`reelish/gamepad`), `app_update_channel.cpp`
  (`reelish/app_update`: installer inspection, Authenticode check, launch).
- Dart: `DesktopWindow` and `DesktopShortcuts`
  (`lib/src/platform/desktop_window.dart`: F11, Esc leaves fullscreen then
  goes back, Backspace back when not typing, arrows move to the first
  control), `DesktopGamepad` (`desktop_gamepad.dart`).
- Playback: `MpvPlayerEngine` only; libmpv from
  `media_kit_libs_windows_video`; vendored bridge patch in
  `packages/video_player_media_kit` (frame request after creating the
  `VideoController`).
- Providers: `quickjs_c_bridge.dll` with Reelish exports
  (`third_party/flutter_js/REELISH_PATCH.md`,
  `tool/build_quickjs_bridge_windows.ps1`).
- Installer: `windows/installer/reelish.iss` (per-user). Updates:
  `WindowsUpdateController`, desktop update dialogs/section; portable ZIP
  copies use a verified-ZIP handoff.
- Reference: `docs/windows.md` (build, tests, differences),
  `docs/WINDOWS_READINESS_AUDIT.md` (history).

## Workflow
1. Reproduce on Windows (`flutter run -d windows`) and note window state,
   scaling and input device.
2. Find whether the cause is Dart (`lib/src/platform`, `lib/src/desktop`)
   or native (`windows/runner`); channel names connect the two.
3. Gate Dart changes on `DeviceCapabilities.isDesktop` /
   `isDesktopPlatform`; keep Android's code path byte-for-byte when
   possible.
4. For runner or installer changes, rebuild the release, run the
   installer over an existing install, and relaunch.
5. Add tests where Dart owns the logic (`windows_update_test`,
   `desktop_gamepad_test`, `desktop_ui_test`).

## Safety constraints
- Keep Authenticode/installer verification and the SHA-256 checks in the
  update flow; never launch an unverified installer.
- Keep the app mutex name and the installer's "close running app" logic in
  step (see the files-in-use fix in git history).
- Don't add Windows packages that ship Android code; the libmpv Windows
  package was verified to leave the APK unchanged.
- `usesTvLayout` is true on Windows: TV-hardware behaviour must use `isTv`.

## Platform considerations
Windows-only: no torrents, PiP, rotation lock, touch lock or brightness
gestures. Shared with Android: catalog data, ViewModels, provider bridge
and network policy, player chrome (with desktop keys and mouse paths).

## Validation
- `flutter build windows --release`.
- Integration on Windows (one at a time; the playback tests stream public
  test media such as Mux HLS and Big Buck Bunny, so they need the network):
  `flutter test integration_test/windows_playback_test.dart -d windows`,
  `windows_player_ui_test.dart`, `provider_runtime_test.dart`,
  `windows_update_channel_test.dart`, `windows_soak_test.dart` (long).
- Unit: `windows_update_test`, `desktop_gamepad_test`,
  `quickjs_windows_limits_test`, `desktop_*_test`.
- Android unaffected: `flutter build apk --profile`.
- Then `regression-check`.

## Completion criteria
Windows release build succeeds; the relevant integration tests pass on
Windows; Android builds; changed runner/installer behaviour checked by an
actual install or relaunch, or listed as unverified.

## Reporting
Per CLAUDE.md § Reporting, plus: Windows version and scaling tested,
whether an installer/update run was done, and native files touched.
