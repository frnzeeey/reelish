import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../models/stream_source.dart';
import '../models/stream_type.dart';
import '../models/playable_source.dart';
import 'source_preparer.dart';
import 'player_engine.dart';

enum PlaybackFailureKind {
  /// The URL was rejected or its host did not resolve before any engine ran.
  preparation,

  /// The server answered with an HTTP error status.
  http,
  network,
  timeout,
  manifest,
  format,
  decoder,
  rendering,
  engine,

  /// An engine reported a non-specific source error (Media3's usual report).
  source,
  cancelled,
  unknown,
}

/// Thrown when a source fails validation or DNS before reaching an engine.
class SourcePreparationException implements Exception {
  const SourcePreparationException(this.cause);

  final Object cause;

  @override
  String toString() => '$cause';
}

class PlaybackFailure {
  const PlaybackFailure(this.kind, this.original, {this.statusCode});

  final PlaybackFailureKind kind;

  /// Reported when audio plays but the engine never draws a picture; it
  /// classifies as [PlaybackFailureKind.rendering].
  static const noPicture = 'The video renderer produced no picture.';
  final Object original;
  final int? statusCode;

  /// Another source may succeed for every failure except cancellation. A
  /// decoder or format failure can be specific to one source's codec.
  bool get canTryAnotherSource => kind != PlaybackFailureKind.cancelled;

  /// Whether retrying the same URL on the other engine can help. Network,
  /// HTTP, DNS and timeout failures do not depend on the engine, so retrying
  /// them only doubles the time spent on a dead source.
  bool get canTryAnotherEngine => switch (kind) {
    PlaybackFailureKind.manifest ||
    PlaybackFailureKind.format ||
    PlaybackFailureKind.decoder ||
    PlaybackFailureKind.rendering ||
    PlaybackFailureKind.engine ||
    PlaybackFailureKind.source ||
    PlaybackFailureKind.unknown => true,
    _ => false,
  };

  /// Short text for the player's error screen.
  String get userMessage => switch (kind) {
    PlaybackFailureKind.preparation =>
      'The provider returned a stream address that cannot be used.',
    PlaybackFailureKind.http => switch (statusCode) {
      401 || 403 => 'The stream host refused access (HTTP $statusCode).',
      404 || 410 => 'The stream is no longer available (HTTP $statusCode).',
      429 => 'The stream host is limiting requests (HTTP 429).',
      _ => 'The stream host returned an error (HTTP $statusCode).',
    },
    PlaybackFailureKind.network =>
      'Could not connect to the stream host. Check your connection.',
    PlaybackFailureKind.timeout => 'The stream took too long to start.',
    PlaybackFailureKind.manifest => 'The stream playlist could not be read.',
    PlaybackFailureKind.format =>
      'The provider did not return a recognizable video stream.',
    PlaybackFailureKind.decoder =>
      'This device could not decode the video format.',
    PlaybackFailureKind.rendering => 'The video could not be displayed.',
    PlaybackFailureKind.engine => 'The video player failed to start.',
    PlaybackFailureKind.source ||
    PlaybackFailureKind.unknown => 'The selected stream could not be opened.',
    PlaybackFailureKind.cancelled => 'Playback was cancelled.',
  };

  static final _url = RegExp(r'''[a-z][a-z0-9+.-]*://[^\s"'<>(),]+''');
  static final _httpStatus = RegExp(
    r'\b(?:http(?:\s*error)?|response code|status(?:\s*code)?)\D{0,12}([45]\d\d)\b',
  );

