# Reelish — engineering rules for AI agents

Reelish (package `onfeed`) is a Flutter app for discovering movies and series
(TMDB metadata) and playing them through user-installed third-party provider
plugins. It ships for **Android phones and tablets, Android TV / Google TV,
and Windows**. iOS, macOS, Linux and web folders exist but are not shipped.

Architecture details live in the `reelish-architecture` skill; read it before
non-trivial changes. Skills are in `.claude/skills/` (index at the end).

## Platforms are separate interfaces

`DeviceCapabilities` (`lib/src/platform/device_capabilities.dart`) chooses
the interface once per launch:

| Platform | Interface | Input |
|---|---|---|
| Phone / tablet | `lib/src/screens/` + `SoftGlassDock` | Touch |
| Android TV / Google TV | `lib/src/screens/tv/`, `lib/src/widgets/tv/` | D-pad focus (`TvFocusable`) |
| Windows | `lib/src/desktop/` (`DesktopShell` sidebar) | Mouse, keyboard, gamepad |

- `usesTvLayout` is true on TV **and** Windows; `isTv` is real TV hardware
  only; `isDesktop` is Windows. Pick the flag that matches the intent.
- Shared below the UI: models, services, ViewModels, the player chrome
  (`lib/src/widgets/player/`), and the phone Settings/Plugins sub-pages
  that the TV and Windows pages reuse.

## Non-negotiable rules

1. **Verify before you change.** Read the code; never assume an
   architecture, a feature or a platform behaviour from a prompt or a doc.
   `docs/` holds useful audits, but some describe past states.
2. **Platform isolation.** Prefer a platform-specific widget over editing a
   shared one. If a shared file must change, make it inert on the other
   platforms (e.g. hover-only, or behind a flag) and say so.
3. **Playback integrity.** Do not change engine selection, source
   discovery/validation/preparation, stream headers or redirects, subtitles,
   audio tracks, or provider execution unless the task is about them and the
   change is verified. Never "tidy" working playback code.
4. **Untrusted input.** Provider scripts, manifests, stream URLs, subtitle
   files and remote responses are untrusted. Never weaken
   `NetworkDestinationValidator`, the QuickJS limits, script-change
   approval, or Authenticode checks to make something work.
5. **Secrets.** `lib/tmdb_config.local.dart` (gitignored) holds the TMDB key.
   Never print, copy, commit or log it, nor keystore or signing material.
   Don't log full stream URLs or auth headers.
6. **Persisted data stays readable.** SharedPreferences keys and JSON shapes
   in `StorageService` are user data; keep old values loadable.
7. **Focused changes.** No broad refactors, new dependencies, or unrelated
   cleanup (including repo-wide `dart format`) without approval. Match the
   surrounding style and comment density.
8. **Commit, push, tag or release only when asked.**

## Validation expectations

- Run `dart format` on the files you touched only, then
  `flutter analyze lib test integration_test test_driver` (CI fails on
  warnings and errors; the baseline has 16 info-level notes) and
  `flutter test`.
- Build what you touched: `flutter build windows --release` for Windows,
  `flutter build apk --profile` for Android.
- Report a test as passed only if it ran. Say what was not verified
  (device, TV, live provider, real window scaling).
- The `regression-check` skill has the full per-platform checklist.

## Reporting

End every task with: what changed (files), why, validation run and its
results, what was not verified, and possible regressions or follow-ups.

## Skills

| Skill | Use it for |
|---|---|
| `reelish-architecture` | Orientation: modules, data flow, where code lives |
| `playback-audit` | Player engines, source pipeline, subtitles/audio, player UI |
| `provider-debugging` | Provider plugins, QuickJS runtime, fetch bridge failures |
| `ui-refinement` | Visual/interaction work on any of the three interfaces |
| `windows-desktop` | Windows runner, window, gamepad, libmpv, installer, updater |
| `regression-check` | Validating a change on every affected platform before commit |
| `performance-memory` | Jank, rebuilds, image memory, isolates, leaks, measuring |
| `security-audit` | Trust boundaries, network policy, secrets, logging |
| `release-validation` | Version bump, tag and GitHub release (invoke explicitly) |
