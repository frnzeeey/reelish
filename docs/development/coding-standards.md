# Coding standards

The conventions the code already follows. The binding rules for every
change, human or AI, are in [`CLAUDE.md`](../../CLAUDE.md); this page
expands on them.

## Style

- **Format** with `dart format`, on the files you touched only. A
  repository-wide format rewrites unrelated files.
- **Lints:** `package:flutter_lints` ([`analysis_options.yaml`](../../analysis_options.yaml)).
  `flutter analyze lib test integration_test test_driver` must report no
  warnings or errors; the baseline has 16 info-level notes.
- **Comments** explain *why*, in full sentences, at the density of the
  surrounding code. Public types and non-obvious methods get a `///` doc
  comment whose first sentence says what it is or does: the generated
  [references](../codebase/class-reference.md) use that sentence.
- **Names** follow Dart style (`UpperCamelCase` types,
  `lowerCamelCase` members, `snake_case.dart` files). A file is named after
  its main type (`playback_coordinator.dart` → `PlaybackCoordinator`).
- **Fonts in button styles:** a `ButtonStyle.textStyle` replaces the
  theme's text style entirely, so set `fontFamily: GlassTheme.fontFamily`
  there, or the text falls back to a system font.

## Structure

- **Platform isolation.** Put platform UI in its platform's folder
  (`lib/src/desktop/`, `lib/src/screens/tv/`, `lib/src/widgets/tv/`). If a
  shared file must change, make the change inert on the other platforms
  (hover-only, or behind `DeviceCapabilities.isTv` / `isDesktop`) and say
  so in the change. Pick the flag that matches the intent:
  `usesTvLayout` (TV and Windows), `isTv` (TV hardware), `isDesktop`
  (Windows).
- **Data out of widgets.** Loading and business rules belong in a view
  model or service; widgets render and forward input.
- **No new dependencies** or broad refactors without agreement.
- **Theme tokens.** Colours from `GlassTheme` (read `GlassTheme.primary`;
  the viewer can change the accent), Windows sizes from `DesktopMetrics`,
  motion through `desktopMotion` or `MediaQuery.disableAnimationsOf` so
  reduced motion is honoured.
- **Images** decode at drawn size (`cacheWidth`; on Windows
  `posterDecodeWidth`). At most one fixed-size blur per panel; none per
  list item.

## Async and lifecycle

- Anything that can be superseded checks a generation number or `mounted`
  before applying its result (see
  [design patterns](../architecture/design-patterns.md)).
- Dispose what you create: controllers, focus nodes, timers, listeners,
  keyboard handlers.
- Do not leave continuous animations running when idle; they also make
  `pumpAndSettle` hang in tests.

## Safety rules

- **Playback integrity.** Don't change engine selection, source discovery,
  validation or preparation, headers, redirects, subtitles, audio tracks or
  provider execution unless that is the task and the change is verified.
- **Untrusted input.** Provider scripts, manifests, stream URLs, subtitle
  files and remote responses are untrusted. Never weaken
  `NetworkDestinationValidator`, the QuickJS limits, script-change approval
  or the update verification to make something work.
- **Secrets.** Never print, copy, commit or log `lib/tmdb_config.local.dart`,
  keystores or signing material. Never log full stream URLs, headers or
  cookies; use `PlaybackLog.describe`.
- **Persisted data stays readable.** SharedPreferences keys and JSON shapes
  are viewers' data: add fields with defaults, keep old keys loadable, and
  version a format change (`.v1` → `.v2`) with a migration. A key whose
  meaning changes gets a new name (as `reelish.desktop.sidebarPinned` did).
- **Commits, tags and releases** only when asked; releases only through CI.

## Documentation

When a change adds, moves or renames code, or changes behaviour, update
the docs in the same change; see
[documentation standards](../maintenance/documentation-standards.md).
