# Reelish Windows readiness audit

Date: 2026-10-16. Commit audited: `141b59b` (v1.10.2), plus the uncommitted
tablet-dock change.

**Scope.** This was a read-only audit: no source files, configuration or
workflows were changed. Two checks were run:

- `flutter build windows --release`, which writes only to the gitignored
  `build/` and `windows/flutter/ephemeral/` folders. `git status` was
  identical before and after.
- Two short launches of the built `onfeed.exe`. They created
  `%APPDATA%\com.example\onfeed`.

**Evidence labels.**

- **Verified:** observed in a build or run.
- **Confirmed (code):** follows directly from the code and binaries cited,
  but wasn't executed.
- **Unverified:** needs testing.

## 1. Executive summary

**Verdict: PARTIALLY READY.** The app compiles and runs on Windows, and the
UI, TMDB catalog and storage work as they are. Three things a streaming app
needs do not work yet:

- video playback;
- provider plugins;
- updates.

Each has a contained fix that doesn't touch Android code paths.

| | Status |
|---|---|
| Compiles for Windows x64 | **Verified**: `onfeed.exe` built in 58 s, 68 MB folder |
| Launches, renders, loads the TMDB catalog | **Verified**: home screen with the spotlight, rows and dock |
| Video playback | **Does not work.** Confirmed (code): no Windows player is registered and libmpv isn't bundled |
| Provider plugins (QuickJS) | **Does not work.** Confirmed (code and DLL export table): the memory-limit lookup throws, so every provider run fails |
| Torrent / P2P | Off on Windows by design (Android-only, gated) |
| In-app updates | Off on Windows (Android-only flow) |

Architecturally the codebase is well suited to Windows:

- Platform code is already behind `defaultTargetPlatform` checks.
- Storage uses `path_provider`.
- Networking is pure `dart:io`.
- The player layer already has a pluggable engine abstraction
  (`PlayerEngine`).

## 2. Compatibility matrix

| Component | Windows status | Risk | Required action |
|---|---|---|---|
| Flutter application | **Verified**: builds and runs | Low | Fix runner branding (name, company, icon) |
| Video playback | **Broken.** Confirmed (code) | High | Use the existing `MpvPlayerEngine` on Windows and add `media_kit_libs_windows_video` (P0-1) |
| QuickJS runtime | **Broken.** Confirmed (code and binary) | High | A Windows bridge DLL exporting the memory limit and interrupt handler (P0-2) |
| Nuvio providers | Blocked by QuickJS; otherwise portable | Medium | None beyond P0-2. The bridge is pure Dart and `dart:io` |
| TMDB integration | **Verified**: catalog loads | Low | None |
| Local storage | Works. Path depends on runner metadata | Medium | Set CompanyName and ProductName **before** the first Windows release (P0-3) |
| Navigation and UI | **Verified** rendering; mouse works | Low | Keyboard shortcuts, hide mobile-only controls (P1/P2) |
| Subtitles | External SRT/VTT drawn by Flutter (portable); embedded tracks need libmpv | Medium | Comes with P0-1. Unverified until playback works |
| Networking | Portable `dart:io` with a pinned client | Low | Note: system proxies are ignored by design (same as Android) |
| Update system | Android-only (APK installer channel) | Medium | A Windows release asset and update flow (P3) |
| Build pipeline | Android-only (`ubuntu-latest`, APK) | Medium | A separate `windows-latest` job or workflow (P3) |

### Dependencies

