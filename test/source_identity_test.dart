// Whether two provider results are the same source (PB-11 in
// docs/playback-audit/PLAYBACK_AUDIT_REPORT.md). The lookup's de-duplication
// (StreamDiscovery) and the player's attempts and fallbacks
// (PlaybackCoordinator) must agree, or a source is listed twice, or a
// different one counts as already tried.
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:onfeed/src/services/stream_discovery.dart';

const _hashA = '0123456789abcdef0123456789abcdef01234567';
const _hashB = 'fedcba9876543210fedcba9876543210fedcba98';

/// How many distinct sources the lookup keeps from [results], and how many
/// the player's coordinator counts as candidates.
({int lookup, int player}) _distinct(List<StreamSource> results) {
  final discovery = StreamDiscovery();
  final coordinator = PlaybackCoordinator();
  var candidates = 0;
  for (final result in results) {
    discovery.add(result);
    if (coordinator.addCandidate(result)) candidates++;
  }
  return (lookup: discovery.sources.length, player: candidates);
}

StreamSource _direct(
  String url, {
  Map<String, String> headers = const {},
  String provider = 'A',
}) => StreamSource(
  name: 'Stream',
  url: url,
  headers: headers,
  providerName: provider,
);

StreamSource _torrent(String hash, {int fileIdx = -1, String url = ''}) =>
    StreamSource(name: 'Torrent', url: url, infoHash: hash, fileIdx: fileIdx);

void main() {
  group('the lookup and the player agree on', () {
    test('the same link with its headers in another order: one source', () {
      final result = _distinct([
        _direct(
          'https://cdn.example/a.m3u8',
          headers: {'Referer': 'https://p.example/', 'Origin': 'https://p'},
        ),
        _direct(
          'https://cdn.example/a.m3u8',
          headers: {'Origin': 'https://p', 'Referer': 'https://p.example/'},
        ),
      ]);
      expect(result, (lookup: 1, player: 1));
    });

    test('header names in another case: one source (HTTP header names are '
        'not case-sensitive)', () {
      final result = _distinct([
        _direct(
          'https://cdn.example/a.m3u8',
          headers: {'Referer': 'https://p.example/'},
        ),
        _direct(
          'https://cdn.example/a.m3u8',
          headers: {'referer': 'https://p.example/'},
        ),
      ]);
      expect(result, (lookup: 1, player: 1));
    });

    test('different authorization values: two sources', () {
      final result = _distinct([
        _direct(
          'https://cdn.example/a.m3u8',
          headers: {'Authorization': 'Bearer one'},
        ),
        _direct(
          'https://cdn.example/a.m3u8',
          headers: {'Authorization': 'Bearer two'},
        ),
      ]);
      expect(result, (lookup: 2, player: 2));
    });

    test('different signed URLs or query parameters: two sources', () {
      final result = _distinct([
        _direct('https://cdn.example/a.m3u8?token=one&exp=1'),
        _direct('https://cdn.example/a.m3u8?token=two&exp=1'),
        _direct('https://cdn.example/a.m3u8?exp=1&token=one'),
      ]);
      expect(result, (lookup: 3, player: 3));
    });

    test('the identical request from two providers: one source, the first '
        'provider\'s', () {
      final first = _direct('https://cdn.example/a.m3u8', provider: 'A');
      final discovery = StreamDiscovery()
        ..add(first)
        ..add(_direct('https://cdn.example/a.m3u8', provider: 'B'));
      expect(discovery.sources.single.providerName, 'A');
      expect(
        _distinct([
          first,
          _direct('https://cdn.example/a.m3u8', provider: 'B'),
        ]),
        (lookup: 1, player: 1),
      );
    });

    test('torrents given only by info hash: one source per torrent', () {
      final result = _distinct([_torrent(_hashA), _torrent(_hashB)]);
      expect(result, (lookup: 2, player: 2));
    });

    test('one torrent\'s different files: one source per file', () {
      final result = _distinct([
        _torrent(_hashA, fileIdx: 3),
        _torrent(_hashA, fileIdx: 4),
      ]);
      expect(result, (lookup: 2, player: 2));
    });

    test('the same torrent twice, by hash in either case: one source', () {
      final result = _distinct([
        _torrent(_hashA, fileIdx: 3),
        _torrent(_hashA.toUpperCase(), fileIdx: 3),
      ]);
      expect(result, (lookup: 1, player: 1));
    });
  });

  group('attempts', () {
    test('trying one hash-only torrent does not count the others as tried', () {
      final coordinator = PlaybackCoordinator()
        ..replaceCandidates([_torrent(_hashA), _torrent(_hashB)]);
      final tried = _torrent(_hashA);
      coordinator.beginAttempt(tried, PlayerEngineId.mediaKit);
      coordinator.recordFailure(tried);
      expect(coordinator.wasAttempted(_torrent(_hashB)), isFalse);
      expect(coordinator.nextAfterFailure(tried)?.infoHash, _hashB);
    });

    test('a link with headers in another case counts as the one tried', () {
      final coordinator = PlaybackCoordinator();
      coordinator.beginAttempt(
        _direct('https://cdn.example/a.m3u8', headers: {'Referer': 'x'}),
        PlayerEngineId.mediaKit,
      );
      expect(
        coordinator.wasAttempted(
          _direct('https://cdn.example/a.m3u8', headers: {'referer': 'x'}),
        ),
        isTrue,
      );
    });
  });
}
