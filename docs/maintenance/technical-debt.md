# Technical debt and maintainability observations

Observations from the documentation audit, as of this commit. None of them
is a bug, and none was changed while documenting; each is a candidate for
a deliberate, tested change. Line counts come from the generated
[file reference](../codebase/file-reference.md).

## Large files with several responsibilities

| File | Lines | What it combines |
|---|---|---|
| [`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart) | ~3,100 | The whole player session: engine attempts and recovery, progress, subtitles (three sources), tracks, episodes, and the touch, TV-remote and desktop input paths in one `State` |
| [`home_screen.dart`](../../lib/src/screens/home_screen.dart) | ~2,400 | The phone Home UI, the TV and Windows shell wiring, the play flow (`_openItem`, `_resolveAndOpenPlayer`), details navigation and update checks |
| [`player_controls.dart`](../../lib/src/widgets/player/player_controls.dart) | ~1,400 | Controls, buttons, seek feedback, buffering, status, error panel and the next-episode card |
| [`playback_settings_screen.dart`](../../lib/src/screens/playback_settings_screen.dart) | ~1,100 | Three screens: Settings, Appearance and Playback settings |

The play flow in `HomeScreen` is the most coupled part: details screens,
the Windows hero and sidebar, and the player itself call back into it. A
change there reaches every interface; test all three.

## Names that outlived their meaning

- **`Tv` names on Windows.** `TvDestination` and `TvCatalog` also drive the
  Windows interface (`usesTvLayout` is true on Windows).
- **Historical prefixes.** Preference keys start with `onfeed.` (the old
  app name) and provider keys with `onfeed.nuvio.`; the Android namespace
  and Kotlin package are `com.example.onfeed`. They must stay as they are:
  renaming a key loses viewers' data unless it is migrated.
- **Unread key.** `reelish.desktop.sidebarExpanded` is no longer read (the
  sidebar's pin uses `reelish.desktop.sidebarPinned`); old values stay in
  viewers' preferences, harmlessly.

## Shared code with platform branches

`GitHubUpdateService` and `AppUpdateFlow` serve both Android and Windows
with platform branches, and the service's class comment still describes
Android only. Windows update orchestration is split between them and
`WindowsUpdateController`.

## Documentation

- Older audits in `docs/` and `docs/security/` describe past states; they
  are kept as records and marked historical. Current behaviour is described
  by the pages linked from [`docs/README.md`](../README.md).
- `ios/`, `linux/`, `macos/` and `web/` are generated platform folders that
  are not shipped or tested.