| Package | Windows | Notes |
|---|---|---|
| `flutter`, `http`, `crypto`, `path_provider`, `shared_preferences`, `package_info_plus`, `url_launcher`, `material_symbols_icons` | Fully compatible | `url_launcher_windows` is in the plugin build; the rest are pure Dart or have Windows implementations |
| `video_player` | **Needs a platform implementation** | The plugin has no official Windows implementation; Reelish must register `video_player_media_kit` |
| `video_player_android` | Android-only, harmless | Not built for Windows |
| `video_player_media_kit` (vendored) | Compatible with configuration | Has a `windows:` flag in `ensureInitialized`, and passes HTTP headers to libmpv |
| `media_kit`, `media_kit_video` | Compatible with configuration | `media_kit_video_plugin.dll` is built (verified), but **libmpv is missing** |
| `media_kit_libs_android_video` | Android-only | The Windows equivalent, `media_kit_libs_windows_video`, isn't a dependency. The build warns: `media_kit: WARNING: package:media_kit_libs_*** not found` |
| `flutter_js` (vendored) | **Requires a platform implementation** | Ships a prebuilt x64 `quickjs_c_bridge.dll` that lacks three exports Reelish needs (see P0-2) |
| `flutter_go_torrent_streamer` (vendored) | Unsupported | Android `jniLibs` only; already gated off |
| `jni` (transitive) | Built on Windows | FFI plugin; built cleanly |

## 3. Critical blockers

### P0-1. No video player on Windows (confirmed, code)

- **Where:**
  - `lib/src/services/player_engine.dart:207-211`:
    `PlayerEngineFactory.forCurrentPlatform()` returns
    `FlutterPlatformPlayerEngine` everywhere except Android. It uses
    `video_player`'s default backend, which has no Windows implementation.
  - `:226-230`: `alternateFor(flutterPlatform)` is `null`, so there's no
    fallback.
  - `:67`: libmpv is registered only in `MpvPlayerEngine.activate()`, with
    `ensureInitialized(android: true)`, which Windows never reaches.
  - `pubspec.yaml:44`: only `media_kit_libs_android_video`. The build
    output has no `libmpv-2.dll` (verified listing).
- **Impact:** opening any stream fails when the player initializes
  (`video_player` would throw an unimplemented or missing-plugin error).
- **Fix:**
  1. Add `media_kit_libs_windows_video`. It's federated and Windows-only, so
     it adds nothing to the APK.
  2. In `forCurrentPlatform()`, return `MpvPlayerEngine` on Windows.
  3. Call `ensureInitialized(android: true, windows: true)`.
- **Complexity:** low (a few lines, plus the dependency).
- **Android risk:** low. The change sits behind a `TargetPlatform.windows`
  check, and Android keeps Media3 first with the libmpv fallback.
  `pubspec.lock` changes, so run the full suite and an Android playback
  check.

### P0-2. Provider plugins fail on Windows (confirmed, code and binary)

- **Where:**
  - `third_party/flutter_js/windows/shared/quickjs_c_bridge.dll`, per
    `dumpbin /exports`: 65 exports, x64 only. It exports none of
    `jsSetMemoryLimit`, `JS_SetMemoryLimit` or `JS_SetInterruptHandler`.
  - `third_party/flutter_js/lib/quickjs/ffi.dart:233-256`: the memory-limit
    setter tries `jsSetMemoryLimit`, then `JS_SetMemoryLimit`. The second
    lookup isn't caught, so it throws `ArgumentError`.
  - `lib/src/services/provider_runner.dart:24`: every app request passes the
    default `memoryLimit` of 64 MiB, and `quickjs_runtime2.dart:140-141`
    then calls the setter.
  - The unit tests pass `memoryLimit: null`
    (`test/provider_runner_test.dart:24`), which is why they pass on
    Windows.
- **Impact:**
  - Every provider run fails, so no streams are found.
  - If the throw were simply suppressed, providers would run with **no
    heap cap and no interrupt deadline**. The interrupt lookup already
    returns null on this DLL (`ffi.dart` around line 262, documented in
    `REELISH_PATCH.md`). A provider stuck in a synchronous loop would trip
    the 45 s caller timeout (`provider_runner.dart:87`), but its isolate
    would keep using a CPU core until the app exits.
