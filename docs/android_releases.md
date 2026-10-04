# Android releases

## How releases are made

`.github/workflows/release.yml` is the only supported way to publish a Reelish
APK. Pushing a `vMAJOR.MINOR.PATCH` tag runs it:

```text
push main → tag that main commit → push tag
  → checkout exact tag (fresh runner, no caches)
  → verify: checkout == tag == event SHA, clean tree, commit is on origin/main,
            tag is the highest version, no release exists yet
  → restore signing keystore and TMDB config from secrets
  → flutter build apk (version from tag, commit SHA compiled in)
  → verify APK: built this run, applicationId, versionName/versionCode,
                commit SHA embedded, signature
  → draft release with reelish.apk, reelish.apk.sha256, build-info.txt
  → re-download uploaded APK, compare SHA-256 → publish as Latest
```

Any failed check stops the job before anything is published. Never upload an
APK to a GitHub Release by hand: a manual upload bypasses every check above.

## Root cause of the stale v1.0.0 release (2026-10-04)

The `v1.0.0` GitHub Release was not built by CI. Both workflow runs for the
`v1.0.0`/`v1.0.1` tags failed at the signing step because the repository had
no `ONFEED_RELEASE_*` Actions secrets. The release was then published by hand
with a local file, `build/app/outputs/flutter-apk/reelish.apk`, built at 09:00
that morning before the `ui update` commit and everything after it. The
published asset and that local file have the same SHA-256
(`e8550e01…c29d42b`), and the APK reports `versionName 1.0.12`,
`versionCode 1000012` with no embedded commit or tag. With the signing secrets added, the first CI
build (`v1.1.0`) then failed to compile because the ignored
`lib/tmdb_config.local.dart` did not exist on the runner; CI now generates it
from `ONFEED_TMDB_API_KEY`.

An earlier incident had a different cause: the old `v1.0.13` tag pointed at a
`main` commit, while the newer source sat only on `new_feature`. The workflow
now refuses tags whose commit is not on `origin/main`.

## Releasing

Set up the signing secrets once (see below), then:

```bash
git switch main
git pull --ff-only
git status                      # must be clean; commit everything first
git push origin main

git tag -a v1.1.0 -m "Reelish v1.1.0"
git rev-parse HEAD v1.1.0^{commit}   # both lines must be identical
git push origin v1.1.0
```

Watch it with `gh run watch`. Each release needs a new version higher than
every existing tag; the workflow refuses an existing or lower version, and it
refuses to replace an existing GitHub Release. If a run fails after creating
a draft, inspect and delete the draft (`gh release delete vX.Y.Z`) before
re-running the job.

Android's version code is `MAJOR * 1,000,000 + MINOR * 1,000 + PATCH`; for
example, `v1.1.0` builds as `1.1.0` with code `1001000`. Minor and patch must
be below 1000. The `version:` in `pubspec.yaml` is only used for local builds.

## Verifying a release

- `build-info.txt` on the release lists the tag, commit, version, APK SHA-256,
  Flutter version, and workflow run link. The commit must equal
  `git rev-parse vX.Y.Z^{commit}`.
- Check the downloaded APK against the published checksum:
  `gh release download vX.Y.Z -p 'reelish.apk*' && sha256sum -c reelish.apk.sha256`
- In the installed app, **Settings > About** shows the version, tag and full
  commit, which are compiled in at build time.
- The release's author is `github-actions[bot]`. A release authored by a person
  was not produced by this workflow.

## Signing secrets

The workflow uses the signing contract in `android/app/build.gradle.kts`.
Add these under **Settings > Secrets and variables > Actions**, using the
production key that signed earlier Reelish releases:

- `ONFEED_RELEASE_KEYSTORE_BASE64`: the keystore file, base64-encoded.
- `ONFEED_RELEASE_STORE_PASSWORD`
- `ONFEED_RELEASE_KEY_ALIAS`
- `ONFEED_RELEASE_KEY_PASSWORD`
- `ONFEED_TMDB_API_KEY`: the TMDB key. CI writes it to the ignored
  `lib/tmdb_config.local.dart` (see README), which the app needs to compile.

With the GitHub CLI, from a local shell where the keystore exists:

```bash
base64 -w0 /path/to/onfeed-upload.jks | gh secret set ONFEED_RELEASE_KEYSTORE_BASE64
gh secret set ONFEED_RELEASE_STORE_PASSWORD   # prompts for the value
gh secret set ONFEED_RELEASE_KEY_ALIAS
gh secret set ONFEED_RELEASE_KEY_PASSWORD
gh secret set ONFEED_TMDB_API_KEY
gh secret list                                # all five must be listed
```

The keystore is written to the runner's temp directory, passed to Gradle via
`ONFEED_RELEASE_STORE_FILE`, and deleted at job end. It is never uploaded.
Keep the key backed up; installs signed with it cannot be updated by an APK
signed with a different key.

## Toolchain and build environment

Flutter is pinned by `FLUTTER_VERSION` in the workflow (currently `3.44.8`);
update it when the local Flutter version changes. Java is Temurin 17. The
workflow restores no caches and downloads no artifacts from other runs, so
every APK comes from a fresh build. It checks that no APK exists before
building. The Android application ID is `com.example.onfeed`.

## In-app updater

On Android, Reelish checks `releases/latest` on startup and when the app
returns to the foreground, at most every six hours, and offers `reelish.apk`
when the release tag is newer than the installed version. Android still asks
the user to confirm installation and refuses an APK with a lower version code
than the installed one.
