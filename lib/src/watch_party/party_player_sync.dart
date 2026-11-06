// Keeps one player in step with its watch party. The player reports the
// viewer's own actions here (sent to the room) and exposes a handle whose
// commands are the remote path: applying the room's timeline through them
// never counts as a viewer action, so a remote pause is not sent back as a
// new pause. Automatic changes (buffering, the end) are reported as status.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'party_models.dart';
import 'playback_sync.dart';
import 'watch_party_controller.dart';

/// What sync can see of the player, and its remote commands.
abstract interface class PartyPlayerHandle {
  /// A picture is up and the engine accepts commands.
  bool get ready;
  bool get playing;
  bool get buffering;

  /// The title has played to its end here.
  bool get completed;

  /// The player gave up on every source.
  bool get failed;
  Duration get position;

  /// The episode on screen, or nulls for a movie.
  int? get season;
  int? get episode;

  Future<void> remotePlay();
  Future<void> remotePause();
  Future<void> remoteSeek(Duration position);
  Future<void> remoteSpeed(double rate);

  /// Follows the host to another episode of the same series.
  void remoteEpisode(int season, int episode);

  /// A short message for the viewer (such as who controls playback).
  void notice(String message);
}

/// What the player's party badge says.
enum PartySyncState {
  /// This player is still finding or opening a source.
  loading,

  /// No source on this device could play the title.
  unavailable,
  waitingForEveryone,
  waitingForHost,
  inSync,
  catchingUp,
  reconnecting,
  ended,
}

class PartyPlayerSync extends ChangeNotifier {
  PartyPlayerSync(
    this.party, {
    @visibleForTesting int Function()? clock,
    this.thresholds = const SyncThresholds(),
    this.checkEvery = const Duration(seconds: 2),
    this.heartbeatEvery = const Duration(seconds: 10),
    this.waitLimit = const Duration(seconds: 45),
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _playbackSubscription = party.playbackChanges.listen(_onPlayback);
    party.addListener(_onParty);
  }

  /// The active party, when it plays [item]'s [season] and [episode].
  static PartyPlayerSync? forTitle({
    required String id,
    required String type,
    int? season,
    int? episode,
  }) {
    final party = WatchPartyController.active.value;
    final room = party?.room;
    if (party == null || room == null || room.phase != PartyPhase.watching) {
      return null;
    }
    bool plays(PartyContent? content) =>
        content != null &&
        '${content.tmdbId}' == id &&
        content.type == type &&
        (!content.isSeries ||
            (content.season == season && content.episode == episode));
    if (!plays(room.content) && !plays(party.pendingContent)) return null;
    return PartyPlayerSync(party);
  }

  final WatchPartyController party;
  final SyncThresholds thresholds;
  final Duration checkEvery;
  final Duration heartbeatEvery;

  /// How long the host waits for everyone before starting anyway.
  final Duration waitLimit;
  final int Function() _clock;

  StreamSubscription<PartyPlayback>? _playbackSubscription;
  PartyPlayerHandle? _player;
  Timer? _check;
  Timer? _heartbeat;
  Timer? _bufferingReport;
  bool _wasReady = false;
  bool _nudging = false;
  double _rate = 1;
  int _echoAfterSeq = 0;
  int _awaitingEchoUntil = 0;

  /// The room's last change this player has acted on.
  int _appliedSeq = -1;

  /// Until then a seek is in flight, and the position means nothing yet.
  int _settleUntil = 0;

  /// No correcting seek before this (see [seekBackoffMs]).
  int _nextSeekAt = 0;
  int _seekStreak = 0;

  /// The seek being timed: when it was asked for, and where to.
  int? _seekStartedAt;
  int _seekTarget = 0;

  /// The last seek just landed, so a small lead is waited out once.
  bool _arrived = false;

  /// Paused at a spot the room has not reached; plays when it does.
  Timer? _hold;
  bool _wasBuffering = false;
  int? _endSentFor;
  int _lastHeartbeatAt = 0;
  final SeekCost _seekCost = SeekCost();

  /// What this player's sync did, for diagnostics.
  final PartySyncStats stats = PartySyncStats();
  int? _readyAt;
  bool _started = false;
  int? _followedEpisodeKey;
  PartySyncState _state = PartySyncState.loading;

  PartySyncState get state => _state;
  bool get canControl => party.canControl;
  bool get isHost => party.isHost;
  PartyRoom? get room => party.room;

  /// Participants whose player is ready, and how many there are.
  ({int ready, int total}) get readiness {
    final people = party.room?.participants ?? const <PartyParticipant>[];
    return (
      ready: people.where((p) => _settled(p.status)).length,
      total: people.length,
    );
  }

  static bool _settled(ParticipantStatus status) =>
      status != ParticipantStatus.joined && status != ParticipantStatus.loading;

  void attach(PartyPlayerHandle player) {
    _player = player;
    party
      ..notePlayerOpened()
      ..reportStatus(ParticipantStatus.loading);
    _check?.cancel();
    _check = Timer.periodic(checkEvery, (_) => _reconcile());
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatEvery, (_) => _sendHeartbeat());
  }

