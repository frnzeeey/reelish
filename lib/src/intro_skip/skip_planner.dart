// Decides, tick by tick, whether the player should skip an intro or outro
// now, offer a Skip button, or do nothing. Pure Dart: the player reports its
// position and state and its seeks, and carries out what this returns
// through its own seek path. docs/player/INTRO_OUTRO_IMPLEMENTATION.md.

import 'skip_segments.dart';

/// What the viewer chose for a kind of segment (Settings > Playback).
enum SkipMode {
  /// Seek past it as soon as it starts, when the data is strong enough;
  /// otherwise offer the button.
  auto,

  /// Offer a Skip button while it plays.
  button,

  /// Do nothing.
  off;

  static SkipMode parse(Object? value, SkipMode fallback) =>
      SkipMode.values.asNameMap()[value] ?? fallback;
}

/// The planner's answer for one tick.
class SkipPlan {
  const SkipPlan({this.seekTo, this.offer});

  static const none = SkipPlan();

  /// Seek here now (automatic skip). Always ahead of the position.
  final Duration? seekTo;

  /// The segment a Skip button should offer, while it plays.
  final SkipSegment? offer;

  @override
  bool operator ==(Object other) =>
      other is SkipPlan && other.seekTo == seekTo && other.offer == offer;

  @override
  int get hashCode => Object.hash(seekTo, offer);
}

enum _State {
  /// May be skipped automatically when playback reaches it.
  armed,

  /// The viewer sought into it: watched on purpose, never skipped
  /// automatically (the button still shows).
  disarmed,

  /// Skipped, or the viewer sought past it.
  done,
}

class SkipPlanner {
  SkipPlanner({
    required this.introMode,
    required this.outroMode,
    this.allowAutomatic = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  SkipMode introMode, outroMode;

  /// False in a Watch Party, where the room decides the position.
  bool allowAutomatic;

  final DateTime Function() _clock;

  /// A segment counts as playing from slightly before its start (the
  /// player's position is sampled) until shortly before its end (a skip
  /// for the last second is pointless and would loop on a rounded end).
  static const leadIn = Duration(milliseconds: 500);
  static const tailOut = Duration(milliseconds: 1500);

  /// After a skip, the planner waits for the position to arrive near the
  /// target, or this long, before deciding anything again.
  static const seekTimeout = Duration(seconds: 4);

  EpisodeSegments? _segments;
  Duration _duration = Duration.zero;
  EpisodeSegments? _usable;
  final _state = {SkipKind.intro: _State.armed, SkipKind.outro: _State.armed};
  ({Duration target, DateTime until})? _pending;
  Duration? _lastUserSeek;
  bool _disposed = false;

  /// IntroDB's data for this episode; may arrive at any time, also after
  /// playback has passed a segment.
  void setSegments(EpisodeSegments segments) {
    _segments = segments;
    _usable = null;
  }

  /// The segments usable for this stream, once its duration is known.
  EpisodeSegments? get usable => _usable;

  /// The viewer (or anything other than this planner) moved the position.
  void userSeeked(Duration to) {
    _pending = null;
    _lastUserSeek = to;
    _applyUserSeek(to);
  }

  void _applyUserSeek(Duration to) {
    final usable = _usable;
    if (usable == null) return;
    for (final segment in [usable.intro, usable.outro]) {
      if (segment == null) continue;
      _state[segment.kind] = to < segment.start - leadIn
          // Back before it: watching again from there, so it may be
          // skipped again.
          ? _State.armed
          : to < segment.end - tailOut
          ? _State.disarmed
          : _State.done;
    }
  }

  SkipMode _mode(SkipKind kind) =>
      kind == SkipKind.intro ? introMode : outroMode;

  /// What to do at [position]. [ready] is false while the stream opens,
  /// switches source or fails.
  SkipPlan update({
    required Duration position,
    required Duration duration,
    required bool playing,
    required bool buffering,
    required bool ready,
  }) {
    if (_disposed || !ready || duration <= Duration.zero) return SkipPlan.none;
    final segments = _segments;
    if (segments == null) return SkipPlan.none;
    if (_usable == null || duration != _duration) {
      _duration = duration;
      _usable = segments.forStream(duration);
      // A seek made before the data arrived still counts.
      final seek = _lastUserSeek;
      if (seek != null) _applyUserSeek(seek);
    }
    final pending = _pending;
    if (pending != null) {
      final arrived = position >= pending.target - tailOut;
      if (!arrived && _clock().isBefore(pending.until)) return SkipPlan.none;
      _pending = null;
    }
    final usable = _usable!;
    for (final segment in [usable.intro, usable.outro]) {
      if (segment == null || !segment.canOffer) continue;
      final mode = _mode(segment.kind);
      if (mode == SkipMode.off) continue;
      final inside =
          position >= segment.start - leadIn &&
          position < segment.end - tailOut;
      if (!inside) continue;
      if (mode == SkipMode.auto &&
          allowAutomatic &&
          segment.canAutoSkip &&
          _state[segment.kind] == _State.armed &&
          playing &&
          !buffering) {
        final target = _target(segment, duration);
        if (target > position) {
          _state[segment.kind] = _State.done;
          _pending = (target: target, until: _clock().add(seekTimeout));
          return SkipPlan(seekTo: target);
        }
      }
      return SkipPlan(offer: segment);
    }
    return SkipPlan.none;
  }

  /// The Skip button was pressed for [segment]: where to seek, or null
  /// when it no longer applies (playback moved on, or a skip is under way).
  Duration? skip(SkipSegment segment) {
    final usable = _usable;
    if (_disposed || usable == null || _pending != null) return null;
    if (segment != usable.intro && segment != usable.outro) return null;
    final target = _target(segment, _duration);
    _state[segment.kind] = _State.done;
    _pending = (target: target, until: _clock().add(seekTimeout));
    return target;
  }

  static Duration _target(SkipSegment segment, Duration duration) =>
      segment.end > duration ? duration : segment.end;

  /// Nothing more is planned once the player is gone.
  void dispose() => _disposed = true;
}
