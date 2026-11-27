// Waits between provider lookups: a lookup the viewer left must not hold the
// runtime slots, and providers that wasted their slot run last next time
// (PB-01, PB-02 in docs/playback-audit/DEEP_AUDIT_2026-11-21.md). Runs real
// QuickJS runtimes with stand-in provider scripts whose timing is known.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/provider_plugin.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/provider_execution_scheduler.dart';
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

/// Answers after [ms] with one stream for the requested title.
String _after(String name, int ms) =>
    '''
  module.exports.getStreams = (tmdbId) => new Promise(r => setTimeout(() =>
    r([{ name: '$name', url: 'https://cdn.example/$name/' + tmdbId + '.m3u8' }]),
    $ms));
''';

/// The default limits, recording the most runtimes alive at once.
class _CountingScheduler extends ProviderExecutionScheduler {
  int active = 0;
  int mostActive = 0;

  @override
  Future<void> acquireRuntime() async {
    await super.acquireRuntime();
    active++;
    if (active > mostActive) mostActive = active;
  }

  @override
  void releaseRuntime() {
    active--;
    super.releaseRuntime();
  }
}

/// One repository whose providers keep the given order (first is highest
/// priority).
ProviderPluginService _service(
  Map<String, String> scripts, {
  ProviderExecutionScheduler? scheduler,
}) => ProviderPluginService(
  storage: StorageService(),
  scheduler: scheduler,
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
      // The diagnostics count what the demotion acted on.
      expect(first.stats.runs, 3);
      expect(first.stats.failed, 0);
      expect(first.stats.stalled, 2);
      expect(first.stats.firstSourceAfter, isNotNull);

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
    'a lookup counts runs and failures, not the runs it stopped',
    () async {
      final service = _service({
        'quick': _quick('quick'),
        'broken':
            "module.exports.getStreams = () => { throw new Error('x'); };",
        'late': _after('late', 3000),
      });
      await service.load();
      final lookup = service.discoverStreams(_movie('1'));
      await lookup.firstSource;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      lookup.cancel();
      await lookup.finished;

      expect(lookup.stats.runs, 2);
      expect(lookup.stats.failed, 1);
      expect(lookup.stats.stalled, 0);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // PB-11: torrents given by info hash alone (the Stremio shape) all had the
  // same key, their empty URL, so only the first of them survived a lookup.
  test(
    'torrents given only by info hash each survive the search',
    () async {
      final service = _service({
        'torrents':
            'module.exports.getStreams = async () => ['
            " { name: 'One', infoHash: '${'a' * 40}' },"
            " { name: 'Two', infoHash: '${'b' * 40}' },"
            " { name: 'One again', infoHash: '${'A' * 40}' } ];",
      });
      await service.load();
      final lookup = service.discoverStreams(_movie('1'));
      await lookup.finished;
      expect(lookup.sources.map((s) => s.name), ['One', 'Two']);

      final returned = await service.streams(_movie('2'));
      expect(returned.map((s) => s.name), ['One', 'Two']);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // PB-05 (docs/playback-audit/PLAYBACK_AUDIT_REPORT.md): a link refresh
  // needs new answers, not the lookup still running.
  group('fresh lookups', () {
    test(
      'a refresh starts its own lookup and leaves the running one going',
      () async {
        final scheduler = _CountingScheduler();
        final service = _service({
          'quick': _quick('quick'),
          'late': _after('late', 1500),
        }, scheduler: scheduler);
        await service.load();

        final first = service.discoverStreams(_movie('1'));
        expect((await first.firstSource)?.providerName, 'quick');
        // Play pressed again shares the running lookup.
        expect(service.discoverStreams(_movie('1')), same(first));

        final refresh = service.discoverStreams(_movie('1'), fresh: true);
        expect(refresh, isNot(same(first)));
        expect(first.isCancelled, isFalse);
        // A later Play shares the newest lookup.
        expect(service.discoverStreams(_movie('1')), same(refresh));

        await Future.wait([first.finished, refresh.finished]);
        // The first lookup's late provider still delivered.
        expect(first.sources.map((s) => s.providerName), ['quick', 'late']);
        expect(
          refresh.sources.map((s) => s.providerName),
          containsAll(['quick', 'late']),
        );
        // Both lookups shared the same two runtime slots.
        expect(scheduler.mostActive, 2);
        expect(scheduler.active, 0);
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'cancelling a refresh stops it and nothing else',
      () async {
        final service = _service({'late': _after('late', 3000)});
        await service.load();
        final first = service.discoverStreams(_movie('1'));
        final refresh = service.discoverStreams(_movie('1'), fresh: true);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final watch = Stopwatch()..start();
        refresh.cancel();
        await refresh.finished;
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(refresh.sources, isEmpty);

        await first.finished;
        expect(first.isCancelled, isFalse);
        expect(first.sources.single.providerName, 'late');
        expect(service.errors, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'a refresh that finds nothing does not stand in for later lookups',
      () async {
        final service = _service({'dead': _dead(200)});
        await service.load();
        final refresh = service.discoverStreams(_movie('1'), fresh: true);
        expect(await refresh.firstSource, isNull);
        await refresh.finished;
        await Future<void>.delayed(Duration.zero);

        final next = service.discoverStreams(_movie('1'));
        expect(next, isNot(same(refresh)));
        expect(next.isCancelled, isFalse);
        next.cancel();
        await next.finished;
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });

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
