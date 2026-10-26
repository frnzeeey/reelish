import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/torrent_source_preparer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory documents;
  late Directory cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reelish-win-torrent-');
    documents = await Directory('${root.path}\\Documents').create();
    cache = await Directory('${root.path}\\LocalAppData').create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => documents.path,
            'getApplicationCacheDirectory' => cache.path,
            'getTemporaryDirectory' => root.path,
            _ => null,
          },
        );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });

  test('Windows without the engine DLL keeps torrents off', () {
    // The test runner has no torrent_streamer.dll beside it, as a Windows
    // build without the engine.
    expect(TorrentSupport.available, isFalse);
  });

  test(
    'Windows startup cleanup stays in the engine folder',
    () async {
      // The user's own folder that Android's cleanup would delete.
      final own = await Directory('${documents.path}\\torrent_cache').create();
      await File('${own.path}\\notes.txt').writeAsString('mine');
      final engine = await Directory('${cache.path}\\torrent_engine').create();
      final sessions = File('${engine.path}\\sessions.json');
      await sessions.writeAsString('[{"id":"1","magnet":"magnet:?xt="}]');
      final data = await Directory(
        '${engine.path}\\flutter_torrent_streamer_global',
      ).create();
      await File('${data.path}\\piece').writeAsBytes(List.filled(16, 0));
      SharedPreferences.setMockInitialValues({
        'onfeed.torrent.clearPending': true,
      });

      await StorageService().cleanTorrentDataAtStartup();

      expect(File('${own.path}\\notes.txt').existsSync(), isTrue);
      expect(sessions.existsSync(), isFalse, reason: 'leftover sessions');
      expect(data.existsSync(), isFalse, reason: 'a clear was pending');
    },
    skip: Platform.isWindows ? false : 'Windows paths',
  );
}
