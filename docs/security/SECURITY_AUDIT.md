# Reelish security audit

<!-- docs-check: historical -->
> **Historical record.** This report describes the codebase when it was written. Files, names and behaviour may have changed since; current documentation starts at [docs/README.md](../README.md).

Date: 2026-10-11. Scope: the whole repository at `073e761` (v1.10.1 plus
README changes): the Flutter app, Android host code, the vendored
`flutter_js` and torrent packages, and the release workflow. The website
(`reelishofficial.netlify.app`) was reviewed from the outside only.

Related reports:
[API_RATE_LIMIT_AUDIT.md](API_RATE_LIMIT_AUDIT.md) ·
[FRONTEND_BACKEND_AUDIT.md](FRONTEND_BACKEND_AUDIT.md) ·
[SECURITY_REMEDIATION.md](SECURITY_REMEDIATION.md). Earlier audits that
still apply: [../streaming_security.md](../streaming_security.md) (trust
boundary, SEC-01) and
[../production_readiness_audit.md](../production_readiness_audit.md).

## Summary

*Updated 2026-10-13: SEC-06 fixed, SEC-05 tried and reverted, NET-02
added.*

No critical or high-severity issues were found. The networking, provider
sandbox, update and storage layers already have the controls that this kind
of audit usually has to add. The open items are supply-chain hardening of the
build (two medium findings) and a few low or informational gaps.

| ID | Severity | Area | Finding | Status |
|---|---|---|---|---|
| SEC-01 | Medium (accepted) | Playback | Native player requests are not covered by the destination policy after preflight | Accepted risk, documented in `streaming_security.md` |
| SEC-02 | Medium | Supply chain | Workflow actions are pinned to movable tags inside the job that holds the signing secrets | **Fixed**: SHA pins plus Dependabot |
| SEC-03 | Medium | Supply chain | No Gradle dependency verification; JitPack is added as a repository for every project | **Partly fixed**: JitPack restricted; checksum verification pending |
| SEC-04 | Low | Credentials | The TMDB API key ships in the APK | Accepted by design, documented |
| SEC-05 | Low | Network | Provider logos load with `Image.network`, outside the DNS-pinned destination policy | Fix tried and reverted (logos failed to load); blocked by NET-02 |
| SEC-06 | Informational | Network | The IPv6 documentation prefix `3fff::/20` is treated as public | **Fixed** (2026-10-13) |
| NET-02 | Medium (reliability) | Network | The pinned client connects to one resolved address and never fails over to the others | Proposed, needs approval |
| SEC-07 | Informational | Dependencies | A few transitive packages are one patch or minor version behind | No action needed |

## Architecture and trust boundaries

- **No backend.** Reelish is a client-only app. It talks directly to TMDB,
  GitHub (catalog, plugin installs, releases), subtitle add-ons, provider
  hosts chosen by the user, and stream hosts returned by providers.
- **Provider code is untrusted.** Scripts run in QuickJS with a 64 MiB heap,
  a 20 s execution deadline enforced by an interrupt handler, and at most two
  runtimes alive at once (`provider_execution_scheduler.dart`). Their only
  path to the network is the `OnfeedFetch` channel, served by
  `ProviderFetchBridge`. They can't reach files, method channels or other
  providers.
- **Every app-initiated HTTP request** (TMDB, catalog, plugin install,
  subtitles, provider fetches, updater) goes through
  `NetworkDestinationValidator` (`network_target_policy.dart`). It:
  - accepts HTTPS only unless a caller allows otherwise, and rejects userinfo
    and odd ports;
  - rejects local hostnames (`localhost`, `.local`, `.internal`, `.lan`,
    `.home.arpa`, …) and numeric or hex IP spellings;
  - resolves DNS once, accepts only public addresses (IPv4 private and
    special ranges blocked; IPv6 limited to `2000::/3` minus special blocks;
    NAT64 `64:ff9b::/96` accepted only when it embeds a public IPv4 address),
    then pins the connection to those addresses so DNS rebinding can't
    change the target;
  - verifies TLS against the original hostname, bypasses system proxies,
    validates every redirect, caps headers (64 headers, 32 KiB) and caps
    bodies (2 MiB by default) with timeouts.
