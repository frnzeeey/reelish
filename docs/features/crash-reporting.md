# Crash reporting

Opt-in crash reports through Firebase Crashlytics on Android phones, Android
TV and Google TV. Windows has no Crashlytics support, so it keeps a small log
on the computer instead.

## How it works

| Piece | Where |
|---|---|
| Error handlers, consent, limits | `lib/src/diagnostics/crash_reporter.dart` |
| What may be reported | `lib/src/diagnostics/error_scrubber.dart` |
| Which playback failures become reports | `lib/src/diagnostics/playback_diagnostics.dart` |
| Windows log | `lib/src/diagnostics/local_error_log.dart`, opened from Help & Support › Open error log |
| One-time question | `lib/src/widgets/crash_report_consent_dialog.dart`, asked after the usage statistics question |
| Settings switch | "Share crash reports" under Settings › General, shown only where reports can be sent |
| Native side | `CrashReportChannel.kt` (method channel `onfeed/crash_reports`), `FirebaseStarter.kt` |

- **Native SDK, not FlutterFire**, for the reason in
  [analytics.md](analytics.md): `firebase_crashlytics` needs `firebase_core`,
  which would build the Firebase C++ SDK into Windows, and Firebase would
  start at launch. `firebase-crashlytics` comes from the same Firebase BoM as
  Analytics.
- **No Crashlytics Gradle plugin.** It refuses to load without the
  `google-services` plugin, which this project leaves out. `build.gradle.kts`
  generates the `com.google.firebase.crashlytics.mapping_file_id` resource the
  plugin would have, without which the SDK will not start. The cost is that R8
  mappings are not uploaded automatically: see
  [Readable stack traces](#readable-stack-traces).
- **Off until yes, and separate from usage statistics.** The manifest keeps
  collection off. Firebase starts for crash reports only after the viewer
  agrees. Crash details stored while collection was off are deleted on
  agreeing, not sent, and turning it off deletes what has not been sent.
- **Debug builds send nothing**, unless built with the test flag below.

## What gets reported

| Severity | Meaning | What happens |
|---|---|---|
| `fatal` | Nothing caught it: `FlutterError.onError` (not an image load) or `PlatformDispatcher.onError` | Report |
| `nonFatal` | Caught, but should not happen: `CrashReporter.recordError`, app-side playback failures | Report |
| `handled` | Expected: network, timeouts, provider-side playback failures, Watch Party connection failures | A note in the log of later reports; never a report |
| Process crash, ANR | The Android SDK sees these directly | Crash report |

The handlers report, then call whatever handler was there before and return
`false`, so errors behave exactly as they would without them. Crashlytics has
no public API to mark a Dart error as a crash, and a Dart error does not end
the process, so those appear under **Non-fatals**. Filter on the
`error_severity` key to find the uncaught ones.

Playback failures are sorted by `PlaybackDiagnostics.sideOf`:

| Side | Kinds | Result |
|---|---|---|
| app | `engine`, `rendering`, `decoder`, `unknown` | One non-fatal per kind, engine and moment |
| provider | `preparation`, `http`, `manifest`, `format`, `source` | Note |
| network | `network`, `timeout` | Note |
| none | `cancelled` | Nothing |

**Limits:** each distinct error is sent once per run, and at most 16 per run.

**Custom keys:** `error_severity`, `error_category`, `feature` (the current
page), `playback_state`, `playback_engine`, `party_state`, `party_role`, and
`com.crashlytics.flutter.build-id.0` on release Dart errors. `setContext` drops
anything that is not a short word, so a title or room code cannot get in.

**Never sent:** account or Trakt ids and names, tokens, search text, provider
names, stream URLs or headers, Watch Party codes, file paths. Only programming
errors (`StateError`, `TypeError`, `FlutterError` and similar) keep a message,
which is scrubbed; network, parsing, platform and plain exceptions quote remote
data, so they report their type alone.

Crashlytics also records device model, OS and app versions, free memory and
disk, and an installation id. When a viewer shares usage statistics too,
Analytics events appear in the report's Logs tab, including `select_content`
with its TMDB id. Reports are kept for 90 days.

Native crashes (libmpv, the torrent engine, QuickJS) are not captured.
`firebase-crashlytics-ndk` was left out because it installs signal handlers in
a process that runs the Go runtime, which handles signals itself; that needs
testing against torrent playback before it is added.

## Setting up Firebase (once)

Uses the same `REELISH_FIREBASE_*` values as [analytics](analytics.md#setting-up-firebase-once).
Open **Crashlytics** in the Firebase console and enable it for the Android
app. No billing is involved: Crashlytics is no-cost on the Spark plan.

## Testing

Debug builds send nothing, and release builds must never have the test
triggers. To test, build with both flags:

```sh
REELISH_CRASH_TEST=true flutter run \
  --dart-define=REELISH_CRASH_TEST=true --dart-define=REELISH_API_URL=https://...
adb shell setprop log.tag.FirebaseCrashlytics DEBUG
```

Answer **Share**, then use the four **Test:** rows at the end of Settings ›
General. Non-fatals are sent on the next launch; after the native crash, open
the app again. Reports reach the console within a few minutes.

The release workflow never sets either flag. Without the Gradle flag the native
crash does nothing, and without the Dart flag the rows are not compiled.

## Readable stack traces

Release builds are obfuscated, so reports show addresses. Each Dart report's
Logs tab holds the raw trace, which works with the existing private symbols
([releasing.md](../releasing.md#debug-symbols)):

```sh
flutter symbolize -i trace.txt -d symbols/app.android-arm64.symbols
```

To have the console do it, upload the symbols. This shares them, and the R8
mapping, with Google, which is a decision about
[code protection](../code_protection.md), so it is not automated:

```sh
firebase crashlytics:symbols:upload --app=<App ID> symbols/
```

## Cost

Crashlytics is no-cost on the Spark plan, with no quota listed. Nothing here
needs Blaze, Functions or another server.

## Release checklist

- Crashlytics enabled in the console.
- One build checked: nothing before **Share**, a report after, and nothing
  after switching off.
- Play Console Data safety, if published there: crash logs and diagnostics,
  collected only with consent.
