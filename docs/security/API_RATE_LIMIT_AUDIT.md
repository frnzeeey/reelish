# Reelish API and rate-limit audit

<!-- docs-check: historical -->
> **Historical record.** This report describes the codebase when it was written. Files, names and behaviour may have changed since; current documentation starts at [docs/README.md](../README.md).

Date: 2026-10-11. Scope: every outbound request the app makes, the limits
applied to it, and whether the limits could slow playback.

## Summary

Every service Reelish calls has a concurrency cap, a cache or
deduplication, timeouts, and a byte cap, except the native player, which
stays unthrottled on purpose. Retries are bounded and respect
`Retry-After`. No service can be flooded by normal or repeated UI use,
including TV remote navigation. **No changes are recommended.** In
particular, no global request queue should be added: it would delay stream
resolution and segment fetches.

## Per-service limits

### TMDB (`tmdb_service.dart`, `tmdb_response_cache.dart`)

- **Concurrency:** at most 4 requests at once through a priority limiter, and
  identical requests share one in-flight future (`_inFlight`, line 71).
- **Caching:**

  | Data | Fresh for |
  |---|---|
  | Catalog | 20 min |
  | Search | 3 min |
  | Metadata | 24 h |
  | IDs | 7 days |

  Stale entries are served for up to 7 more days while being revalidated.
- **Retries:** `maxRetries = 2` (line 27), only for 429, 500, 502, 503 and
  504 and network errors.
  - Backoff with jitter.
  - `Retry-After` is honored; waits over 2 minutes give up instead of
    retrying (line 1026).
- **Caps:** 5 MiB responses, 3 redirects, per-origin pinned client reused
  for 5 minutes.

### Provider scripts (`provider_execution_scheduler.dart`, `provider_runner.dart`)

- **Concurrency:** 4 workers and at most 2 QuickJS runtimes alive at once.
- **Timeouts:** 20 s script execution, 45 s hard timeout per provider, and a
  60 s cap on the whole search, after which no new providers start. Results
  show up progressively.

### Provider HTTP (`provider_fetch_bridge.dart`)

- **Concurrency:** 4 requests at once per runtime.
- **Caps:** 2 MiB bodies, validated redirects, 64 timers per runtime, and a
  256-entry cookie jar.

### Plugin install (`provider_plugin_service.dart`)

- **When:** on user action only.
- **Caps:** HTTPS only, 5 redirects, 4 MiB, 15 s and 20 s timeouts.
- **GitHub API:** GitHub links are turned into `raw.githubusercontent.com` or
  one `api.github.com` lookup.

### Plugin catalog (`plugin_library_service.dart`)

- **Frequency:** at most every 6 hours, or on pull-to-refresh.
- **Fallback:** the cached file, then the copy bundled in the APK.
- **Caps:** byte cap and timeout.

### Subtitle add-ons (`subtitle_addon_service.dart`)

- **Caching:** 30-minute cache with bounded size; identical searches share
  one in-flight request.
- **Retries:** one retry on 429, only when `Retry-After` is 5 s or less
  (lines 293-298).

### Subtitle files (`subtitle_loader.dart`)

- **When:** one file per selection.
- **Caps:** HTTPS only, 4 MiB, 15 s (lines 262-264).

### GitHub updater (`github_update_service.dart`)

- **Background checks:** at most every 6 hours, persisted across launches
  (lines 134, 149).
- **Manual checks:** **Check for updates** always asks GitHub, and repeated
  checks share one request.
- **Download caps:** 512 MiB, plus size and SHA-256 verification.

### Images (`Image.network`: TMDB CDN, provider logos)

- Flutter's in-memory image cache; logos are decoded at display size.
- `image.tmdb.org` is a CDN and isn't covered by API rate limits.

### TV UI (`screens/tv/*`, `paged_feed_controller.dart`)

- **Search:** 450 ms debounce, stale responses dropped (`_request` counter),
  at most 10 pages (`tv_pages.dart:371-460`).
- **Rows:** load more only within 6 items of the end, once per frame, and
  `loadMore` is ignored while busy, at the end, or after an error
  (`paged_feed_controller.dart:212-220`).
- **Details:** seasons and episodes are loaded per screen or season and served
  from the TMDB cache.

### Playback (Media3 / libmpv)

**Not throttled, on purpose.** Segments, manifests and redirects run at full
speed.

## Behavior under failure

- **TMDB 429:** waits as told, then shows cached or stale data or the row's
  retry state. It doesn't retry in a loop.
- **Provider slowness:** one slow provider doesn't block the others. The
  search stops starting new providers after 60 s.
- **GitHub API limit (60 per hour per IP, unauthenticated):** background
  checks use at most 4 per day. A failed check never blocks the app.
- **Offline:** TMDB serves stale cache, and the catalog falls back to the
  bundled copy.

## Notes

- **Shared IPs (households, CGNAT):** TMDB limits per API key, not per IP. A
  shared key across all installs is the only real scaling concern. See
  SEC-04 in SECURITY_AUDIT.md: the fix is a proxy, and only if TMDB starts
  rejecting the key.
- **Manual update checks** are user-paced. Even fast repeated taps are
  deduplicated while a check is in flight. No change needed.

## Tests

Existing unit tests cover the TMDB limiter and cache, subtitle add-on
caching and 429 handling, the fetch bridge and destination policy, and the
updater throttle. See SECURITY_REMEDIATION.md for the baseline run.
