import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onfeed/src/services/github_update_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'reuses persisted GitHub check result within the six hour window',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(
          jsonEncode({
            'tag_name': 'v1.1.0',
            'draft': false,
            'prerelease': false,
            'body': 'Improvements',
            'assets': [
              {
                'name': 'app-release.apk',
                'browser_download_url':
                    'https://github.com/frnzeeey/reelish/releases/download/v1.1.0/app-release.apk',
              },
            ],
          }),
          200,
        );
      });
      final instant = DateTime.utc(2026, 1, 1, 12);

      final first = await GitHubUpdateService.checkForUpdate(
        client: client,
        clock: () => instant,
        installedVersionLoader: () async => '1.0.0',
      );
      final second = await GitHubUpdateService.checkForUpdate(
        client: client,
        clock: () => instant.add(const Duration(minutes: 5)),
        installedVersionLoader: () async => '1.0.0',
      );

      expect(first?.version, 'v1.1.0');
      expect(second?.version, 'v1.1.0');
      expect(requests, 1);
      client.close();
    },
  );

  test('does not offer the installed version from the cached result', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response(
        jsonEncode({
          'tag_name': 'v1.1.0',
          'draft': false,
          'prerelease': false,
          'body': '',
          'assets': [
            {
              'name': 'app-release.apk',
              'browser_download_url':
                  'https://github.com/frnzeeey/reelish/releases/download/v1.1.0/app-release.apk',
            },
          ],
        }),
        200,
      );
    });
    final instant = DateTime.utc(2026, 1, 1, 12);
    await GitHubUpdateService.checkForUpdate(
      client: client,
      clock: () => instant,
      installedVersionLoader: () async => '1.0.0',
    );

    final afterInstalling = await GitHubUpdateService.checkForUpdate(
      client: client,
      clock: () => instant.add(const Duration(minutes: 1)),
      installedVersionLoader: () async => '1.1.0',
    );

    expect(afterInstalling, isNull);
    expect(requests, 1);
    client.close();
  });
}