  static PlaybackFailure classify(Object error) {
    if (error is SourcePreparationException) {
      return PlaybackFailure(PlaybackFailureKind.preparation, error);
    }
    if (error is TimeoutException) {
      return PlaybackFailure(PlaybackFailureKind.timeout, error);
    }
    // Engine messages often embed the stream URL. Remove URLs first so a
    // path such as /render/ or a .m3u8 file name cannot change the result.
    final text = error.toString().toLowerCase().replaceAll(_url, ' ');
    bool has(List<String> words) => words.any(text.contains);
    if (has(['was cancelled', 'was canceled'])) {
      return PlaybackFailure(PlaybackFailureKind.cancelled, error);
    }
    if (has(['timed out', 'timeout'])) {
      return PlaybackFailure(PlaybackFailureKind.timeout, error);
    }
    final status = _httpStatus.firstMatch(text);
    if (status != null) {
      return PlaybackFailure(
        PlaybackFailureKind.http,
        error,
        statusCode: int.parse(status.group(1)!),
      );
    }
    if (has(['cleartext'])) {
      // Media3 obeys Android's cleartext policy; libmpv does not.
      return PlaybackFailure(PlaybackFailureKind.engine, error);
    }
    if (has([
      'unrecognized',
      'failed to recognize file format',
      'unsupported format',
      'no demuxer',
    ])) {
      return PlaybackFailure(PlaybackFailureKind.format, error);
    }
    if (has(['decoder', 'codec'])) {
      return PlaybackFailure(PlaybackFailureKind.decoder, error);
    }
    if (has(['surface', 'texture', 'render'])) {
      return PlaybackFailure(PlaybackFailureKind.rendering, error);
    }
    if (has(['manifest', 'playlist', 'm3u8', 'mpd'])) {
      return PlaybackFailure(PlaybackFailureKind.manifest, error);
    }
    if (has([
      'host lookup',
      'unknownhost',
      'unable to resolve',
      'name resolution',
      'socket',
      'connection',
      'network',
      'unreachable',
      'handshake',
      'certificate',
      'ssl',
      'tls',
    ])) {
      return PlaybackFailure(PlaybackFailureKind.network, error);
    }
    if (has(['source error', 'failed to open', 'could not open'])) {
      return PlaybackFailure(PlaybackFailureKind.source, error);
    }
    if (has(['engine'])) {
      return PlaybackFailure(PlaybackFailureKind.engine, error);
    }
    return PlaybackFailure(PlaybackFailureKind.unknown, error);
  }
}

/// Owns candidate identity, ranking and the bounded source-attempt policy
/// independently of widget rendering. Player construction remains behind
/// Flutter's VideoPlayerController API for compatibility with the controls.
class PlaybackCoordinator {
  PlaybackCoordinator({
    this.maxAutomaticAttempts = 5,
    SourcePreparer? sourcePreparer,
  }) : _sourcePreparer = sourcePreparer ?? SourcePreparer();

  /// Maximum number of distinct sources tried automatically. Retrying one
  /// source on the other engine does not use up this budget.
  final int maxAutomaticAttempts;
  final SourcePreparer _sourcePreparer;
  final Set<String> _attempted = {};
  final Set<String> _attemptedSources = {};
  final Set<String> _failedSources = {};
  final Map<String, int> _providerFailures = {};
  final List<StreamSource> _candidates = [];

  List<StreamSource> get candidates => List.unmodifiable(_candidates);

  /// Distinct sources attempted since the last [reset].
  int get attemptedCount => _attemptedSources.length;

  Future<({PlayableSource source, VideoPlayerController controller})>
  prepareAndOpen(
    StreamSource source, {
    required PlayerEngine engine,
    required bool allowLoopback,
    required Duration startupTimeout,
    required Future<void> cancellation,
  }) async {
    final PlayableSource prepared;
    try {
      prepared = await _sourcePreparer.prepare(
        source,
        allowLoopback: allowLoopback,
      );
    } catch (error) {
      throw SourcePreparationException(error);
    }
    await PlayerEngineGate.activate(engine);
    final controller = engine.createController(prepared);
    var initialized = false;
    try {
      final initialize = controller.initialize().timeout(startupTimeout).then((
        _,
      ) {
        initialized = true;
      });
      await Future.any<void>([
        initialize,
        cancellation.then((_) async {
          if (initialized) return;
          await controller.dispose();
          throw StateError('Playback initialization was cancelled.');
        }),
      ]);
      return (source: prepared, controller: controller);
    } catch (_) {
      await controller.dispose();
      rethrow;
    }
  }

