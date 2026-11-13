# TMDB usage by personalised discovery

## Requests

| When | Requests | Endpoint |
|---|---|---|
| Launch | **0** — last rows are read from disk | — |
| Refresh due (rows older than 6 h, or tastes changed) | **≤ 4**, one per seed, page 1 only | `GET /movie|tv/{id}/recommendations` |
| Refresh not due | **0** | — |
| Cold start (no signals) | **0** | — |
| Picked genres only | **0** — built from rows Home already has | — |
| Feedback, Settings, reset | **0** | — |

There are no detail requests per candidate, no pagination and no new
endpoint. Every candidate's metadata (genres, rating, votes, popularity,
dates, artwork) comes from list results already parsed into `MediaItem`.

## Reuse

- `TmdbService.recommendations` is the existing method (used by Details).
  It goes through the shared request limiter (4 concurrent) at **deferred**
  priority, so it never delays catalog rows, details or playback.
- Its responses use the existing disk cache with stale-while-revalidate
  (`TmdbCacheTtl.recommendations`, 20 min) and the gateway's edge cache
  (`catalog`, 20 min). A seed that is also a Top 10 seed or a recently opened
  title is usually a cache hit.
- Requests for the same URL already in flight are shared
  (`TmdbService._inFlight`), as are failures' cool-downs.
- The rows Home already loaded (New movies, Series worth the queue, Top 10,
  New releases, phone Trending) are scored as a free second pool.

## Bounding

- Seeds: `DiscoveryWeights.maxSeeds` = 4.
- Candidates: at most 4 × 20 + the loaded rows (typically ~140–200), scored
  in one pass on the UI isolate. The engine is linear in candidates apart
  from sorting.
- Single flight: concurrent `refresh` calls share one; there is no timer and
  no background task outside Home's lifetime.
- Triggers are events (catalog settled, back from the player, app resumed),
  never rebuilds; when the rows are fresh and the profile unchanged a refresh
  returns after one local My list read.

## Failures

| Case | Behaviour |
|---|---|
| One seed fails | Its candidates are lost; other seeds and Home's rows still build rows. |
| TMDB / gateway down, Home has rows | Rows from Home's rows only. |
| Everything down, rows cached | Cached rows kept (minus anything since watched or hidden). |
| Empty recommendation lists | Rows that would have fewer than 6 titles are not shown. |
| Rate limited (429) | Handled by `TmdbService` retries with `Retry-After`; deferred priority keeps it behind interactive requests. |

## Measured

Request counts are asserted in `test/discovery_controller_test.dart`
(see the [test report](PERSONALIZED_DISCOVERY_TEST_REPORT.md)): a new viewer
makes 0 requests, a refresh makes one per seed, simultaneous refreshes and a
second refresh within 6 hours make none, and a restart shows cached rows with
no request. Timings on real devices were not measured.