  void detach() {
    // Back in the waiting room, still in the party; a title this device
    // cannot play stays marked so.
    final player = _player;
    if (player != null && !player.failed && party.endReason == null) {
      party.reportStatus(ParticipantStatus.joined);
    }
    _player = null;
    _check?.cancel();
    _heartbeat?.cancel();
    _bufferingReport?.cancel();
    _hold?.cancel();
    _hold = null;
    if (!kReleaseMode) {
      debugPrint(
        '[PartySync] ${stats.summary()} seekCost=${_seekCost.estimateMs}ms '
        '${party.stats.summary()}',
      );
    }
  }

  // ---- Opening ----

  /// Where a player opening now should start, from the room's latest state,
  /// or null before the room has started. Asked for at the moment of the
  /// seek, so a change made while the source was found is already in it.
  Duration? takeOpeningPosition() {
    final playback = party.room?.playback;
    if (playback == null || !_startedFor(playback)) return null;
    final expected = expectedPositionMs(
      playback,
      party.clock.serverNow(_clock()),
    );
    if (!playback.playing) return Duration(milliseconds: expected);
    final target = expected + _seekCost.leadMs;
    _seekTarget = target;
    _seekStartedAt = _clock();
    _settleUntil = _clock() + 1500;
    _appliedSeq = playback.seq;
    return Duration(milliseconds: target);
  }

  /// Whether a player opening now should wait instead of starting: the room
  /// is paused or has not started (the host starts it when everyone is ready).
  bool get holdOpening {
    final playback = party.room?.playback;
    return playback == null || !playback.playing;
  }

  // ---- The viewer's own actions ----

  /// Whether the viewer may play, pause or seek; says why not if not.
  bool allowLocal() {
    if (canControl) return true;
    _player?.notice('${party.room?.hostName ?? 'The host'} controls playback.');
    return false;
  }

  /// Whether the viewer may move to another episode (the host only).
  bool allowEpisodeChange() {
    if (isHost) return true;
    _player?.notice('Only the host can change the episode.');
    return false;
  }

  void localPlay(Duration position) => _local('play', position);
  void localPause(Duration position) => _local('pause', position);
  void localSeek(Duration position) => _local('seek', position);

  void localEpisode(int season, int episode) {
    final content = party.room?.content;
    if (!isHost || content == null || !content.isSeries) return;
    party.changeContent(
      PartyContent(
        tmdbId: content.tmdbId,
        type: content.type,
        title: content.title,
        posterPath: content.posterPath,
        season: season,
        episode: episode,
      ),
    );
  }

  void _local(String action, Duration position) {
    if (!canControl) return;
    _started = true;
    // Until the room echoes this (a newer sequence), its timeline is the
    // old one and must not be applied over the viewer's action.
    _awaitingEchoUntil = _clock() + 3000;
    _echoAfterSeq = party.room?.playback.seq ?? 0;
    party.control(action, position.inMilliseconds);
  }

  // ---- What the player reports ----

