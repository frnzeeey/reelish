import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/services/playback_source_policy.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:onfeed/src/services/provider_execution_scheduler.dart';
import 'package:onfeed/src/services/source_preparer.dart';
import 'package:onfeed/src/services/stream_normalizer.dart';
import 'package:onfeed/src/services/video_quality_selector.dart';

void main() {
  test('normalization preserves provider identity and media headers', () {
    final normalized = const StreamNormalizer().normalize(
      {
        'url': 'https://media.example/manifest',
        'mimeType': 'application/vnd.apple.mpegurl',
        'headers': {
          'User-Agent': 'Provider UA',
          'Referer': 'https://provider.example/',
          'Cookie': 'session=abc',
        },
      },
      providerId: 'provider-a',
      providerName: 'Provider A',
    );

    expect(normalized.source.providerId, 'provider-a');
    expect(normalized.source.headers['User-Agent'], 'Provider UA');
    expect(normalized.source.headers['Referer'], 'https://provider.example/');
    expect(normalized.source.headers['Cookie'], 'session=abc');
    expect(normalized.streamType, StreamType.hls);
  });

  test(
    'source preparation keeps headers and rejects private DNS results',
    () async {
      final source = StreamSource.fromJson({
        'url': 'https://media.example.org/video.mp4',
        'headers': {'Authorization': 'Bearer test'},
      });
      final preparer = SourcePreparer(
        destinations: NetworkDestinationValidator(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
      );
      final prepared = await preparer.prepare(source);
      expect(prepared.headers['Authorization'], 'Bearer test');
      expect(prepared.uri.host, 'media.example.org');

      final blocked = SourcePreparer(
        destinations: NetworkDestinationValidator(
          lookup: (_) async => [InternetAddress('10.0.0.5')],
        ),
      );
      await expectLater(blocked.prepare(source), throwsFormatException);
    },
  );

  test('candidate coordinator bounds automatic source retries', () {
    final coordinator = PlaybackCoordinator(maxAutomaticAttempts: 2);
    final first = StreamSource(
      name: 'first',
      url: 'https://one.example/video.mp4',
      providerName: 'A',
    );
    final second = StreamSource(
      name: 'second',
      url: 'https://two.example/video.mp4',
      providerName: 'B',
    );
    coordinator.replaceCandidates([first, second]);
    expect(coordinator.beginAttempt(first, PlayerEngineId.mediaKit), isTrue);
    expect(coordinator.nextAfterFailure(first), second);
    expect(coordinator.beginAttempt(second, PlayerEngineId.mediaKit), isTrue);
    expect(coordinator.nextAfterFailure(second), isNull);
  });

  test(
    'Android engine selection prefers Media3 and falls back to MediaKit',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final primary = PlayerEngineFactory.forCurrentPlatform();
      expect(primary, isA<Media3PlayerEngine>());
      expect(PlayerEngineFactory.alternateFor(primary), isA<MpvPlayerEngine>());
    },
  );

  test('provider scheduler keeps separate worker and runtime bounds', () {
    final scheduler = ProviderExecutionScheduler();
    expect(scheduler.workersFor(90), 4);
    expect(scheduler.runtimeLimit, 2);
    expect(scheduler.workersFor(1), 1);
  });

  test('video quality preference selects the closest supported rendition', () {
    expect(selectPreferredVideoHeight([2160, 1080, 720], 1080), 1080);
    expect(selectPreferredVideoHeight([2160, 1440], 1080), 1440);
    expect(selectPreferredVideoHeight([1080, 720, 480], 900), 720);
    expect(selectPreferredVideoHeight([null, null], 1080), isNull);
    expect(selectPreferredVideoHeight([1080, 720], 0), isNull);
  });

  test('source policy enforces provider and torrent settings', () {
    final providerStream = StreamSource(
      name: 'Provider stream',
      url: 'https://video.example/stream.m3u8',
      providerId: 'repo-a|provider-a',
    );
    final torrentStream = StreamSource(
      name: 'Torrent stream',
      url: 'magnet:?xt=urn:btih:${'a' * 40}',
      providerId: 'repo-a|provider-a',
    );

    expect(
      isPlaybackSourceAllowed(
        providerStream,
        allowedProviderIds: {'repo-a|provider-a'},
        allowTorrents: true,
      ),
      isTrue,
    );
    expect(
      isPlaybackSourceAllowed(
        providerStream,
        allowedProviderIds: {'repo-b|provider-b'},
        allowTorrents: true,
      ),
      isFalse,
    );
    expect(
      isPlaybackSourceAllowed(
        torrentStream,
        allowedProviderIds: {'repo-a|provider-a'},
        allowTorrents: true,
      ),
      isTrue,
    );
    expect(
      isPlaybackSourceAllowed(
        torrentStream,
        allowedProviderIds: {'repo-a|provider-a'},
        allowTorrents: false,
      ),
      isFalse,
    );
  });
}
