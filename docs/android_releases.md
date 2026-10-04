# Android releases

## Fresh release baseline

The GitHub release list and remote version tags have been cleared. The new
release line starts at `v1.0.0`, built from the repaired source on `main`.
This tag builds version `1.0.0` with Android build number `1000000`.

This is a fresh baseline for new installs. Reelish's in-app updater compares
version tags, and Android prevents installing a lower version code over a
higher one. Someone with an earlier `1.0.13` installation must uninstall it
before installing `1.0.0`; Android will erase that app's local data. To offer
existing users a normal update, publish a version higher than `1.0.13` instead.

## Root cause found

The previous release was built from the wrong Git ref, not from a stale APK
cache. At the time of the audit, GitHub `main` and the old `v1.0.13` tag pointed
to commit `1996509` (`improved liquid glass`). The newer, already-pushed Reelish
source was on `new_feature` at `d26a969`, with newer changes in the liquid-glass
and media-card widgets. The tag workflow checked out its tag correctly, so it
built the older source named by that tag.

Deleting a GitHub tag does not delete the same tag in local clones. The local
`v1.0.13` tag had remained at `1996509`; pushing it again recreated a release
from that old commit. Old local version tags have now been removed. Before
publishing, verify that the new tag resolves to the intended commit:

```bash
git rev-parse HEAD
git rev-parse v1.0.0
```

The workflow now records and checks out the tag commit, verifies it equals
`github.sha`, prints source-file checksums, and embeds the full commit SHA in
the APK. This proves what source was built; it cannot decide which branch the
maintainer intended to release, so create the tag from the intended branch.

## Release flow

The single production workflow is `.github/workflows/release.yml`. A pushed
`vMAJOR.MINOR.PATCH` tag triggers checkout of that exact tag. The job removes
old APK outputs, runs `flutter clean` and `flutter pub get`, then builds the
release APK with the tag, version, and full source SHA embedded. It verifies
the manifest version and application ID when Android inspection tools are
available, verifies the signature, copies only the canonical Flutter output
to `release/reelish.apk`, and requires the source and staged APK checksums to
match. It also lists all APKs before upload and publishes `build-info.txt` and
`reelish.apk.sha256` alongside the APK.

To release the repaired source:

```bash
git switch main
git push origin HEAD
git tag v1.0.0 HEAD
git push origin refs/tags/v1.0.0
```

The remote `v1.0.0` tag and release must be absent before the first push. For
later releases, use a new version tag. The workflow refuses to overwrite a
GitHub Release that already exists for a tag; a failed draft must be inspected
and deleted before retrying.

The tag is the version source. The build name is the tag without its leading
`v`. Android's version code remains
`MAJOR * 1,000,000 + MINOR * 1,000 + PATCH`; for example, `v1.0.0` builds as
version `1.0.0` and build number `1000000`. Minor and patch components must be
below 1000, and the result must fit Android's supported range.

## Build identity in Reelish

Open **Settings > About** in the installed app to see its version, Android
build number, release tag, and full source commit. The commit and tag are
compiled into the app with Dart defines. The release also contains
`build-info.txt` with the commit, tag, GitHub run, Flutter version, APK
metadata, build time, and checksum.

## Signing and Android configuration

The workflow uses the existing signing contract in
`android/app/build.gradle.kts`. Configure these repository Actions secrets with
the production signing key already used for Reelish:

- `ONFEED_RELEASE_KEYSTORE_BASE64`: base64-encoded JKS or PKCS12 keystore.
- `ONFEED_RELEASE_STORE_PASSWORD`
- `ONFEED_RELEASE_KEY_ALIAS`
- `ONFEED_RELEASE_KEY_PASSWORD`

The keystore is reconstructed in the runner's temporary directory, passed to
Gradle through the existing `ONFEED_RELEASE_*` variables, and removed at job
end. It is never uploaded. Keep the existing production key backed up; a
replacement key cannot update installations signed with the original key.

The Android application ID is currently `com.example.onfeed`; it is not
changed by the release workflow. There is one app entry point (`lib/main.dart`),
no product flavors or Git submodules, and the additional Flutter packages are
tracked local path dependencies. The repository does not pin Flutter with FVM
or a version file, so the workflow uses the stable channel. It does not cache
build outputs or use artifacts from another run. Generated APKs and the
`release/` staging directory are ignored by Git.

On Android, Reelish checks the latest stable release on startup and when the
app returns to the foreground, at most once every six hours. When the release
tag is newer than the installed app, the user can choose to download the APK
and open Android's installer. Android still asks the user to confirm
installation. iOS and desktop builds do not use this APK updater.