  /// Called from the player's listener: readiness, buffering, failure.
  void playerChanged() {
    final player = _player;
    if (player == null) return;
    if (player.failed) {
      party.reportStatus(ParticipantStatus.unavailable);
      _setState(PartySyncState.unavailable);
      return;
    }
    if (!player.ready) {
      _setState(PartySyncState.loading);
      // A new engine comes back at normal speed, with no seek in flight, and
      // is put right as soon as it is ready.
      _wasReady = false;
      _nudging = false;
      _rate = 1;
      _seekStartedAt = null;
      _hold?.cancel();
      _hold = null;
    }
    if (player.ready && !_wasReady) {
      _wasReady = true;
      _readyAt ??= _clock();
      _reconcile();
    }
    if (_noteLanding(player)) _reconcile();
    _followHostBuffering(player);
    _reportStatus(player);
  }

  /// Times a seek when it lands: the picture moved past where it aimed, or
  /// buffering has finished once the seek has had time to begin. True when
  /// it just did, so the room should be checked straight away.
  bool _noteLanding(PartyPlayerHandle player) {
    final started = _seekStartedAt;
    if (started == null) return false;
    final now = _clock();
    if (now - started > 20000) {
      _seekStartedAt = null;
      return false;
    }
    if (!player.playing || player.buffering) return false;
    if (player.position.inMilliseconds <= _seekTarget && now < _settleUntil) {
      return false;
    }
    _seekCost.add(now - started);
    _seekStartedAt = null;
    _settleUntil = 0;
    _arrived = true;
    return true;
  }

  /// A host that stopped to buffer has fallen behind its own timeline; says
  /// where it really is when it moves again, not at the next heartbeat.
  void _followHostBuffering(PartyPlayerHandle player) {
    final was = _wasBuffering;
    _wasBuffering = player.buffering;
    if (was &&
        !player.buffering &&
        _clock() - _lastHeartbeatAt >= thresholds.seekMs) {
      _sendHeartbeat();
    }
  }

  void _reportStatus(PartyPlayerHandle player) {
    if (!player.ready) {
      party.reportStatus(ParticipantStatus.loading);
      return;
    }
    if (player.buffering) {
      // Brief stalls are not worth telling the room about.
      _bufferingReport ??= Timer(const Duration(seconds: 1), () {
        _bufferingReport = null;
        if (_player?.buffering == true) {
          party.reportStatus(ParticipantStatus.buffering);
        }
      });
      return;
    }
    _bufferingReport?.cancel();
    _bufferingReport = null;
    final playback = party.room?.playback;
    if (player.playing) {
      party.reportStatus(ParticipantStatus.playing);
    } else if (playback == null || !_startedFor(playback)) {
      party.reportStatus(ParticipantStatus.ready);
    } else {
      party.reportStatus(ParticipantStatus.paused);
    }
  }

  /// Whether the room has started this title (anything after `start`).
  bool _startedFor(PartyPlayback playback) =>
      playback.status == PlaybackStatus.playing ||
      playback.positionMs > 0 ||
      _started;

  // ---- Applying the room ----

  void _onPlayback(PartyPlayback playback) {
    if (playback.seq > _echoAfterSeq) _awaitingEchoUntil = 0;
    // This player already did what it asked the room to do.
    if (playback.by == party.you) _appliedSeq = playback.seq;
    if (playback.status != PlaybackStatus.idle && _startedFor(playback)) {
      _started = true;
    }
    _reconcile();
  }

  void _onParty() {
    if (party.endReason != null) {
      _setState(PartySyncState.ended);
      return;
    }
    _reconcile();
  }

  /// The title reached its end here. The host says so, so the room's
  /// timeline stops running on past it.
  void playerCompleted(Duration position) {
    final playback = party.room?.playback;
    if (!isHost || playback == null || !playback.playing) return;
    if (_endSentFor == playback.seq) return;
    _endSentFor = playback.seq;
    party.control('ended', position.inMilliseconds);
  }

