# Playback quality prioritization

How Reelish picks between provider sources by resolution, what it can and
cannot know, and how it falls back. Audit and design of 2026-11-20.

## Audit: who controls what

| Part | Controlled by | Finding |
|---|---|---|
| Which sources exist, their URLs and headers | Provider plugins | Reelish only receives them (`StreamSource.fromJson`) |
| Resolution metadata | Provider plugins | Free text: a `quality` or `resolution` field ("1080p", "4K", "HD"), or nothing but the stream's name. Never verified before playback |
| First source played | Reelish (`StreamDiscovery.startingSource`, Home) | The first source to arrive; a torrent first waits 2 s for a direct stream |
| Fallback after a failure | Reelish (`PlaybackCoordinator.nextAfterFailure`) | Ranks by provider diversity, failed providers, direct over torrent; resolution plays no part |
| Failure kinds | Reelish (`PlaybackFailure.classify`) | http, network, timeout, manifest, format, decoder, rendering, engine, preparation, source, cancelled, unknown |
| Stream manifests before playback | Nobody | `SourcePreparer` validates addresses and never fetches media or manifests |
| Real resolution | Engines, after opening | `VideoPlayerController.value.size`; HLS/DASH variants through `getVideoTracks` |
| Quality inside one adaptive stream | Media3 (Android) | Adaptive by bandwidth and device; `Preferred video quality` selects a track when not Auto |
| Quality inside one adaptive stream | libmpv (Windows) | The bridge has no video-track API: the setting does nothing there, and libmpv plays an HLS stream's highest variant |
| Device limits | Not read | No decoder or display query existed; `DeviceCapabilities` knew only TV, touch and PiP |
| Watch Party | Each viewer's own source search | Sync is by position; which source each viewer plays does not matter to it |

**Conclusion.** Reelish cannot verify a provider's claimed resolution before
playing it, cannot make a plugin return a 4K source, and on Windows cannot
yet choose a variant inside an HLS stream. It can rank what providers return,
cap that ranking by what the device can show and decode, wait briefly for a
better source, and fall back by tier. That is what this change does; labels
are always treated as claims.

## Design

### Claimed resolution

`SourceQuality.claimedHeight` reads, in order, the source's `quality` field,
its name, then its description: an explicit height (`2160`, `1080p`, `720p`,
`480p`, also `4320`, `1440`, `576`, `360`), `8K`, `4K`/`UHD`, `FHD`/`Full HD`,
or `SD`. A bare "HD" is ambiguous (720p or 1080p) and counts as unknown.
Nothing else is inferred.

### The target

`PlaybackQualityPolicy.resolve` turns the existing `Preferred video quality`
setting into a ceiling:

| Setting | Ceiling |
|---|---|
| Auto (0, the default) | The device's: the largest size its hardware decoders and its display support (Android), the monitor's (Windows), 2160 when unknown; 1080 on a metered connection |
| 2160, 1440, 1080, 720 | That height, lowered to what the device can decode |
| 480 | 480: data saver |

So Auto is 4K first on a 4K-capable TV or PC, with 1080p fallback, and 1080p
first on a phone or a 1080p screen, where 4K adds data and decoding work but
no visible detail.

### Ranking

Within a target T and a floor F = min(720, T):

1. Claimed heights from F up to T, highest first.
2. Unknown heights (often adaptive "Auto" streams).
3. Claimed heights below F, highest first.
4. Claimed heights above T, lowest first.

Direct streams still come before torrents, which need metadata first.

### Starting source

`startingSource` takes the best-ranked source already found. When it is
below the target, it waits up to 3 s more (from the first result) for one at
the target, then takes the best it has. A source at the target ends the wait
at once. No wait ever exceeds that; with `Auto stream selection` off, the
picker opens as before with the best source preselected.

### Fallback

`nextAfterFailure` ranks the untried candidates by tier first, then by the
existing rules (another provider, failed providers lower, direct before
torrent). A provider that failed twice, or a host that answered with
something no engine recognized as video, drops below everything else. After a
`decoder` or `rendering` failure of a source claiming 1440p or more, the
ceiling drops below that height for the session: the device could not show
it, so other sources of the same height are not tried first. The automatic
budget stays 5 distinct sources; buffering is still handled by reconnecting
the same source (`StallWatchdog`), never by switching sources.

### Verification after opening

After a source opens, the debug log records its claimed and actual height.
Release builds log nothing new.

## Platform differences

| | Android phone | Android TV / Google TV | Windows |
|---|---|---|---|
| Ceiling in Auto | Display and hardware decoders; usually 1080 | Display modes and hardware decoders; 2160 on 4K TVs | Monitor height |
| Metered connection | 1080 cap in Auto | 1080 cap in Auto | Not detected |
| Inside an adaptive stream | Media3 adapts; a fixed setting selects a track | Same | libmpv plays the highest variant; no selection |
| Unsupported codec | Media3 decoder error, then libmpv, then the next tier | Same | libmpv error, then the next tier |

## Limits

- Claims cannot be checked before playing. A mislabelled source is found
  out only by its real size after opening (logged in debug builds).
- On Windows the setting does not limit the variant inside an HLS stream;
  that needs a video-track API in the libmpv bridge (planned).
- Network speed is not measured; only "metered" is read, on Android.
- Waiting for a better source costs up to 3 s at the start when the first
  sources are below the target.

## Tests

`test/playback_quality_test.dart`: claimed heights (and what is never
guessed), ranking for 4K, 1080p and data-saver targets, Auto per device and
connection, the starting source (4K and 1080p both found, only 1080p within
the wait, a 4K arriving during it, a finished lookup, direct before a 4K
torrent, no target), and fallback (4K, 4K, 1080p, 720p; a 4K the device
cannot decode; a provider that failed twice; the attempt budget when
everything fails). The existing `test/playback_reliability_test.dart`,
`test/playback_pipeline_test.dart` and `test/player_session_test.dart` cover
the unchanged rules.
