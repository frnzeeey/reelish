---
name: provider-debugging
description: Debug third-party provider plugins in Reelish — repositories and manifests, script download and approval, the QuickJS runtime on isolates, the fetch/XHR bridge, cookies, timeouts and the network destination policy. Use when providers return no sources, fail on one platform, time out, or when changing provider execution code.
---

# Provider debugging

## Purpose
Explain why a provider returns nothing or fails, and fix Reelish's side of
it without loosening the sandbox. Outcome: the failing step identified, a
compatible fix, and evidence from a real provider run.

## Activation
- "No sources found", one provider works on Android but not Windows,
  provider timeouts, scripts that throw, repository install/update issues.
- Changes to `provider_runner.dart`, `provider_fetch_bridge.dart`,
  `provider_execution_scheduler.dart`, `provider_plugin_service.dart`,
  `provider_script_cache.dart`, `stream_discovery.dart`,
  `network_target_policy.dart`, or `third_party/flutter_js`.
- Playback failing *after* sources appear belongs to `playback-audit`.

## Codebase context
- `ProviderPluginService` (`lib/src/services/provider_plugin_service.dart`):
  repositories, enabled overrides, script hashes; changed scripts wait in
  `pendingScriptUpdates` until the user allows them. `discoverStreams`
  returns one shared `StreamDiscovery` per request key.
- `ProviderRunner` (`provider_runner.dart`): each run on `Isolate.run` with
  its own QuickJS runtime (`memoryLimit` 64 MiB, interrupt after 40 s,
  `getStreamsTimeout` 30 s, `hardTimeout` 45 s).
- `ProviderExecutionScheduler`: 4 concurrent workers, at most 2 live
  runtimes.
- `ProviderFetchBridge` (`provider_fetch_bridge.dart`): `fetch` and XHR on
  Dart HTTP, with a cookie jar; every destination passes
  `NetworkDestinationValidator` (public addresses only, connection pinned to
  the validated IP to prevent DNS rebinding).
- `ProviderScriptCache`: per-session script cache with TTL and a stale copy
  if a refresh fails.
- Windows: QuickJS comes from `quickjs_c_bridge.dll` with Reelish's
  memory-limit/interrupt exports (`third_party/flutter_js/REELISH_PATCH.md`,
  `tool/build_quickjs_bridge_windows.ps1`). `test/flutter_test_config.dart`
  preloads it for tests.
- Trust boundary and accepted risks: `docs/streaming_security.md`.

## Workflow
1. Reproduce with one provider. Note platform, title type (movie/series,
   season/episode) and whether the repository loaded.
2. Classify: manifest/install → script download/approval → runtime start
   (DLL, memory) → script error → network (blocked destination, headers,
   cookies, TLS) → timeout → zero results → results filtered out
   (`playback_source_policy.dart`, torrents disabled/unsupported).
3. Compare with another platform or a working provider. When comparing
   stream candidates, redact URLs, tokens and headers before logging or
   sharing them.
4. Fix the bridge or runner behaviour to match what browsers/Node do
   (e.g. dropping forbidden connection headers, tolerant cookie parsing),
   not by special-casing one provider.
5. Add a test in `provider_fetch_bridge_test` / `provider_runner_test`
   reproducing the script's pattern.

## Safety constraints
- Never bypass `NetworkDestinationValidator`, allow private/loopback
  destinations, raise memory limits or remove interrupts to make a
  provider work.
- Never auto-approve changed scripts or skip hash checks.
- Provider scripts and responses are untrusted: no `eval` of their output
  in Dart, no file-system access, no secrets in their environment.
- Don't modify a provider's script or repository; Reelish adapts its
  bridge, providers stay third-party.

## Platform considerations
- Android and Windows share the Dart bridge and policy; the QuickJS binary
  differs (Windows DLL patch). A Windows-only failure is often the runtime
  or DLL, not the script.
- Torrent sources are requested only where `TorrentSupport` allows (64-bit
  Android, P2P setting on).

## Validation
- `provider_runner_test`, `provider_fetch_bridge_test`,
  `provider_repository_state_test`, `network_destination_validator_test`,
  `stream_discovery_test`, `plugin_library_test`,
  `quickjs_windows_limits_test` (Windows).
- Real runtime: `flutter test integration_test/provider_runtime_test.dart -d windows`;
  on Android, a device run with a real repository.
- Then `regression-check`.

## Completion criteria
The failing step is named with evidence (redacted log or test), the fix is
covered by a test, and a real provider run on each affected platform
returns sources (or the remaining gap is stated).

## Reporting
Per CLAUDE.md § Reporting, plus: providers tested, before/after source
counts per platform, and any sandbox-relevant change called out explicitly.
