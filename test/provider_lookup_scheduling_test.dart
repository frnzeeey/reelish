// Waits between provider lookups: a lookup the viewer left must not hold the
// runtime slots, and providers that wasted their slot run last next time
// (PB-01, PB-02 in docs/playback-audit/DEEP_AUDIT_2026-11-21.md). Runs real
// QuickJS runtimes with stand-in provider scripts whose timing is known.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/provider_plugin.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/provider_plugin_service.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = 'https://example.com/repo/manifest.json';

/// Answers at once with one stream for the requested title.
String _quick(String name) =>
    '''
  module.exports.getStreams = async (tmdbId) =>
    [{ name: '$name', url: 'https://cdn.example/$name/' + tmdbId + '.m3u8' }];
''';

/// An upstream that takes [ms] and then finds nothing.
String _dead(int ms) =>
    'module.exports.getStreams = () => '
    'new Promise(r => setTimeout(() => r([]), $ms));';

/// Takes 8 s for title 1, answers at once for any other title.
String _slowForTitle1(String name) =>
    '''
  module.exports.getStreams = (tmdbId) => new Promise(r => {
    const list = [{ name: '$name', url: 'https://cdn.example/$name/' + tmdbId + '.m3u8' }];
    if (String(tmdbId) === '1') setTimeout(() => r(list), 8000); else r(list);
  });
''';

/// One repository whose providers keep the given order (first is highest
/// priority).
ProviderPluginService _service(Map<String, String> scripts) =>
    ProviderPluginService(
      storage: StorageService(),
      networkDestinations: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
      manifestReader: (url) async => ProviderRepository(
        url: url,
        name: 'repo',
        plugins: [
          for (final (i, name) in scripts.keys.indexed)
            ProviderPlugin(
              id: name,
              name: name,
              filename: '$name.js',
              priority: 100 - i,
            ),
        ],
      ),
      scriptReader: (uri) async =>
          scripts[uri.pathSegments.last.replaceAll('.js', '')]!,
    );

MediaItem _movie(String id) =>
    MediaItem.fromJson({'id': id, 'type': 'movie', 'name': 'Movie $id'});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'onfeed.nuvio.plugin.repositories': [_repo],
    });
  });

  test(
    'leaving a lookup frees its runtime slots for the next title',
    () async {
      // Both slots are taken by providers waiting 8 s on title 1. The viewer
      // backs out and picks title 2, which those providers answer at once.
      final service = _service({
        'slowA': _slowForTitle1('slowA'),
        'slowB': _slowForTitle1('slowB'),
      });
      await service.load();
      final left = service.discoverStreams(_movie('1'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      left.cancel();

      final watch = Stopwatch()..start();
      final next = service.discoverStreams(_movie('2'));
      expect(await next.firstSource, isNotNull);
      // Before the fix: about 7.5 s, until the old runs returned.
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));

      await left.finished;
      expect(left.sources, isEmpty);
      // Stopped runs are not provider failures.
      expect(service.errors, isEmpty);
      await next.finished;
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'providers that wasted their slot run after the others next time',
    () async {
      // Two top-priority providers take 11 s and find nothing; the third
      // answers at once but waits for a slot.
      final service = _service({
        'deadA': _dead(11000),
        'deadB': _dead(11000),
        'fastC': _quick('fastC'),
      });
      await service.load();

      final first = service.discoverStreams(_movie('1'));
      expect((await first.firstSource)?.providerName, 'fastC');
      await first.finished;

      final watch = Stopwatch()..start();
      final second = service.discoverStreams(_movie('2'));
      expect((await second.firstSource)?.providerName, 'fastC');
      // Before the fix: about 11 s again.
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      second.cancel();
      await second.finished;
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'slow providers that find sources keep their place',
    () async {
      // Slow, but finding a source is not wasting the slot: the manifest's
      // order stays, so the third provider waits again on the next lookup.
      final service = _service({
        'slowA': _slowForTitle1('slowA'),
        'slowB': _slowForTitle1('slowB'),
        'fastC': _quick('fastC'),
      });
      await service.load();
      final first = service.discoverStreams(_movie('1'));
      await first.finished;
      await Future<void>.delayed(Duration.zero);

      final second = service.discoverStreams(_movie('1'));
      final firstSource = await second.firstSource;
      expect(firstSource?.providerName, isNot('fastC'));
      await second.finished;
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