  void _reconcile() {
    final player = _player;
    final room = party.room;
    // The room as last seen may be out of date: everyone keeps playing, and
    // nothing is corrected until the connection brings the real one.
    if (party.connection == PartyConnection.reconnecting) {
      _setState(PartySyncState.reconnecting);
      return;
    }
    if (player == null || room == null || room.phase != PartyPhase.watching) {
      return;
    }
    if (_followEpisode(player, room)) return;
    if (!player.ready || player.failed) return;
    final now = _clock();
    final playback = room.playback;

    // The host starts the title once everyone is ready (or on their own).
    if (!_startedFor(playback)) {
      if (player.playing) unawaited(player.remotePause());
      if (isHost) {
        _maybeStart(player, room, now);
      } else {
        _setState(PartySyncState.waitingForHost);
      }
      return;
    }
    if (now < _awaitingEchoUntil || party.controlPending) return;

    final expected = expectedPositionMs(playback, party.clock.serverNow(now));
    final local = player.position.inMilliseconds;
    final drift = local - expected;
    final seekNeeded = drift.abs() > thresholds.seekMs;
    // A change from the room overrides waiting, and starts corrections afresh.
    final commanded = playback.seq != _appliedSeq;
    _appliedSeq = playback.seq;
    if (commanded) {
      _hold?.cancel();
      _hold = null;
      _nextSeekAt = 0;
      _seekStreak = 0;
    }
    if (_hold != null) return;
    // Before anything below reads the position, or a new seek replaces this
    // one and the time it took is lost.
    _noteLanding(player);

    if (!playback.playing) {
      if (player.playing) unawaited(player.remotePause());
      if ((local - playback.positionMs).abs() > thresholds.ignoreMs &&
          (commanded || now >= _settleUntil) &&
          (commanded || !player.buffering)) {
        unawaited(
          player.remoteSeek(Duration(milliseconds: playback.positionMs)),
        );
        _seekStartedAt = null;
        _settleUntil = now + 1500;
      }
      _settleSpeed(player);
      _setState(PartySyncState.inSync);
      return;
    }
    // The room's timeline can outlast this copy of the title.
    if (player.completed && drift > -thresholds.seekMs) {
      _settleSpeed(player);
      _setState(PartySyncState.inSync);
      return;
    }
    // Still arriving. Seeking again would throw away what it has buffered.
    // Some engines report "not playing" while they buffer, so this comes
    // before that check. Only a change from the room moves it on.
    if (player.buffering && !(commanded && seekNeeded)) {
      if (!player.playing) unawaited(player.remotePlay());
      if (!isHost) _setState(PartySyncState.catchingUp);
      return;
    }
    if (now < _settleUntil && !commanded) return;
    if (!player.playing) {
      if (drift.abs() > thresholds.ignoreMs &&
          (commanded || now >= _nextSeekAt)) {
        if (!commanded) {
          _seekStreak++;
          _nextSeekAt = now + _seekCost.estimateMs + seekBackoffMs(_seekStreak);
        }
        _seek(player, expected, now, commanded: commanded);
      }
      unawaited(player.remotePlay());
      _setState(PartySyncState.catchingUp);
      return;
    }
    // The host's timeline is the reference; only others correct drift.
    if (isHost) {
      _settleSpeed(player);
      _setState(PartySyncState.inSync);
      return;
    }
    if (commanded && seekNeeded) {
      _settleSpeed(player);
      _seek(player, expected, now, commanded: true);
      _setState(PartySyncState.catchingUp);
      return;
    }
    if (_arrived) {
      _arrived = false;
      if (drift > thresholds.ignoreMs && drift <= thresholds.holdMs) {
        _waitForRoom(player, drift);
        return;
      }
    }
    if (_nudging || !seekNeeded) {
      stats.worstDriftMs = max(stats.worstDriftMs, drift.abs());
    }
    switch (decideSync(drift, nudging: _nudging, thresholds: thresholds)) {
      case SyncAction.none:
        _seekStreak = 0;
        _settleSpeed(player);
        _setState(PartySyncState.inSync);
      case SyncAction.seek:
        if (drift > 0 && drift <= thresholds.holdMs) {
          _waitForRoom(player, drift);
          return;
        }
        if (now < _nextSeekAt) {
          _nudge(
            player,
            drift < 0 ? 1 + thresholds.nudgeRate : 1 - thresholds.nudgeRate,
          );
          return;
        }
        _settleSpeed(player);
        _seekStreak++;
        _nextSeekAt = now + _seekCost.estimateMs + seekBackoffMs(_seekStreak);
        _seek(player, expected, now);
        _setState(PartySyncState.catchingUp);
      case SyncAction.speedUp:
        _nudge(player, 1 + thresholds.nudgeRate);
      case SyncAction.slowDown:
        _nudge(player, 1 - thresholds.nudgeRate);
    }
  }

