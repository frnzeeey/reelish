# Glossary

Terms used in the code and these docs, A–Z.

| Term | Meaning |
|---|---|
| **Catalog** | The browsable titles, all from TMDB. Providers never add titles. |
| **Catalog settled** | `HomeViewModel.catalogSettled`: page 1 of Movies and Series has loaded; Top 10 and New releases may load. |
| **Continue watching** | History entries with a resume position, shown with `ResumeSummary` text. In the Windows sidebar on Windows. |
| **Discovery** | One provider lookup for one title or episode: a `StreamDiscovery`. |
| **Engine** | What decodes and renders video under package:video_player: Media3 or libmpv (`PlayerEngine`). |
| **Engine gate** | `PlayerEngineGate`: waits for the other engine's players to close before switching engines. |
| **Episode hand-off** | `EpisodeHandOff`: the playing player releasing its engine to the player of the next episode. |
| **Failure kind** | `PlaybackFailureKind`: the classified reason a source failed. |
| **GlassTheme** | Reelish's design tokens and themes. |
| **Hard timeout** | `ProviderRunner.hardTimeout` (45 s): the longest a caller waits for a provider run. |
| **Libmpv / media_kit** | The engine on Windows and the fallback on Android, through the vendored `video_player_media_kit`. |
| **Manifest** | A provider repository's JSON listing its providers and their script files. |
| **Media3** | Android's ExoPlayer successor; the first engine on Android. |
| **My list** | The viewer's favourites (`onfeed.favorites`). |
| **Nuvio** | A historical name kept in provider preference keys (`onfeed.nuvio.*`). |
| **Onfeed** | The app's former name; the Dart package and preference keys keep it. |
| **P2P** | Torrent playback; Android, 64-bit processes only. |
| **Pinned (sidebar)** | The Windows sidebar kept open beside the page instead of opening on hover. |
| **Plugin / provider** | A third-party script, from an installed repository, that returns stream sources. |
| **Plugin Library** | The community catalog of repositories shown in Plugins → Browse. |
| **Playable source** | `PlayableSource`: a source after validation, ready for an engine. |
| **Repository** | A provider manifest URL the viewer installed. |
| **Resume summary** | `ResumeSummary`: the progress and text of a Continue watching card. |
| **Runtime slot** | One of the two QuickJS runtimes `ProviderExecutionScheduler` allows at once. |
| **Script approval** | A changed or newly added provider script waits in `pendingScriptUpdates` until the viewer allows it. |
| **SEC-01** | The accepted risk that native engines make their own requests; see [`docs/streaming_security.md`](../streaming_security.md). |
| **Source** | A `StreamSource`: one playable stream a provider returned, with headers, quality and subtitles. |
| **Spotlight** | The featured titles at the top of Home. |
| **Top 10** | Recommendations from the best movie and series on page 1, ranked; a fixed-size row. |
| **TTF / TTR** | Time to first candidate / first valid source in a discovery (debug logs). |
| **`usesTvLayout`** | True on TV and Windows: they share the rail-based layouts. |
