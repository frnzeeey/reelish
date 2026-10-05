import 'dart:async';
import 'dart:ffi';
import 'dart:io';

/// Runs before every test file in this folder.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _loadQuickJs();
  await testMain();
}

/// The plugin runtime opens QuickJS by bare name (`quickjs_c_bridge.dll`).
/// App builds bundle that library next to the executable; `flutter test` does
/// not, so the provider tests could not start the engine. Loading the
/// repository's copy by full path first makes Windows resolve the bare name
/// to the library already in the process, including on background isolates.
void _loadQuickJs() {
  if (!Platform.isWindows) return;
  final library = File(
    'third_party/flutter_js/windows/shared/quickjs_c_bridge.dll',
  );
  if (library.existsSync()) DynamicLibrary.open(library.absolute.path);
}
