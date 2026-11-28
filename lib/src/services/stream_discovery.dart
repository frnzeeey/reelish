import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/stream_source.dart';
import 'source_quality.dart';

/// Owns one progressive provider lookup and its results for one playback request.
class StreamDiscovery {
  StreamDiscovery() : _startedAt = DateTime.now();

  final DateTime _startedAt;
  final List<StreamSource> _sources = [];
  final StreamController<StreamSource> _updates =
      StreamController<StreamSource>.broadcast();
  final Completer<StreamSource?> _firstSource = Completer<StreamSource?>();
  final Completer<void> _finished = Completer<void>();
  bool _cancelled = false;
  bool _completed = false;
  bool _recordedCandidate = false;

  /// Counts and times of this lookup, for diagnostics.
  final LookupStats stats = LookupStats();

  /// One provider finished: with an error ([failed]), and whether it
  /// wasted its runtime slot ([stalled]).
  void providerRan({required bool failed, required bool stalled}) {
    stats._runs++;
    if (failed) stats._failed++;
    if (stalled) stats._stalled++;
  }

  /// Why this lookup found no stream (no providers, all failed, paused for
  /// review...), once it has finished; null when nothing needs saying.
  String? message;

  List<StreamSource> get sources => List.unmodifiable(_sources);
  Stream<StreamSource> get updates => _replaySources();
  Future<StreamSource?> get firstSource => _firstSource.future;

  /// The source to start playback with. Usually [firstSource]; when that is a
  /// torrent, which needs metadata before playback can start, a direct stream
  /// arriving within [grace] is preferred. Direct first results never wait.
  ///
  /// With a [quality] target, the best-ranked source found so far starts
  /// (direct streams before torrents, then [QualityTarget.rank]). When it is
  /// not at the target, a source that is may still arrive: the wait lasts at
  /// most [qualityGrace] from the first result, ends as soon as one arrives
  /// or the lookup finishes, and then the best source found plays.
  Future<StreamSource?> startingSource({
    Duration grace = const Duration(seconds: 2),
    QualityTarget? quality,
    Duration qualityGrace = const Duration(seconds: 3),
  }) async {
    final first = await firstSource;
    if (quality != null && first != null) {
      return _bestWithin(quality, qualityGrace);
    }
    if (first == null || !first.isTorrent) return first;
    final direct = _sources.where((source) => !source.isTorrent).firstOrNull;
    if (direct != null) return direct;
    try {
      return await updates
          .firstWhere((source) => !source.isTorrent)
          .timeout(grace);
    } on TimeoutException {
      return first;
    } on StateError {
      // Discovery finished without a direct stream.
      return first;
    }
  }

  /// The best source by [quality], waiting up to [wait] for an ideal one.
  Future<StreamSource> _bestWithin(QualityTarget quality, Duration wait) async {
    int compare(StreamSource a, StreamSource b) {
      if (a.isTorrent != b.isTorrent) return a.isTorrent ? 1 : -1;
      return quality.rank(a).compareTo(quality.rank(b));
    }

    StreamSource best() => _sources.reduce((a, b) => compare(b, a) < 0 ? b : a);
    bool ideal(StreamSource source) =>
        !source.isTorrent && quality.isIdeal(source);

    if (ideal(best()) || _completed) return best();
    final done = Completer<void>();
    final subscription = _updates.stream.listen(
      (source) {
        if (ideal(source) && !done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    try {
      await done.future.timeout(wait, onTimeout: () {});
    } finally {
      await subscription.cancel();
    }
    return best();
  }

  Future<void> get finished => _finished.future;
  bool get isCancelled => _cancelled;

  /// Whether providers may still add sources: neither finished nor cancelled.
  bool get isRunning => !_completed && !_cancelled;

  void recordCandidate() {
    if (_recordedCandidate) return;
    _recordedCandidate = true;
    if (kDebugMode) {
      final elapsed = DateTime.now().difference(_startedAt).inMilliseconds;
      // ignore: avoid_print
      print('[Stream] First provider candidate (TTF) in ${elapsed}ms');
    }
  }

  Stream<StreamSource> _replaySources() => Stream.multi((controller) {
    final seen = <String>{};
    final subscription = _updates.stream.listen((source) {
      if (seen.add(_key(source))) controller.add(source);
    }, onDone: controller.close);
    controller.onCancel = subscription.cancel;
    // Subscribe first, then replay, so a source arriving during subscription
    // setup cannot be lost. The key set removes any replay/live duplicates.
    for (final source in _sources) {
      if (seen.add(_key(source))) controller.add(source);
    }
  });

  void add(StreamSource source) {
    if (_cancelled || _completed || !source.isPlayable) return;
    if (_sources.any((existing) => _key(existing) == _key(source))) return;
    _sources.add(source);
    if (!_firstSource.isCompleted) {
      _firstSource.complete(source);
      final after = stats._firstSourceAfter = DateTime.now().difference(
        _startedAt,
      );
      final elapsed = after.inMilliseconds;
      if (kDebugMode) {
        // Never include stream URLs or headers in playback diagnostics.
        // ignore: avoid_print
        print('[Stream] First valid source (TTR) in ${elapsed}ms');
      }
    }
    if (!_updates.isClosed) _updates.add(source);
  }

  void complete() {
    _completed = true;
    if (!_firstSource.isCompleted) _firstSource.complete(null);
    if (!_finished.isCompleted) _finished.complete();
    if (!_updates.isClosed) unawaited(_updates.close());
  }

  /// Completes on [cancel]; running provider runs stop when it does.
  Future<void> get whenCancelled => _cancelledSignal.future;
  final Completer<void> _cancelledSignal = Completer<void>();

  void cancel() {
    _cancelled = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
  }

  static String _key(StreamSource source) => source.identityKey;
}

/// What a [StreamDiscovery] measured, without its sources: counts and times
/// only, never which provider, link or title. Safe to keep for diagnostics.
class LookupStats {
  Duration? _firstSourceAfter;
  int _runs = 0;
  int _failed = 0;
  int _stalled = 0;

  /// How long the first valid source took from the lookup's start; null
  /// until one arrives.
  Duration? get firstSourceAfter => _firstSourceAfter;

  /// Providers that ran or failed to start so far. A run the lookup itself
  /// stopped (cancelled, search cap) is not counted.
  int get runs => _runs;
  int get failed => _failed;

  /// Runs that timed out or took the stall limit without a source: the
  /// ones later lookups in the session run last.
  int get stalled => _stalled;
}
