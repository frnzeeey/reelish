# Reelish improvement pass: security, UI, performance, metadata

Date: 2026-10-13. Baseline: `1188c72` (main). This pass followed the brief
"Comprehensive Security, UI, Performance & Metadata Optimization". It made
only small changes, each backed by evidence. Most of the app was already in
the state the brief asks for, so most of this report says what was checked
and left alone, and why.

## Summary

| Area | Changed | Left alone (after checking) |
|---|---|---|
| Security | SEC-06 fixed (IPv6 documentation range). SEC-05 tried and reverted, because real logos failed to load. New finding NET-02 | Network policy, provider sandbox, update checks, storage, logging (see [SECURITY_AUDIT.md](SECURITY_AUDIT.md)) |
| Metadata | Playback no longer makes a separate TMDB `external_ids` request: the IMDb ID now comes with the details request | Endpoints, caching, dedupe, fallbacks |
| UI | One text contrast fix in the player's error panel | Glass, motion, TV focus: already tiered and accessible |
| Performance | None. Nothing measured justified a change | Controllers, timers, images, blur, startup |
| Tests | 3 new tests. Fixed a test that started failing on 2026-10-13 because it hard-coded an air date | — |

## A. Security

| ID | Severity | Root cause | Result |
|---|---|---|---|
| SEC-06 | Informational | `_isPublic` accepted `3fff::/20`, a documentation-only range (RFC 9637) | **Fixed.** Rejected and covered by a test; neighbouring addresses are still accepted |
| SEC-05 | Low | Plugin logos use `Image.network`, which skips the DNS-pinned destination check | **Not fixed.** A validated loader was built and passed its unit tests. Tested live, it loaded 42 and 39 of 54 real logos, against 54 of 54 with `Image.network`, so it was reverted |
| NET-02 (new) | Medium (reliability) | The pinned HTTP client connects to one resolved address and never fails over to the others | **Proposed, needs approval.** It touches every request, including provider fetches |

Earlier items still apply: SEC-02 is done, SEC-03 is partly done, SEC-01 is
an accepted risk, and SEC-04 is accepted by design.

Re-checked for this brief and found sound:

- **Secrets:** the TMDB key is the only client credential. It's documented as
  public; hiding it needs a backend, which isn't built (see
  [FRONTEND_BACKEND_AUDIT.md](FRONTEND_BACKEND_AUDIT.md)).
- **Requests:** timeouts and bounded retries with backoff, jitter and
  `Retry-After` on 429 and 503. Duplicate requests are merged.
- **Redirects and SSRF:** every hop is re-validated against public
  addresses.
- **Android:** cleartext is the platform default (no global override).
  `MainActivity` is the only exported activity, and it has no deep links.
  There's no WebView.
- **Logging:** release builds log nothing.

## B. UI

- **Contrast:** the player's error panel showed source details as 12 px text
  at `white38`, about 3.4:1 on black, below WCAG AA's 4.5:1. It's now
  `white54`, about 6:1 (`player_controls.dart`).
- **Checked, no change needed:**
  - Theme tokens: muted text on the background is about 8:1, and the accent
    `#FF4D6D` is unchanged.
  - `LiquidGlass` is the only `BackdropFilter`. It's tiered by device
    quality (no blur on the low tier) and uses grouped backdrops.
  - Reduced motion is respected in transitions, home, splash and the plugin
    library.
  - `shrinkWrap` lists appear only in short sheets and dialogs.
  - The one animated `Opacity` is a short entrance effect.
- **TV:** no TV code changed.
- **Not done:** a screen-by-screen visual review on devices. Spacing and
  radius changes without screenshots would be guesswork.

## C. Performance

- **Checked:**
  - Every `AnimationController`, `ScrollController`, `TextEditingController`,
    `FocusNode`, `Timer` and subscription is disposed or cancelled.
  - All 11 `Image.network` call sites decode at display size.
  - TV search is debounced. Pagination is bounded and ignored while a load is
    running.
  - Startup has its own budget test (`home_startup_budget_test.dart`).
- **Changed:** none. No profiling showed a bottleneck, and the brief rules
  out speculative optimization.
