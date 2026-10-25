# Google TV

Google TV is Android TV with Google's launcher. Reelish treats them as one
platform: the same APK, the same detection (`UI_MODE_TYPE_TELEVISION` or
the `leanback` feature) and the same code under
[`lib/src/screens/tv/`](../../lib/src/screens/tv) and
[`lib/src/widgets/tv/`](../../lib/src/widgets/tv). There is no Google
TV-specific code path.

Everything on the [Android TV page](android-tv.md) applies. Points that
matter most on Google TV devices:

- **32-bit devices.** Chromecast with Google TV and similar devices run
  32-bit Android on 64-bit chips. `TorrentSupport.available` is false there,
  so torrent sources are neither requested nor offered.
- **Launcher entry.** The manifest's `LEANBACK_LAUNCHER` intent filter and
  `android:banner` make Reelish appear on the TV home screen
  ([`AndroidManifest.xml`](../../android/app/src/main/AndroidManifest.xml)).
- **Installing.** Sideload the APK once (for example with the Downloader
  app); after that, the in-app updater works as on phones. Steps are in the
  root [README](../../README.md#installing-on-a-tv).
