# Caching

Two separate layers: TMDB API responses and artwork images. Neither holds
user data, credentials or tokens; clearing either never touches settings,
history, My list or downloads.

## TMDB responses (`lib/src/services/tmdb_response_cache.dart`, `tmdb_service.dart`)

| Concern | Behaviour |
|---|---|
| Memory (L1) | LRU of 64 parsed responses; search results evicted first |
| Disk (L2) | One JSON file per request in the OS cache directory; temp-file + rename writes; corrupt files deleted; 8 MB / 64 files, pruned at most every 6 h (header-only reads) |
| Freshness | Catalog, recommendations, releases 20 min; search 3 min; details, seasons, episodes 24 h; ID lookups 7 days; stale copies kept 7 days more |
| Strategy | Fresh → cache only. Stale → shown at once, refreshed in the background (stale-while-revalidate). Missing → network. Pull-to-refresh → network first (`forceRefresh`) |
| Refresh results | The UI is updated only when the refreshed JSON differs from what it shows |
| Deduplication | One in-flight request per URL; callers share it; failures leave the registry |
| Failures | Backoff with jitter, `Retry-After` and 429 respected, a 30 s cooldown before refreshing a key that just failed; stale data stays on screen |
| Keys | The gateway URL with sorted parameters; never a token. Responses are public TMDB data, the same for every account |
| Diagnostics | `TmdbService.cacheStats` (counts only); debug builds log a summary every 25 network requests |

The Reelish API's gateway has its own edge cache keyed by the upstream TMDB
URL (no credential), and answers the app with `private, no-store`.

## Artwork (`lib/src/widgets/artwork_image.dart`)

**Decision: `cached_network_image` (with `flutter_cache_manager`), wrapped
in one component.** Before it, artwork used `Image.network`, whose only
cache is Flutter's in-memory `ImageCache`: every launch downloaded every
poster again. There was no other image cache to reuse. A hand-written disk
cache would have duplicated what `flutter_cache_manager` already does
(index, eviction, stale periods, concurrent downloads), so the package was
chosen; it supports Android (SQLite index) and Windows (JSON index).

- `ArtworkImage.network(...)` is a drop-in for `Image.network` (same
  `frameBuilder`, `errorBuilder`, placeholders, `cacheWidth`), and
  `artworkProvider(url, cacheWidth:)` replaces `NetworkImage` where a
  provider is needed. Call sites never use the package directly.
- Only `https://image.tmdb.org` is cached on disk. Other images (add-on
  logos from third-party manifests) load as before, uncached.
- Decoding is unchanged: images are still decoded at their drawn size
  through `ResizeImage`, so memory use is the same as before.
- Disk: up to 600 files (about 60–100 MB of w342/w500 posters and w1280
  backdrops), each dropped after 30 days unused, in the OS temp/cache
  directory (`%TEMP%\reelishArtwork` on Windows; the app cache on Android,
  which the system may clear). `ArtworkCache.clear()` empties it.
- Widget tests turn the disk cache off (`test/flutter_test_config.dart`);
  `artwork_image_cache_test.dart` and `integration_test/artwork_cache_test.dart`
  cover it.

Measured: across two launches the same poster was downloaded twice before
and once after (`artwork_image_cache_test.dart`), decoded at the same size;
on Windows a real 50 KB TMDB poster was read back from disk by a fresh cache
manager. APK size grew by about 0.7 MB.

**Note:** on Windows the installed app and a development build share the
artwork cache folder and index. That only costs re-downloads if both run at
once; it holds no user data.
