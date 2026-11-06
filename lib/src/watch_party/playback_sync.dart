// The arithmetic of watch party sync, kept free of Flutter and sockets so it
// can be tested exactly: the server clock as seen from this device, where
// the room's timeline is now, and what a player should do about a gap.

import 'party_models.dart';

/// Estimates the server clock from `time` round trips (NTP-style): the
/// sample with the shortest round trip is the most accurate.
class ClockSync {
  int? _offsetMs;
  int _bestRoundTripMs = 1 << 30;

  /// Server time minus local time; zero until the first sample.
  int get offsetMs => _offsetMs ?? 0;
  bool get synced => _offsetMs != null;

  /// One round trip: sent at local [sentMs], answered with server [serverMs],
  /// received at local [receivedMs].
  void add(int sentMs, int serverMs, int receivedMs) {
    final roundTrip = receivedMs - sentMs;
    if (roundTrip < 0 || roundTrip > 10000) return;
    // A first estimate from the welcome message is replaced by any sample.
    if (_offsetMs != null && roundTrip >= _bestRoundTripMs) return;
    _bestRoundTripMs = roundTrip;
    _offsetMs = serverMs - (sentMs + roundTrip ~/ 2);
  }

  /// A new connection: its round trips replace the old ones, which may have
  /// taken another network path. The estimate stands until one arrives.
  void restart() => _bestRoundTripMs = 1 << 30;

  /// A rough estimate from a server timestamp alone, until samples arrive.
  void seed(int serverMs, int localMs) {
    _offsetMs ??= serverMs - localMs;
  }

  int serverNow(int localMs) => localMs + offsetMs;
}

/// Where the room's timeline is at server time [serverNowMs].
int expectedPositionMs(PartyPlayback playback, int serverNowMs) {
  if (!playback.playing) return playback.positionMs;
  final elapsed = (serverNowMs - playback.at).clamp(0, 24 * 60 * 60 * 1000);
  return playback.positionMs + (elapsed * playback.rate).round();
}

enum SyncAction {
  /// Close enough; play at normal speed.
  none,

  /// A little behind: play slightly faster until caught up.
  speedUp,

  /// A little ahead: play slightly slower until the room catches up.
  slowDown,

  /// Too far apart to catch up gently: jump to the room's position.
  seek,
}

/// How far apart is acceptable, and when to stop nudging. Values in ms.
class SyncThresholds {
  const SyncThresholds({
    this.ignoreMs = 500,
    this.settleMs = 150,
    this.seekMs = 3000,
    this.nudgeRate = 0.05,
    this.holdMs = 15000,
  });

  /// Gaps up to this are left alone.
  final int ignoreMs;

  /// While nudging, normal speed resumes once the gap is this small.
  final int settleMs;

  /// Gaps beyond this are fixed with a seek.
  final int seekMs;

  /// How much faster or slower a nudge plays (0.05 = 5 %).
  final double nudgeRate;

  /// A player ahead of the room by up to this waits for it. What it needs
  /// next is already buffered, so that is exact and costs only the wait; a
  /// seek back would buffer again and land late.
  final int holdMs;
}

/// How long a seek takes on this device and stream, from asking to the picture
/// moving again.
///
/// A player that seeks to where the room is now arrives that much behind it,
/// and on a stream that buffers for longer than [SyncThresholds.seekMs] would
/// then seek again, forever. Seeks aim ahead by this estimate instead; landing
/// a little early is cheap, because the player can wait for the room there.
class SeekCost {
  SeekCost({this.estimateMs = 2500});

  static const _minMs = 300;
  static const _maxMs = 12000;

  /// Smoothed cost of recent seeks.
  int estimateMs;

  /// How far ahead of the room a seek should aim: the estimate with a margin,
  /// since landing early costs less than landing late.
  int get leadMs => (estimateMs * 1.15).round();

  void add(int measuredMs) {
    final sample = measuredMs.clamp(_minMs, _maxMs);
    // Landing late is what costs another seek, so a slower sample counts in
    // full; a quicker one only brings the estimate down gradually.
    estimateMs = sample > estimateMs
        ? sample
        : ((estimateMs + sample) / 2).round();
  }
}

/// How long to wait before another correcting seek after [streak] of them
/// (from 1), on top of the seek itself. Doubles from 2 s up to 30 s, so a
/// stream that cannot keep up is not sought over and over.
int seekBackoffMs(int streak) =>
    (1000 << streak.clamp(1, 5)).clamp(2000, 30000);

/// One player's sync over a session, for debug and profile builds.
class PartySyncStats {
  /// Seeks that followed a change the room made.
  int commandedSeeks = 0;

  /// Seeks that corrected drift.
  int correctingSeeks = 0;
  int nudges = 0;
  int holds = 0;

  /// Largest gap to the room measured during steady playback.
  int worstDriftMs = 0;

  String summary() =>
      'commandedSeeks=$commandedSeeks correctingSeeks=$correctingSeeks '
      'nudges=$nudges holds=$holds worstDrift=${worstDriftMs}ms';
}

/// What to do about a gap of [driftMs] (local minus room; positive means
/// this player is ahead). [nudging] keeps a nudge going until the gap has
/// shrunk to the settle threshold, so the speed does not flap.
SyncAction decideSync(
  int driftMs, {
  bool nudging = false,
  SyncThresholds thresholds = const SyncThresholds(),
}) {
  final gap = driftMs.abs();
  if (gap > thresholds.seekMs) return SyncAction.seek;
  final limit = nudging ? thresholds.settleMs : thresholds.ignoreMs;
  if (gap <= limit) return SyncAction.none;
  return driftMs > 0 ? SyncAction.slowDown : SyncAction.speedUp;
}