- **Media playback** (Media3, libmpv) fetches streams natively. URLs and
  headers are validated once before playback, but segment and redirect
  requests made by the native player are not re-checked. This is SEC-01,
  already documented and accepted.

## What was checked and found sound

| Area | Evidence |
|---|---|
| Provider fetch isolation | `provider_fetch_bridge.dart`:<br>• 4 concurrent requests, 2 MiB bodies, 64 timers per runtime.<br>• Cookie jar is per runtime, capped at 256 cookies, 256-byte names, 4 KiB values and 8 KiB `Cookie` headers.<br>• `Authorization` and `Cookie` are dropped on cross-origin redirects (lines 72-95). |
| Script integrity | Scripts are pinned by SHA-256 when first approved; changed code needs approval again (`provider_plugin_service.dart` ~745).<br>Installs are HTTPS-only, with at most 5 redirects, 4 MiB and 15-20 s timeouts. |
| TMDB key handling | The key is added only when the request is sent (`tmdb_service.dart:798`).<br>Cache keys use a hash of the key (`:794`).<br>`ClientException` messages and URIs are stripped of the key before they surface (`:1051-1063`). |
| Update integrity | The download is checked against GitHub's reported size and SHA-256, capped at 512 MiB.<br>Native checks run before the installer opens: package, versionName, versionCode and signing certificate.<br>The APK path must be inside `cache/updates` (`MainActivity.kt:217-218`), the only directory the `FileProvider` shares. |
| Android manifest | Not debuggable and no cleartext override.<br>Only `MainActivity` and the DUMP-protected `ProfileInstallReceiver` are exported; the `FileProvider` is not. |
| Backup and privacy | Backup includes only `FlutterSharedPreferences.xml` (both rule files).<br>Cached stream links, which can hold signed URLs and provider headers, live in the private `last_streams.v1.json`, which is excluded from backup (`storage_service.dart:362`). |
| Release logging | Every Dart `print` and `debugPrint` is behind `kDebugMode`, and playback logs never contain URLs or headers (`PlaybackLog`).<br>The vendored QuickJS runtime is gated on `dart.vm.product`.<br>No `android.util.Log` calls exist in app Kotlin code. |
| Catalog data | Catalog URLs (`manifestUrl`, `iconUrl`, …) must be HTTPS (`plugin_catalog.dart`).<br>Logos are additionally limited to dotted hostnames, never IP literals or `.local`. |
| Secrets in the repo | `lib/tmdb_config.local.dart` is gitignored and absent from history.<br>Signing keys and passwords exist only as Actions secrets. |
| Code protection | Dart obfuscation, R8 and encrypted debug symbols (see `../code_protection.md`). |
| Native binaries | `libtorrent_streamer.so` ships with its Go sources, `go.sum` and `build_android.ps1`, so it can be rebuilt.<br>The QuickJS Android runtime comes from a pinned Maven version (0.3.6). |

## Findings

### SEC-02 — Workflow actions are pinned to tags (Medium)

- **Where:** `.github/workflows/release.yml` lines 35, 116, 175 and 355:
  - `actions/checkout@v7`
  - `actions/setup-java@v6`
  - `subosito/flutter-action@v2`
  - `actions/upload-artifact@v7`
- **Evidence:** The release job has `contents: write` (line 32) and reads the
  keystore, the key passwords, the TMDB key and the symbols passphrase. A
  tag can be moved to different code. `subosito/flutter-action` is a
  third-party action.
- **Impact:** If any of these repositories is compromised, the next tagged
  release could leak the signing key or publish a tampered APK. The in-app
  updater accepts only the original signing certificate, but a stolen key
  defeats that.
- **Fix:** Pin each action to a full commit SHA, with the tag as a comment.
  Add Dependabot for `github-actions` so the pins stay current.
- **Compatibility risk:** None at runtime. It's a release-workflow change, so
  it needs approval.
- **Test:** Run the workflow on a throwaway tag, or with `workflow_dispatch`
  on a fork, and confirm every step resolves.
