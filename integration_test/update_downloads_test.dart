// On an Android device (phone or TV): the updater's native "Save to
// Downloads" copies only verified APKs from cache/updates into Downloads.
// Run with: flutter test integration_test/update_downloads_test.dart -d <device>

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/services/github_update_service.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bytes = utf8.encode('reelish integration test apk bytes');
  final update = AppUpdate(
    currentVersion: AppVersion.tryParse('1.0.0')!,
    latestVersion: AppVersion.tryParse('9.9.9')!,
    tagName: 'v9.9.9',
    releaseName: 'Reelish v9.9.9',
    releaseNotes: '',
    downloadUri: Uri.parse(
      'https://github.com/frnzeeey/reelish/releases/download/v9.9.9/reelish.apk',
    ),
    assetName: 'reelish.apk',
    sizeBytes: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );

  testWidgets('a verified update is saved to Downloads by name', (_) async {
    expect(await GitHubUpdateService.canSaveToDownloads(), isTrue);
    final dir = await GitHubUpdateService.updatesDirectory();
    final apk = File('${dir.path}/reelish-9.9.9.apk');
    await apk.writeAsBytes(bytes);

    final name = await GitHubUpdateService.saveApkToDownloads(apk, update);
    expect(name, startsWith('Reelish-9.9.9'));
    expect(name, endsWith('.apk'));
    expect(await apk.exists(), isTrue, reason: 'the private copy stays');
    // ignore: avoid_print
    print('SAVED_AS=$name');
  });

  testWidgets('a file outside cache/updates is refused by Android', (_) async {
    final outside = File('${(await getTemporaryDirectory()).path}/x.apk');
    await outside.writeAsBytes(bytes);
    await expectLater(
      GitHubUpdateService.saveApkToDownloads(outside, update),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('not found'),
        ),
      ),
    );
  });
}
