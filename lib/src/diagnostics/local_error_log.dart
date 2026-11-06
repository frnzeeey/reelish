// A small error log on this computer, for Windows: Crashlytics does not
// support it, and nothing here leaves the device.
import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Appends scrubbed error reports to `logs/errors.log` in the app's support
/// folder, keeping one older file so the two stay near twice [maxBytes].
/// Never throws: a log that cannot be written is not worth failing over.
class LocalErrorLog {
  LocalErrorLog({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const maxBytes = 256 * 1024;

  final Future<Directory> Function() _directory;

  Future<void> _writes = Future.value();

  /// The folder holding the log.
  Future<Directory> folder() async =>
      Directory('${(await _directory()).path}${Platform.pathSeparator}logs');

  /// Adds [entry]; entries keep their order. Completes once it is written.
  Future<void> append(String entry) =>
      _writes = _writes.then((_) => _write(entry)).catchError((Object _) {});

  Future<void> _write(String entry) async {
    final directory = await folder();
    await directory.create(recursive: true);
    final separator = Platform.pathSeparator;
    final file = File('${directory.path}${separator}errors.log');
    if (await file.exists() && await file.length() >= maxBytes) {
      await file.rename('${directory.path}${separator}errors.old.log');
    }
    await file.writeAsString('$entry\n', mode: FileMode.append, flush: true);
  }
}
