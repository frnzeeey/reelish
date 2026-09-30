import 'dart:async';
import 'dart:convert';

import 'package:video_player/video_player.dart';

import '../models/stream_source.dart';
import '../models/playable_source.dart';
import 'source_preparer.dart';
import 'player_engine.dart';

enum PlaybackFailureKind {
  network,
  source,
  manifest,
  timeout,
  decoder,
  rendering,
  engine,
  unknown,
}

class PlaybackFailure {
  const PlaybackFailure(this.kind, this.original);

  final PlaybackFailureKind kind;
  final Object original;

  bool get canTryAnotherSource => switch (kind) {
    PlaybackFailureKind.network ||
    PlaybackFailureKind.source ||
    PlaybackFailureKind.manifest ||
    PlaybackFailureKind.timeout ||
    PlaybackFailureKind.unknown => true,
    PlaybackFailureKind.decoder ||
    PlaybackFailureKind.rendering ||
    PlaybackFailureKind.engine => false,
  };

  static PlaybackFailure classify(Object error) {
    final text = error.toString().toLowerCase();
    if (error is TimeoutException || text.contains('timeout')) {
      return PlaybackFailure(PlaybackFailureKind.timeout, error);
    }
    if (text.contains('decoder') || text.contains('codec')) {
      return PlaybackFailure(PlaybackFailureKind.decoder, error);
    }
    if (text.contains('surface') ||
        text.contains('texture') ||
        text.contains('render')) {
      return PlaybackFailure(PlaybackFailureKind.rendering, error);
    }
    if (text.contains('engine')) {
      return PlaybackFailure(PlaybackFailureKind.engine, error);
    }
    if (text.contains('manifest') ||
        text.contains('playlist') ||
        text.contains('.m3u8') ||
        text.contains('.mpd')) {
      return PlaybackFailure(PlaybackFailureKind.manifest, error);
    }
    if (text.contains('http') ||
        text.contains('socket') ||
        text.contains('network') ||
        text.contains('connection')) {
      return PlaybackFailure(PlaybackFailureKind.network, error);
    }
    return PlaybackFailure(PlaybackFailureKind.source, error);
  }
}

/// Owns candidate identity and bounded source-attempt policy independently of
/// widget rendering. Player construction remains behind Flutter's
/// VideoPlayerController API for compatibility with the existing controls.
class PlaybackCoordinator {
  PlaybackCoordinator({
    this.maxAutomaticAttempts = 5,
    SourcePreparer? sourcePreparer,
  }) : _sourcePreparer = sourcePreparer ?? SourcePreparer();

  final int maxAutomaticAttempts;
  final SourcePreparer _sourcePreparer;
  final Set<String> _attempted = {};
  final List<StreamSource> _candidates = [];

  List<StreamSource> get candidates => List.unmodifiable(_candidates);
  int get attemptedCount => _attempted.length;

  Future<({PlayableSource source, VideoPlayerController controller})>
  prepareAndOpen(
    StreamSource source, {
    required PlayerEngine engine,
    required bool allowLoopback,
    required Duration startupTimeout,
    required Future<void> cancellation,
  }) async {
    final prepared = await _sourcePreparer.prepare(
      source,
      allowLoopback: allowLoopback,
    );
    engine.activate();
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

  void reset() => _attempted.clear();

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

  bool beginAttempt(StreamSource source, PlayerEngineId engine) =>
      _attempted.add(attemptKey(source, engine));

  bool wasAttempted(StreamSource source) =>
      _attempted.any((key) => key.startsWith('${sourceKey(source)}|'));

  StreamSource? nextAfterFailure(StreamSource failed) {
    if (_attempted.length >= maxAutomaticAttempts) return null;
    final candidates = _candidates
        .where((source) => !wasAttempted(source))
        .toList();
    if (candidates.isEmpty) return null;
    final provider = failed.providerName;
    if (provider.isEmpty) return candidates.first;
    return candidates
            .where((source) => source.providerName != provider)
            .firstOrNull ??
        candidates.first;
  }
}
