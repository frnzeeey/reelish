import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/desktop/desktop_update_dialogs.dart';
import 'package:onfeed/src/desktop/desktop_update_section.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/platform/windows_installation.dart';
import 'package:onfeed/src/services/github_update_service.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/update_config.dart';
import 'package:onfeed/src/services/windows_update_controller.dart';
import 'package:onfeed/src/widgets/app_update_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _download = 'https://github.com/frnzeeey/reelish/releases/download';
const _setup = 'Reelish-Setup-x64.exe';

Map<String, Object?> _asset(
  String tag,
  String name, {
  int size = 1000,
  String? digest,
}) => {
  'name': name,
  'state': 'uploaded',
  'size': size,
  'browser_download_url': '$_download/$tag/$name',
  'digest': ?digest,
};

Map<String, Object?> _release(String tag, List<Map<String, Object?>> assets) =>
    {
      'tag_name': tag,
      'name': 'Reelish $tag',
      'draft': false,
      'prerelease': false,
      'body': '## What\'s Changed\n- Faster plugin initialization',
      'html_url': 'https://github.com/frnzeeey/reelish/releases/tag/$tag',
      'published_at': '2026-10-15T12:00:00Z',
      'assets': assets,
    };

AppVersion _v(String value) => AppVersion.tryParse(value)!;

AppUpdate _update({
  String version = '1.12.0',
  int? size,
  String? sha,
  bool sidecar = false,
}) => AppUpdate(
  currentVersion: _v('1.11.0'),
  latestVersion: _v(version),
  tagName: 'v$version',
  releaseName: 'Reelish v$version',
  releaseNotes: '- Improved Windows playback stability',
  downloadUri: Uri.parse('$_download/v$version/$_setup'),
  assetName: _setup,
  sizeBytes: size,
  sha256: sha,
  checksumUri: sidecar
      ? Uri.parse('$_download/v$version/$_setup.sha256')
      : null,
  publishedAt: DateTime.utc(2026, 10, 15, 12),
);

class _FakeBridge extends WindowsInstallerBridge {
  _FakeBridge({this.inspection});

  InstallerInspection? inspection;
  int? free;
  bool launches = true;
  final launched = <String>[];

  @override
  Future<InstallerInspection?> inspect(String path) async => inspection;

  @override
  Future<int?> freeDiskSpace(String path) async => free;

  @override
  Future<bool> launchAndQuit(String path, {required String logPath}) async {
    launched.add(path);
    return launches;
  }
}

const _reelish = InstallerInspection(
  productName: 'Reelish',
  companyName: 'frnzeeey',
  version: '1.12.0',
  signature: 'unsigned',
);