- **Status: fixed.** Each action is pinned to the commit its major tag
  pointed at on 2026-10-11, which is also its latest release:

  | Action | Pinned release |
  |---|---|
  | `actions/checkout` | v7.0.1 |
  | `actions/setup-java` | v6.0.1 |
  | `subosito/flutter-action` | v2.23.0 |
  | `actions/upload-artifact` | v7.0.2 |

  CI runs the same code as before. `.github/dependabot.yml` opens a monthly
  PR when a new release comes out. The next release run is the first
  end-to-end test of the pins.

### SEC-03 — No Gradle dependency verification; JitPack for every project (Medium)

- **Where:** `third_party/flutter_js/android/build.gradle` lines 5-10 add
  `maven { url 'https://jitpack.io' }` through `rootProject.allprojects`, and
  line 51 pulls
  `com.github.fast-development.android-js-runtimes:fastdev-jsruntimes-quickjs:0.3.6`
  from JitPack. There is no `android/gradle/verification-metadata.xml`.
- **Impact:** Gradle accepts whatever bytes a repository serves. JitPack
  builds artifacts from GitHub on demand, and since it's added for every
  project, any dependency name it can resolve could come from there. The
  risk is limited because `google()` and `mavenCentral()` are listed first,
  but a missing artifact would fall through to JitPack.
- **Fix:**
  1. Add a content filter so JitPack serves only
     `com.github.fast-development.*`.
  2. Generate `verification-metadata.xml` with
     `./gradlew --write-verification-metadata sha256` and commit it.
- **Compatibility risk:** Build only. The resulting APK is identical. A
  missing checksum fails the build, so the first CI run needs watching.
  Approval needed (build and release pipeline).
- **Test:** A clean CI build passes. `classes.dex` and native libraries match
  the previous build byte for byte.
- **Status: step 1 fixed.** JitPack is wrapped in `exclusiveContent` for
  `com.github.fast-development.android-js-runtimes`, whose artifact has no
  transitive dependencies.
  - Verified locally: obfuscated release APKs built with and without the
    change are byte-identical in `classes.dex` and every `.so`, for both
    ABIs.
- **Step 2 (checksum file) is pending.** The file has to list artifacts from
  the Linux CI build, including Linux-only tools such as AAPT2. A file
  generated on Windows would make the next release fail. Generate it on
  Linux (in CI or a container) and commit it before a release, then
  regenerate it after every Flutter or dependency upgrade.

### SEC-04 — TMDB API key is in the client (Low, accepted)

- **Where:** It's compiled from `lib/tmdb_config.local.dart` (written by CI
  from `ONFEED_TMDB_API_KEY`) and visible as a string in `libapp.so`.
- **Impact:** Anyone can extract the key and use it against TMDB's free,
  per-key rate limits. It grants no access to user data or paid resources.
- **Mitigations in place:**
  - The key is redacted from errors and cache keys.
  - Requests use a response cache, deduplication and a limiter of 4
    concurrent requests (see the rate-limit report).
  - The README and `code_protection.md` say to treat it as a public key.
- **Fix if abuse appears:** Put a small proxy in front of TMDB that holds the
  key (see FRONTEND_BACKEND_AUDIT.md). This is a backend change and needs
  approval. It isn't recommended now.

### SEC-05 — Provider logos load outside the destination policy (Low)

- **Where:** `lib/src/widgets/plugin_library/plugin_logo.dart:34`
  (`Image.network`) and `:56-64` (`isLoadableLogo`).
- **Evidence:** The URL check rejects IP literals and `.local` names but
  doesn't resolve DNS. A catalog `iconUrl` whose hostname resolves to a
  private address would make the device send a GET to that address.
- **Impact:** Low:
  - The catalog is curated in this repository (`assets/data/plugins.json`).
  - The request is a plain image GET whose response isn't readable.
  - Logos are decoded at display size, so the work is bounded.
  - This is at most a LAN ping or tracking pixel, not data access.
- **Fix:** An `ImageProvider` that fetches through
  `NetworkDestinationValidator.sendForBytes` with a small byte cap (for
  example 512 KiB).
