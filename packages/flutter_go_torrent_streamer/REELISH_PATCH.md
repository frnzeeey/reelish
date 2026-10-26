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
3. **Windows x64.** The same engine and C API as a DLL, loaded with
   `dart:ffi` (no method channel: Android's foreground service has no
   Windows counterpart).
   - `go/`: the logcat call moved from `main.go` into `log_android.go`
     (`//go:build android`, the same code); `log_other.go` writes to stderr
     elsewhere. Android builds compile what they did before; the shipped
     `.so` files were not rebuilt for this.
   - `go/build_windows.ps1` builds `windows/shared/torrent_streamer.dll`
     with Go and llvm-mingw (UCRT), checks the exports, and refuses a DLL
     that imports anything Windows does not ship (MinGW runtime DLLs).
   - `windows/CMakeLists.txt` (an FFI plugin, `ffiPlugin: true` in
     `pubspec.yaml`) bundles the DLL next to `Reelish.exe` when it exists.
   - `lib/flutter_go_torrent_streamer.dart`: Windows opens the DLL by full
     path beside the executable; `isSupported` reports whether the engine
     loads with its exports; `engineDirectory()` is the folder `Init` gets:
     on Windows `%LOCALAPPDATA%\<company>\<app>\torrent_engine`, never the
     user's Documents (Android keeps the documents directory).

   The committed DLL was built with Go 1.27.3 and llvm-mingw 20261020
   (UCRT); the build is reproducible (`-trimpath`, empty build ID, no link
   timestamp), so the same toolchain gives SHA-256
   `372207fe7eca4a60a7f1c7b2c55843498ab7228dfd3d718e80aa55d45769e9de`.
   It imports only `kernel32`, `ws2_32` and the Universal CRT
   (`api-ms-win-crt-*`, part of Windows 10/11); C and C++ runtimes are
   linked in (`-static`).

   Build and install (prints the SHA-256 to put in
   `.github/workflows/release-windows.yml` `TORRENT_STREAMER_SHA256`):

   ```powershell
   powershell -ExecutionPolicy Bypass -File packages\flutter_go_torrent_streamer\go\build_windows.ps1 `
     -Go <go>\bin\go.exe -LlvmMingw <llvm-mingw-ucrt-x86_64> -Install
   ```
