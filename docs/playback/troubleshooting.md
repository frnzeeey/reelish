# Playback troubleshooting

Symptoms mapped to the code that produces them. Debug builds log each
stage with a `[Playback][…]`, `[Stream]`, `[Provider Perf]` or `[Perf]`
prefix (release builds log almost nothing); none of these lines contain
stream URLs or headers. How to read logs on each platform is in the
[debugging guide](../development/debugging-guide.md).

Start by naming the stage: **discovery** (no sources) → **preparation**
(URL rejected) → **engine open** (HTTP, manifest, format) →
**decode/render** → **UI**. The `[Playback][Failure] kind=…` line gives the
`PlaybackFailureKind`.

---

**Problem:** "No source was returned for this title" or a snackbar about
providers.

**Relevant source files:** [`provider_plugin_service.dart`](../../lib/src/services/provider_plugin_service.dart) (`streams`), [`stream_discovery.dart`](../../lib/src/services/stream_discovery.dart).

**Execution path:** `HomeScreen._resolveAndOpenPlayer` →
`ProviderPluginService.discoverStreams` → `streams` → `StreamDiscovery.complete`
with `message` set.

**Potential failure points:** no repositories installed or none loaded
(offline at launch); every provider switched off; Allowed plugins in
Playback settings excludes all of them; no provider supports the type
(movie/series); scripts held for review (`pendingScriptUpdates`); each
provider failed or timed out (see `errors`); results dropped by
`StreamValidator` or because torrents are not allowed.

**How to investigate:** read the snackbar text (it is `discovery.message`);
check `[Provider Perf] <id> started / returned N candidates / failed` lines;
open Plugins for pending script updates; follow the `provider-debugging`
skill for one provider at a time.

**Related tests:** `stream_discovery_test`, `provider_runner_test`,
`provider_repository_state_test`, `provider_fetch_bridge_test`.

---

**Problem:** Playback takes long to start.

**Relevant source files:** [`home_screen.dart`](../../lib/src/screens/home_screen.dart) (`_resolveAndOpenPlayer`), [`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart) (`_initialize`), [`playback_coordinator.dart`](../../lib/src/services/playback_coordinator.dart).

**Execution path:** TMDB id resolution (capped at 3 s) → optional last
link → discovery → first source (`startingSource` waits up to 2 s for a
direct stream when the first is a torrent) → with automatic selection off,
waits for all providers or the selection timeout → `prepareAndOpen`
(startup timeout 20 s) → track queries (≤ 2 s) → resume seek (≤ 2 s) →
`play()` (≤ 10 s).

**Potential failure points:** slow providers before the first source;
automatic stream selection switched off; a torrent waiting for metadata;
an engine retry after a failure; several sources failing in turn.

**How to investigate:** compare `[Stream] First valid source (TTR) in …ms`
with `[Playback][Player] initialized in …ms` and `first frame after …ms`;
`[Playback][Fallback]` lines show retries.

**Related tests:** `playback_reliability_test`, `home_startup_budget_test`.

---

**Problem:** "The stream host refused access (HTTP 403)" or another HTTP
error.

**Relevant source files:** [`playback_coordinator.dart`](../../lib/src/services/playback_coordinator.dart) (`PlaybackFailure.classify`, `userMessage`), [`source_preparer.dart`](../../lib/src/services/source_preparer.dart).

**Execution path:** engine `initialize()` throws → `_handleFailure` →
`classify` → no engine retry for HTTP kinds → next source.

**Potential failure points:** the provider's headers (Referer, cookies)
were incomplete or dropped (hop-by-hop headers are always removed); a signed
URL expired (a reused cached link is refreshed once).

**How to investigate:** the `[Playback][Failure]` line shows `status=`; try
the same title with Reuse last link off; check the provider's headers in a
redacted trace.

---

**Problem:** Audio plays over a black picture.

**Relevant source files:** [`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart) (`_watchForPicture`), [`player_engine.dart`](../../lib/src/services/player_engine.dart).

**Execution path:** Media3 drops a video track it cannot decode and plays
audio; after 4 s with no picture `_watchForPicture` reports a rendering
failure; `_handleFailure` retries on libmpv at the same position.

**Potential failure points:** an unsupported codec on both engines; on an
emulator, libmpv's OpenGL output (MediaCodec output is used there instead).

**How to investigate:** look for `kind=rendering` and `engine media3 ->
mediaKit`; on Windows there is only libmpv, so check its log lines.

**Related tests:** `playback_pipeline_test`,
[`libmpv_playback_test.dart`](../../integration_test/libmpv_playback_test.dart)
(real devices and Windows).

---

**Problem:** The player stays on "Starting playback…" or hangs on close.

**Relevant source files:** [`player_engine.dart`](../../lib/src/services/player_engine.dart) (`_EngineVideoController.dispose`, `PlayerEngineGate`), [`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart).

**Execution path:** `initialize()` and `play()` have timeouts; dispose waits
at most 5 s; switching engines waits at most 5 s for the other engine's
players.

**How to investigate:** `[Playback][Engine] player did not dispose within
5s` or `switching to … while another engine still has a player open`
lines point at a native engine that stopped answering.

---

**Problem:** Resumes at the wrong place, or Continue watching is out of
date.

**Relevant source files:** [`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart) (`_startPosition`, `_saveProgress`, `_tick`), [`storage_service.dart`](../../lib/src/services/storage_service.dart), [`home_view_model.dart`](../../lib/src/viewmodels/home_view_model.dart) (`loadHistory`), [`resume_summary.dart`](../../lib/src/models/resume_summary.dart).

**Execution path:** progress is saved every 15 s, on pause and on close; a
series episode resumes from its own entry in `onfeed.history.episodes.v1`;
Home reloads history when the player closes.

**Potential failure points:** the app was killed between saves (at most
15 s lost); an episode change after a hand-off (the old player does not
save again by design); a series saved before per-episode tracking shows no
progress (by design: never guessed).

**Related tests:** `continue_watching_test`, `episode_selection_test`,
`home_view_model_test`.

---

**Problem:** No subtitles, or subtitles out of sync.

**Relevant source files:** [`subtitle_addon_service.dart`](../../lib/src/services/subtitle_addon_service.dart), [`subtitle_loader.dart`](../../lib/src/services/subtitle_loader.dart), [`external_cue_clock.dart`](../../lib/src/widgets/player/external_cue_clock.dart).

**Potential failure points:** no IMDb id for the title (addons need one;
`SubtitleRequest.create` returns null); an episode without season/episode;
embedded tracks on Media3 (not exposed); an unsupported file format. Delay
is adjustable in the player settings.

**Related tests:** `subtitles_test`, `external_cue_clock_test`.

---

**Problem:** Torrent sources never appear.

**Relevant source files:** [`torrent_source_preparer.dart`](../../lib/src/services/torrent_source_preparer.dart) (`TorrentSupport`).

**Potential failure points:** P2P streaming is off; a 32-bit Android
process (most Chromecast-class TVs); Windows (not supported).

**Related tests:** `torrent_source_preparer_test`,
[`torrent_streamer_test.dart`](../../integration_test/torrent_streamer_test.dart).
