---
name: performance-memory
description: Measure and fix Reelish performance and memory problems — slow startup, scroll jank, excess rebuilds, image decode and cache growth, TMDB request bursts, QuickJS/isolate memory, player sessions that grow over time, and leaked listeners or timers. Use when something is slow, stutters or grows in memory, or before optimisation work.
---

# Performance and memory

## Purpose
Make a measured improvement, not a guessed one. Outcome: a before/after
number from the same measurement, and no behaviour change.

## Activation
- Slow launch or first rows, scrolling stutter, slow details or player
  open, high memory, memory that grows over a long session.
- Requests for "optimisation" or "memory profiling".

## Codebase context
- Timing: `PerfTimeline` (`lib/src/services/perf_timeline.dart`) logs
  `[Perf]` milestones in debug builds only (use DevTools in profile mode
  for real timings); budgets in
  `test/home_startup_budget_test.dart`; `integration_test/ui_perf_test.dart`.
- Requests: `TmdbService` limiter (`maxConcurrentRequests` 4), retries,
  disk cache with TTLs (`tmdb_response_cache.dart`); rows load as they near
  the screen (`PagedFeedController`, `DesktopPagedRow`);
  `tmdb_scalability_test` guards request counts.
- Images: decode at drawn size via `cacheWidth`; Windows buckets widths
  with `posterDecodeWidth()` so resizes reuse decodes.
- Rendering: `LiquidGlass` quality (low on TV), one fixed-size blur per
  panel on Windows; inactive shell pages are `Offstage` with `TickerMode`
  off.
- Providers: isolate per run, QuickJS 64 MiB limit, at most 2 runtimes
  (`ProviderExecutionScheduler`); script cache TTL 30 min.
- Long sessions: `player_long_session_test`, `windows_soak_test`.

## Workflow
1. **Measure first**, in profile mode (`flutter run --profile -d <device>`)
   with DevTools (performance timeline, memory, rebuild counts); `[Perf]`
   lines in a debug run help locate slow spans. Record the number and how
   it was taken.
2. **Find the cause**: rebuild scope (a `setState` or listener too high in
   the tree), synchronous work on the UI isolate, oversized image decodes,
   unbounded lists, repeated requests, layers (opacity, clip, blur),
   undisposed controllers/timers/subscriptions, work in offstage pages.
3. **Change one thing** at the narrowest layer: smaller rebuild boundary,
   `const`, lazy builders, `cacheWidth`, cancel/dispose, debounce, cache.
4. **Measure again** the same way; keep the change only if it helps.
5. Lock it in with a test where possible (request counts, build counts,
   budgets).

## Safety constraints
- Don't trade correctness for speed: keep request ordering, dedup, cache
  freshness and the provider limits.
- Don't raise QuickJS memory limits or concurrency to make providers
  faster.
- Don't remove animations users rely on; use reduced-motion paths instead.
- No new dependencies for profiling.

## Platform considerations
- TV hardware is the slowest target (low-end SoCs, often 32-bit): measure
  there or on a low-spec emulator for UI work.
- Windows: high-DPI decode sizes, window resizes, libmpv memory.
- Phone: battery and thermal; background isolates.

## Validation
- The before/after measurement, same device and mode.
- Related tests: `home_startup_budget_test`, `tmdb_scalability_test`,
  `paged_feed_controller_test`, `liquid_glass_test`, plus the feature's
  tests; long-session integration tests when the player is touched.
- Then `regression-check`.

## Completion criteria
A measured improvement (or a documented finding that nothing needed
changing), no new rebuild or memory growth, tests green.

## Reporting
Per CLAUDE.md § Reporting, plus: metric, method, device/mode, before and
after values. Say "not measured" rather than estimating.
