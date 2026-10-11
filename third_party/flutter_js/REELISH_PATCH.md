# Reelish patch

This is a local copy of `flutter_js` 0.8.7. Reelish keeps the native runtime
and plugin platform implementations unchanged. The only code change is in
`lib/quickjs/ffi.dart`: memory-limit lookup first tries the package's bridge
symbol and falls back to QuickJS's exported `JS_SetMemoryLimit` API. The
Android `fastdev-jsruntimes-quickjs` 0.3.6 library exports the latter symbol,
which lets Reelish enforce the existing 64 MiB provider heap cap.

Keep this patch isolated when syncing upstream changes, and verify the native
symbol names for every Android runtime version before updating the binding.

## Script interrupt deadline

`lib/quickjs/ffi.dart` also looks up QuickJS's public `JS_SetInterruptHandler`
and installs a Dart callback that stops a script once a deadline passes
(`QuickJsRuntime2.setInterruptDeadline`). The runtime's `timeout` argument
alone does not stop synchronous code such as `while (true) {}` on every
build, and a script stuck there never returns. The handler replaces any
handler the native bridge installed. Builds that do not export the symbol
(the Windows test DLL) keep their previous behaviour; the lookup returns null.

## No runtime diagnostics in release logs

`lib/quickjs/quickjs_runtime2.dart` printed JavaScript exceptions, unhandled
promise rejections and channel errors with `print`, which also runs in
release builds. Provider error messages can quote request URLs, so these now
go through `_log`, which prints only when the build is not a release build
(`dart.vm.product`). Debug and profile builds log exactly as before. No
behaviour other than logging changes.

## Obfuscation note

`_DartFunction.invoke` (`lib/quickjs/object.dart`) decides whether to pass
`thisVal` by matching `thisVal` in the function's `runtimeType` string, which
Dart obfuscation can rename. Reelish registers no callback with a `thisVal`
parameter (its bridge uses `sendMessage` channels with JSON payloads), so the
check is false with and without obfuscation. A future callback that needs
`thisVal` must be tested in an obfuscated release build.

## JitPack limited to the QuickJS runtime

Upstream adds `https://jitpack.io` to every project in the build. Reelish
wraps it in `exclusiveContent` in `android/build.gradle`: JitPack serves only
`com.github.fast-development.android-js-runtimes` (the QuickJS runtime, which
has no transitive dependencies), and that group is never requested from any
other repository. No other dependency can be resolved from JitPack.
