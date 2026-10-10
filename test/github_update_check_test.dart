import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/services/github_update_service.dart';
import 'package:onfeed/src/widgets/app_update_flow.dart';
import 'package:onfeed/src/widgets/update_dialog.dart';

const _download = 'https://github.com/frnzeeey/reelish/releases/download';

Map<String, Object?> _asset(String tag, String name, {int size = 1000}) => {
  'name': name,
  'state': 'uploaded',
  'size': size,
  'browser_download_url': '$_download/$tag/$name',
};

Map<String, Object?> _release(
  String tag, {
  List<Map<String, Object?>>? assets,
  String body = 'Bug fixes',
}) => {
  'tag_name': tag,
  'name': 'Reelish $tag',
  'draft': false,
  'prerelease': false,
  'body': body,
  'html_url': 'https://github.com/frnzeeey/reelish/releases/tag/$tag',
  'assets': assets ?? [_asset(tag, 'reelish.apk')],
};

AppVersion _v(String value) => AppVersion.tryParse(value)!;

AppUpdate _update({
  String version = '1.0.1',
  int? size,
  String? sha,
  String? url,
  String notes = '',
}) => AppUpdate(
  currentVersion: _v('1.0.0'),
  latestVersion: _v(version),
  tagName: 'v$version',
  releaseName: 'Reelish v$version',
  releaseNotes: notes,
  downloadUri: Uri.parse(url ?? '$_download/v$version/reelish.apk'),
  assetName: 'reelish.apk',
  sizeBytes: size,
  sha256: sha,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AppVersion', () {
    test('compares numerically, not as strings', () {
      expect(_v('1.0.1') > _v('1.0.0'), isTrue);
      expect(_v('1.0.0') > _v('1.0.1'), isFalse);
      expect(_v('1.0.1') == _v('1.0.1'), isTrue);
      expect(_v('1.10.0') > _v('1.9.0'), isTrue);
      expect(_v('1.0.10') > _v('1.0.9'), isTrue);
      expect(_v('2.0.0') > _v('1.99.99'), isTrue);
    });

    test('strips the v prefix and ignores build metadata', () {
      expect(_v('v1.0.1'), _v('1.0.1'));
      expect(_v('V2.0.0'), _v('2.0.0'));
      expect(_v('1.0.0+7'), _v('1.0.0'));
      expect(_v('1.1'), _v('1.1.0'));
    });

    test('orders pre-releases before their release', () {
      expect(_v('1.0.0-beta') < _v('1.0.0'), isTrue);
      expect(_v('1.0.0-beta.2') < _v('1.0.0-beta.10'), isTrue);
      expect(_v('1.0.0-alpha') < _v('1.0.0-beta'), isTrue);
    });

    test('release tags: only vX.Y.Z (or X.Y.Z) count', () {
      expect(GitHubUpdateService.releaseVersion('v1.0.0'), _v('1.0.0'));
      expect(GitHubUpdateService.releaseVersion('1.0.10'), _v('1.0.10'));
      for (final tag in [
        'release-1.0.0',
        'v1.0',
        'v1',
        'v1.0.0-beta.1',
        'v1.0.0+5',
        'latest',
        'V1.0.0 ',
      ]) {
        expect(GitHubUpdateService.releaseVersion(tag), isNull, reason: tag);
      }
    });

    test('huge components are malformed, not a crash', () {
      expect(AppVersion.tryParse('1.0.99999999999999999999999'), isNull);
    });

    test('rejects malformed versions', () {
      for (final value in ['', 'latest', 'v', '1.0.0.0', '1..0', 'v1.x']) {
        expect(AppVersion.tryParse(value), isNull, reason: value);
      }
    });
  });

  group('parseRelease', () {
    UpdateCheckResult parse(String installed, Map<String, Object?> release) =>
        GitHubUpdateService.parseRelease(release, _v(installed));

    test('scenario 1: same version shows no update', () {
      expect(
        parse('1.0.0', _release('v1.0.0')).status,
        UpdateCheckStatus.upToDate,
      );
    });

    test('scenario 2: newer release offers an update', () {
      final result = parse('1.0.0', _release('v1.0.1'));
      expect(result.hasUpdate, isTrue);
      expect(result.update!.latestVersion, _v('1.0.1'));
      expect(result.update!.currentVersion, _v('1.0.0'));
      expect(result.update!.assetName, 'reelish.apk');
      expect(result.update!.releaseNotes, 'Bug fixes');
    });

    test('scenario 3: older release shows no update', () {
      expect(
        parse('1.0.1', _release('v1.0.0')).status,
        UpdateCheckStatus.upToDate,
      );
    });

    test('scenario 4: 1.0.10 is newer than 1.0.9', () {
      expect(parse('1.0.9', _release('v1.0.10')).hasUpdate, isTrue);
    });

    test('scenario 5: release without an APK is not offered', () {
      final result = parse(
        '1.0.0',
        _release(
          'v1.0.1',
          assets: [
            _asset('v1.0.1', 'source.zip'),
            _asset('v1.0.1', 'reelish.tar.gz'),
          ],
        ),
      );
      expect(result.status, UpdateCheckStatus.missingApk);
      expect(result.update, isNull);
      expect(result.latestVersion, _v('1.0.1'));
    });

    test('rejects APKs hosted outside this repository', () {
      final result = parse(
        '1.0.0',
        _release(
          'v1.0.1',
          assets: [
            {
              ..._asset('v1.0.1', 'reelish.apk'),
              'browser_download_url':
                  'https://github.com/someone/else/releases/download/v1.0.1/reelish.apk',
            },
          ],
        ),
      );
      expect(result.status, UpdateCheckStatus.missingApk);
    });

    test('ignores assets that are still uploading or empty', () {
      final result = parse(
        '1.0.0',
        _release(
          'v1.0.1',
          assets: [
            {..._asset('v1.0.1', 'reelish.apk'), 'state': 'starter'},
            _asset('v1.0.1', 'app-release.apk', size: 0),
          ],
        ),
      );
      expect(result.status, UpdateCheckStatus.missingApk);
    });

    test('scenario 6: picks reelish.apk among many assets', () {
      final result = parse(
        '1.0.0',
        _release(
          'v1.0.1',
          assets: [
            _asset('v1.0.1', 'source.zip'),
            _asset('v1.0.1', 'app-debug.apk'),
            _asset('v1.0.1', 'reelish-arm64.apk'),
            _asset('v1.0.1', 'reelish.apk.sha256'),
            _asset('v1.0.1', 'reelish.apk'),
            _asset('v1.0.1', 'reelish-universal.apk'),
          ],
        ),
      );
      expect(result.update!.assetName, 'reelish.apk');
      expect(
        result.update!.downloadUri.toString(),
        '$_download/v1.0.1/reelish.apk',
      );
    });

    test('never guesses: other APK names are not offered', () {
      for (final names in [
        ['app-release.apk'],
        ['Reelish-1.0.1.apk'],
        ['app-debug.apk', 'reelish-arm64.apk'],
        ['REELISH.APK'],
      ]) {
        final result = parse(
          '1.0.0',
          _release(
            'v1.0.1',
            assets: [for (final n in names) _asset('v1.0.1', n)],
          ),
        );
        expect(result.status, UpdateCheckStatus.missingApk, reason: '$names');
      }
    });

    test('rejects an APK that belongs to another release', () {
      // Release v1.0.2 whose asset link points at v1.0.1's (older) APK.
      final result = parse(
        '1.0.0',
        _release('v1.0.2', assets: [_asset('v1.0.1', 'reelish.apk')]),
      );
      expect(result.status, UpdateCheckStatus.missingApk);
    });

    test('rejects an asset without a known size', () {
      final asset = _asset('v1.0.1', 'reelish.apk')..remove('size');
      expect(
        parse('1.0.0', _release('v1.0.1', assets: [asset])).status,
        UpdateCheckStatus.missingApk,
      );
    });

    test('drafts and pre-releases are never offered', () {
      expect(
        parse('1.0.0', {..._release('v2.0.0'), 'draft': true}).hasUpdate,
        isFalse,
      );
      expect(
        parse('1.0.0', {..._release('v2.0.0'), 'prerelease': true}).hasUpdate,
        isFalse,
      );
    });

    test('scenario 4: an older release is not offered over 1.0.10', () {
      expect(
        parse('1.0.10', _release('v1.0.9')).status,
        UpdateCheckStatus.upToDate,
      );
    });

    test('reads the GitHub asset digest for verification', () {
      final digest = 'a' * 64;
      final result = parse(
        '1.0.0',
        _release(
          'v1.0.1',
          assets: [
            {..._asset('v1.0.1', 'reelish.apk'), 'digest': 'sha256:$digest'},
          ],
        ),
      );
      expect(result.update!.sha256, digest);
      expect(result.update!.sizeBytes, 1000);
    });
  });

  group('checkForUpdate', () {
    Future<UpdateCheckResult> check(
      http.Client client, {
      String installed = '1.0.0',
      DateTime? at,
      bool force = false,
    }) => GitHubUpdateService.checkForUpdate(
      client: client,
      forceRefresh: force,
      clock: () => at ?? DateTime.utc(2026, 1, 1, 12),
      installedVersionLoader: () async => installed,
    );

    test('reuses the persisted result within the check interval', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(jsonEncode(_release('v1.1.0')), 200);
      });
      final first = await check(client);
      final second = await check(client, at: DateTime.utc(2026, 1, 1, 12, 5));
      expect(first.update?.latestVersion, _v('1.1.0'));
      expect(second.update?.latestVersion, _v('1.1.0'));
      expect(requests, 1);

      await check(client, at: DateTime.utc(2026, 1, 1, 19));
      expect(requests, 2);
    });

    test('does not offer the installed version from the cache', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(jsonEncode(_release('v1.1.0')), 200);
      });
      await check(client);
      final afterInstalling = await check(
        client,
        installed: '1.1.0',
        at: DateTime.utc(2026, 1, 1, 12, 1),
      );
      expect(afterInstalling.hasUpdate, isFalse);
      expect(afterInstalling.status, UpdateCheckStatus.upToDate);
      // The new version is checked once, which also clears the used APK.
      expect(requests, 2);
    });

    test(
      'a known update is not offered once installed, even offline',
      () async {
        var online = true;
        final client = MockClient((_) async {
          if (!online) throw const SocketException('offline');
          return http.Response(jsonEncode(_release('v1.1.0')), 200);
        });
        await check(client);
        online = false;
        final afterInstalling = await check(
          client,
          installed: '1.1.0',
          at: DateTime.utc(2026, 1, 1, 12, 1),
        );
        expect(afterInstalling.hasUpdate, isFalse);
      },
    );

    test('scenario 6: no internet reports a network error', () async {
      final client = MockClient(
        (_) async => throw const SocketException('Failed host lookup'),
      );
      final result = await check(client);
      expect(result.status, UpdateCheckStatus.networkError);
      expect(result.hasUpdate, isFalse);
    });

    test('maps GitHub HTTP errors', () async {
      Future<UpdateCheckStatus> statusFor(
        int code, [
        Map<String, String> headers = const {},
      ]) async {
        SharedPreferences.setMockInitialValues({});
        final client = MockClient(
          (_) async => http.Response('{}', code, headers: headers),
        );
        return (await check(client, force: true)).status;
      }

      expect(await statusFor(404), UpdateCheckStatus.noRelease);
      expect(
        await statusFor(403, {'x-ratelimit-remaining': '0'}),
        UpdateCheckStatus.rateLimited,
      );
      expect(await statusFor(429), UpdateCheckStatus.rateLimited);
      expect(await statusFor(403), UpdateCheckStatus.serverError);
      for (final code in [500, 502, 503]) {
        expect(await statusFor(code), UpdateCheckStatus.serverError);
      }
    });

    test('invalid JSON is handled', () async {
      final client = MockClient((_) async => http.Response('<html>', 200));
      expect((await check(client)).status, UpdateCheckStatus.invalidResponse);
    });

    test('a failed refresh keeps offering a known update', () async {
      var fail = false;
      final client = MockClient((_) async {
        if (fail) throw const SocketException('offline');
        return http.Response(jsonEncode(_release('v1.1.0')), 200);
      });
      await check(client);
      fail = true;
      final later = await check(client, at: DateTime.utc(2026, 1, 2));
      expect(later.update?.latestVersion, _v('1.1.0'));
    });

    test('a network failure retries sooner than the full interval', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        throw const SocketException('offline');
      });
      await check(client);
      await check(client, at: DateTime.utc(2026, 1, 1, 12, 5));
      expect(requests, 1);
      await check(client, at: DateTime.utc(2026, 1, 1, 12, 20));
      expect(requests, 2);
    });
  });

  group('checkForUpdate concurrency and cache', () {
    test('a forced check never reuses a throttled background answer', () async {
      var requests = 0;
      var latest = 'v1.1.0';
      final release = Completer<void>();
      final client = MockClient((_) async {
        requests++;
        if (requests == 2) await release.future;
        return http.Response(jsonEncode(_release(latest)), 200);
      });
      Future<UpdateCheckResult> check({bool force = false}) =>
          GitHubUpdateService.checkForUpdate(
            client: client,
            forceRefresh: force,
            clock: () => DateTime.utc(2026, 1, 1, 12),
            installedVersionLoader: () async => '1.0.0',
          );
      await check(); // Fills the cache and starts the 6-hour throttle.
      expect(requests, 1);

      latest = 'v1.2.0'; // Published meanwhile.
      final background = check(); // Throttled: answers from the cache.
      final manual = check(force: true);
      release.complete();
      expect((await background).update?.latestVersion, _v('1.1.0'));
      expect((await manual).update?.latestVersion, _v('1.2.0'));
      expect(requests, 2);
    });

    test('a cached update pointing at another release is dropped', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.update.github.nextCheckAt.v2': DateTime.utc(
          2026,
          1,
          1,
          13,
        ).toIso8601String(),
        'onfeed.update.github.lastResult.v2': jsonEncode({
          'installedVersion': '1.0.0',
          'status': 'updateAvailable',
          'latestVersion': '1.1.0',
          'update': {
            ..._update(version: '1.1.0').toJson(),
            // Tampered: v1.1.0's entry downloading v1.0.1's APK.
            'downloadUri': '$_download/v1.0.1/reelish.apk',
          },
        }),
      });
      final result = await GitHubUpdateService.checkForUpdate(
        client: MockClient((_) async => fail('throttled; no request expected')),
        clock: () => DateTime.utc(2026, 1, 1, 12),
        installedVersionLoader: () async => '1.0.0',
      );
      expect(result.hasUpdate, isFalse);
    });
  });

  group('cache follows the installed version', () {
    Future<UpdateCheckResult> check(
      http.Client client,
      String installed, {
      int minute = 0,
    }) => GitHubUpdateService.checkForUpdate(
      client: client,
      clock: () => DateTime.utc(2026, 1, 1, 12, minute),
      installedVersionLoader: () async => installed,
    );

    test('a reinstall or downgrade is re-checked at once', () async {
      // Found on a device: an "up to date" computed for 1.2.0 hid the 1.0.1
      // update for six hours after 1.0.0 was installed.
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(jsonEncode(_release('v1.0.1')), 200);
      });
      expect((await check(client, '1.2.0')).status, UpdateCheckStatus.upToDate);
      final after = await check(client, '1.0.0', minute: 1);
      expect(after.update?.latestVersion, _v('1.0.1'));
      expect(requests, 2);
      // Then the throttle applies again.
      await check(client, '1.0.0', minute: 2);
      expect(requests, 2);
    });

    test('a failed re-check does not retry on every resume', () async {
      var requests = 0;
      var online = true;
      final client = MockClient((_) async {
        requests++;
        if (!online) throw const SocketException('offline');
        return http.Response(jsonEncode(_release('v1.0.1')), 200);
      });
      await check(client, '1.2.0');
      online = false;
      await check(client, '1.0.0', minute: 1); // Re-check fails.
      await check(client, '1.0.0', minute: 2);
      await check(client, '1.0.0', minute: 3);
      expect(requests, 2);
    });

    test('results saved by older app versions are re-checked once', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.update.github.nextCheckAt.v2': DateTime.utc(
          2026,
          1,
          1,
          13,
        ).toIso8601String(),
        'onfeed.update.github.lastResult.v2': jsonEncode({
          'status': 'upToDate',
          'latestVersion': '1.0.1',
        }),
      });
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(jsonEncode(_release('v1.0.1')), 200);
      });
      expect((await check(client, '1.0.0')).hasUpdate, isTrue);
      expect(requests, 1);
    });
  });

  group('downloadApk', () {
    late Directory cache;
    final apkBytes = List<int>.generate(4096, (i) => i % 251);

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('reelish_update_test');
    });
    tearDown(() => cache.delete(recursive: true));

    MockClient serving(List<int> bytes, {int status = 200}) =>
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.fromIterable([
              for (var i = 0; i < bytes.length; i += 1024)
                bytes.sublist(i, (i + 1024).clamp(0, bytes.length)),
            ]),
            status,
            contentLength: bytes.length,
          ),
        );

    List<String> filesIn(Directory directory) => directory
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList();

    test('downloads, reports progress and verifies the digest', () async {
      final progress = <int>[];
      final file = await GitHubUpdateService.downloadApk(
        _update(
          size: apkBytes.length,
          sha: sha256.convert(apkBytes).toString(),
        ),
        client: serving(apkBytes),
        cacheDirectory: () async => cache,
        onProgress: (received, _) => progress.add(received),
      );
      expect(await file.readAsBytes(), apkBytes);
      expect(file.path, endsWith('reelish-1.0.1.apk'));
      expect(progress.last, apkBytes.length);
      expect(filesIn(cache), ['reelish-1.0.1.apk']);
    });

    test('rejects a corrupted download and leaves no files', () async {
      await expectLater(
        GitHubUpdateService.downloadApk(
          _update(size: apkBytes.length, sha: 'b' * 64),
          client: serving(apkBytes),
          cacheDirectory: () async => cache,
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(filesIn(cache), isEmpty);
    });

    test('rejects a truncated download', () async {
      await expectLater(
        GitHubUpdateService.downloadApk(
          _update(size: apkBytes.length + 10),
          client: serving(apkBytes),
          cacheDirectory: () async => cache,
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(filesIn(cache), isEmpty);
    });

    test('reports HTTP failures', () async {
      await expectLater(
        GitHubUpdateService.downloadApk(
          _update(),
          client: serving(const [], status: 404),
          cacheDirectory: () async => cache,
        ),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('removed'),
          ),
        ),
      );
    });

    test('refuses download links outside the release repository', () async {
      await expectLater(
        GitHubUpdateService.downloadApk(
          _update(url: 'https://example.com/reelish.apk'),
          client: serving(apkBytes),
          cacheDirectory: () async => cache,
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(filesIn(cache), isEmpty);
    });

    test('refuses the APK of another release', () async {
      var requests = 0;
      await expectLater(
        GitHubUpdateService.downloadApk(
          _update(version: '1.0.2', url: '$_download/v1.0.1/reelish.apk'),
          client: MockClient((_) async {
            requests++;
            return http.Response('', 200);
          }),
          cacheDirectory: () async => cache,
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(requests, 0);
    });

    test('scenario 8: a failed download can be retried', () async {
      var fail = true;
      final client = MockClient.streaming((_, _) async {
        if (fail) throw const SocketException('connection reset');
        return http.StreamedResponse(
          Stream.value(apkBytes),
          200,
          contentLength: apkBytes.length,
        );
      });
      final update = _update(size: apkBytes.length);
      await expectLater(
        GitHubUpdateService.downloadApk(
          update,
          client: client,
          cacheDirectory: () async => cache,
        ),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            isNot(contains('SocketException')),
          ),
        ),
      );
      expect(filesIn(cache), isEmpty);

      fail = false;
      final file = await GitHubUpdateService.downloadApk(
        update,
        client: client,
        cacheDirectory: () async => cache,
      );
      expect(file.lengthSync(), apkBytes.length);
      expect(filesIn(cache), ['reelish-1.0.1.apk']);
    });

    test('reuses a verified earlier download', () async {
      final update = _update(
        size: apkBytes.length,
        sha: sha256.convert(apkBytes).toString(),
      );
      await GitHubUpdateService.downloadApk(
        update,
        client: serving(apkBytes),
        cacheDirectory: () async => cache,
      );
      var requests = 0;
      final file = await GitHubUpdateService.downloadApk(
        update,
        client: MockClient((_) async {
          requests++;
          return http.Response('', 500);
        }),
        cacheDirectory: () async => cache,
      );
      expect(requests, 0);
      expect(await file.readAsBytes(), apkBytes);
    });
  });

  group('release notes', () {
    test('cleans generated GitHub notes', () {
      const generated = '''
## What's Changed
* Improve video playback by @frnzeeey in https://github.com/frnzeeey/reelish/pull/12
* Fix **login** issues by @frnzeeey in https://github.com/frnzeeey/reelish/pull/13

## New Contributors
* @someone made their first contribution in https://github.com/frnzeeey/reelish/pull/11

**Full Changelog**: https://github.com/frnzeeey/reelish/compare/v1.0.0...v1.0.1''';
      expect(
        formatReleaseNotes(generated),
        '• Improve video playback\n• Fix login issues',
      );
    });

    test('drops the build provenance the release workflow adds', () {
      const notes = '''
**Version:** 1.2.0 (Android versionCode 1002000)
**Commit:** 6e21ac91b18f9ced608b8a1626bc770b27906090
**APK SHA-256:** `caeea36fadd68d89581866659e5762bfb3b1db19c4771f7398e2b5c923948934`
**Built by:** https://github.com/frnzeeey/reelish/actions/runs/1

## What's Changed
* Cinematic pause screen by @frnzeeey in https://github.com/frnzeeey/reelish/pull/20''';
      expect(formatReleaseNotes(notes), '• Cinematic pause screen');
    });

    test('drops a "What\'s new" heading the dialog already shows', () {
      const notes = '''
## What's new

### Reelish on Android TV
- Find Reelish on your TV's home screen.''';
      expect(
        formatReleaseNotes(notes),
        "Reelish on Android TV\n• Find Reelish on your TV's home screen.",
      );
    });

    test('empty notes stay empty', () {
      expect(formatReleaseNotes(''), '');
      expect(
        formatReleaseNotes(
          '**Full Changelog**: https://github.com/frnzeeey/reelish/commits/v1.0.0',
        ),
        '',
      );
    });
  });

  group('update UI', () {
    setUp(AppUpdateFlow.resetForTest);

    testWidgets('a manual check takes over from a background check', (
      tester,
    ) async {
      final background = Completer<UpdateCheckResult>();
      final update = _update(version: '1.2.0');
      final available = UpdateCheckResult(
        UpdateCheckStatus.updateAvailable,
        update: update,
        latestVersion: update.latestVersion,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => AppUpdateFlow.checkAutomatically(
                      context,
                      checker: () => background.future,
                    ),
                    child: const Text('background'),
                  ),
                  TextButton(
                    onPressed: () => AppUpdateFlow.checkManually(
                      context,
                      checker: () async => available,
                    ),
                    child: const Text('manual'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('background'));
      await tester.pump();
      expect(AppUpdateFlow.phase, UpdateFlowPhase.checkingInBackground);

      // Previously answered "An update is already in progress".
      await tester.tap(find.text('manual'));
      await tester.pumpAndSettle();
      expect(find.text('An update is already in progress.'), findsNothing);
      expect(find.text('New Reelish update available'), findsOneWidget);
      expect(AppUpdateFlow.phase, UpdateFlowPhase.updating);

      // The background answer arriving later opens no second prompt.
      background.complete(available);
      await tester.pumpAndSettle();
      expect(find.text('New Reelish update available'), findsOneWidget);

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(AppUpdateFlow.phase, UpdateFlowPhase.idle);
    });

    testWidgets('scenario 7: a failing check never surfaces or throws', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => AppUpdateFlow.checkAutomatically(
                  context,
                  checker: () async => throw const SocketException('offline'),
                ),
                child: const Text('check'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(AppUpdateFlow.phase, UpdateFlowPhase.idle);
    });

    Future<void> pumpHome(
      WidgetTester tester,
      Future<UpdateCheckResult> Function() checker,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    AppUpdateFlow.checkAutomatically(context, checker: checker),
                child: const Text('check'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
    }

    testWidgets('no popup when up to date', (tester) async {
      await pumpHome(
        tester,
        () async => UpdateCheckResult(
          UpdateCheckStatus.upToDate,
          latestVersion: _v('1.0.0'),
        ),
      );
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('no popup when offline or the APK is missing', (tester) async {
      for (final status in [
        UpdateCheckStatus.networkError,
        UpdateCheckStatus.missingApk,
        UpdateCheckStatus.serverError,
      ]) {
        await pumpHome(tester, () async => UpdateCheckResult(status));
        expect(find.byType(Dialog), findsNothing, reason: status.name);
      }
    });

    testWidgets('shows versions and notes; Later is not repeated', (
      tester,
    ) async {
      final update = _update(version: '1.0.7', notes: '* Faster playback');
      Future<UpdateCheckResult> checker() async => UpdateCheckResult(
        UpdateCheckStatus.updateAvailable,
        update: update,
        latestVersion: update.latestVersion,
      );
      await pumpHome(tester, checker);
      expect(find.text('New Reelish update available'), findsOneWidget);
      expect(
        find.textContaining('Version 1.0.7 is now available'),
        findsOneWidget,
      );
      expect(find.textContaining('using version 1.0.0'), findsOneWidget);
      expect(find.text('• Faster playback'), findsOneWidget);

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);

      // The same release is not offered again in this session.
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('hides the notes section when notes are empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: UpdateAvailableDialog(update: _update())),
      );
      expect(find.text("What's new"), findsNothing);
    });

    testWidgets('download dialog shows progress and allows retry', (
      tester,
    ) async {
      var attempts = 0;
      void Function(int, int?)? report;
      await tester.pumpWidget(
        MaterialApp(
          home: UpdateDownloadDialog(
            update: _update(),
            download: (onProgress, _) async {
              attempts++;
              report = onProgress;
              if (attempts == 1) {
                throw const UpdateException('The download stalled.');
              }
              // Stays in progress for the rest of the test.
              return Completer<File>().future;
            },
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Download failed'), findsOneWidget);
      expect(find.text('The download stalled.'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(find.text('Downloading Reelish 1.0.1'), findsOneWidget);
      report!(78 * 1024 * 1024, 100 * 1024 * 1024);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('78%'), findsOneWidget);
      expect(find.text('78.0 MB / 100.0 MB'), findsOneWidget);
      expect(attempts, 2);
    });
  });
}
