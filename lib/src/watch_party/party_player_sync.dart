// Keeps one player in step with its watch party. The player reports the
// viewer's own actions here (sent to the room) and exposes a handle whose
// commands are the remote path: applying the room's timeline through them
// never counts as a viewer action, so a remote pause is not sent back as a
// new pause. Automatic changes (buffering, the end) are reported as status.

import 'dart:async';

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
  int _seekCooldownUntil = 0;
  int _awaitingEchoUntil = 0;
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
    if (!player.ready) _setState(PartySyncState.loading);
    if (player.ready && !_wasReady) {
      _wasReady = true;
      _readyAt = _clock();
      _reconcile();
    }
    _reportStatus(player);
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

  void _reconcile() {
    final player = _player;
    final room = party.room;
    if (party.connection == PartyConnection.reconnecting) {
      _setState(PartySyncState.reconnecting);
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
    if (now < _awaitingEchoUntil) return;

    final expected = expectedPositionMs(playback, party.clock.serverNow(now));
    final local = player.position.inMilliseconds;
    if (!playback.playing) {
      if (player.playing) unawaited(player.remotePause());
      if ((local - playback.positionMs).abs() > thresholds.ignoreMs) {
        unawaited(
          player.remoteSeek(Duration(milliseconds: playback.positionMs)),
        );
      }
      _settleSpeed(player);
      _setState(PartySyncState.inSync);
      return;
    }
    if (!player.playing) {
      if ((local - expected).abs() > thresholds.ignoreMs) {
        unawaited(player.remoteSeek(Duration(milliseconds: expected)));
        _seekCooldownUntil = now + 1500;
      }
      unawaited(player.remotePlay());
      _setState(PartySyncState.catchingUp);
      return;
    }
    // The host's timeline is the reference; only others correct drift.
    if (isHost || player.buffering || now < _seekCooldownUntil) {
      if (isHost) _setState(PartySyncState.inSync);
      return;
    }
    switch (decideSync(
      local - expected,
      nudging: _nudging,
      thresholds: thresholds,
    )) {
      case SyncAction.none:
        _settleSpeed(player);
        _setState(PartySyncState.inSync);
      case SyncAction.seek:
        _settleSpeed(player);
        unawaited(player.remoteSeek(Duration(milliseconds: expected)));
        _seekCooldownUntil = now + 1500;
        _setState(PartySyncState.catchingUp);
      case SyncAction.speedUp:
        _nudge(player, 1 + thresholds.nudgeRate);
      case SyncAction.slowDown:
        _nudge(player, 1 - thresholds.nudgeRate);
    }
  }

  void _nudge(PartyPlayerHandle player, double rate) {
    _nudging = true;
    if (_rate != rate) {
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