- **Compatibility risk:** Low. It affects only the plugin library UI, not
  playback or providers.
- **Test:** A widget test that a logo resolving to a private address shows the
  monogram fallback, and that a public one still loads.
- **Status (2026-10-13): fix tried and reverted.** The loader built for this
  passed its unit tests, but against the real catalog it was clearly worse.
  Fetching the 54 `i.postimg.cc` logos six at a time:

  | Loader | Logos loaded | Time |
  |---|---|---|
  | `Image.network` | 54 of 54 | 40 s |
  | Validated loader | 42 and 39 of 54 (two runs) | 113-177 s |

  Every failure was a 20 s TCP connect timeout. The cause is NET-02. Fix
  NET-02 first, then this loader can be used.

### SEC-06 — `3fff::/20` accepted as a public IPv6 address (Informational)

- **Where:** `lib/src/services/network_target_policy.dart:264-280`.
- **Evidence:** RFC 9637 (2024) reserves `3fff::/20` for documentation, like
  `2001:db8::/32`, which is already rejected. It falls inside `2000::/3`, so
  it passes.
- **Impact:** Negligible. The range isn't routed on the internet, so a
  connection to it fails anyway.
- **Fix:** Reject `bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0x00`
  and add a case to the policy tests.
- **Compatibility risk:** None in practice. The range isn't routed on the
  internet, so no real stream host can be in it.
- **Status: fixed (2026-10-13).** `_isPublic` rejects `3fff::/20`. Test:
  `network_destination_validator_test.dart`, "rejects IPv6 documentation
  prefixes but not neighbours". `3fff:1000::1` and `2606:4700::1111` are
  still accepted.

### NET-02 — Pinned connections never fail over to another address (Medium, reliability)

- **Where:** `lib/src/services/network_target_policy.dart:87-97`
  (`createPinnedClient`, `connectionFactory`). This client serves TMDB,
  catalog, plugin install, subtitle and provider requests.
- **Evidence:** Each connection picks one validated address in rotation
  (`addresses[nextAddress++ % addresses.length]`) and waits for it alone.
  Dart's normal `HttpClient` moves on to the next address when one doesn't
  answer. Measured against a real host with three IPv4 addresses
  (`i.postimg.cc`, one of which answered in 9 s):
  - The pinned path failed 12-15 of 54 fetches on 20 s connect timeouts.
  - A plain `HttpClient` loaded all 54.
- **Impact:** When a host has a slow or unresponsive address (common behind
  CDNs and load balancers), requests that land on it stall for the connect
  timeout and then fail. Users would see slow or failed provider lookups,
  catalog loads or subtitle searches on some networks.
- **Fix:** In `connectionFactory`, try the validated addresses in turn: on a
  connect error or a short per-address timeout (for example 3 s), move to
  the next. The pin stays: only already-validated addresses are ever used.
- **Compatibility risk:** Medium. It changes how every app request connects,
  including provider fetches, but not which hosts are allowed. Needs your
  approval, plus a provider integration test on an emulator.
- **Test:**
  1. A unit test with a fake socket connector: the first address never
     connects and the second does. The request should succeed within the
     per-address timeout.
  2. Repeat the 54-logo comparison.

### SEC-07 — Minor dependency drift (Informational)

`flutter pub outdated` (2026-10-11):

- Direct dependencies: `shared_preferences` is at 2.5.5; 2.5.6 is available.
- Transitive dependencies are a patch or minor version behind: `archive`,
  `image`, `jni_flutter`, `video_player_avfoundation` and others.
- Pub reported no discontinued or advisory-flagged packages.

There's no security reason to upgrade now. Per the brief, upgrades should be
deliberate and come with a full test and playback check. The old Android
library versions in vendored packages (`flutter_js` compileSdk 34, the
torrent package's `androidx.core` 1.10.1) don't affect the app's targetSdk
36 manifest.

## Not tested

- No penetration testing against production services, as the brief
  requires.
- The website was checked from the outside. Its source isn't in this
  repository.
- No device testing was done for this audit. The code wasn't changed (see
  SECURITY_REMEDIATION.md).
