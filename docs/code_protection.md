# Code protection

What Reelish's release builds protect against casual reverse engineering, how
it is verified, and what stays visible. Obfuscation raises the cost of reading
the app; it does not make the app impossible to reverse engineer, and it is
not a substitute for keeping secrets off the client.

## What is protected

| Layer | Mechanism | Where |
|---|---|---|
| Dart code (all of Reelish's own logic and UI) | `flutter build apk --release --obfuscate --split-debug-info=…`: classes, functions, fields and library paths in the AOT snapshot (`libapp.so`) are renamed | `.github/workflows/release.yml`, "Clean build" |
| Android code (Kotlin/Java, plugins, AndroidX) | R8 shrinking and obfuscation, which the Flutter Gradle plugin enables for every release build. In v1.10.1, 1,570 of 2,037 classes ship with short renamed names; Kotlin's standard library is renamed or removed | Flutter Gradle plugin defaults (no app-level keep rules are needed) |
| Debug symbols and R8 mapping | Kept out of the APK and the workspace, encrypted (AES-256, PBKDF2) and uploaded as a private workflow artifact | Workflow, "Package/Upload encrypted debug symbols"; [releasing.md](releasing.md#debug-symbols) |
| Release logs | App logging is `kDebugMode`-gated. The vendored QuickJS runtime no longer prints JavaScript exceptions or channel errors in release builds | `third_party/flutter_js/lib/quickjs/quickjs_runtime2.dart` |
| APK integrity | Every release is built by CI from the tagged commit, checksummed (SHA-256 published with the APK), and signed with one key. The in-app updater only installs an APK whose package, version and signing certificate match the installed app | Workflow, "Verify APK"; `lib/src/services/github_update_service.dart`, `ReelishActivity.kt` |

Measured on the v1.10.1 sources: the obfuscated release APK is 2.9 MB smaller
(83.8 → 80.9 MB). The only file that changes is `libapp.so` (8.3 → 7.0 MB
for arm64). `classes.dex`, the R8 mapping and every native library
(libflutter, libmpv, the QuickJS runtime, the torrent streamer) are
byte-identical with and without obfuscation, so playback engines and native
bindings are exactly the same code.

## How the build proves it

The release workflow fails unless, in both `arm64-v8a` and `armeabi-v7a`
`libapp.so`:

- `ProviderFetchBridge`, `TmdbService`, `PlaybackCoordinator` and
  `package:onfeed/src` are absent (an unobfuscated build contains them all);
- `OnfeedFetch`, `OnfeedTimer` and `getStreams` are present (the provider
  bridge contract);
- debug symbols exist for both ABIs.

It also runs `flutter analyze` and the full test suite (400 tests, including
the QuickJS provider sandbox on Linux) before building.

## Compatibility rules

Dart obfuscation renames identifiers, never string literals. Reelish's
external contracts are all strings, so they are unaffected:

- **Provider plugins (QuickJS):** the JavaScript bridge uses `sendMessage`
  channels named `OnfeedFetch`, `OnfeedCancel` and `OnfeedTimer` with JSON
  payloads, and providers export `getStreams`. Provider scripts, manifests and
  JSON keys are never modified. Verified by running
  `integration_test/provider_runtime_test.dart` as an obfuscated build on a
  32-bit Android TV emulator (all tests pass).
- **Method channels** (`onfeed/player`, `onfeed/device`, `onfeed/app_update`)
  and **FFI symbols** (QuickJS, the torrent streamer) are looked up by string.
- **Enums:** `.name` returns the declared name in obfuscated builds.

Things that do change, and must not be relied on in app logic:

- `runtimeType.toString()` and `Type` names (obfuscated; Reelish only uses
  them in log text).
- `flutter_js`'s `_DartFunction.invoke` matches `thisVal` in a function's
  type string; any future Dart callback that needs `thisVal` must be tested
  in an obfuscated build (see `third_party/flutter_js/REELISH_PATCH.md`).

## What remains visible in the APK

Anyone with the APK can still see:

- All string literals in `libapp.so`: URLs, user-facing text, JSON keys,
  channel names, error messages, and the **TMDB API key**.
- Assets (`cheerio_bundle.js`, `plugins.json`, fonts, images) and resources.
- The Android manifest, permissions and component names.
- Class names R8 must keep (entry points, `ReelishActivity` (the `.MainActivity` launcher alias targets it), Media3 factories
  loaded by reflection, JNI classes) and native library exports.
- The app's behavior: network traffic can be observed with a proxy, and the
  AOT code can still be disassembled.

**The TMDB API key** is a client key and can't be hidden in any mobile app.
TMDB keys are free and rate-limited per key. If abuse becomes a problem, the
fix is a small proxy that holds the key server-side, not more obfuscation.

## Deliberately not added

- **Runtime signature or tamper checks.** A repackaged APK is re-signed by
  whoever modified it, and the same person can delete a client-side check.
  Such checks protect little, add startup work, and risk false positives on
  legitimate TVs, emulators and custom ROMs. Distribution integrity comes from
  CI-only releases, published checksums and the updater's signer check.
- **Play Integrity or root/emulator detection.** Reelish is distributed
  outside Google Play and supports emulators, Android TV and Google TV.
- **String or asset encryption.** It needs a runtime decryption key in the
  same APK, so it hides nothing from a determined reader, and costs startup
  time.
- **Paid obfuscators or custom R8 rules.** R8's defaults already obfuscate
  the Android code with no compatibility issues; extra rules would add risk
  for no measurable gain.
