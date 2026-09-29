# Reelish patch

This is a local copy of `flutter_js` 0.8.7. Reelish keeps the native runtime
and plugin platform implementations unchanged. The only code change is in
`lib/quickjs/ffi.dart`: memory-limit lookup first tries the package's bridge
symbol and falls back to QuickJS's exported `JS_SetMemoryLimit` API. The
Android `fastdev-jsruntimes-quickjs` 0.3.6 library exports the latter symbol,
which lets Reelish enforce the existing 64 MiB provider heap cap.

Keep this patch isolated when syncing upstream changes, and verify the native
symbol names for every Android runtime version before updating the binding.
