# Android releases

Push a version tag such as `v1.0.5` to build and publish a signed universal APK
as `reelish.apk` on GitHub Releases. The GitHub Actions workflow uses the
same release keystore for every version so Android can install upgrades over
existing copies of the app. Tags must use `vMAJOR.MINOR.PATCH`; minor and patch
numbers must each be below 1000 so the workflow can create an increasing
Android build number.

The workflow creates a public stable GitHub release when one does not exist. If
the tag already has a release, it replaces that release's APK only when the
release is neither a draft nor a prerelease. It then checks that the published
release contains a non-empty `reelish.apk`, which is the preferred asset used
by the Android in-app updater. The updater also accepts the previous
`app-release.apk` asset name so existing releases remain installable.

On Android, Reelish checks the latest stable release on startup and when the app
returns to the foreground, at most once every six hours. When the release tag is
newer than the installed app, the user can choose to download the APK and open
Android's installer. Android requires the user to confirm installation; the
app does not silently install updates. iOS and desktop builds do not use this
APK updater.

Before the first release, add these repository Actions secrets using the
keystore and alias that signed the existing public APKs:

- `ONFEED_RELEASE_KEYSTORE_BASE64`: base64-encoded JKS or PKCS12 keystore.
- `ONFEED_RELEASE_STORE_PASSWORD`
- `ONFEED_RELEASE_KEY_ALIAS`
- `ONFEED_RELEASE_KEY_PASSWORD`

Keep the keystore and passwords private and backed up. If the existing release
signing key is unavailable, Android will reject an in-place update signed with
a replacement key; users must uninstall the old app before installing a
replacement-signed build.
