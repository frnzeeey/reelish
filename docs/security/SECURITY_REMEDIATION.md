# Reelish security remediation plan

Date: 2026-10-11. Findings are described in
[SECURITY_AUDIT.md](SECURITY_AUDIT.md).

## What changed in this audit

The audit itself changed no code. After the report, you approved SEC-02 and
SEC-03, and these changes were made:

| Change | Files | Verification |
|---|---|---|
| SEC-02: workflow actions pinned to commit SHAs | `.github/workflows/release.yml` (4 lines), new `.github/dependabot.yml` | Each SHA was resolved from GitHub and equals the commit behind the action's major tag and latest release, so CI runs the same code. The next release run is the first end-to-end check |
| SEC-03, step 1: JitPack limited to the QuickJS runtime group | `third_party/flutter_js/android/build.gradle`, `REELISH_PATCH.md` | Obfuscated release builds with and without the change are byte-identical in `classes.dex` and every `.so` (arm64-v8a, armeabi-v7a) |

Still open:

- **SEC-03, step 2 (Gradle checksum file):** it must be generated on Linux
  to match CI.
- **SEC-05 and SEC-06:** they still need your approval.

## Baseline verification (run 2026-10-11, Windows, Flutter 3.44.8)

| Check | Result |
|---|---|
| `flutter analyze --no-fatal-infos lib test integration_test` | Exit 0, 18 info-level lints, no warnings or errors |
| `flutter test` | **400 / 400 passed** |
| `flutter pub outdated` | No discontinued or advisory-flagged packages |

No device or emulator testing was done, because no runtime code changed.

## Classification and proposed order

| # | ID | Risk class | Change | Needs | Regression tests to add or run |
|---|---|---|---|---|---|
| 1 | SEC-02 | High (release workflow) | Pin the four actions to commit SHAs and add `.github/dependabot.yml` for `github-actions` | **Done** | Workflow run on a test tag; the release job's existing APK checks |
| 2 | SEC-03 | High (build and release) | Restrict JitPack to `com.github.fast-development.*` (**done**), and commit Gradle `verification-metadata.xml` generated on Linux (**pending**) | Checksum file still to come | Clean CI build; compare `classes.dex` and native libraries byte for byte with the previous APK |
| 3 | SEC-05 | Medium (UI networking) | Load plugin logos through `NetworkDestinationValidator` (512 KiB cap) in a custom `ImageProvider` | Your approval of the approach | Widget tests for private-address rejection, public success and monogram fallback |
| 4 | SEC-06 | Low effect, but in the policy that guards stream preflight | Reject `3fff::/20` in `_isPublic` | Your approval | New case in the network policy tests; full suite; provider integration test on an emulator |
| — | SEC-01 | High (playback) | Local media proxy for native player requests | Separate design and approval; not planned | Playback matrix (HLS, DASH, MP4, torrents, subtitles) on phone and TV |
| — | SEC-04 | High (backend) | TMDB proxy | Only if TMDB throttles or revokes the key | — |
| — | SEC-07 | Low | Patch upgrades (`shared_preferences` 2.5.6 and transitive packages) | Do with a normal release, not as a security fix | Full suite plus a playback check |

Items 1 and 2 are the meaningful hardening work. They protect the signing
key and the APK supply chain and don't change the app itself.

## Rules these changes follow

- **Provider compatibility:** the `OnfeedFetch`, `OnfeedCancel` and
  `OnfeedTimer` channels, `getStreams`, manifests and script hashes stay
  untouched. None of the proposed changes affect providers.
- **Playback:** no throttling or queueing is added to stream resolution,
  segments or subtitles.
- **Signing:** keys are never rotated or replaced. SEC-02 and SEC-03 protect
  them without touching them.
- **No commits, pushes, tags or releases** without your explicit approval.
