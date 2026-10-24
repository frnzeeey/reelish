---
name: regression-check
description: Validate a Reelish change on every platform it can reach (phone, Android TV/Google TV, Windows) before committing, or run a whole-app sanity check after a series of changes. Use at the end of any code change, before a commit or release, or when asked for a regression audit or sanity check.
---

# Regression check

## Purpose
Prove a change works where it should and changes nothing where it
shouldn't. Outcome: a list of checks run with results, and an honest list
of what could not be verified.

## Activation
- Finishing any code change, before commit or release.
- "Sanity check", "regression audit", "post-fix verification".

## Codebase context
- Platform flags: `DeviceCapabilities` (`isTv`, `isDesktop`,
  `usesTvLayout`); interface split in `reelish-architecture`.
- Tests: `test/` (unit and widget; `flutter_test_config.dart` preloads the
  Windows QuickJS DLL), `integration_test/` (device/desktop runs).
- CI (`.github/workflows/release.yml`) runs
  `flutter analyze --no-fatal-infos lib test integration_test` and
  `flutter test` on release tags.

## Workflow
1. **Scope.** `git diff --stat`: list touched files and, for each, which
   platforms reach it (platform UI folder, or shared). Confirm nothing
   unrelated changed (a stray repo-wide format shows up here; revert it).
2. **Static.** `dart format` the touched files only;
   `flutter analyze lib test integration_test test_driver`. The baseline is
   16 info-level notes; any new warning or error fails CI.
3. **Tests.** Targeted tests first, then the full `flutter test`. A new
   behaviour gets a test that fails without the change; check that once
   (temporarily revert, run, restore).
4. **Builds.** Windows: `flutter build windows --release`. Android:
   `flutter build apk --profile` (release builds need the private keystore
   configured through `ONFEED_RELEASE_*` variables, which CI holds).
5. **Devices**, when the change is user-visible or platform-specific:
   - Phone/TV: `flutter run -d <emulator>`; check touch on phone, D-pad
     focus and Back on TV. `flutter drive` and some integration runs wipe
     the app's data on the device.
   - Windows: `flutter run -d windows`, mouse, keyboard, resize, fullscreen;
     integration tests from `windows-desktop`.
6. **Review** (also the sanity-check pass):
   - persisted data still loads (`StorageService` keys, JSON shapes);
   - listeners, timers, controllers and subscriptions disposed;
   - shared widgets: change inert on other platforms;
   - no secrets, tokens or full stream URLs in code or logs;
   - docs in `docs/` that describe the changed behaviour.

## Safety constraints
- Don't "fix" an unrelated failing test by weakening it; report it.
- Don't skip hooks, signing or CI checks.
- Worktrees on Windows need short paths (deep paths break the C++ build
  with include errors). A worktree lacks the gitignored
  `lib/tmdb_config.local.dart`; copy it in for the run and delete it after.
- Never publish or commit as part of a check.

## Platform considerations
A change under `lib/src/desktop/` needs Windows checks only, but still the
full test run; `lib/src/screens/tv` needs TV focus checks; anything under
`services/`, `models/`, `viewmodels/` or `widgets/player/` is shared and
needs all three.

## Validation
This skill is the validation. Record each command and its result.

## Completion criteria
Analyze has no new issues; the full test suite passes (or failures are
shown to be pre-existing); every affected platform builds; device checks
done or listed as not done.

## Reporting
Per CLAUDE.md § Reporting, as a table: check, command, result. Then the
unverified items and the residual risk per platform.
