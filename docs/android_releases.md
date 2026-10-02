# Android releases

Push a version tag such as `v1.0.5` to build and publish a signed universal APK
as `app-release.apk` on GitHub Releases. The GitHub Actions workflow uses the
same release keystore for every version so Android can install upgrades over
existing copies of the app.

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
