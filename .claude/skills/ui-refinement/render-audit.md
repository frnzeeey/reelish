# Rendering screens for a visual audit

Widget tests can render the real app to PNG, which is how Reelish's Windows
layouts were audited. Do this in a **scratch** test outside `test/` (for
example `build/_render/audit_test.dart`, which is gitignored) and delete it
when done. Never screen-capture the user's desktop instead.

## Ingredients

1. **Real fonts.** Before rendering, load Montserrat from
   `assets/fonts/Montserrat-*.ttf` with `FontLoader('Montserrat')`, and the
   icon font `MaterialSymbolsRounded.ttf` from the `material_symbols_icons`
   package (`.dart_tool/package_config.json` gives its path) under the
   family `packages/material_symbols_icons/MaterialSymbolsRounded`.
2. **The real Home.** Pump `HomeScreen` with `GlassTheme.dark`, a
   `TmdbService(testClient: MockClient(...), network:
   NetworkDestinationValidator(lookup: (_) async => [InternetAddress('8.8.8.8')]),
   cache: TmdbResponseCache(directory: <temp dir>), wait: (_) async {})`, as
   `test/desktop_home_top_ten_test.dart` does. Use
   `variant: TargetPlatformVariant.only(TargetPlatform.windows)` for the
   Windows UI; `DeviceCapabilities.debugOverride` for TV.
3. **Artwork.** `Image.network` uses `dart:io` `HttpClient`; set
   `HttpOverrides.global` to a fake client that serves PNG bytes generated
   in `setUpAll` (draw gradients with `PictureRecorder`, `toImage`,
   `toByteData(png)`). Generating images inside the fake-async test zone
   hangs.
4. **Library data.** Seed with `StorageService().saveProgress(...)` /
   `toggleFavorite(...)` inside `tester.runAsync`, after
   `SharedPreferences.setMockInitialValues({})` and
   `StorageService.debugResetWrites()`.
5. **Settling.** Alternate `tester.runAsync(() => Future.delayed(20 ms))`
   with `tester.pump(20 ms)`; `pumpAndSettle` never settles with timers.
6. **Capture.** Wrap the app in a keyed `RepaintBoundary`, then in
   `runAsync`: `boundary.toImage()` → `toByteData(format: png)` → write to
   the scratchpad and view the PNG.

## Sizes worth rendering (Windows)

1024×640, 1280×720, 1366×768, 1920×1080, 2560×1440, and 3840×2160 at
`devicePixelRatio` 2. Content width is the window minus the sidebar
(80 px compact; 248 px when pinned open).

## Reading the results

Fake data produces fake defects (repeated names, "Untitled" search results,
odd runtimes). Report only issues caused by the UI.
