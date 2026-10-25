# Getting started

## Requirements

| Tool | Version | Notes |
|---|---|---|
| Flutter | 3.44.8 stable (what CI uses; `FLUTTER_VERSION` in the workflows) | Dart SDK `^3.12.2` per [`pubspec.yaml`](../../pubspec.yaml) |
| Android SDK and JDK 17 | — | For Android builds; CI uses Temurin 17 |
| Visual Studio with "Desktop development with C++" | — | For Windows builds; see [`docs/windows.md`](../windows.md#build-from-source) |
| A TMDB API key | — | Free from themoviedb.org |

## First run

1. Create the git-ignored file `lib/tmdb_config.local.dart`:

   ```dart
   const tmdbApiKey = 'YOUR_TMDB_API_KEY';
   ```

   Never commit, print or share this file. The key ships inside client
   builds, so restrict it in your TMDB account.
2. Fetch packages and run:

   ```sh
   flutter pub get
   flutter run                 # a connected device, emulator or Windows
   flutter run -d windows      # Windows
   ```

3. Try the TV interface on any device:

   ```sh
   flutter run --dart-define=REELISH_FORCE_TV=true
   ```

   Arrow keys and Enter act as the remote. A TV emulator setup is described
   in [`docs/android_tv.md`](../android_tv.md#testing).

On first launch, accept the privacy policy and terms, then install a
provider repository from **Plugins** to play anything; browsing works
without one.

## Builds

```sh
flutter build apk --profile          # Android, for measuring
flutter build apk --release          # Android; unsigned without the release keystore
flutter build windows --release      # Windows
```

Release builds for users are made only by CI from a version tag, signed,
obfuscated and verified: [`docs/releasing.md`](../releasing.md). Never
upload a hand-built APK or installer.

## Day-to-day commands

| Task | Command |
|---|---|
| Format touched files | `dart format <files>` (not the whole repository) |
| Analyse | `flutter analyze lib test integration_test test_driver` |
| All unit and widget tests | `flutter test` |
| One test file | `flutter test test/<name>_test.dart` |
| An integration test | `flutter test integration_test/<name>_test.dart -d <device>` |
| Regenerate the code reference | `dart run tool/docs/docs_tool.dart generate` |
| Check the docs | `dart run tool/docs/docs_tool.dart check` |
| Update the plugin catalog | `dart run tool/generate_plugin_catalog.dart` |

More in the [testing guide](testing-guide.md) and the
[debugging guide](debugging-guide.md).
