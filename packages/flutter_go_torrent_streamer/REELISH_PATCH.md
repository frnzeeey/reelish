# Reelish patch

A local copy of `flutter_go_torrent_streamer` 0.0.8 (MIT, Yan Ruibin), the
latest published version. The examples and Android unit tests are left out.
Two changes:

1. **No Kotlin Gradle Plugin.** `android/build.gradle` no longer applies
   `kotlin-android` (and drops the Kotlin-only test setup). Kotlin is then supplied by
   the build: while the app keeps `android.builtInKotlin=false` (the Flutter
   template default), the Flutter Gradle plugin applies Kotlin to plugins
   that do not; with built-in Kotlin, AGP compiles it. Flutter is removing
   support for plugins that apply the Kotlin Gradle Plugin themselves.
2. **16 KB page alignment.** The published `libtorrent_streamer.so` files
   have 4 KB ELF segment alignment, which devices with 16 KB memory pages
   cannot load (Android 16 falls back to page-size compatibility mode for
   the whole app). They were rebuilt from the unchanged `go/` sources
   (`go.mod`/`go.sum` as published) with Go 1.27.1 and NDK 28.2:

   ```sh
   cd go
   CGO_ENABLED=1 GOOS=android GOARCH=arm64 \
     CC=<ndk>/toolchains/llvm/prebuilt/<host>/bin/aarch64-linux-android24-clang \
     go build -buildmode=c-shared -trimpath \
       -ldflags="-s -w -extldflags=-Wl,-z,max-page-size=16384" \
       -o ../android/src/main/jniLibs/arm64-v8a/libtorrent_streamer.so .
   # GOARCH=amd64 with x86_64-linux-android24-clang for jniLibs/x86_64
   ```

   The exported C API (Init, Configure, StartStream, SelectFile, GetFiles,
   GetStreamStatus, DownloadFile, Pause/ResumeSession, GetAllSessions,
   StopClient, FreeString) is unchanged. Check alignment after any rebuild:
   `llvm-readelf -lW libtorrent_streamer.so` must show `0x4000` (or larger)
   for every LOAD segment.
