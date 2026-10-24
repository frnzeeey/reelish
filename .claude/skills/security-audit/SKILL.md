---
name: security-audit
description: Review or change Reelish code that touches a trust boundary — provider scripts and manifests, stream and subtitle URLs, the network destination policy, script-change approval, update downloads and verification, secrets (TMDB key, signing), logging and persisted data. Use for security reviews and before merging changes in those areas.
---

# Security audit

## Purpose
Keep untrusted content contained and secrets private. Outcome: findings
ranked by severity with evidence, fixes that tighten (never loosen) the
boundary, and tests for them.

## Activation
- A security review, or any change to provider execution, networking,
  update flows, logging, storage or build/signing configuration.

## Codebase context
- Trust model: `docs/streaming_security.md` (the model and the accepted
  risk SEC-01: native player requests after preflight). Its numeric limits
  can lag the code; read the constants in the services.
- Untrusted inputs: repository manifests, provider scripts, every URL and
  header they return, subtitle files, TMDB and GitHub responses.
- Controls (verify each still holds):
  - `NetworkDestinationValidator` (`network_target_policy.dart`): public
    addresses only, connection pinned to the validated IP.
  - `ProviderFetchBridge`: the only network surface for scripts; size,
    concurrency and timeout limits.
  - `ProviderRunner`: isolate per run, QuickJS memory limit and interrupt.
  - Script pinning by SHA-256 with "Allow update" approval
    (`ProviderPluginService.pendingScriptUpdates`).
  - Updates: SHA-256 per asset (`github_update_service.dart`); Windows
    installer Authenticode check (`windows/runner/app_update_channel.cpp`).
  - Secrets: `lib/tmdb_config.local.dart` is gitignored; `TmdbService`
    redacts the key from errors (`_redactedClientException`); CI writes the
    key and signing material from secrets.
  - Code protection: `docs/code_protection.md` (obfuscation, split debug
    info, encrypted symbols).
- History: `docs/security/` and `docs/production_*` record past findings.

## Workflow
1. Map the data flow for the change: source of the input, where it is
   parsed, where it reaches the network, file system, player or UI.
2. Check each control above on that path; read the tests that enforce it
   (`network_destination_validator_test`, `provider_fetch_bridge_test`,
   `provider_runner_test`, `github_update_check_test`,
   `windows_update_test`).
3. Look for: new network paths that skip the validator, logs of URLs,
   headers, tokens or keys, untrusted values used in file paths, commands
   or HTML, unbounded sizes or timeouts, weaker verification.
4. Rank findings (critical/high/medium/low) with file:line and a concrete
   exploit scenario; fix in place with a test.

## Safety constraints
- Never weaken a control to make a provider, stream or update work.
- Never print, copy or commit `lib/tmdb_config.local.dart`, keystores,
  passphrases or tokens; redact them in reports.
- Don't test against third-party services beyond normal use.

## Platform considerations
- Android: Media3 follows the platform cleartext policy; libmpv uses its
  own network stack (why SEC-01 is an accepted risk).
- Windows: DLL loading (QuickJS, libmpv) and the installer/updater run with
  user rights; the installer is per-user.
- TV shares Android's code and controls.

## Validation
The tests above, plus `regression-check`. For update changes, a real
update run on the affected platform where possible.

## Completion criteria
Every finding has evidence and a status (fixed with test, accepted with a
reason, or open); no control was weakened; no secret appears in the diff or
logs.

## Reporting
Per CLAUDE.md § Reporting, as findings: ID, severity, location, scenario,
status. Note any doc in `docs/` that is now out of date.
