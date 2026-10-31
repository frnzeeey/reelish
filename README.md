# Reelish

[![Get on GitHub](https://img.shields.io/badge/Get%20on-GitHub-181717?logo=github&logoColor=white)](https://github.com/frnzeeey/reelish)

Reelish is an open-source Flutter app for discovering movies and TV series and watching them with providers you choose, on your own or together with friends. Sign in with Trakt, browse TMDB-powered catalogs, find a title, search enabled providers for streams, and play a source in the built-in player. Reelish was previously named Onfeed in parts of the codebase.

**Developers:** the technical documentation starts at [docs/README.md](docs/README.md). See also [For developers](#for-developers) below and [CONTRIBUTING.md](CONTRIBUTING.md).

## Features

- Sign in with your Trakt account: in the browser on phones and Windows, or with a short code on a TV.
- Browse popular and trending movies and series, search titles, and view recommendations, new releases, and title details.
- Keep a library of favorites, recently watched titles, and playback progress so you can continue where you left off. My list can stay in sync with your Trakt watchlist across your devices.
- **Watch Party:** watch a movie or episode in sync with up to five people. Start a party from a title, share its 8-digit code, and everyone plays from their own providers while the host's play, pause, seek and episode changes are followed.
- Get notified when a new episode of a series on My list, one you're watching, or a popular series comes out.
- Set a display name and an avatar (an illustrated preset or a photo that stays on the device), and on Android choose the app icon's color.
- Browse a built-in library of community provider repositories, search and filter it by language or content type, and install a repository from its details page.
- Install provider repositories from a manifest URL, enable the providers you want, and choose which providers can be used for playback.
- Play supported direct streams, with source selection, resume progress, playback controls, and configurable subtitles.
- On Android, allow compatible providers to return torrent sources for P2P playback.
- Use Reelish on Android TV and Google TV with an interface built for the remote, from the same APK as phones and tablets.
- Run Reelish on Windows 10 and 11 as a desktop app with its own desktop interface, mouse and keyboard controls, and fullscreen playback.
- Choose an accent color (the app logo follows it) and customize playback, subtitle appearance, language preferences, and gestures.
- Read the privacy policy, terms of use, and third-party credits in the app.

## Images

| Home | Title details |
|:---:|:---:|
| <img src="assets/images/reelish-1.png" alt="Reelish home screen showing featured titles and recommendations" width="360"> | <img src="assets/images/reelish-2.png" alt="Reelish title details screen with synopsis, genres, and cast" width="360"> |

| Provider plugins | Personal library |
|:---:|:---:|
| <img src="assets/images/reelish-3.png" alt="Reelish provider plugins screen" width="360"> | <img src="assets/images/reelish-4.png" alt="Reelish personal library with continue watching, favorites, and history" width="360"> |

## Providers

Open **Plugins** and choose **Browse the library** to find a provider repository, or paste a provider manifest URL (or a supported GitHub repository/file link) with the link button. Review the repository's providers, then enable the ones you want. Provider repositories and enabled-provider choices are saved on the device. Reelish runs provider scripts in a constrained JavaScript runtime and requests streams when you open a title; providers do not populate the catalog.

Providers are third-party code and services. Install repositories only from publishers you trust. Reelish does not supply or host streams. Provider availability and compatibility depend on each provider and its sources.

### Plugin library

The library lists repositories from a community-maintained catalog curated by wolf knight. Listings are not verified or endorsed by Reelish; repository names, descriptions, and manifests belong to their authors.

The app downloads the catalog from [`assets/data/plugins.json`](assets/data/plugins.json) on this repository's `main` branch, checks for a newer copy at most every six hours (or when you pull to refresh), and keeps the last copy on the device. The same file is bundled with each release as an offline fallback. To update the catalog without an app release, regenerate the file and commit it:

```sh
dart run tool/generate_plugin_catalog.dart
```

Reelish is an independent project. It is not affiliated with, endorsed by, or sponsored by Stremio, CloudStream, or OpenSubtitles; their names are used only to describe compatible formats and services.

## Playback and subtitles

Choose a source from the title's stream list to start playback. Reelish supports direct HTTP(S) streams accepted by the platform player. Android also supports compatible torrent/P2P sources returned by providers; this depends on the provider and torrent source. Other platforms do not offer Reelish's torrent playback.

The player supports external SRT and WebVTT subtitles, with language selection and display settings. Reelish can search OpenSubtitles for subtitles. Stream and subtitle availability, formats, and behavior vary by source and platform.

## Watch Party

Watch the same movie or episode in sync with friends, each on their own device.

1. On a title's details page choose **Watch together** (a series asks which episode), set who can control playback and whether to wait for everyone, and create the party.
2. Share the 8-digit code from the waiting room (**Copy code** or **Copy invitation**).
3. Friends choose **Join a watch party** in Settings (or the button in the phone's Home header), enter or paste the code, and see the title, host, and number of people before joining.
4. The host chooses **Start watching**. Each person's player finds a source with their own providers; the party starts once everyone is ready.

While watching, the host's play, pause, seek and episode changes are followed by everyone, and players that drift apart catch up on their own. The waiting room shows who has joined and whether their player is ready; the host can let others control playback, hand over hosting, or remove someone. Parties hold up to five people and end when the host ends them, after everyone has left for a while, or after 12 hours.

Each person needs a provider that can play the title. Different releases of the same title (an extra intro, a different cut) can leave pictures a few seconds apart even when the timelines match. Video never passes through Reelish's servers: only the title, the room's playback position, and who is in the room are shared.

## Android TV and Google TV

<p align="center">
  <img src="assets/images/TV.png" alt="Reelish on Android TV: the side menu, a large preview of the featured title, and a row of movie posters" width="720">
</p>

The same APK runs on phones, tablets, Android TV, and Google TV. Reelish checks at startup whether it's on a TV and, if so, shows an interface built for the remote:

- A side menu for Home, Movies, Series, Search, My library, Plugins, and Settings.
- A large preview of the focused title above rows of posters; each row remembers where you left off.
- Details pages with seasons and episodes you can browse with the remote, and search with the TV's keyboard.
- Remote playback controls: play/pause, fast forward, rewind, next episode, captions, and D-pad seeking. Back while watching shows the controls first instead of leaving.

Phones and tablets keep the touch interface.

### Installing on a TV

Android TV has no browser for downloads, so install the APK once by sideloading it. The easiest way is the **Downloader** app from the Play Store: enter the link below, install, and allow installs from Downloader when Android asks.

```
https://github.com/frnzeeey/reelish/releases/latest/download/reelish.apk
```

From a computer, enable **USB debugging** (or **Network debugging**) in the TV's Developer options, then run `adb connect <tv-ip>:5555` and `adb install reelish.apk`.

After the first install, Reelish updates itself like on a phone. The first time you update, allow **Install unknown apps** for Reelish in the TV's settings.

Details on TV detection, remote navigation, and known limitations are in [docs/android_tv.md](docs/android_tv.md).

## Windows

Download `Reelish-Setup-x64.exe` from the [latest release](https://github.com/frnzeeey/reelish/releases/latest) and run it; it installs for your user only, without administrator rights, and installed copies update themselves from **Settings > About**. A portable `Reelish-Windows-x64.zip` is also available: extract it and run `Reelish\Reelish.exe`. The app is not code-signed yet, so SmartScreen may ask before the first launch.

Windows has its own desktop interface with a collapsible side menu and mouse and keyboard controls: click or use the keyboard, Ctrl+F to search, Escape or Backspace to go back, F11 for fullscreen, and Space, Left/Right, Up/Down (volume), M and F in the player. P2P playback and the app icon choice are Android-only.

Details, building from source, and the release workflow are in [docs/windows.md](docs/windows.md).

## Accounts and the Reelish API

Reelish uses your [Trakt](https://trakt.tv/) account to sign in; there are no Reelish passwords. Signing in goes through the Reelish API, a Cloudflare Worker in [`backend/`](backend/) that:

- signs you in with Trakt and keeps your Trakt tokens encrypted on the server, so they never sit on the device;
- reaches [The Movie Database (TMDB)](https://www.themoviedb.org/) on the app's behalf through an allowlisted gateway, so no TMDB key ships in any build;
- syncs My list with your Trakt watchlist, checks for new episodes, and hosts Watch Party rooms.

The catalog needs a signed-in account. This product uses the TMDB API but is not endorsed or certified by TMDB. Credits and third-party notices are available in Reelish under **Settings > Credits**. How the API works, and how to run your own, is in [docs/backend/README.md](docs/backend/README.md) and [docs/backend/operations.md](docs/backend/operations.md).

## Run from source

Install Flutter for your target platform, then run the app against a deployed Reelish API (your own, or a staging deployment you have access to) by passing its HTTPS address:

```sh
flutter pub get
flutter run --dart-define=REELISH_API_URL=https://your-reelish-api.example
```

Without `REELISH_API_URL` the app starts but cannot sign in or load the catalog. The API itself is tested with `cd backend && npm ci && npm test`.

To try the TV interface on a phone or a regular emulator, use `flutter run --dart-define=REELISH_FORCE_TV=true` (arrow keys and Enter act as the remote). On an Android TV emulator, see the testing notes in [docs/android_tv.md](docs/android_tv.md).

## Android releases

Release builds are published on [GitHub Releases](https://github.com/frnzeeey/reelish/releases). One `reelish.apk` covers phones, tablets, and TVs. Android can check for a newer stable release and offer to download its APK; installation is confirmed through Android's package installer. See [docs/releasing.md](docs/releasing.md) for how releases are made.

## Privacy and terms

On first launch, read and accept the privacy policy and terms of use shown in the app. Favorites, playback history, settings, provider choices, and your profile name and avatar are stored on the device. Signing in creates an account on the Reelish API that holds your Trakt username and ID, your signed-in devices, and your encrypted Trakt tokens; you can sign out everywhere or delete the account from **Settings > Profile and account**. My list sync reads and edits your Trakt watchlist. Catalog requests go to TMDB through the Reelish API. A watch party shares the title, the playback position, and each person's display name and preset avatar with the people in it, for as long as the party lasts. Provider publishers, stream hosts, and subtitle services receive requests needed for the features you use. The plugin library downloads its catalog from GitHub and loads provider logos from their listed hosts, and Android and Windows may contact GitHub for update checks. See the in-app **Privacy policy** and **Terms of use** for details.

## For developers

**Supported platforms:** Android phones and tablets, Android TV and Google TV (one APK), and Windows 10 and 11. The `ios/`, `linux/`, `macos/` and `web/` folders are generated by Flutter and are not shipped.

**Technology:** Flutter and Dart; the Reelish API on Cloudflare Workers (TypeScript) with D1 for accounts and sessions and a SQLite-backed Durable Object per Watch Party room (WebSocket Hibernation API, within the Workers Free plan); Trakt for sign-in and watchlist sync; TMDB for metadata through the API's gateway; provider scripts run in QuickJS (vendored `flutter_js`) on background isolates; playback through `package:video_player` with Media3 on Android and libmpv (media_kit) on Android and Windows; a Go torrent streamer on Android; local storage in SharedPreferences and secure storage for sessions.

**Repository layout:**

| Path | Contents |
|---|---|
| `lib/` | The app: `main.dart`, then `src/` with services, models, view models, the account and Watch Party clients (`account/`, `watch_party/`), the phone (`screens/`, `widgets/`), TV (`screens/tv/`, `widgets/tv/`) and Windows (`desktop/`) interfaces, and the shared player (`widgets/player/`) |
| `backend/` | The Reelish API: a Cloudflare Worker (TypeScript), D1 migrations, the Watch Party room, and its tests |
| `test/`, `integration_test/` | Unit and widget tests; tests on devices and Windows |
| `android/`, `windows/` | Native projects (Android activity; Windows runner and installer) |
| `packages/`, `third_party/` | Vendored native packages (libmpv bridge, torrent streamer, QuickJS) |
| `tool/` | Plugin catalog generator, Windows QuickJS build script, documentation tool |
| `docs/` | Technical documentation |

**Build and test:**

```sh
flutter pub get
flutter analyze lib test integration_test test_driver
flutter test
flutter build apk --profile --dart-define=REELISH_API_URL=https://...       # Android
flutter build windows --release --dart-define=REELISH_API_URL=https://...   # Windows
cd backend && npm ci && npm test                                            # Reelish API
```

**Documentation:** [docs/README.md](docs/README.md) is the index: architecture, a feature-to-code map, playback and provider internals, platform guides, and A–Z references to every file, class and function. Start with [onboarding](docs/development/onboarding.md).

**Contributing:** read [CONTRIBUTING.md](CONTRIBUTING.md) and [CLAUDE.md](CLAUDE.md).
