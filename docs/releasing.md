# Releasing Reelish (Android)

Releases are built and published only by
[`.github/workflows/release.yml`](../.github/workflows/release.yml), triggered
by pushing a `vMAJOR.MINOR.PATCH` tag. Never upload an APK to a GitHub Release
by hand.

```text
commit → push main → tag that commit → push tag
  → checkout exact tagged commit
  → validate: tag format, checkout == tag == event SHA, commit on origin/main,
              pubspec version == tag, release does not exist, newer than latest
  → check signing keystore + alias, write TMDB config
  → flutter clean → pub get (locked) → flutter build apk --release
  → verify APK: exists, non-empty, built this run, applicationId,
                versionName/versionCode, commit SHA embedded, signature
  → create GitHub Release for the tag with reelish.apk + reelish.apk.sha256
```

If any step fails, no release is created.

## Version

`version:` in `pubspec.yaml` is the single source of truth. It must be
`MAJOR.MINOR.PATCH+BUILD`, where the tag is `vMAJOR.MINOR.PATCH` and
`BUILD = MAJOR*1000000 + MINOR*1000 + PATCH` (the Android versionCode).

| Tag      | pubspec `version:` |
|----------|--------------------|
| `v1.2.0` | `1.2.0+1002000`    |
| `v1.2.1` | `1.2.1+1002001`    |
| `v2.0.0` | `2.0.0+2000000`    |

Each release needs a new version higher than the latest release. Tags are
never reused.

## Making a release

```bash
git switch main
git pull --ff-only origin main

# 1. Set the version in pubspec.yaml, e.g. version: 1.2.0+1002000
git add -A
git commit -m "Release v1.2.0"
git push origin main

# 2. Confirm the tree is clean and local main == origin/main
git status --short                         # must print nothing
git fetch origin
git rev-parse HEAD origin/main             # both lines must match

# 3. Tag that exact commit and push the tag
git tag -a v1.2.0 -m "Reelish v1.2.0"
git rev-parse HEAD 'v1.2.0^{commit}'       # both lines must match
git push origin v1.2.0

# 4. Watch the build
gh run watch
```

If a run fails, fix the cause on `main`, bump to the next patch version, and
tag again. Don't move or reuse a tag that has been pushed.

## Never release by hand

Don't build with `--build-name` / `--build-number` overrides and upload the
APK yourself. That is how v1.0.0 and v1.0.1 were published, and it splits the
version into two sources: `pubspec.yaml` said `1.2.0+1002000` while the
published APKs said `1.0.0` / `1.0.1+2`. Every build from source then
disagrees with what users have installed.

The in-app updater still protects users from a bad release: before opening
the installer it checks the APK's package, versionName (must equal the tag),
versionCode (must not be lower than the installed one) and signing key. A
mislabelled or wrongly signed APK is refused with an explanation. But the
workflow is what prevents such a release from existing.

## Troubleshooting

| Workflow error | Cause and fix |
|----------------|---------------|
| `Git tag version (vX) does not match application version (Y in pubspec.yaml)` | The tag and `pubspec.yaml` disagree. Set `version:` in `pubspec.yaml`, commit, and tag that commit. |
| `pubspec.yaml build number is N; version X requires +M` | Use the build number from the table above. |
| `The key '…' could not be unlocked with ONFEED_RELEASE_KEY_PASSWORD` | The key password secret is wrong (this is what failed the first v1.2.0 run: Gradle's `Cannot recover key`). Re-set `ONFEED_RELEASE_KEY_PASSWORD`. |
| `… is not newer than the latest release` | Pick a version above the current latest release. |
| `… which is not on origin/main` | Merge your branch into `main`, push `main`, then tag a `main` commit. |

## Verifying a release

- The release notes list the commit and APK SHA-256. The commit must equal
  `git rev-parse 'vX.Y.Z^{commit}'`.
- Check the APK against the published checksum:
  `gh release download vX.Y.Z -p 'reelish.apk*' && sha256sum -c reelish.apk.sha256`
- The release author is `github-actions[bot]`, and the notes link the
  workflow run that built it.
- In the app, **Settings > About** shows the tag and commit compiled into
  the build.

## Repository secrets

Under **Settings > Secrets and variables > Actions**:

| Secret | Value |
|--------|-------|
| `ONFEED_RELEASE_KEYSTORE_BASE64` | The upload keystore, base64-encoded |
| `ONFEED_RELEASE_STORE_PASSWORD`  | Keystore password |
| `ONFEED_RELEASE_KEY_ALIAS`       | Key alias inside the keystore |
| `ONFEED_RELEASE_KEY_PASSWORD`    | Key password |
| `ONFEED_TMDB_API_KEY`            | TMDB API key, written to `lib/tmdb_config.local.dart` |

```bash
keytool -list -keystore /path/to/onfeed-upload.jks   # shows the alias name
base64 -w0 /path/to/onfeed-upload.jks | gh secret set ONFEED_RELEASE_KEYSTORE_BASE64
gh secret set ONFEED_RELEASE_STORE_PASSWORD
gh secret set ONFEED_RELEASE_KEY_ALIAS
gh secret set ONFEED_RELEASE_KEY_PASSWORD
gh secret set ONFEED_TMDB_API_KEY
```

Always sign with the same key. Android won't update an installed app from an
APK signed with a different key.

## Toolchain

Flutter is pinned by `FLUTTER_VERSION` in the workflow. Keep it equal to the
local `flutter --version`. Java is Temurin 17. Only the Flutter SDK and pub
packages are cached; the APK is built fresh on every run.

## In-app updater

Android builds check `releases/latest` (the newest published, non-draft,
non-pre-release release) and offer it when its tag is newer than the
installed versionName. Versions are compared numerically, so `1.0.10` is
newer than `1.0.9`. Only the asset named exactly `reelish.apk`, downloaded
from that same release's `/releases/download/<tag>/` path, is ever used.
Don't rename that asset. The download is checked against the size and
SHA-256 digest GitHub reports for it, then the APK itself is checked as
described under "Never release by hand".

Checks run in the background after the home screen appears and on resume,
at most once every 6 hours; **Settings > About > Check for updates** always
asks GitHub. A failed check never blocks the app.