  void reset() {
    _attempted.clear();
    _attemptedSources.clear();
  }

  void replaceCandidates(Iterable<StreamSource> sources) {
    _candidates
      ..clear()
      ..addAll(sources);
  }

  bool addCandidate(StreamSource source) {
    final key = sourceKey(source);
    if (_candidates.any((entry) => sourceKey(entry) == key)) return false;
    _candidates.add(source);
    return true;
  }

  String sourceKey(StreamSource source) {
    final headers = source.headers.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return '${source.url}|${jsonEncode(headers.map((entry) => [entry.key.toLowerCase(), entry.value]).toList())}';
  }

  String attemptKey(StreamSource source, PlayerEngineId engine) =>
      '${sourceKey(source)}|${engine.name}';

  bool beginAttempt(StreamSource source, PlayerEngineId engine) {
    _attemptedSources.add(sourceKey(source));
    return _attempted.add(attemptKey(source, engine));
  }

  bool wasAttempted(StreamSource source) =>
      _attemptedSources.contains(sourceKey(source));

  /// Records that [source] failed on every engine tried. Provider failures in
  /// this session lower that provider's later candidates. Idempotent.
  void recordFailure(StreamSource source) {
    if (!_failedSources.add(sourceKey(source))) return;
    final provider = source.providerName;
    if (provider.isNotEmpty) {
      _providerFailures[provider] = (_providerFailures[provider] ?? 0) + 1;
    }
  }

  /// The best untried candidate after [failed], or null when the automatic
  /// budget is spent. Ranking is deterministic: a different provider first,
  /// providers that already failed this session last, direct streams before
  /// torrents (which need metadata before they can start), and recognized
  /// stream types before unknown ones. Ties keep discovery order, which
  /// already reflects provider priority and response time.
  StreamSource? nextAfterFailure(StreamSource failed) {
    if (attemptedCount >= maxAutomaticAttempts) return null;
    final candidates = _candidates
        .where((source) => !wasAttempted(source))
        .toList();
    if (candidates.isEmpty) return null;
    int score(StreamSource source) {
      var value = 0;
      if (failed.providerName.isNotEmpty &&
          source.providerName != failed.providerName) {
        value += 8;
      }
      value -= 3 * (_providerFailures[source.providerName] ?? 0);
      if (!source.isTorrent) value += 4;
      if (source.detectedStreamType != StreamType.unknown) value += 1;
      return value;
    }

    final ranked =
        [
          for (var index = 0; index < candidates.length; index++)
            (
              source: candidates[index],
              score: score(candidates[index]),
              index: index,
            ),
        ]..sort((a, b) {
          final byScore = b.score.compareTo(a.score);
          return byScore != 0 ? byScore : a.index.compareTo(b.index);
        });
    return ranked.first.source;
  }
}

/// Development-only playback diagnostics. Lines never include stream URLs,
/// query strings, header values or cookies.
abstract final class PlaybackLog {
  static void log(String stage, String message) {
    if (!kDebugMode) return;
    debugPrint('[Playback][$stage] $message');
  }

  static String describe(StreamSource source) {
    final host = Uri.tryParse(source.url.trim())?.host ?? '';
    return [
      if (source.providerName.isNotEmpty) 'provider=${source.providerName}',
      'host=${source.isTorrent ? 'torrent' : (host.isEmpty ? '?' : host)}',
      'type=${source.detectedStreamType.name}',
      if (source.quality.isNotEmpty) 'quality=${source.quality}',
      'headers=${source.headers.isNotEmpty}',
    ].join(' ');
  }
}