  /// Seeks to where the room will be once the seek has finished.
  void _seek(
    PartyPlayerHandle player,
    int expected,
    int now, {
    bool commanded = false,
  }) {
    if (commanded) {
      stats.commandedSeeks++;
    } else {
      stats.correctingSeeks++;
    }
    final target = expected + _seekCost.leadMs;
    unawaited(player.remoteSeek(Duration(milliseconds: target)));
    _seekTarget = target;
    _seekStartedAt = now;
    _settleUntil = now + 1500;
    _arrived = false;
  }

  /// Landed ahead of the room: holds the frame until the room gets here,
  /// which is quicker and more exact than playing slowly for much longer.
  void _waitForRoom(PartyPlayerHandle player, int aheadMs) {
    stats.holds++;
    unawaited(player.remotePause());
    _settleSpeed(player);
    _setState(PartySyncState.catchingUp);
    _hold = Timer(Duration(milliseconds: aheadMs), () {
      _hold = null;
      unawaited(player.remotePlay());
      _reconcile();
    });
  }

  void _nudge(PartyPlayerHandle player, double rate) {
    _nudging = true;
    if (_rate != rate) {
      stats.nudges++;
      _rate = rate;
      unawaited(player.remoteSpeed(rate));
    }
    _setState(PartySyncState.catchingUp);
  }

  void _maybeStart(PartyPlayerHandle player, PartyRoom room, int now) {
    final counts = readiness;
    final waited = now - (_readyAt ?? now);
    final everyone = counts.ready >= counts.total;
    if (room.settings.waitForAll &&
        !everyone &&
        waited < waitLimit.inMilliseconds) {
      _setState(PartySyncState.waitingForEveryone);
      return;
    }
    _started = true;
    unawaited(player.remotePlay());
    localPlay(player.position);
    _setState(PartySyncState.inSync);
  }

  /// A guest whose player shows another episode than the room follows the
  /// host there. True when it asked the player to switch.
  bool _followEpisode(PartyPlayerHandle player, PartyRoom room) {
    final content = room.content;
    if (!content.isSeries || isHost) return false;
    if (player.season == content.season && player.episode == content.episode) {
      return false;
    }
    final key = (content.season ?? 0) * 100000 + (content.episode ?? 0);
    if (_followedEpisodeKey == key) return true;
    _followedEpisodeKey = key;
    player.remoteEpisode(content.season!, content.episode!);
    return true;
  }

  void _settleSpeed(PartyPlayerHandle player) {
    if (!_nudging) return;
    _nudging = false;
    _rate = 1;
    unawaited(player.remoteSpeed(1));
  }

  void _sendHeartbeat() {
    final player = _player;
    final playback = party.room?.playback;
    if (!isHost || player == null || playback == null) return;
    if (!playback.playing || !player.playing || player.buffering) return;
    if (_clock() < _awaitingEchoUntil) return;
    _lastHeartbeatAt = _clock();
    party.heartbeat(player.position.inMilliseconds);
  }

  void _setState(PartySyncState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    party.removeListener(_onParty);
    unawaited(_playbackSubscription?.cancel());
    super.dispose();
  }
}

/// The badge's words for [sync].
String partySyncLabel(PartyPlayerSync sync) {
  switch (sync.state) {
    case PartySyncState.loading:
      return 'Getting the title ready…';
    case PartySyncState.unavailable:
      return 'Can’t play this title here · the party goes on';
    case PartySyncState.waitingForEveryone:
      final counts = sync.readiness;
      return 'Waiting for everyone · ${counts.ready}/${counts.total} ready';
    case PartySyncState.waitingForHost:
      return 'Waiting for the host to start';
    case PartySyncState.inSync:
      return sync.canControl ? 'In sync' : 'In sync · host controls playback';
    case PartySyncState.catchingUp:
      return 'Syncing with the party…';
    case PartySyncState.reconnecting:
      return 'Reconnecting…';
    case PartySyncState.ended:
      return 'The party has ended';
  }
}