- **Fix:** build a Windows `quickjs_c_bridge.dll` from upstream
  `quickjs-c-bridge` source that also exports QuickJS's public
  `JS_SetMemoryLimit` and `JS_SetInterruptHandler`.
  - Commit it with its source revision and a build script, as was done for
    the torrent streamer.
  - Don't ship a version that silently skips the limits: that weakens the
    sandbox on Windows only.
  - Build ARM64 the same way if ARM64 is wanted.
- **Complexity:** medium (a native build plus provenance).
- **Android risk:** none if only the Windows DLL changes. The shared
  `ffi.dart` needs no change once both symbols exist.

### P0-3. Template runner identity sets the data folder (confirmed, code and run)

- **Where:**
  - `windows/runner/Runner.rc:92-98`: `CompanyName "com.example"`,
    `ProductName "onfeed"`, `OriginalFilename "onfeed.exe"`.
  - `windows/runner/main.cpp:30`: window title `onfeed`.
  - `windows/CMakeLists.txt`: `BINARY_NAME "onfeed"`.
  - The default Flutter icon.
- **Impact:** `path_provider_windows` derives the app-data folder from these
  values. The verified run created `%APPDATA%\com.example\onfeed`. If this
  changes after users install, their settings, history and plugins appear
  to vanish unless they're migrated.
- **Fix:** set the company, product, executable name, title and icon to
  Reelish **before** the first Windows release.
- **Complexity:** low.
- **Android risk:** none.

## 4. Recommended Windows architecture

Keep one codebase. Windows differences sit at the same seams Android TV
already uses.

| Shared (no change) | Platform-specific (Windows adds or swaps) |
|---|---|
| UI, theme, liquid glass, navigation, dock (tablet metrics already apply to desktop windows of 600 dp or more) | Player engine choice in `PlayerEngineFactory`: Media3 then libmpv on Android, libmpv only on Windows |
| TMDB service, cache and limiter | libmpv binaries (`media_kit_libs_windows_video`) |
| Provider bridge, scheduler, manifests and SHA-256 pinning (Dart) | The QuickJS bridge DLL (rebuilt with the limit exports) |
| `NetworkDestinationValidator` and the subtitle loader | Window chrome and fullscreen (window API or a small runner method channel) |
| Storage (`path_provider`, `shared_preferences`) | The update flow (Windows asset and installer or ZIP) |
| External subtitle rendering (Flutter overlay) | Keyboard shortcuts in the player (reuse the TV key handler) |

Rules that protect Android:

1. Every Windows branch keys on `TargetPlatform.windows`, never on "not
   Android". Android TV and phone paths keep their existing conditions.
2. Don't touch Android-only method channels (`onfeed/player`,
   `onfeed/device`, `onfeed/app_update`). Guard their call sites on
   desktop instead of adding desktop handlers to the same channel.
3. Windows-only dependencies must be federated, with no Android
   implementation, so the APK contents don't change. Verify this with the
   byte-for-byte APK comparison used for SEC-03.

## 5. Implementation roadmap

**P0. Before a Windows build can stream**

1. Register libmpv on Windows (P0-1).
2. Rebuild the QuickJS bridge DLL with the memory-limit and interrupt
   exports (P0-2), then run `integration_test/provider_runtime_test.dart`
   as a Windows desktop test.
3. Set the runner identity and icon (P0-3).

**P1. Reliable desktop function**

- **Guard Android-only calls on desktop:**
  - `custom_video_player.dart:2489-2491`: `resetBrightness` is called
    without a platform check or error handler, so desktop logs an uncaught
    `MissingPluginException` each time the player closes.
  - Hide the picture-in-picture button (`:2878`) and the rotate button
    (`onRotate`) on desktop, where they do nothing.
- **Fullscreen:** `SystemChrome` immersive mode and orientation calls
  (`:325`, `:1482`, `:2492-2494`) do nothing on Windows. Add real window
  fullscreen with Esc to exit.
