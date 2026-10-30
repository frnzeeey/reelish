# Android (phones and tablets)

The default interface. The same APK also runs on Android TV and Google TV,
which switch to the [TV interface](android-tv.md) at runtime.

## Where the code is

| Concern | Location |
|---|---|
| Home tabs and dock | [`home_screen.dart`](../../lib/src/screens/home_screen.dart) (`_home`, the tab pages), [`soft_glass_dock.dart`](../../lib/src/widgets/soft_glass_dock.dart) |
| Details | [`media_details_screen.dart`](../../lib/src/screens/media_details_screen.dart) |
| Library | [`library_screen.dart`](../../lib/src/screens/library_screen.dart) |
| Plugins, Plugin Library | [`plugins_screen.dart`](../../lib/src/screens/plugins_screen.dart), [`plugin_library_screen.dart`](../../lib/src/screens/plugin_library_screen.dart), [`plugin_details_screen.dart`](../../lib/src/screens/plugin_details_screen.dart) |
| Settings | [`playback_settings_screen.dart`](../../lib/src/screens/playback_settings_screen.dart), [`lib/src/widgets/settings/`](../../lib/src/widgets/settings) |
| Cards and glass | [`media_card.dart`](../../lib/src/widgets/media_card.dart), [`liquid_glass.dart`](../../lib/src/widgets/liquid_glass.dart), [`glass_box.dart`](../../lib/src/widgets/glass_box.dart) |
| Player (shared) | [`lib/src/widgets/player/`](../../lib/src/widgets/player); touch in [`gesture_touch_layer.dart`](../../lib/src/widgets/player/gesture_touch_layer.dart) |
| Updates | [`github_update_service.dart`](../../lib/src/services/github_update_service.dart), [`app_update_flow.dart`](../../lib/src/widgets/app_update_flow.dart), [`update_dialog.dart`](../../lib/src/widgets/update_dialog.dart) |
| Native | [`ReelishActivity.kt`](../../android/app/src/main/kotlin/com/example/onfeed/ReelishActivity.kt): `onfeed/device`, `onfeed/player`, `onfeed/app_update` |

## Interface

- Bottom dock (`SoftGlassDock`); tablets (shortest side ≥ 600 dp) get a
  compact centred dock. Content keeps clear of it with
  `SettingsMetrics.dockClearance`.
- Home: brand header, category chips, a rotating Spotlight carousel (6 s,
  paused while scrolled, searching or with reduced motion), and catalog
  rows that load as they near the screen.
- Touch targets stay at 48 dp or more.

## Playback

Media3 first, libmpv as fallback, with non-HTTPS URLs sent straight to
libmpv; see [player engines](../playback/platform-player-engines.md).
Phone-only player features: touch gestures (a tap toggles the controls;
double-tap seek, swipes for brightness and volume, and long-press speed
follow the gesture settings), a touch lock, picture-in-picture (`enterPip`), keep-screen-on, and
landscape for wide video once per session. Torrents work in 64-bit
processes when P2P streaming is on.

## Build and configuration

- Gradle: [`android/app/build.gradle.kts`](../../android/app/build.gradle.kts).
  Application id `io.github.frnzeeey.reelish`; namespace
  `com.example.onfeed` (the Kotlin package keeps the original name).
  SDK levels come from Flutter's defaults.
- Release APKs contain ARM code only (`lib/x86_64/**` is excluded at
  packaging); debug builds keep x86_64 for emulators. The release build
  is also copied to `build/app/outputs/flutter-apk/reelish.apk`, the asset
  name the in-app updater looks for.
- Manifest: [`AndroidManifest.xml`](../../android/app/src/main/AndroidManifest.xml)
  declares `INTERNET`, `WAKE_LOCK` and `REQUEST_INSTALL_PACKAGES`, removes
  the foreground-service permissions a dependency adds, and declares
  `leanback` and `touchscreen` as not required so the same APK installs on
  TVs.
- Release signing, obfuscation and debug symbols:
  [`docs/releasing.md`](../releasing.md) and
  [`docs/code_protection.md`](../code_protection.md).

## Distribution and updates

Releases are published by `.github/workflows/release.yml` as `reelish.apk`
on GitHub Releases. In the app, `GitHubUpdateService` checks the latest
release (throttled across launches), downloads the APK, verifies its
SHA-256 digest and that its signature matches the installed app
(`inspectApk`), and hands it to Android's package installer. The viewer
confirms the install; the first time, Android asks to allow installs from
Reelish.

## Known limitations

See [known issues](../maintenance/known-issues.md). Platform-specific:
torrents need a 64-bit process; embedded subtitle tracks are only available
when libmpv plays the stream.