/// Plain tests set the platform for the whole test; widget tests use
/// [TargetPlatformVariant], which the framework resets before its checks.
void _onWindows() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
}

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WindowsInstallation.debugUsesInstaller = true;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    WindowsInstallation.debugUsesInstaller = null;
  });

  group('release selection', () {
    _onWindows();
    test('an installed copy updates from the installer, never the APK or '
        'the ZIP', () {
      final result = GitHubUpdateService.parseRelease(
        _release('v1.12.0', [
          _asset('v1.12.0', 'reelish.apk'),
          _asset(
            'v1.12.0',
            'Reelish-Windows-x64.zip',
            digest: 'sha256:${'a' * 64}',
          ),
          _asset('v1.12.0', _setup, size: 5000, digest: 'sha256:${'B' * 64}'),
        ]),
        _v('1.11.0'),
      );
      expect(result.status, UpdateCheckStatus.updateAvailable);
      final update = result.update!;
      expect(update.assetName, _setup);
      expect(update.sha256, 'b' * 64);
      expect(update.sizeBytes, 5000);
      expect(update.publishedAt, DateTime.utc(2026, 10, 15, 12));
    });

    test('a portable copy still updates from the ZIP', () {
      WindowsInstallation.debugUsesInstaller = false;
      final result = GitHubUpdateService.parseRelease(
        _release('v1.12.0', [
          _asset(
            'v1.12.0',
            'Reelish-Windows-x64.zip',
            digest: 'sha256:${'a' * 64}',
          ),
          _asset('v1.12.0', _setup, digest: 'sha256:${'b' * 64}'),
        ]),
        _v('1.11.0'),
      );
      expect(result.update!.assetName, 'Reelish-Windows-x64.zip');
    });

    test('no SHA-256 at all means no update is offered', () {
      final result = GitHubUpdateService.parseRelease(
        _release('v1.12.0', [_asset('v1.12.0', _setup)]),
        _v('1.11.0'),
      );
      expect(result.status, UpdateCheckStatus.missingApk);
      expect(result.update, isNull);
    });

    test('without a digest, the release checksum file is used', () {
      final result = GitHubUpdateService.parseRelease(
        _release('v1.12.0', [
          _asset('v1.12.0', _setup),
          _asset('v1.12.0', '$_setup.sha256', size: 90),
        ]),
        _v('1.11.0'),
      );
      expect(result.status, UpdateCheckStatus.updateAvailable);
      expect(result.update!.sha256, isNull);
      expect(
        result.update!.checksumUri.toString(),
        '$_download/v1.12.0/$_setup.sha256',
      );
    });

    test('a checksum file of another release is ignored', () {
      final checksum = _asset('v1.12.0', '$_setup.sha256')
        ..['browser_download_url'] = '$_download/v1.11.0/$_setup.sha256';
      final result = GitHubUpdateService.parseRelease(
        _release('v1.12.0', [_asset('v1.12.0', _setup), checksum]),
        _v('1.11.0'),
      );
      expect(result.status, UpdateCheckStatus.missingApk);
    });

    test('the installed version and older releases are not updates', () {
      for (final installed in ['1.12.0', '1.13.0']) {
        final result = GitHubUpdateService.parseRelease(
          _release('v1.12.0', [
            _asset('v1.12.0', _setup, digest: 'sha256:${'b' * 64}'),
          ]),
          _v(installed),
        );
        expect(result.status, UpdateCheckStatus.upToDate, reason: installed);
      }
    });

    test('pre-releases and invalid tags are never offered', () {
      final pre = _release('v1.12.0', [
        _asset('v1.12.0', _setup, digest: 'sha256:${'b' * 64}'),
      ])..['prerelease'] = true;
      expect(
        GitHubUpdateService.parseRelease(pre, _v('1.11.0')).hasUpdate,
        isFalse,
      );
      for (final tag in ['v1.12.0-beta.1', 'latest', 'v1.12']) {
        final release = _release(tag, [
          _asset(tag, _setup, digest: 'sha256:${'b' * 64}'),
        ]);
        expect(
          GitHubUpdateService.parseRelease(release, _v('1.11.0')).hasUpdate,
          isFalse,
          reason: tag,
        );
      }
    });

    test(
      'a cached ZIP update is not reused once Reelish is installed',
      () async {
        WindowsInstallation.debugUsesInstaller = false;
        final storage = StorageService();
        var requests = 0;
        final client = MockClient((_) async {
          requests++;
          return http.Response(
            jsonEncode(
              _release('v1.12.0', [
                _asset(
                  'v1.12.0',
                  'Reelish-Windows-x64.zip',
                  digest: 'sha256:${'a' * 64}',
                ),
                _asset('v1.12.0', _setup, digest: 'sha256:${'b' * 64}'),
              ]),
            ),
            200,
          );
        });
        final first = await GitHubUpdateService.checkForUpdate(
          storage: storage,
          client: client,
          installedVersionLoader: () async => '1.11.0',
        );
        expect(first.update!.assetName, 'Reelish-Windows-x64.zip');

        WindowsInstallation.debugUsesInstaller = true;
        final second = await GitHubUpdateService.checkForUpdate(
          storage: storage,
          client: client,
          installedVersionLoader: () async => '1.11.0',
        );
        // Throttled: the cached ZIP result is dropped, not offered.
        expect(requests, 1);
        expect(second.hasUpdate, isFalse);
        expect(
          await GitHubUpdateService.lastSuccessfulCheck(storage: storage),
          isNotNull,
        );
      },
    );
  });

  group('checksum files', () {
    _onWindows();
    final hex = 'ab' * 32;

    test('reads sha256sum output', () {
      expect(
        GitHubUpdateService.parseChecksumFile('$hex  $_setup', _setup),
        hex,
      );
      expect(
        GitHubUpdateService.parseChecksumFile('$hex *$_setup\n', _setup),
        hex,
      );
      expect(
        GitHubUpdateService.parseChecksumFile('﻿${hex.toUpperCase()}', _setup),
        hex,
      );
    });

    test('rejects another file, extra lines and malformed digests', () {
      for (final contents in [
        '$hex  other.exe',
        '$hex  $_setup\n$hex  $_setup',
        '${'ab' * 31}  $_setup',
        'not a checksum',
        '',
      ]) {
        expect(
          GitHubUpdateService.parseChecksumFile(contents, _setup),
          isNull,
          reason: contents,
        );
      }
    });
  });

  group('downloads', () {
    _onWindows();
    late Directory cache;
    final bytes = [0x4D, 0x5A, ...List<int>.generate(4094, (i) => i % 251)];
    final sha = sha256.convert(bytes).toString();

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('reelish_win_update');
    });
    tearDown(() => cache.delete(recursive: true));

    http.StreamedResponse body(List<int> data, [int status = 200]) =>
        http.StreamedResponse(
          Stream.value(data),
          status,
          contentLength: data.length,
        );

    test('saves the installer as .exe in a Reelish folder of %TEMP%', () async {
      final result = await GitHubUpdateService.downloadUpdate(
        _update(size: bytes.length, sha: sha),
        client: MockClient.streaming((_, _) async => body(bytes)),
        cacheDirectory: () async => cache,
      );
      expect(
        result.file.path,
        '${cache.path}${Platform.pathSeparator}Reelish'
        '${Platform.pathSeparator}updates${Platform.pathSeparator}'
        'reelish-1.12.0.exe',
      );
      expect(result.update.sha256, sha);
    });

    test('never touches a generic %TEMP%\\updates folder', () async {
      final foreign = await File(
        '${cache.path}${Platform.pathSeparator}updates'
        '${Platform.pathSeparator}other-app.bin',
      ).create(recursive: true);
      await GitHubUpdateService.downloadUpdate(
        _update(size: bytes.length, sha: sha),
        client: MockClient.streaming((_, _) async => body(bytes)),
        cacheDirectory: () async => cache,
      );
      await GitHubUpdateService.deleteDownloadedUpdates(
        cacheDirectory: () async => cache,
      );
      expect(await foreign.exists(), isTrue);
      expect(
        await Directory(
          '${cache.path}${Platform.pathSeparator}Reelish'
          '${Platform.pathSeparator}updates',
        ).exists(),
        isFalse,
      );
    });

    test('reads the SHA-256 from the checksum file, then verifies', () async {
      final requested = <String>[];
      final result = await GitHubUpdateService.downloadUpdate(
        _update(size: bytes.length, sidecar: true),
        client: MockClient.streaming((request, _) async {
          requested.add(request.url.pathSegments.last);
          return request.url.path.endsWith('.sha256')
              ? body(utf8.encode('$sha  $_setup'))
              : body(bytes);
        }),
        cacheDirectory: () async => cache,
      );
      expect(requested, ['$_setup.sha256', _setup]);
      expect(result.update.sha256, sha);
      expect(await result.file.readAsBytes(), bytes);
    });

    test('a checksum mismatch leaves no file behind', () async {
      await expectLater(
        GitHubUpdateService.downloadUpdate(
          _update(size: bytes.length, sidecar: true),
          client: MockClient.streaming(
            (request, _) async => request.url.path.endsWith('.sha256')
                ? body(utf8.encode('${'0' * 64}  $_setup'))
                : body(bytes),
          ),
          cacheDirectory: () async => cache,
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(cache.listSync(recursive: true).whereType<File>(), isEmpty);
    });

    test('refuses to download without any SHA-256', () async {
      var requests = 0;
      await expectLater(
        GitHubUpdateService.downloadUpdate(
          _update(size: bytes.length),
          client: MockClient((_) async {
            requests++;
            return http.Response('', 200);
          }),
          cacheDirectory: () async => cache,
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(requests, 0);
      expect(
        await GitHubUpdateService.verifyDownload(
          File('${cache.path}/x'),
          _update(),
        ),
        isFalse,
      );
    });

    test('follows redirects only to GitHub release storage', () async {
      Future<Object?> attempt(String location) async {
        // Each attempt downloads again, never reusing the last verified file.
        await GitHubUpdateService.deleteDownloadedUpdates(
          cacheDirectory: () async => cache,
        );
        try {
          await GitHubUpdateService.downloadUpdate(
            _update(size: bytes.length, sha: sha),
            client: MockClient.streaming((request, _) async {
              expect(request.followRedirects, isFalse);
              if (request.url.host == 'github.com') {
                return http.StreamedResponse(
                  const Stream.empty(),
                  302,
                  headers: {'location': location},
                );
              }
              return body(bytes);
            }),
            cacheDirectory: () async => cache,
          );
          return null;
        } catch (error) {
          return error;
        }
      }

      expect(
        await attempt(
          'https://release-assets.githubusercontent.com/github-production-release-asset/1',
        ),
        isNull,
      );
      for (final location in [
        'https://example.com/Reelish-Setup-x64.exe',
        'http://objects.githubusercontent.com/asset',
        'https://raw.githubusercontent.com/someone/repo/main/setup.exe',
      ]) {
        expect(
          await attempt(location),
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('unexpected address'),
          ),
          reason: location,
        );
      }
    });
  });

  group('installer identity', () {
    _onWindows();
    test('accepts the expected Reelish installer, signed or not', () {
      expect(
        WindowsUpdateController.installerProblem(_reelish, _v('1.12.0')),
        isNull,
      );
      expect(
        WindowsUpdateController.installerProblem(
          const InstallerInspection(
            productName: 'Reelish',
            companyName: 'frnzeeey',
            version: '1.12.0',
            signature: 'valid',
          ),
          _v('1.12.0'),
        ),
        isNull,
      );
    });

    test('rejects other programs, versions and broken signatures', () {
      for (final info in <InstallerInspection?>[
        null,
        const InstallerInspection(
          productName: 'Other',
          companyName: 'frnzeeey',
          version: '1.12.0',
          signature: 'unsigned',
        ),
        const InstallerInspection(
          productName: 'Reelish',
          companyName: 'someone',
          version: '1.12.0',
          signature: 'unsigned',
        ),
        const InstallerInspection(
          productName: 'Reelish',
          companyName: 'frnzeeey',
          version: '1.11.0',
          signature: 'unsigned',
        ),
        const InstallerInspection(
          productName: 'Reelish',
          companyName: 'frnzeeey',
          version: '1.12.0',
          signature: 'invalid',
        ),
      ]) {
        expect(
          WindowsUpdateController.installerProblem(info, _v('1.12.0')),
          isNotNull,
        );
      }
    });
  });

  group('WindowsUpdateController', () {
    _onWindows();
    late Directory cache;
    late _FakeBridge bridge;
    late bool playing;
    late List<int> installerBytes;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('reelish_win_ctrl');
      bridge = _FakeBridge(inspection: _reelish);
      playing = false;
      installerBytes = [0x4D, 0x5A, 1, 2, 3, 4];
    });
    tearDown(() => cache.delete(recursive: true));

    WindowsUpdateController controller({
      UpdateCheckResult? result,
      Object? downloadError,
      Completer<void>? gate,
    }) {
      final update = _update(
        size: installerBytes.length,
        sha: sha256.convert(installerBytes).toString(),
      );
      return WindowsUpdateController(
        checker: ({required force}) async =>
            result ??
            UpdateCheckResult(
              UpdateCheckStatus.updateAvailable,
              latestVersion: update.latestVersion,
              update: update,
            ),
        downloader: (update, onProgress, cancellation) async {
          if (downloadError != null) throw downloadError;
          onProgress(3, installerBytes.length);
          await gate?.future;
          if (cancellation.isCancelled) throw const UpdateDownloadCancelled();
          final file = File('${cache.path}/reelish-1.12.0.exe');
          await file.writeAsBytes(installerBytes);
          onProgress(installerBytes.length, installerBytes.length);
          return (file: file, update: update);
        },
        bridge: bridge,
        playbackActive: () => playing,
        cacheDirectory: () async => cache,
      );
    }

    test('check → download → verify → ready → installer handoff', () async {
      final c = controller();
      await c.load();
      final stages = <WindowsUpdateStage>[];
      c.addListener(() {
        if (stages.isEmpty || stages.last != c.stage) stages.add(c.stage);
      });
      await c.check(force: true);
      expect(c.stage, WindowsUpdateStage.available);
      await c.download();
      expect(c.stage, WindowsUpdateStage.ready);
      expect(await c.install(), isNull);
      expect(bridge.launched, [endsWith('reelish-1.12.0.exe')]);
      expect(stages, [
        WindowsUpdateStage.checking,
        WindowsUpdateStage.available,
        WindowsUpdateStage.downloading,
        WindowsUpdateStage.verifying,
        WindowsUpdateStage.ready,
        WindowsUpdateStage.installing,
      ]);
    });

    test('never installs during playback', () async {
      final c = controller();
      await c.check();
      await c.download();
      playing = true;
      expect(await c.install(), contains('Stop playback'));
      expect(bridge.launched, isEmpty);
      expect(c.stage, WindowsUpdateStage.ready);
      playing = false;
      expect(await c.install(), isNull);
    });

    test('a file changed after verification is removed, not run', () async {
      final c = controller();
      await c.check();
      await c.download();
      final file = File('${cache.path}/reelish-1.12.0.exe');
      await file.writeAsBytes([0x4D, 0x5A, 9, 9, 9, 9]);
      expect(await c.install(), contains('changed'));
      expect(bridge.launched, isEmpty);
      expect(await file.exists(), isFalse);
      expect(c.stage, WindowsUpdateStage.available);
    });

    test('a file that is not the Reelish installer is rejected', () async {
      bridge.inspection = const InstallerInspection(
        productName: 'Something else',
        companyName: 'frnzeeey',
        version: '1.12.0',
        signature: 'unsigned',
      );
      final c = controller();
      await c.check();
      await c.download();
      expect(c.stage, WindowsUpdateStage.failed);
      expect(c.error, contains('not a Reelish installer'));
      expect(File('${cache.path}/reelish-1.12.0.exe').existsSync(), isFalse);
    });

    test('a non-executable download is rejected before inspection', () async {
      installerBytes = utf8.encode('<html>not an exe</html>');
      final c = controller();
      await c.check();
      await c.download();
      expect(c.stage, WindowsUpdateStage.failed);
      expect(c.error, contains('not a Windows installer'));
    });

    test('a launch failure keeps Reelish open with the update ready', () async {
      bridge.launches = false;
      final c = controller();
      await c.check();
      await c.download();
      expect(await c.install(), contains('could not be started'));
      expect(c.stage, WindowsUpdateStage.ready);
    });

    test('cancelling returns to "available"', () async {
      final gate = Completer<void>();
      final c = controller(gate: gate);
      await c.check();
      final download = c.download();
      await Future<void>.delayed(Duration.zero);
      expect(c.stage, WindowsUpdateStage.downloading);
      c.cancelDownload();
      gate.complete();
      await download;
      expect(c.stage, WindowsUpdateStage.available);
    });

    test('download failures and low disk space are reported', () async {
      final c = controller(
        downloadError: const UpdateException('The download stalled.'),
      );
      await c.check();
      await c.download();
      expect(c.stage, WindowsUpdateStage.failed);
      expect(c.error, 'The download stalled.');

      bridge.free = 10;
      final low = controller();
      await low.check();
      await low.download();
      expect(low.error, contains('not enough free disk space'));
    });

    test('a failed manual check is reported; a silent one is not', () async {
      final c = controller(
        result: const UpdateCheckResult(UpdateCheckStatus.networkError),
      );
      await c.check();
      expect(c.stage, WindowsUpdateStage.idle);
      await c.check(force: true);
      expect(c.stage, WindowsUpdateStage.failed);
      expect(c.error, contains('internet connection'));
    });

    test('up to date', () async {
      final c = controller(
        result: UpdateCheckResult(
          UpdateCheckStatus.upToDate,
          latestVersion: _v('1.11.0'),
        ),
      );
      await c.check(force: true);
      expect(c.stage, WindowsUpdateStage.upToDate);
    });

    test('preferences persist', () async {
      final c = controller();
      await c.load();
      expect(c.autoCheck, isTrue);
      await c.setAutoCheck(false);
      await c.dismiss(_update());
      final again = controller();
      await again.load();
      expect(again.autoCheck, isFalse);
      expect(again.isDismissed(_update()), isTrue);
      expect(again.isDismissed(_update(version: '1.13.0')), isFalse);
    });
  });

  group('automatic checks', () {
    setUp(() {
      AppUpdateFlow.resetForTest();
      AppUpdateFlow.windowsStartupDelay = Duration.zero;
    });
    tearDown(() {
      AppUpdateFlow.windowsController = WindowsUpdateController.instance;
    });

    Future<void> pumpCheck(
      WidgetTester tester,
      Future<UpdateCheckResult> Function() checker,
    ) async {
      late BuildContext home;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              home = context;
              return const SizedBox();
            },
          ),
        ),
      );
      // Real async: the check reads preferences, then shows its dialog (or
      // nothing) once frames are pumped below.
      await tester.runAsync(() async {
        unawaited(AppUpdateFlow.checkAutomatically(home, checker: checker));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('respect the automatic-check switch', (tester) async {
      final c = WindowsUpdateController();
      await tester.runAsync(() async {
        await c.load();
        await c.setAutoCheck(false);
      });
      AppUpdateFlow.windowsController = c;
      var calls = 0;
      await pumpCheck(tester, () async {
        calls++;
        return const UpdateCheckResult(UpdateCheckStatus.upToDate);
      });
      expect(calls, 0);
    }, variant: _windows);

    testWidgets('do not prompt again for a dismissed version', (tester) async {
      final c = WindowsUpdateController();
      final update = _update(sha: 'a' * 64);
      await tester.runAsync(() async {
        await c.load();
        await c.dismiss(update);
      });
      AppUpdateFlow.windowsController = c;
      await pumpCheck(
        tester,
        () async => UpdateCheckResult(
          UpdateCheckStatus.updateAvailable,
          latestVersion: update.latestVersion,
          update: update,
        ),
      );
      expect(find.byType(DesktopUpdateAvailableDialog), findsNothing);

      // A newer version is offered.
      AppUpdateFlow.resetForTest();
      AppUpdateFlow.windowsStartupDelay = Duration.zero;
      final newer = _update(version: '1.13.0', sha: 'a' * 64);
      await pumpCheck(
        tester,
        () async => UpdateCheckResult(
          UpdateCheckStatus.updateAvailable,
          latestVersion: newer.latestVersion,
          update: newer,
        ),
      );
      expect(find.byType(DesktopUpdateAvailableDialog), findsOneWidget);
      expect(find.text('Reelish update available'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(c.isDismissed(newer), isTrue);
    }, variant: _windows);
  });

  group('desktop UI', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets('the update dialog shows versions, date, size and notes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(DesktopUpdateAvailableDialog(update: _update(size: 52428800))),
      );
      expect(
        find.text(
          "Version 1.12.0 is now available. You're currently running version 1.11.0.",
        ),
        findsOneWidget,
      );
      expect(
        find.text('Released October 15, 2026 · 50.0 MB download'),
        findsOneWidget,
      );
      expect(
        find.text('• Improved Windows playback stability'),
        findsOneWidget,
      );
      expect(find.text('Update now'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
    }, variant: _windows);

    testWidgets('Settings shows the state and the matching action', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cache = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reelish_win_ui'),
      ))!;
      addTearDown(() => cache.delete(recursive: true));
      final bytes = [0x4D, 0x5A, 1, 2];
      final update = _update(
        size: bytes.length,
        sha: sha256.convert(bytes).toString(),
      );
      final c = WindowsUpdateController(
        checker: ({required force}) async => UpdateCheckResult(
          UpdateCheckStatus.updateAvailable,
          latestVersion: update.latestVersion,
          update: update,
        ),
        downloader: (update, onProgress, _) async {
          final file = File('${cache.path}/setup.exe');
          await file.writeAsBytes(bytes);
          return (file: file, update: update);
        },
        bridge: _FakeBridge(inspection: _reelish),
        cacheDirectory: () async => cache,
      );
      await tester.pumpWidget(
        host(WindowsUpdateSection(installedVersion: '1.11.0', controller: c)),
      );
      await tester.pump();
      expect(find.text('APPLICATION UPDATES'), findsOneWidget);
      expect(find.text('1.11.0'), findsOneWidget);
      expect(find.text('Never'), findsOneWidget);
      expect(find.text('Installed'), findsOneWidget);

      await tester.runAsync(() => c.check(force: true));
      await tester.pump();
      expect(find.text('Version 1.12.0 is available.'), findsOneWidget);
      expect(find.text('Update now'), findsOneWidget);

      await tester.runAsync(c.download);
      await tester.pump();
      expect(
        find.text('Version 1.12.0 is downloaded and ready to install.'),
        findsOneWidget,
      );
      expect(find.text('Restart and install'), findsOneWidget);
    }, variant: _windows);
  });

  test('UpdateConfig names the Windows assets the workflow publishes', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(UpdateConfig.windowsInstallerAssetName, _setup);
    expect(UpdateConfig.windowsAssetName, 'Reelish-Windows-x64.zip');
    expect(UpdateConfig.assetName, _setup);
    WindowsInstallation.debugUsesInstaller = false;
    expect(UpdateConfig.assetName, 'Reelish-Windows-x64.zip');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(UpdateConfig.assetName, 'reelish.apk');
    expect(UpdateConfig.requiresChecksum, isFalse);
  });
}