- **API requests:** one fewer TMDB request per playback start (see D),
  verified by test.
- **Not measured:** cold and warm start, frame times and memory on a device.
  No before/after numbers are claimed.

## D. Metadata

**Sources.** TMDB is the only catalog source. Subtitles come from
OpenSubtitles and subtitle add-ons. Providers receive the TMDB ID.

| Data | TMDB endpoint |
|---|---|
| Movie and series details, genres, runtime, rating, release dates, cast | `/movie/{id}` or `/tv/{id}` with `append_to_response=credits,external_ids` |
| Seasons | Same request as details (deduplicated in flight) |
| Episodes | `/tv/{id}/season/{n}` |
| Trending | `/trending/all/day` |
| New releases, movies, series | `/discover/movie`, `/discover/tv` |
| Search | `/search/multi`. People are dropped and records with invalid IDs skipped |
| IMDb ID (subtitles) | Details `external_ids` (new); `/find/{imdb}` for legacy items |
| Images | `image.tmdb.org` |

**What changed.** `resolveIds` used to request
`/{type}/{id}/external_ids` on every playback start. Details now append
`external_ids`, and `resolveIds` reads the same cached request.

- **Result:** opening a title and playing it makes one TMDB request instead
  of two, and the IMDb ID is ready immediately for subtitles.
- **Verified:**
  - Unit tests confirm one request for details, seasons and the IMDb ID.
  - Movies fall back to the top-level `imdb_id`, and nulls are tolerated.
  - Live TMDB: Breaking Bad returns `external_ids.imdb_id`, The Matrix has
    both fields, and the response grows by about 200 bytes.
- **Compatibility:** the details cache key changes, so each title is fetched
  once more after the update. Providers still get the same TMDB ID.

**Already correct.**

- **Records:** a malformed record is skipped instead of breaking the list,
  and lists are deduped.
- **Seasons:** season 0 (specials) is excluded from season lists.
- **Fallbacks:** a missing season doesn't block the other seasons' episodes.
  Stale cache is served when TMDB fails, and images fall back to
  placeholders.

## E. Regression validation

| Check | Result |
|---|---|
| `flutter analyze --no-fatal-infos lib test integration_test` | Exit 0; same 18 info-level notes as the baseline |
| `flutter test` | **403 / 403 passed** (400 existing + 3 new) |
| New: details, seasons and IMDb ID share one request | Pass |
| New: IMDb ID from the movie field, nulls tolerated | Pass |
| New: IPv6 documentation ranges rejected, neighbours accepted | Pass |
| Live TMDB `append_to_response=credits,external_ids` | Verified (2 titles) |
| Live logo comparison (led to reverting SEC-05) | Done: 54/54 old, 42 and 39/54 new |

**Fixed test:** `episode_selection_test.dart` "an unaired episode cannot be
chosen" hard-coded an air date of 2026-10-12, which made the episode count
as aired from 2026-10-13. It now uses a date one week after today.

**Not run:** device or emulator playback tests (movie or episode playback,
seeking, tracks, subtitles, TV remote) and performance profiling. No
playback, player or provider code changed.

## F. Modified files

| File | Why |
|---|---|
| `lib/src/services/tmdb_service.dart` | Details append `external_ids`; `resolveIds` reads the shared details request |
| `lib/src/services/network_target_policy.dart` | SEC-06: reject `3fff::/20` |
| `lib/src/widgets/player/player_controls.dart` | Contrast of the error panel's source details |
| `test/tmdb_scalability_test.dart` | Tests for the shared details request and IMDb ID fallback |
| `test/network_destination_validator_test.dart` | Test for the IPv6 documentation ranges |
| `test/episode_selection_test.dart` | Relative air date instead of one that has passed |
| `docs/security/SECURITY_AUDIT.md`, `SECURITY_REMEDIATION.md` | SEC-05, SEC-06 and NET-02 status |
| `docs/security/IMPROVEMENT_REPORT.md` | This report |

## Recommended next step

Approve NET-02 (fail over between validated addresses). It improves
reliability for provider, catalog and subtitle requests on hosts with
several addresses, and it unblocks SEC-05.
