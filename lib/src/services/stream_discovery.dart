import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/stream_source.dart';

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

  List<StreamSource> get sources => List.unmodifiable(_sources);
  Stream<StreamSource> get updates => _replaySources();
  Future<StreamSource?> get firstSource => _firstSource.future;

  /// The source to start playback with. Usually [firstSource]; when that is a
  /// torrent, which needs metadata before playback can start, a direct stream
  /// arriving within [grace] is preferred. Direct first results never wait.
  Future<StreamSource?> startingSource({
    Duration grace = const Duration(seconds: 2),
  }) async {
    final first = await firstSource;
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
  Future<void> get finished => _finished.future;
  bool get isCancelled => _cancelled;

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
      final elapsed = DateTime.now().difference(_startedAt).inMilliseconds;
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

  void cancel() {
    _cancelled = true;
  }

  static String _key(StreamSource source) =>
      '${source.url}|${source.headers.entries.toList()..sort((a, b) => a.key.compareTo(b.key))}';
}
