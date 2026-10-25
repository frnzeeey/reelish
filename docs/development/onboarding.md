# Developer onboarding

Answers to the questions a new developer asks first, with a reading order.

## Suggested reading order

1. [Architecture overview](../architecture/architecture-overview.md): the
   layers, startup, navigation and state.
2. [Platform architecture](../architecture/platform-architecture.md): what
   the phone, TV and Windows interfaces share.
3. [Getting started](getting-started.md): run it.
4. [Feature index](../features/feature-index.md): find the feature you
   will work on.
5. [Playback architecture](../playback/playback-architecture.md) and
   [provider integration](../playback/provider-integration.md), before
   touching anything that plays.
6. [Coding standards](coding-standards.md) and the
   [testing guide](testing-guide.md), before your first change.
7. [`CLAUDE.md`](../../CLAUDE.md): the project's non-negotiable rules, short
   and worth reading even if you are not an AI.

## Questions

**1. What is Reelish?** A Flutter app for discovering movies and series
(TMDB) and playing them through provider plugins the viewer installs. It
ships for Android phones and tablets, Android TV / Google TV (same APK) and
Windows. See the root [README](../../README.md).

**2. How is the repository organised?** App code in [`lib/`](../../lib),
tests in [`test/`](../../test) and [`integration_test/`](../../integration_test),
native projects in [`android/`](../../android) and [`windows/`](../../windows),
vendored native packages in [`packages/`](../../packages) and
[`third_party/`](../../third_party), tools in [`tool/`](../../tool). Every
folder: [directory reference](../codebase/directory-reference.md).

**3. Where does execution begin?** [`lib/main.dart`](../../lib/main.dart):
`main` → `ReelishApp` → the startup gate → `HomeScreen`. Step by step in
the [architecture overview](../architecture/architecture-overview.md#startup).

**4. How is application state managed?** With `ChangeNotifier` view models
([`lib/src/viewmodels/`](../../lib/src/viewmodels)) over services
([`lib/src/services/`](../../lib/src/services)); `HomeScreen` orchestrates
and rebuilds on their notifications. No state-management package. See
[design patterns](../architecture/design-patterns.md).

**5. Where is playback implemented?** The play flow starts in
`HomeScreen._openItem` ([`home_screen.dart`](../../lib/src/screens/home_screen.dart));
the session is `CustomVideoPlayer`
([`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart));
the policy and engines are in
[`playback_coordinator.dart`](../../lib/src/services/playback_coordinator.dart)
and [`player_engine.dart`](../../lib/src/services/player_engine.dart).

**6. Where are provider integrations located?**
[`provider_plugin_service.dart`](../../lib/src/services/provider_plugin_service.dart),
[`provider_runner.dart`](../../lib/src/services/provider_runner.dart),
[`provider_fetch_bridge.dart`](../../lib/src/services/provider_fetch_bridge.dart)
and the vendored QuickJS in [`third_party/flutter_js/`](../../third_party/flutter_js).

**7. Where are UI components located?** Phone: [`lib/src/screens/`](../../lib/src/screens),
[`lib/src/widgets/`](../../lib/src/widgets). TV: [`lib/src/screens/tv/`](../../lib/src/screens/tv),
[`lib/src/widgets/tv/`](../../lib/src/widgets/tv). Windows:
[`lib/src/desktop/`](../../lib/src/desktop). Player (all):
[`lib/src/widgets/player/`](../../lib/src/widgets/player).

**8. How do the platforms differ?** Interface, input, player engine,
torrents and updates; the matrix is in
[platform architecture](../architecture/platform-architecture.md#matrix).

**9. How do I add a feature?** Follow [adding features](adding-features.md).

**10. How do I fix a bug safely?** Reproduce it, find the stage (the
[troubleshooting guide](../playback/troubleshooting.md) maps playback
symptoms to code), write a test that fails, fix it in the narrowest place,
run the [validation steps](testing-guide.md#before-a-commit), and say what
you could not verify.

**11. How do I run tests?** `flutter test` for everything in `test/`;
integration tests one file at a time on a device or Windows. See the
[testing guide](testing-guide.md).

**12. How do I build the application?** `flutter build apk` or
`flutter build windows` after creating the TMDB key file; releases are
built by CI from a tag. See [getting started](getting-started.md) and
[`docs/releasing.md`](../releasing.md).

**13. Which files should I not modify without understanding their
dependencies?**

| File | Why |
|---|---|
| [`home_screen.dart`](../../lib/src/screens/home_screen.dart) | Orchestrates all three interfaces and the play flow |
| [`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart) | Every platform's player; touch, remote and desktop paths in one file |
| [`player_engine.dart`](../../lib/src/services/player_engine.dart) | Engine order, scheme routing, the engine gate |
| [`playback_coordinator.dart`](../../lib/src/services/playback_coordinator.dart) | Attempt budget and failure classification |
| [`provider_plugin_service.dart`](../../lib/src/services/provider_plugin_service.dart), [`provider_runner.dart`](../../lib/src/services/provider_runner.dart), [`provider_fetch_bridge.dart`](../../lib/src/services/provider_fetch_bridge.dart), [`network_target_policy.dart`](../../lib/src/services/network_target_policy.dart) | The sandbox and trust boundary for untrusted code |
| [`storage_service.dart`](../../lib/src/services/storage_service.dart) | Viewers' saved data; old formats must stay readable |
| [`device_capabilities.dart`](../../lib/src/platform/device_capabilities.dart) | Chooses the interface for every launch |
| [`third_party/flutter_js/`](../../third_party/flutter_js), [`packages/`](../../packages) | Patched native code; see each `REELISH_PATCH.md` |

The generated [dependency map](../codebase/dependency-map.md#most-depended-on-files)
lists the files most others import.
