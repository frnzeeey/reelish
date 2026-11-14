// Playback discovery for Universal Search: whether the viewer's enabled
// providers report sources for a movie, through the same provider lookup
// Play uses (ProviderPluginService.streams, by TMDB id, never by title).
// It is kept apart from metadata search: search never waits for it, one
// check runs at a time, a newer one cancels the older, and nothing here
// starts playback. A source found is a source a provider listed, not one
// that has been tried.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../models/stream_source.dart';

/// Asks the providers for [item]'s sources (the app passes the provider
/// lookup with the viewer's playback settings). Stops starting providers
/// once [isCancelled] says so; reports each source to [onSource].
typedef SourceLookup =
    Future<List<StreamSource>> Function(
      MediaItem item, {
      required bool Function() isCancelled,
      required void Function(StreamSource source) onSource,
    });

enum AvailabilityState {
  checking,

  /// At least one provider listed a source.
  found,

  /// Every provider answered and none listed a source.
  none,

  /// The check stopped before every provider answered, without a source.
  timedOut,
  failed,
}

/// What one provider listed: how many sources and what it said about them.
/// Only what the provider supplied; nothing is guessed.
class ProviderSources {
  ProviderSources(this.provider);

  final String provider;
  int count = 0;

  /// Quality labels as the provider wrote them (`1080p`, `4K`…).
  final Set<String> qualities = {};
  int torrents = 0;

  /// Sources that came with their own subtitle tracks.
  int withSubtitles = 0;
}

class TitleAvailability {
  TitleAvailability(this.item) : startedAt = DateTime.now();

  final MediaItem item;
  final DateTime startedAt;
  AvailabilityState state = AvailabilityState.checking;

  /// Every provider answered, or the check reached its limit.
  bool finished = false;
  final Map<String, ProviderSources> _providers = {};
  final Set<String> _seen = {};

  /// The providers that listed sources, most sources first.
  List<ProviderSources> get providers =>
      _providers.values.toList()..sort((a, b) => b.count - a.count);

  int get sourceCount =>
      _providers.values.fold(0, (total, provider) => total + provider.count);

  void _add(StreamSource source) {
    // The lookup removes duplicates at its end; sources reported as they
    // arrive are deduplicated here the same way (address and headers).
    final headers = source.headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (!_seen.add('${source.url}|$headers')) return;
    final name = source.providerName.trim().isEmpty
        ? 'Provider'
        : source.providerName.trim();
    final entry = _providers.putIfAbsent(name, () => ProviderSources(name));
    entry.count++;
    final quality = source.quality.trim();
    if (quality.isNotEmpty && quality.length <= 24) {
      entry.qualities.add(quality);
    }
    if (source.isTorrent) entry.torrents++;
    if (source.subtitles.isNotEmpty) entry.withSubtitles++;
  }
}

class PlaybackAvailability extends ChangeNotifier {
  PlaybackAvailability({
    required this._lookup,
    this.limit = const Duration(seconds: 45),
    this.keepFor = const Duration(minutes: 10),
  });

  final SourceLookup _lookup;

  /// The longest a check runs before it reports what it has.
  final Duration limit;

  /// How long a finished check is reused for the same title.
  final Duration keepFor;

  final Map<String, TitleAvailability> _results = {};
  String? _active;
  bool _disposed = false;

  static String _key(MediaItem item) => '${item.type}:${item.id}';

  /// The last check for [item], if any.
  TitleAvailability? of(MediaItem item) => _results[_key(item)];

  /// Whether [item] can be checked here: movies only, since providers look
  /// series up one episode at a time.
  static bool canCheck(MediaItem item) =>
      item.type == 'movie' && (int.tryParse(item.id) ?? 0) > 0;

  /// Asks the providers about [item]. A check for another title still
  /// running is cancelled; a running or recent finished one for [item] is
  /// reused unless [again].
  void check(MediaItem item, {bool again = false}) {
    if (_disposed || !canCheck(item)) return;
    final key = _key(item);
    if (_active == key) return;
    final previous = _results[key];
    if (!again &&
        previous != null &&
        previous.finished &&
        previous.state != AvailabilityState.failed &&
        DateTime.now().difference(previous.startedAt) < keepFor) {
      return;
    }
    cancel();
    final result = TitleAvailability(item);
    _results[key] = result;
    _active = key;
    notifyListeners();
    unawaited(_run(key, result));
  }

  Future<void> _run(String key, TitleAvailability result) async {
    var cancelled = false;
    bool stopped() => cancelled || _disposed || _active != key;
    try {
      await _lookup(
        result.item,
        isCancelled: stopped,
        onSource: (source) {
          if (stopped()) return;
          result._add(source);
          if (result.state == AvailabilityState.checking) {
            result.state = AvailabilityState.found;
          }
          notifyListeners();
        },
      ).timeout(limit);
      if (stopped()) return;
      result.state = result.sourceCount > 0
          ? AvailabilityState.found
          : AvailabilityState.none;
    } on TimeoutException {
      cancelled = true;
      if (_disposed) return;
      result.state = result.sourceCount > 0
          ? AvailabilityState.found
          : AvailabilityState.timedOut;
    } catch (_) {
      if (_disposed) return;
      result.state = result.sourceCount > 0
          ? AvailabilityState.found
          : AvailabilityState.failed;
    }
    result.finished = true;
    if (_active == key) _active = null;
    if (!_disposed) notifyListeners();
  }

  /// Stops the running check; providers already started finish their own
  /// bounded run, and no new ones start.
  void cancel() {
    final active = _active;
    if (active == null) return;
    _active = null;
    final result = _results[active];
    // Not finished: asked again later, it runs again.
    if (result != null && !result.finished) _results.remove(active);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _active = null;
    super.dispose();
  }
}
