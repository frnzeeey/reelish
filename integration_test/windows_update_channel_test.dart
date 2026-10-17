// The Windows updater's native channel (windows/runner/app_update_channel.cpp)
// against real files. Run on Windows:
//
//   flutter test integration_test/windows_update_channel_test.dart -d windows ^
//     --dart-define=REELISH_TEST_INSTALLER=<path to Reelish-Setup-x64.exe> ^
//     --dart-define=REELISH_TEST_INSTALLER_VERSION=<its version> ^
//     --dart-define=REELISH_TEST_SIGNED=<path to any Authenticode-signed .exe>
//
// Without the defines, the tests that need those files are skipped. Nothing
// here starts an installer: launchInstaller would close the test app.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/platform/windows_installation.dart';
import 'package:onfeed/src/services/windows_update_controller.dart';

const _installer = String.fromEnvironment('REELISH_TEST_INSTALLER');
const _installerVersion = String.fromEnvironment(
  'REELISH_TEST_INSTALLER_VERSION',
);
const _signed = String.fromEnvironment('REELISH_TEST_SIGNED');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bridge = WindowsInstallerBridge();
  late Directory temp;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('reelish_channel_test');
  });
  tearDownAll(() => temp.delete(recursive: true));

  testWidgets('reads a real Reelish installer', (tester) async {
    final info = await bridge.inspect(_installer);
    expect(info, isNotNull);
    expect(info!.productName, 'Reelish');
    expect(info.companyName, 'frnzeeey');
    expect(info.version, _installerVersion);
    expect(info.signature, anyOf('unsigned', 'valid'));
    expect(
      WindowsUpdateController.installerProblem(
        info,
        AppVersion.tryParse(_installerVersion)!,
      ),
      isNull,
    );
  }, skip: _installer.isEmpty);

  testWidgets(
    'a signed executable verifies; a tampered copy does not',
    (tester) async {
      expect((await bridge.inspect(_signed))!.signature, 'valid');
      final bytes = await File(_signed).readAsBytes();
      // A byte in the signed code, well inside the image.
      bytes[bytes.length ~/ 3] ^= 0xFF;
      final tampered = await File(
        '${temp.path}\\tampered.exe',
      ).writeAsBytes(bytes);
      expect((await bridge.inspect(tampered.path))?.signature, 'invalid');
    },
    skip: _signed.isEmpty,
  );

  testWidgets('a file that is not an executable is not an installer', (
    tester,
  ) async {
    final page = await File(
      '${temp.path}\\setup.exe',
    ).writeAsString('<html>Not found</html>');
    expect(await bridge.inspect(page.path), isNull);
    expect(await bridge.inspect('${temp.path}\\missing.exe'), isNull);
    expect(await bridge.inspect('relative\\setup.exe'), isNull);
  });

  testWidgets('reports free disk space', (tester) async {
    expect(await bridge.freeDiskSpace(temp.path), greaterThan(0));
    expect(await bridge.freeDiskSpace(''), isNull);
  });

  testWidgets('refuses to start anything that is not a plain .exe path', (
    tester,
  ) async {
    final text = await File('${temp.path}\\notes.txt').writeAsString('x');
    for (final path in [
      text.path,
      '${temp.path}\\missing.exe',
      '${temp.path}\\a" /VERYSILENT ".exe',
      'setup.exe',
    ]) {
      expect(
        await bridge.launchAndQuit(path, logPath: '${temp.path}\\log.txt'),
        isFalse,
        reason: path,
      );
    }
    // A log path that could break out of its quotes is refused too.
    expect(
      await bridge.launchAndQuit(text.path, logPath: 'x" /DIR="C:\\'),
      isFalse,
    );
  });
}
