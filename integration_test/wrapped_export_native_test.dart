// Exports a Reelish Wrapped card through the real platform code
// (WrappedExport; ShareChannel.kt on Android):
//
//   flutter test integration_test/wrapped_export_native_test.dart -d <device>
//
// Android (phone or tablet, Android 10 or later; pass
// --dart-define=CAN_SAVE=false for an older one): Save adds a PNG to
// Pictures/Reelish, Share opens the system chooser (press Back to close it),
// and the channel refuses empty, oversized and badly named images. The saved
// test image is named `reelish-export-test` and may be deleted afterwards.
// Windows: Save writes Pictures\Reelish\reelish-export-test.png, opens
// Explorer on it, and the test deletes the file.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/wrapped/wrapped_export.dart';
import 'package:path_provider_windows/path_provider_windows.dart';

const _channel = MethodChannel('onfeed/share');
const _canSave = bool.fromEnvironment('CAN_SAVE', defaultValue: true);
const _name = 'reelish-export-test';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// A small real PNG, drawn and encoded by the engine as a card would be.
  Future<Uint8List> png(WidgetTester tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: key,
          child: Container(
            width: 90,
            height: 160,
            color: const Color(0xFFFF6B5B),
          ),
        ),
      ),
    );
    late Uint8List bytes;
    await tester.runAsync(() async {
      bytes = await WrappedExport.capture(
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary,
        pixelRatio: 1,
      );
    });
    expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
    return bytes;
  }

  testWidgets('Android: refuses what is not a safe image', (tester) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      markTestSkipped('Android only.');
      return;
    }
    final image = await png(tester);
    Future<bool?> send(String method, Uint8List bytes, String name) =>
        _channel.invokeMethod<bool>(method, {'bytes': bytes, 'name': name});
    for (final method in ['saveImage', 'shareImage']) {
      expect(await send(method, Uint8List(0), _name), isFalse);
      expect(
        await send(method, Uint8List(20 * 1024 * 1024 + 1), _name),
        isFalse,
      );
      for (final bad in ['../x', 'a/b', 'a.png', '', 'x' * 81]) {
        expect(await send(method, image, bad), isFalse, reason: '$method $bad');
      }
    }
  });

  testWidgets('Android: saves to Pictures/Reelish', (tester) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      markTestSkipped('Android only.');
      return;
    }
    expect(await WrappedExport.canSave(), _canSave);
    final saved = await WrappedExport.save(await png(tester), _name);
    // ignore: avoid_print
    print('WRAPPED_SAVE $saved');
    expect(saved, _canSave ? 'Pictures/Reelish' : isNull);
  });

  testWidgets('Android: opens the share sheet', (tester) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      markTestSkipped('Android only.');
      return;
    }
    expect(WrappedExport.canShare, isTrue);
    final shared = await WrappedExport.share(
      await png(tester),
      _name,
      text: 'My year on Reelish',
    );
    // ignore: avoid_print
    print('WRAPPED_SHARE $shared');
    expect(shared, isTrue);
  });

  testWidgets('Windows: saves to Pictures\\Reelish', (tester) async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      markTestSkipped('Windows only.');
      return;
    }
    expect(await WrappedExport.canSave(), isTrue);
    expect(WrappedExport.canShare, isFalse);
    final image = await png(tester);
    late String? path;
    await tester.runAsync(() async {
      path = await WrappedExport.save(image, _name);
    });
    // ignore: avoid_print
    print('WRAPPED_SAVE $path');
    // The real Pictures folder, which OneDrive backup may have moved.
    late String? pictures;
    await tester.runAsync(() async {
      final Future<String?> Function(String) lookup =
          PathProviderWindows().getPath;
      pictures = await lookup(WrappedExport.windowsPicturesFolderId);
    });
    // ignore: avoid_print
    print('WINDOWS_PICTURES $pictures');
    expect(path, '$pictures\\Reelish\\reelish-export-test.png');
    final file = File(path!);
    expect(file.readAsBytesSync(), image);
    file.deleteSync();
  });
}
