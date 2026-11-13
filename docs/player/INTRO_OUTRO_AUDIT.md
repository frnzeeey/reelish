# Intro and outro skipping: playback audit

What the player already offers for skipping intros and outros, what
IntroDB provides, and how the two fit. Audited 2026-11-13. The
implementation is described in [INTRO_OUTRO_IMPLEMENTATION.md](INTRO_OUTRO_IMPLEMENTATION.md).
Background: [playback architecture](../playback/playback-architecture.md),
[lifecycle](../playback/playback-lifecycle.md),
[player engines](../playback/platform-player-engines.md).

## Player architecture

| Question | Finding |
|---|---|
| Player | One session widget for every platform: `CustomVideoPlayer` (`lib/src/widgets/player/custom_video_player.dart`), pushed by `PlayerScreen`. Phone, TV and Windows share it; the chrome branches on `_tv` / `_tvHardware` / `_desktop` |
| Engines | Android: Media3 first, libmpv fallback (`PlayerEngineFactory`, `lib/src/services/player_engine.dart`). Windows: libmpv only. TV: same as Android. Both engines build a `VideoPlayerController` |
| Time unit | `VideoPlayerController.value.position` and `.duration` are Dart `Duration`s on both engines; no per-engine conversion is needed |
| State to UI | One listener, `_tick`, on the controller: play/pause, buffering, completion, errors, progress saves, the next-episode offer, Watch Party reports |
| Seeking | Local seeks go through `_seekTo(Duration)`, which clamps to the duration and reports to Watch Party (`party.localSeek`), refusing when the party disallows local control. Room commands use `_PartyHandle`, never `_seekTo` |
| Seek status | `video_player` exposes no "seeking" flag; `seekTo` returns a future. A seek in flight has to be tracked by the caller |
| Resume | `_startPosition` (saved progress) is applied once at start (`CustomVideoPlayer.validResume`); Continue watching can therefore start inside an intro |
| Episode identity | Fixed per player: `widget.item` (the series, TMDB id), `widget.season`, `widget.episode` (TMDB numbering), `widget.imdbId` (a `Future<String>` resolving the **series** IMDb id from TMDB `/tv/{id}` `external_ids`). The future may be empty when TMDB has no IMDb id |
| Episode change | A new player widget per episode (`onPlayEpisode` with `EpisodeHandOff`); there is no `didUpdateWidget`, so per-episode state cannot leak to the next episode |
| End of episode | The next-episode offer appears at `nextEpisodeThresholdPercent` (default 99 %) of the duration; with auto-play it counts down 8 s |
| Engine switch / reconnect | Same widget and position; the controller is replaced (`_controller`), the position restored |
| Subtitles / audio | External cues follow `_externalCue.sync(position…)` on every tick; embedded tracks follow the engine. A seek is handled like any user seek, so both stay in sync |
| TV remote | `_onRemoteKey` on the player focus: hidden controls → Left/Right seek, Select/Up/Down show controls. A control with focus takes its own keys |
| Watch Party | `PartyPlayerSync` exists only for a party title; the room is the playback authority |
| Settings | `PlaybackSettings` (`lib/src/models/playback_settings.dart`), one JSON preference `onfeed.playback.settings.v1`, device-local (no account sync); unknown keys default |
| Existing skip logic | None (no intro/recap/outro/chapter code anywhere in `lib/`) |

## IntroDB (read API)

Read from <https://api.introdb.app> (overview, reference, errors and limits,
authentication, open data, `openapi.json`) and <https://introdb.app/docs>
(terms, best practices) on 2026-11-13.

| Question | Answer from the docs |
|---|---|
| Endpoint | `GET https://api.introdb.app/segments?imdb_id=tt…&season=N&episode=N` (`imdb_id` pattern `^tt[0-9]{7,8}`, season/episode ≥ 1). `/intro` is legacy; `/outro` is for movies |
| Episode key | **IMDb series id + season + episode**. No TMDB, TVDB or IMDb-episode id on read endpoints |
| Response | `imdb_id`, `media_type`, `is_movie`, `season`, `episode`, `intro` / `recap` / `outro` / `post_credits` (null or `{start_ms, end_ms, start_sec, end_sec, confidence, submission_count, updated_at}`), `no_intro` / `no_recap` / `no_outro` |
| Units | Milliseconds (integers) and seconds; Reelish uses `start_ms` / `end_ms` |
| Quality signals | `confidence` (0–1, agreement of submissions) and `submission_count`; one aggregate per segment ("the median of the strongest cluster") |
| Versions / cuts | **Not represented.** No duration, release or version field; one timestamp per segment per episode |
| No data | `/segments` never 404s: segments are `null`; `no_*` flags mark a confirmed absence |
| Errors | JSON `{error}`; 400 bad parameters, 429 rate limited |
| Authentication | "Reads are anonymous." No key; keys are for `/submit` only, and the docs say not to ship a shared key in a public app |
| Rate limits | Reads are not metered per user; "keep them to what your player needs"; bulk crawling is prohibited (use the open data export) |
| Terms | Permitted: "Integrating skip functionality into media players", commercial apps with reasonable usage. API attribution appreciated, not required |

## Gaps and decisions

1. **Identity.** Reelish has the series IMDb id and TMDB season/episode
   numbers, which is IntroDB's key. IntroDB's submit endpoint checks
   episodes against TMDB/TVDB, so numbering normally agrees. Where TMDB and
   IMDb numbering differ (specials, some anime), a wrong match is possible.
   The response's `imdb_id`, `season` and `episode` are checked against the
   request, and the timestamps are checked against the stream (below).
2. **Version.** IntroDB cannot say which release it timed. Reelish can only
   check that the segment is plausible for the stream it is playing: an
   intro must end in the first half of the stream, an outro must start in
   the second half and end inside it, and segments must not overlap. A
   segment that fails is not used. A different cut whose intro moved by a
   few seconds still passes; that residual risk is why automatic skipping
   needs at least 2 agreeing submissions and confidence ≥ 0.7, and why the
   button is offered for weaker data instead.
3. **Engines.** One integration in `CustomVideoPlayer` covers Media3 and
   libmpv on every platform; no engine code changes.
4. **Seeks.** Skips use `_seekTo`, the same path as the user's seeks, so
   subtitles, audio, progress saves and Watch Party behave as for any seek.
   A pure planner tracks its own seek in flight and the user's seeks, which
   `_seekTo` reports.
5. **Watch Party.** Automatic skipping is off in a party: the room is the
   authority, and a guest's automatic seek would fight it. The button stays,
   and goes through `_seekTo`'s party rules.
6. **Transport.** Reads need no key, so the app calls IntroDB directly
   (fixed HTTPS host, no redirects, small body cap). No backend or proxy.
   IntroDB then sees the device's IP address and the series and episode
   being played; the privacy policy says so, and turning both skips off
   sends nothing.
7. **Settings.** `PlaybackSettings` gains two fields, device-local like the
   rest of the playback settings (they do not sync today; adding sync for
   two fields would need a backend route and is not justified).