- **Playback matrix on Windows:** HLS, DASH, MP4 and MKV; streams that need
  `User-Agent` or `Referer` headers; redirects; audio and subtitle track
  switching; seek, speed and aspect ratio; network drops. All are
  unverified until P0-1. libmpv's DASH support depends on its FFmpeg build.
- **Subtitles:** confirm external SRT/VTT timing and embedded tracks under
  libmpv.

**P2. Desktop experience**

- **Player keyboard shortcuts:** `_onRemoteKey` (`custom_video_player.dart`,
  around line 1171) is attached only when `_tv` is true (`:2649-2656`). Add
  Space, arrows, F and Esc on desktop by attaching the same handler.
- **Mouse:** hover states (`InkWell` already hovers), and showing the
  player controls when the mouse moves.
- **Window:** minimum window size, remembering size and position, and
  checking layouts at common window sizes and DPI scales. The dock already
  switches to tablet metrics at a shortest side of 600 dp.

**P3. Distribution**

- **CI:** a separate `windows-latest` job or workflow. The current release
  job is `ubuntu-latest` (`release.yml:29`) and builds only the APK. Keep it
  isolated so an APK release never depends on Windows.
- **Artifacts:** a portable ZIP first. Then an installer (Inno Setup) or
  MSIX.
- **Code signing:** without it, SmartScreen warns about unsigned
  executables.
- **Updates:** a `reelish-windows.zip` asset and a Windows update check. The
  current flow is Android-only (`app_update_flow.dart:51`).
- **Obfuscation:** `flutter build windows --obfuscate --split-debug-info`
  works the same way as on Android.

## 6. Final recommendation

1. **Can Reelish compile for Windows?** Yes. Verified: `flutter build
   windows --release` succeeds.
2. **Can its playback architecture work on Windows?** Yes. The libmpv engine
   and media_kit bridge already support Windows. They just aren't selected
   or bundled (P0-1).
3. **Can Nuvio plugins run on Windows?** Not with the current DLL; the
   memory-limit lookup throws. The provider bridge is portable Dart, so a
   bridge DLL with the right exports fixes it (P0-2).
4. **Which dependencies are incompatible or unverified?**
   - Missing: `media_kit_libs_windows_video`.
   - Insufficient: `flutter_js`'s Windows DLL.
   - Unsupported, already gated: `flutter_go_torrent_streamer`.
   - Unverified on Windows: libmpv behavior for each stream type.
5. **Does Windows need a separate player?** No. It uses the existing
   `MpvPlayerEngine` as its only engine.
6. **Can Windows support be added without changing Android playback?** Yes.
   The changes are behind `TargetPlatform.windows`, and the dependency is
   Windows-only.
7. **Minimum path to a working Windows app:** P0-1, P0-2 and P0-3, plus the
   P1 call-site guards. That gives browsing, providers and libmpv playback
   in a portable ZIP.
8. **Highest-risk changes:**
   - The QuickJS DLL rebuild: native code, sandbox limits, provenance.
   - Any edit to the shared `ffi.dart` or `PlayerEngineFactory`, since
     Android shares them.
9. **Is the architecture suitable for maintaining both?** Yes. The engine
   abstraction, platform-gated services and `path_provider` storage already
   separate the platforms cleanly.
10. **Implement now, or fix blockers first?** Fix P0-2 (the QuickJS DLL)
    first. It's the only blocker needing native work, and the only one with
    a security angle. P0-1 and P0-3 are small and can follow in the same
    change. Then do P1 before any public Windows build.

## Not verified

- Video playback, subtitles and providers on Windows (blocked as above).
- ARM64 Windows: the bridge DLL is x64 only.
- Behaviour behind Windows proxies or with Defender Firewall prompts.
  Outbound HTTPS from a desktop app normally needs no firewall rule.
- Multi-monitor setups, DPI scaling beyond the default, and trackpad
  gestures.
