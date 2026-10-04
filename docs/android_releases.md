# Android releases

## Publish a release

Android APK releases are built and published by the single workflow in
`.github/workflows/release.yml`. It runs only when a `vMAJOR.MINOR.PATCH` tag
is pushed. The workflow checks out and verifies the commit named by that tag,
cleans Flutter build outputs, builds a signed APK, stages that build as
`release/reelish.apk`, calculates and verifies its SHA-256 checksum, then
creates and publishes a GitHub Release with the APK and checksum.

For a new release, commit and push the intended source first, then create and
push a new tag that points to it:

```bash
git push origin HEAD
git tag v1.0.13
git push origin v1.0.13
```

The tag is the source of truth for both app version and release source. The
workflow derives the Flutter build name by removing the leading `v`. Android's
version code uses `MAJOR * 1,000,000 + MINOR * 1,000 + PATCH`, preserving the
existing scheme (for example, `v1.0.13` becomes version name `1.0.13` and build
number `1000013`). Minor and patch components must be below 1000, and the result
must fit Android's supported version-code range.

Each tag may have only one release. If a GitHub Release already exists for a
tag, the workflow fails rather than replacing its APK or other assets. If a
run fails after creating a draft, inspect and delete that draft in GitHub
before retrying the tag. A successfully published release includes both
`reelish.apk` and `reelish.apk.sha256`.

## Signing setup

The release uses the existing Android signing contract in
`android/app/build.gradle.kts`. Configure these repository Actions secrets
using the same production key that signed existing public APKs:

- `ONFEED_RELEASE_KEYSTORE_BASE64`: base64-encoded JKS or PKCS12 keystore.
- `ONFEED_RELEASE_STORE_PASSWORD`
- `ONFEED_RELEASE_KEY_ALIAS`
- `ONFEED_RELEASE_KEY_PASSWORD`

The workflow reconstructs the keystore in the runner's temporary directory,
passes its path and credentials to Gradle through the existing
`ONFEED_RELEASE_*` variables, verifies the resulting APK signature, and removes
the temporary keystore at the end of the job. It never uploads the keystore.
Do not commit the keystore or passwords. Keep the production key backed up; a
replacement key cannot update installations signed with the original key.

Generated APKs and the release staging directory are ignored by Git. The
workflow does not use previously committed APKs, cached APKs, or artifacts from
other workflow runs. `release/reelish.apk` is copied only from the canonical
`build/app/outputs/flutter-apk/app-release.apk` built during that same run.

The workflow uses Flutter's stable channel because the repository does not pin
a Flutter SDK version or use FVM. It does not cache build outputs.

On Android, Reelish checks the latest stable release on startup and when the app
returns to the foreground, at most once every six hours. When the release tag
is newer than the installed app, the user can choose to download the APK and
open Android's installer. Android requires the user to confirm installation;
the app does not silently install updates. iOS and desktop builds do not use
this APK updater.
