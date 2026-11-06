# Usage statistics (Firebase Analytics)

Opt-in product analytics for Android phones, Android TV and Google TV,
through Google Analytics for Firebase. Windows sends nothing.

## How it works

| Piece | Where |
|---|---|
| Event catalog and parameter rules | `lib/src/analytics/analytics_events.dart` |
| Consent, the channel, deduplication | `lib/src/analytics/analytics_service.dart` |
| One-time question | `lib/src/widgets/analytics_consent_dialog.dart`, asked from Home after its first frame, before the update check |
| Settings switch | "Share usage statistics" under Settings › General (`playback_settings_screen.dart`), shown only where analytics can run |
| Native side | `android/app/src/main/kotlin/com/example/onfeed/AnalyticsChannel.kt` (method channel `onfeed/analytics`) |
| Build configuration | `REELISH_FIREBASE_*` in `android/app/build.gradle.kts`; manifest switches in `AndroidManifest.xml` |

- **Native SDK, not FlutterFire.** `firebase_core` would also build for
  Windows (pulling the Firebase C++ SDK into every Windows build) although
  Firebase Analytics does not support Windows. The Android SDK
  (`firebase-analytics` through the Firebase BoM) is called through the
  app's own method channel instead; no Flutter package was added.
- **Off until yes.** Firebase is not started at launch (`FirebaseInitProvider`
  is removed). It starts in `AnalyticsChannel` only after the viewer agrees.
  The manifest keeps collection disabled and denies analytics and ad storage
  by default; consent mode grants `analytics_storage` only, and ad storage,
  ad user data and ad personalization are always denied.
- **No advertising or device ids.** The `AD_ID`, `ACCESS_ADSERVICES_AD_ID`,
  `ACCESS_ADSERVICES_ATTRIBUTION` and Play install-referrer permissions the
  SDK requests are removed in the manifest, and advertising-id and SSAID
  collection are switched off. Check with
  `aapt2 dump permissions <apk>` after SDK upgrades.
- **Turning it off** sets collection off, denies storage and calls
  `resetAnalyticsData()`, which clears the device's analytics data and its
  app-instance id.
- **Never critical.** Every Dart call is fire-and-forget; native errors are
  swallowed. A build without the `REELISH_FIREBASE_*` values reports
  `isConfigured = false`: no question, no switch, no Firebase.

## Event catalog

Firebase already calculates DAU/WAU/MAU, new and returning users, retention,
sessions, engagement time, app versions, device models, OS versions and
country from its automatic events (`first_open`, `session_start`,
`user_engagement`, `app_update`). Reelish sends only what those cannot know.

| Event | Parameters | Sent when | Question it answers |
|---|---|---|---|
| `screen_view` | `screen_name` (`home`, `plugins`, `library`, `settings` on phones; TV rail destinations such as `movies`, `search`, `profile`), `screen_class` | A phone tab or TV rail destination opens; repeats of the same page are dropped | Which pages people use and which they ignore |
| `select_content` | `content_type` (`movie`/`series`), `item_id` (TMDB id) | A details page opens | Which titles people look at; movies versus series |
| `search_performed` | `outcome` (`results`, `no_results`, `failed`), `results` (0–20, 21 = more) | A search settles (phone search, TV search) | Whether search finds things; never the text |
| `playback_session` | `content_type`, `item_id`, `outcome` (`played`, `failed`, `abandoned`), `engine`, `first_frame_ms`, `rebuffers`, `rebuffer_ms`, `stalls`, `failure` (first failure kind, such as `http`, `timeout`, `decoder`), `watched_pct` (tens), `watch_party` (0/1) | Once, when the player closes | Startup time, playback failure and abandonment rates, buffering, completion |
| `feature_used` | `feature`: `my_list_add`, `my_list_remove`, `watch_party_create`, `watch_party_join` (a valid code entered), `plugin_repository_install`, `accent_change`, `app_icon_change`, `episode_alerts_on`, `update_accepted` | The feature succeeds | Which features matter |
| `analytics_enabled` | — | The viewer turns sharing on | Where a device's data starts |

User property: `interface` = `phone` or `tv` (set at each launch while
sharing). Android TV versus Google TV and device models come from Firebase's
automatic device data.

**Never sent:** account or Trakt ids and names, display names, tokens,
search text, provider, plugin or repository names or addresses, stream URLs
or headers, file paths, precise location.

Useful reports: playback success rate = `playback_session` with
`outcome = played` ÷ all sessions; completion = `watched_pct ≥ 90` among
played sessions; startup = median `first_frame_ms`. Register
`content_type`, `outcome`, `failure`, `feature`, `screen_name` as custom
dimensions and `first_frame_ms`, `rebuffer_ms`, `watched_pct` as custom
metrics in the Firebase console to see them in reports.

## Setting up Firebase (once)

1. Create a Firebase project (Spark plan; Analytics is free) with Google
   Analytics enabled.
2. Add an Android app with package name `io.github.frnzeeey.reelish`. The
   SHA-1 is not needed for Analytics. Do not add `google-services.json` to
   the repository; its values go into build settings instead.
3. From that file (or Project settings › Your apps), copy:

   | Build setting | Firebase value |
   |---|---|
   | `REELISH_FIREBASE_APP_ID` | `mobilesdk_app_id` (App ID, `1:…:android:…`) |
   | `REELISH_FIREBASE_API_KEY` | `current_key` (Web API key) |
   | `REELISH_FIREBASE_PROJECT_ID` | `project_id` |
   | `REELISH_FIREBASE_SENDER_ID` | `project_number` (optional) |

4. Add them as **repository variables** (Settings › Secrets and variables ›
   Actions › Variables) for release builds. They are client identifiers,
   not secrets; restrict the API key to the Android app in Google Cloud
   console. For local builds, put them in `~/.gradle/gradle.properties` or
   the environment.
5. In Google Analytics › Admin › Data retention, choose **2 months** (the
   privacy policy points to this setting), and keep Google signals off.

## Testing with DebugView

```sh
adb shell setprop debug.firebase.analytics.app io.github.frnzeeey.reelish
flutter run --dart-define=REELISH_API_URL=https://...   # with REELISH_FIREBASE_* set
```

Answer **Share** in the question, use the app, and watch Firebase console ›
DebugView; events appear within seconds. Normal reports take up to 24 hours,
so a missing event there is not a failed delivery. Turn debug mode off with
`adb shell setprop debug.firebase.analytics.app .none.`.

## Cost

Google Analytics for Firebase is free on the Spark plan with no event
quota for app streams. Reelish adds no Firestore, Functions, Storage,
Crashlytics or BigQuery. Possible future costs only if added deliberately:
BigQuery export (needs the Blaze plan; storage and queries are billed) and
Crashlytics or Performance Monitoring (free, but more SDK size and data to
disclose).

## Release checklist

- Repository variables `REELISH_FIREBASE_*` set; API key restricted to the
  Android app.
- Data retention set to 2 months; Google signals off.
- Play Console Data safety (if published there): app activity and app info
  and performance, collected only with consent, not shared for advertising.
- One release build checked in DebugView on a phone and a TV: question
  shown once, nothing before **Share**, events after, nothing after
  switching off.
