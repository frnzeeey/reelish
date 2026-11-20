// Source prioritization by resolution (docs/playback/quality-prioritization.md):
// what sources claim, the device target, the starting source and fallback.
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/services/playback_quality_policy.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:onfeed/src/services/source_quality.dart';
import 'package:onfeed/src/services/stream_discovery.dart';

StreamSource _s(
  String id, {
  String quality = '',
  String name = 'Stream',
  String provider = 'A',
  bool torrent = false,
}) => StreamSource(
  name: name,
  url: torrent ? 'magnet:?xt=urn:btih:$id' : 'https://8.8.8.8/$id.m3u8',
  quality: quality,
  providerName: provider,
);

void main() {
  group('what a source claims', () {
    test('explicit heights and common labels', () {
      for (final (label, height) in const [
        ('2160p', 2160),
        ('4K', 2160),
        ('UHD HDR', 2160),
        ('1080p', 1080),
        ('1080', 1080),
        ('FHD', 1080),
        ('Full HD', 1080),
        ('720p', 720),
        ('480p', 480),
        ('SD', 480),
        ('8K', 4320),
        ('1920x1080', 1080),
      ]) {
        expect(SourceQuality.heightOf(label), height, reason: label);
      }
    });

    test('nothing is guessed', () {
      for (final label in const [
        '',
        'HD',
        'Auto',
        'Blade Runner 2049',
        'x265',
      ]) {
        expect(SourceQuality.heightOf(label), isNull, reason: label);
      }
    });

    test('quality field first, then the name', () {
      expect(
        SourceQuality.claimedHeight(
          _s('a', quality: '720p', name: 'Movie.2160p.mkv'),
        ),
        720,
      );
      expect(
        SourceQuality.claimedHeight(_s('a', name: 'Movie.2160p.HDR.mkv')),
        2160,
      );
    });
  });

  group('ranking against a target', () {
    final uhd = _s('uhd', quality: '4K');
    final fhd = _s('fhd', quality: '1080p');
    final hd = _s('hd', quality: '720p');
    final sd = _s('sd', quality: '480p');
    final unknown = _s('unknown');
    List<String> order(QualityTarget target, List<StreamSource> sources) =>
        ([...sources]..sort((a, b) => target.rank(a).compareTo(target.rank(b))))
            .map((s) => s.url.split('/').last.split('.').first)
            .toList();

    test('4K first, then 1080p, 720p; unknown before low; 480p last', () {
      expect(order(const QualityTarget(2160), [sd, unknown, hd, fhd, uhd]), [
        'uhd',
        'fhd',
        'hd',
        'unknown',
        'sd',
      ]);
    });

    test('a 1080p ceiling puts 4K after everything it can use', () {
      expect(order(const QualityTarget(1080), [uhd, sd, unknown, hd, fhd]), [
        'fhd',
        'hd',
        'unknown',
        'sd',
        'uhd',
      ]);
    });

    test('data saver prefers 480p', () {
      expect(order(const QualityTarget(480), [uhd, fhd, sd, unknown]), [
        'sd',
        'unknown',
        'fhd',
        'uhd',
      ]);
    });

    test('below a failed 4K comes 1440p, then 1080p', () {
      expect(QualityTarget.best.below(2160).height, 1440);
      expect(const QualityTarget(1440).below(1440).height, 1080);
      // Never raises the ceiling.
      expect(const QualityTarget(720).below(2160).height, 720);
    });
  });

  group('the target for this device', () {
    QualityTarget auto(VideoDeviceLimits d) =>
        PlaybackQualityPolicy.targetFor(0, d);

    test('Auto on a 4K TV that decodes 4K: 4K', () {
      expect(
        auto(
          const VideoDeviceLimits(maxDecodeHeight: 2160, displayHeight: 2160),
        ).height,
        2160,
      );
    });

    test('Auto on a phone or 1080p screen: 1080p', () {
      expect(
        auto(
          const VideoDeviceLimits(maxDecodeHeight: 2160, displayHeight: 1080),
        ).height,
        1080,
      );
    });

    test('Auto on a device that cannot decode 4K: 1080p', () {
      expect(
        auto(
          const VideoDeviceLimits(maxDecodeHeight: 1080, displayHeight: 2160),
        ).height,
        1080,
      );
    });

    test('Auto on a metered connection: at most 1080p', () {
      expect(
        auto(
          const VideoDeviceLimits(
            maxDecodeHeight: 2160,
            displayHeight: 2160,
            metered: true,
          ),
        ).height,
        1080,
      );
    });

    test('Auto with nothing known: 4K first', () {
      expect(auto(VideoDeviceLimits.unknown).height, 2160);
    });

    test('a chosen quality, never above what the device decodes', () {
      expect(
        PlaybackQualityPolicy.targetFor(
          2160,
          const VideoDeviceLimits(maxDecodeHeight: 1080),
        ).height,
        1080,
      );
      expect(
        PlaybackQualityPolicy.targetFor(720, VideoDeviceLimits.unknown).height,
        720,
      );
    });

    test('an unreadable device falls back to unknown', () async {
      final previous = PlaybackQualityPolicy.readLimits;
      addTearDown(() => PlaybackQualityPolicy.readLimits = previous);
      PlaybackQualityPolicy.readLimits = () async => throw Exception('no');
      expect((await PlaybackQualityPolicy.resolve(0)).height, 2160);
    });
  });

  group('starting source', () {
    test('4K and 1080p both found: 4K plays at once', () async {
      final d = StreamDiscovery()
        ..add(_s('fhd', quality: '1080p'))
        ..add(_s('uhd', quality: '2160p'));
      final start = await d.startingSource(quality: QualityTarget.best);
      expect(start!.quality, '2160p');
    });

    test('only 1080p: plays after the short wait, no longer', () async {
      final d = StreamDiscovery()..add(_s('fhd', quality: '1080p'));
      final clock = Stopwatch()..start();
      final start = await d.startingSource(
        quality: QualityTarget.best,
        qualityGrace: const Duration(milliseconds: 200),
      );
      expect(start!.quality, '1080p');
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a 4K source arriving during the wait wins', () async {
      final d = StreamDiscovery()..add(_s('fhd', quality: '1080p'));
      final pending = d.startingSource(
        quality: QualityTarget.best,
        qualityGrace: const Duration(seconds: 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      d.add(_s('uhd', quality: '4K'));
      expect((await pending)!.quality, '4K');
    });

    test('a finished lookup never waits', () async {
      final d = StreamDiscovery()
        ..add(_s('hd', quality: '720p'))
        ..complete();
      final clock = Stopwatch()..start();
      await d.startingSource(quality: QualityTarget.best);
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('a direct stream still comes before a 4K torrent', () async {
      final d = StreamDiscovery()
        ..add(_s('t', quality: '2160p', torrent: true))
        ..add(_s('fhd', quality: '1080p'))
        ..complete();
      final start = await d.startingSource(quality: QualityTarget.best);
      expect(start!.isTorrent, isFalse);
    });

    test('without a target, the first source as before', () async {
      final d = StreamDiscovery()
        ..add(_s('hd', quality: '720p'))
        ..add(_s('uhd', quality: '4K'));
      expect((await d.startingSource())!.quality, '720p');
    });
  });

  group('fallback by tier', () {
    PlaybackCoordinator coordinator(List<StreamSource> sources) =>
        PlaybackCoordinator()
          ..quality = QualityTarget.best
          ..replaceCandidates(sources);

    test('a failed 4K tries the other 4K, then 1080p, then 720p', () {
      final a = _s('a', quality: '4K', provider: 'A');
      final b = _s('b', quality: '4K', provider: 'B');
      final c = _s('c', quality: '1080p', provider: 'C');
      final d = _s('d', quality: '720p', provider: 'D');
      final p = coordinator([d, c, b, a]);
      p.beginAttempt(a, PlayerEngineId.mediaKit);
      p.recordFailure(a, kind: PlaybackFailureKind.network);
      expect(p.nextAfterFailure(a), b);
      p.beginAttempt(b, PlayerEngineId.mediaKit);
      p.recordFailure(b, kind: PlaybackFailureKind.http);
      expect(p.nextAfterFailure(b), c);
      p.beginAttempt(c, PlayerEngineId.mediaKit);
      p.recordFailure(c, kind: PlaybackFailureKind.timeout);
      expect(p.nextAfterFailure(c), d);
    });

    test('a 4K the device cannot decode skips the other 4K', () {
      final a = _s('a', quality: '4K', provider: 'A');
      final b = _s('b', quality: '4K', provider: 'B');
      final c = _s('c', quality: '1080p', provider: 'C');
      final p = coordinator([a, b, c]);
      p.beginAttempt(a, PlayerEngineId.media3);
      p.recordFailure(a, kind: PlaybackFailureKind.decoder);
      expect(p.quality!.height, 1440);
      expect(p.nextAfterFailure(a), c);
    });

    test('a 4K that never drew a picture also lowers the ceiling', () {
      final a = _s('a', quality: '2160p');
      final p = coordinator([a, _s('b', quality: '1080p', provider: 'B')]);
      p.beginAttempt(a, PlayerEngineId.media3);
      p.recordFailure(a, kind: PlaybackFailureKind.rendering);
      expect(p.quality!.height, 1440);
    });

    test('a provider that failed twice goes last whatever it claims', () {
      final a1 = _s('a1', quality: '4K', provider: 'A');
      final a2 = _s('a2', quality: '4K', provider: 'A');
      final a3 = _s('a3', quality: '4K', provider: 'A');
      final b = _s('b', quality: '720p', provider: 'B');
      final p = coordinator([a1, a2, a3, b]);
      for (final s in [a1, a2]) {
        p.beginAttempt(s, PlayerEngineId.mediaKit);
        p.recordFailure(s, kind: PlaybackFailureKind.http);
      }
      expect(p.nextAfterFailure(a2), b);
    });

    test('everything unavailable: stops at the attempt budget', () {
      final sources = [
        for (var i = 0; i < 8; i++)
          _s('s$i', quality: '1080p', provider: 'P$i'),
      ];
      final p = coordinator(sources);
      StreamSource? next = sources.first;
      var tried = 0;
      while (next != null) {
        p.beginAttempt(next, PlayerEngineId.mediaKit);
        p.recordFailure(next, kind: PlaybackFailureKind.network);
        tried++;
        next = p.nextAfterFailure(next);
      }
      expect(tried, p.maxAutomaticAttempts);
    });
  });
}
