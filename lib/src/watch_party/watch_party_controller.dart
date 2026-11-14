// This device's place in a watch party: the room's WebSocket (reconnected
// with backoff and a fresh session token), the clock offset to the server,
// and the room as last described. Screens and the player read it; only the
// server decides the room's state.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';
import '../account/profile_controller.dart';
import 'party_models.dart';
import 'playback_sync.dart';
import '../analytics/analytics_events.dart';
import '../analytics/analytics_service.dart';
import '../diagnostics/crash_reporter.dart';

/// One open connection to a room; dart:io's WebSocket in the app.
abstract interface class PartySocket {
  Stream<dynamic> get messages;
  void send(String text);
  Future<void> close([int? code, String? reason]);
  int? get closeCode;
}

typedef PartySocketConnector =
    Future<PartySocket> Function(Uri uri, String accessToken);

class _IoPartySocket implements PartySocket {
  _IoPartySocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get messages => _socket;

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);

  @override
  int? get closeCode => _socket.closeCode;
}

Future<PartySocket> _connectIo(Uri uri, String accessToken) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  // Protocol pings: Cloudflare answers them without waking the room or
  // counting a request, and a missing pong closes a dead connection so it
  // reconnects instead of hanging.
  socket.pingInterval = WatchPartyController.pingInterval;
  return _IoPartySocket(socket);
}

enum PartyConnection { connecting, connected, reconnecting, ended }

/// A viewer action not yet sent: [moving] when playback went on after it.
typedef _PendingControl = ({
  String action,
  int positionMs,
  DateTime at,
  bool moving,
});

typedef PartyConnectionStats = ({
  int reconnects,
  int staleStates,
  int averageDeliveryMs,
  int worstDeliveryMs,
});

extension PartyConnectionStatsSummary on PartyConnectionStats {
  String summary() =>
      'reconnects=$reconnects staleStates=$staleStates '
      'delivery=${averageDeliveryMs}ms worstDelivery=${worstDeliveryMs}ms';
}

/// Why this device is no longer in the party.
enum PartyEndReason {
  /// This device left.
  left,

  /// The host ended it, or it expired or was replaced by a new party.
  ended,
  removed,

  /// The same account joined from another device.
  replaced,
  notFound,
  full,
  signedOut,
  failed,
}

/// Creates a party for [content] hosted by the signed-in account and
/// returns its code. Throws [AccountApiException].
Future<String> createWatchParty({
  required PartyContent content,
  PartySettings settings = const PartySettings(),
  AccountController? account,
  AccountApi? api,
  ProfileController? profile,
}) async {
  final session = account ?? AccountController.instance;
  final client = api ?? AccountApi(baseUrl: BackendConfig.apiUrl);
  final String code;
  try {
    code = await _withToken(
      session,
      (token) => client.createParty(
        token,
        content: content.toJson(),
        settings: settings.toJson(),
        profile: _profileJson(profile ?? ProfileController.instance, session),
      ),
    );
  } on AccountApiException catch (error) {
    AnalyticsService.instance.log(
      AnalyticsEvent.watchPartyFailed(step: 'create', reason: error.code),
    );
    CrashReporter.instance.note('party create failed ${error.code}');
    rethrow;
  }
  AnalyticsService.instance.log(
    AnalyticsEvent.featureUsed(AnalyticsFeature.watchPartyCreate),
  );
  return code;
}

/// What [code] opens. Throws [AccountApiException] (`party_not_found`…).
Future<PartyPreview> previewWatchParty(
  String code, {
  AccountController? account,
  AccountApi? api,
}) async {
  final session = account ?? AccountController.instance;
  final client = api ?? AccountApi(baseUrl: BackendConfig.apiUrl);
  final body = await _withToken(
    session,
    (token) => client.previewParty(token, code),
  );
  final preview = PartyPreview.fromJson(body);
  if (preview == null) {
    throw const AccountApiException('unavailable', 'Unexpected response.');
  }
  return preview;
}

Future<T> _withToken<T>(
  AccountController account,
  Future<T> Function(String token) call,
) async {
  final token = await account.accessToken();
  if (token == null) {
    throw const AccountApiException(
      'missing_token',
      'Sign in to continue.',
      status: 401,
    );
  }
  try {
    return await call(token);
  } on AccountApiException catch (error) {
    if (!error.isUnauthorized) rethrow;
    final fresh = await account.accessToken(forceRefresh: true);
    if (fresh == null) rethrow;
    return call(fresh);
  }
}

Map<String, Object?> _profileJson(
  ProfileController profile,
  AccountController account,
) => {
  'name': profile.nameOr(account.username),
  // A photo stays on this device; others see the initial.
  'avatar': profile.avatar.kind == AvatarKind.preset
      ? profile.avatar.presetId
      : null,
};

class WatchPartyController extends ChangeNotifier {
  WatchPartyController({
    required this.code,
    AccountController? account,
    AccountApi? api,
    ProfileController? profile,
    PartySocketConnector? connector,
    @visibleForTesting Duration Function(int attempt)? backoff,
    this.maxOutage = const Duration(minutes: 5),
    this.silenceLimit = const Duration(seconds: 35),
    this.controlInterval = const Duration(milliseconds: 800),
    this.textPingInterval = const Duration(seconds: 25),
  }) : _account = account ?? AccountController.instance,
       _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _profile = profile ?? ProfileController.instance,
       _connector = connector ?? _connectIo,
       _backoff = backoff ?? _defaultBackoff;

  /// How long reconnecting keeps trying before the party is given up; long
  /// enough for a phone that spent a while in the background.
  final Duration maxOutage;

  /// How long a playing room may go without a message before the connection
  /// counts as dead. The host's heartbeats arrive every 10 seconds, so this
  /// is several missed in a row, on a socket that still looks open.
  final Duration silenceLimit;

  /// Viewer actions reach the room at most this often (see [control]).
  final Duration controlInterval;

  /// How often this device tells the room it is still here. A text `ping`
  /// is answered by Cloudflare without waking the room; the room closes a
  /// socket whose pings stopped, so a vanished device frees its place and a
  /// vanished host is replaced.
  final Duration textPingInterval;

  /// Reactions and chat lines leave this device at most this often, well
  /// inside what the room relays.
  static const reactionInterval = Duration(milliseconds: 700);
  static const chatInterval = Duration(milliseconds: 1500);

  /// Chat lines kept on this device (the room keeps none).
  static const maxChatMessages = 100;
  static const maxChatChars = 300;

  /// The party this device is in, for the player and Home to find.
  static final active = ValueNotifier<WatchPartyController?>(null);

  final String code;
  final AccountController _account;
  final AccountApi _api;
  final ProfileController _profile;
  final PartySocketConnector _connector;
  final Duration Function(int attempt) _backoff;

  /// Clock offset to the room's server.
  final ClockSync clock = ClockSync();

  final _playback = StreamController<PartyPlayback>.broadcast();

  /// Every new room timeline (higher sequence), for the player.
  Stream<PartyPlayback> get playbackChanges => _playback.stream;

  static const pingInterval = Duration(seconds: 25);
  static const _timeChecks = 3;

  PartySocket? _socket;

  /// Whether the room has welcomed the current socket.
  bool _socketReady = false;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
  Timer? _silence;
  DateTime _lastMessageAt = DateTime.now();
  int _attempt = 0;

  /// When the connection was last lost, while reconnecting.
  DateTime? _failingSince;
  bool _disposed = false;
  AppLifecycleListener? _lifecycle;

  /// The account the party was joined with; another one ends it.
  String? _userId;

  PartyConnection _connection = PartyConnection.connecting;
  PartyEndReason? _endReason;
  PartyRoom? _room;
  String? _you;
  String? _lastError;
  ParticipantStatus? _status;
  PartyContent? _pendingContent;
  int _playerSessions = 0;

  /// The viewer's last action while disconnected, sent on reconnecting.
  _PendingControl? _queuedControl;

  /// The latest action held back by [controlInterval], and its timer.
  _PendingControl? _deferredControl;
  Timer? _deferTimer;
  DateTime? _lastControlAt;

  /// Actions sent that the room has not yet answered with a new timeline of
  /// this device's own, and how long to wait for that at most (a refused
  /// one is never answered).
  int _unconfirmedControls = 0;
  DateTime? _controlPendingUntil;

  Timer? _textPing;
  Set<String> _features = const {};
  final _reactions = StreamController<PartyReaction>.broadcast();
  final List<PartyChatMessage> _messages = [];
  int _unreadChat = 0;
  DateTime? _lastReactionAt;
  DateTime? _lastChatAt;
  int _chatIds = 0;
  int _reconnects = 0;
  bool _joinCounted = false;

  /// When this device first reached the room.
  DateTime? _joinedAt;
  int _staleStates = 0;
  int _deliveries = 0;
  int _deliveryTotalMs = 0;
  int _worstDeliveryMs = 0;

  /// Whether an action of this device's is held back or has not come back
  /// from the room yet. Until it does, the room still describes the time
  /// before it, so that must not be applied over it.
  bool get controlPending {
    if (_deferredControl != null) return true;
    final until = _controlPendingUntil;
    return _unconfirmedControls > 0 &&
        until != null &&
        DateTime.now().isBefore(until);
  }

  /// Whether the room relays reactions and chat (older rooms do not).
  bool get supportsReactions => _features.contains('reactions');
  bool get supportsChat => _features.contains('chat');

  /// Everyone's reactions as they arrive, this device's own included.
  Stream<PartyReaction> get reactions => _reactions.stream;

  /// The chat as this device has seen it, oldest first. Kept across
  /// reconnects; a device that joins later starts empty.
  List<PartyChatMessage> get messages => List.unmodifiable(_messages);

  /// Lines from others since [markChatRead].
  int get unreadChat => _unreadChat;

  void markChatRead() {
    if (_unreadChat == 0) return;
    _unreadChat = 0;
    notifyListeners();
  }

  /// Chat views on screen now; lines that arrive while one is open are read.
  int _chatViews = 0;
  bool get chatOpen => _chatViews > 0;

  /// Called by a chat view as it appears and goes ([open] false).
  void chatViewChanged({required bool open}) {
    _chatViews = (_chatViews + (open ? 1 : -1)).clamp(0, 1 << 20);
    if (open) markChatRead();
  }

  /// The connection so far, for diagnostics.
  PartyConnectionStats get stats => (
    reconnects: _reconnects,
    staleStates: _staleStates,
    averageDeliveryMs: _deliveries == 0 ? 0 : _deliveryTotalMs ~/ _deliveries,
    worstDeliveryMs: _worstDeliveryMs,
  );

  /// How many players have joined this party's sync on this device; the
  /// waiting room compares it to tell whether a player opened at all.
  int get playerSessions => _playerSessions;

  /// Called by a player when it starts syncing with this party.
  void notePlayerOpened() => _playerSessions++;

  PartyConnection get connection => _connection;
  PartyEndReason? get endReason => _endReason;
  PartyRoom? get room => _room;

  /// The title the host asked the room to switch to, until it confirms;
  /// the host's next player may open before the reply arrives.
  PartyContent? get pendingContent => _pendingContent;

  /// This device's participant id in the room.
  String? get you => _you;
  bool get isHost => _room != null && _room!.hostPid == _you;

  /// Whether this device may play, pause and seek for everyone.
  bool get canControl => isHost || (_room?.settings.guestControl ?? false);

  /// The last error code the room answered (such as `not_allowed`).
  String? get lastError => _lastError;

  static Duration _defaultBackoff(int attempt) =>
      Duration(seconds: const [1, 2, 4, 8, 15, 30][attempt.clamp(0, 5)]);

  /// Connects; call once. Makes this the [active] party.
  Future<void> start() async {
    final previous = active.value;
    if (previous != null && previous != this) await previous.leave();
    active.value = this;
    _userId = _account.userId;
    _account.addListener(_accountChanged);
    // Back from the background: retry at once rather than at the backoff.
    _lifecycle = AppLifecycleListener(onResume: _retryNow);
    await _connect();
  }

  /// Signing out, or another account signing in here, leaves the party:
  /// the socket was opened as the previous account.
  void _accountChanged() {
    if (_endReason != null) return;
    if (_account.status == AccountStatus.signedIn &&
        _account.userId == _userId) {
      return;
    }
    _sendJson({'t': 'leave'});
    unawaited(_close(PartyEndReason.signedOut));
  }

  void _retryNow() {
    if (_endReason != null || _connection != PartyConnection.reconnecting) {
      return;
    }
    _retry?.cancel();
    unawaited(_connect());
  }

  /// Whether the connection has been gone too long to keep trying.
  bool _outageTooLong() {
    final since = _failingSince ??= DateTime.now();
    return DateTime.now().difference(since) >= maxOutage;
  }

  Future<void> _connect() async {
    if (_disposed || _endReason != null) return;
    final uri = _api.partySocket(code);
    if (uri == null) return _end(PartyEndReason.failed);
    String? token;
    try {
      token = await _account.accessToken();
    } on AccountApiException {
      // Offline: retried below.
    }
    if (_disposed || _endReason != null) return;
    if (token == null && _account.status != AccountStatus.signedIn) {
      return _end(PartyEndReason.signedOut);
    }
    final PartySocket socket;
    try {
      if (token == null) throw const SocketException('No session token.');
      socket = await _connector(
        uri,
        token,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      CrashReporter.instance.note('party connect failed');
      return _connectFailed();
    }
    if (_disposed || _endReason != null) {
      unawaited(socket.close(1000));
      return;
    }
    _socket = socket;
    _subscription = socket.messages.listen(
      _onMessage,
      onDone: () => _onClosed(socket),
      onError: (Object _) => _onClosed(socket),
      cancelOnError: true,
    );
  }

  /// The handshake failed: find out whether the room is still there, and
  /// retry with backoff while it is.
  Future<void> _connectFailed() async {
    _attempt += 1;
    if (_attempt >= 2) {
      try {
        final preview = await previewWatchParty(
          code,
          account: _account,
          api: _api,
        );
        if (preview.full && _room == null) return _end(PartyEndReason.full);
      } on AccountApiException catch (error) {
        if (error.code == 'party_not_found') {
          return _end(
            _room == null ? PartyEndReason.notFound : PartyEndReason.ended,
          );
        }
        if (error.isUnauthorized && _account.status != AccountStatus.signedIn) {
          return _end(PartyEndReason.signedOut);
        }
      }
    }
    if (_outageTooLong()) return _end(PartyEndReason.failed);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _endReason != null) return;
    _setConnection(PartyConnection.reconnecting);
    _retry?.cancel();
    _retry = Timer(_backoff(_attempt), _connect);
  }

  void _onClosed(PartySocket socket) {
    if (socket != _socket) return;
    _socket = null;
    _socketReady = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (_disposed || _endReason != null) return;
    switch (socket.closeCode) {
      case 4000:
        return _end(PartyEndReason.ended);
      case 4001:
        return _end(PartyEndReason.replaced);
      case 4003:
        return _end(PartyEndReason.removed);
      case 4004:
        return _end(PartyEndReason.ended);
      case 4029:
        return _end(PartyEndReason.failed);
    }
    // A dropped network: reconnect and take the room's state afresh.
    _attempt += 1;
    if (_outageTooLong()) return _end(PartyEndReason.failed);
    _scheduleReconnect();
  }

  /// Reconnects a socket that stopped delivering. Without this a client can
  /// sit "connected" and hear nothing more from the room.
  void _checkSilence() {
    final socket = _socket;
    final room = _room;
    if (socket == null ||
        !_socketReady ||
        room == null ||
        !room.playback.playing ||
        !room.hostConnected ||
        DateTime.now().difference(_lastMessageAt) < silenceLimit) {
      return;
    }
    if (!kReleaseMode) debugPrint('[PartySync] no messages; reconnecting');
    _socket = null;
    _socketReady = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(socket.close(1000).catchError((Object _) {}));
    _attempt += 1;
    _scheduleReconnect();
  }

  void _onMessage(dynamic data) {
    // A pong is Cloudflare's answer, not the room's: it does not show the
    // room is still delivering (see [_checkSilence]).
    if (data is! String || data == 'pong') return;
    _lastMessageAt = DateTime.now();
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) return;
      message = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (message['t']) {
      case 'welcome':
        final room = PartyRoom.fromJson(message['room']);
        final you = message['you'];
        if (room == null || you is! Map || you['pid'] is! String) return;
        _attempt = 0;
        _failingSince = null;
        _you = you['pid'] as String;
        final serverTime = message['serverTime'];
        if (_room != null) {
          _reconnects++;
        } else {
          _joinedAt = DateTime.now();
        }
        _silence ??= Timer.periodic(silenceLimit ~/ 3, (_) => _checkSilence());
        _textPing ??= Timer.periodic(textPingInterval, (_) {
          if (_socketReady) _send('ping');
        });
        final features = message['features'];
        _features = features is List
            ? features.whereType<String>().toSet()
            : const {};
        clock.restart();
        if (serverTime is int) clock.seed(serverTime, now);
        _socketReady = true;
        // Whatever was sent on the old socket is answered by this room, or
        // was lost with it.
        _unconfirmedControls = 0;
        _controlPendingUntil = null;
        // Before anything hears of the room, which does not include this.
        _flushControl();
        _setRoom(room);
        _noteJoined();
        _setConnection(PartyConnection.connected);
        _send(jsonEncode({'t': 'hello', ..._profileJson(_profile, _account)}));
        final status = _status;
        if (status != null) _sendStatus(status);
        _checkClock();
      case 'room':
        final room = PartyRoom.fromJson(message['room']);
        if (room != null) _setRoom(room);
      case 'state':
        final room = _room;
        if (room == null) return;
        final playback = PartyPlayback.fromJson(message['playback']);
        // Newer changes only; a heartbeat carries the current sequence.
        if (playback.seq < room.playback.seq) {
          _staleStates++;
          return;
        }
        final sentAt = message['serverTime'];
        if (sentAt is int) {
          final delivery = max(0, clock.serverNow(now) - sentAt);
          _deliveries++;
          _deliveryTotalMs += delivery;
          _worstDeliveryMs = max(_worstDeliveryMs, delivery);
        }
        // This device's own action, back from the room.
        if (playback.seq > room.playback.seq &&
            playback.by != null &&
            playback.by == _you &&
            _unconfirmedControls > 0) {
          _unconfirmedControls--;
        }
        _room = room.copyWith(playback: playback);
        _playback.add(playback);
        notifyListeners();
      case 'participants':
        final room = _room;
        if (room == null) return;
        _room = room.copyWith(
          participants: participantsFrom(message['participants']),
          hostConnected: message['hostConnected'] != false,
        );
        notifyListeners();
      case 'time':
        final sent = message['c'];
        final server = message['s'];
        if (sent is int && server is int) clock.add(sent, server, now);
      case 'reaction':
        final reaction = PartyReaction.fromJson(message, _nameOf);
        if (reaction != null && reaction.pid != _you) _reactions.add(reaction);
      case 'chat':
        final line = PartyChatMessage.fromJson(message, you: _you);
        if (line == null) return;
        _messages.add(line);
        if (_messages.length > maxChatMessages) _messages.removeAt(0);
        if (!line.mine && !chatOpen) _unreadChat++;
        notifyListeners();
      case 'error':
        _lastError = '${message['code']}';
        notifyListeners();
      case 'removed':
        _end(PartyEndReason.removed);
      case 'ended':
        _end(PartyEndReason.ended);
    }
  }

  void _setRoom(PartyRoom room) {
    final previous = _room;
    _room = room;
    final pending = _pendingContent;
    if (pending != null && room.content.sameTitleAs(pending)) {
      _pendingContent = null;
    }
    if (previous == null || room.playback.seq > previous.playback.seq) {
      _playback.add(room.playback);
    }
    notifyListeners();
  }

  /// A few round trips for the clock offset, spaced out so one slow packet
  /// does not decide it.
  void _checkClock() {
    for (var i = 0; i < _timeChecks; i++) {
      Timer(Duration(milliseconds: 400 * i), () {
        if (_socket == null) return;
        _send(
          jsonEncode({'t': 'time', 'c': DateTime.now().millisecondsSinceEpoch}),
        );
      });
    }
  }

  void _send(String text) {
    try {
      _socket?.send(text);
    } catch (_) {
      // Closing; the close handler reconnects.
    }
  }

  void _sendJson(Map<String, Object?> body) => _send(jsonEncode(body));

  /// Counts a guest's arrival once: a reconnect is not another join, and
  /// creating the party already counted for the host.
  void _noteJoined() {
    CrashReporter.instance.setContext(
      CrashContext.partyRole,
      isHost ? 'host' : 'guest',
    );
    if (_joinCounted) return;
    _joinCounted = true;
    if (isHost) return;
    AnalyticsService.instance.log(
      AnalyticsEvent.featureUsed(AnalyticsFeature.watchPartyJoin),
    );
  }

  /// One event for this device's time in the party, however it ended.
  void _reportEnd(PartyEndReason reason) {
    final joinedAt = _joinedAt;
    if (joinedAt == null) {
      if (reason != PartyEndReason.left) {
        AnalyticsService.instance.log(
          AnalyticsEvent.watchPartyFailed(step: 'join', reason: reason.name),
        );
      }
    } else {
      AnalyticsService.instance.log(
        AnalyticsEvent.watchPartySession(
          host: isHost,
          endReason: reason.name,
          minutes: DateTime.now().difference(joinedAt).inMinutes,
          reconnects: _reconnects,
        ),
      );
    }
    if (reason == PartyEndReason.failed) {
      CrashReporter.instance.note('party ended failed');
    }
    CrashReporter.instance
      ..setContext(CrashContext.partyState, null)
      ..setContext(CrashContext.partyRole, null);
  }

  void _setConnection(PartyConnection next) {
    if (_connection == next) return;
    _connection = next;
    CrashReporter.instance.setContext(CrashContext.partyState, next.name);
    notifyListeners();
  }

  // ---- Actions ----

  /// Reports what this device's player is doing (shown to the room).
  void reportStatus(ParticipantStatus status) {
    if (_status == status) return;
    _status = status;
    _sendStatus(status);
  }

  void _sendStatus(ParticipantStatus status) =>
      _sendJson({'t': 'status', 'state': status.name});

  /// Play, pause, seek or end for everyone, at [positionMs] now.
  ///
  /// At most one goes to the room per [controlInterval]: a held seek key
  /// repeats many times a second, and each change makes every guest seek
  /// (and costs the room a write). The first is sent at once; the last of
  /// those that follow is sent when the interval ends, from where playback
  /// has reached by then. Made while disconnected, the last one is kept and
  /// sent on reconnecting; otherwise the room's old state would undo it.
  void control(String action, int positionMs) {
    if (!canControl) return;
    final now = DateTime.now();
    // A seek keeps the room's play state, so it moves on only while playing.
    final moving =
        action == 'play' ||
        (action == 'seek' && (_room?.playback.playing ?? false));
    final pending = (
      action: action,
      positionMs: positionMs,
      at: now,
      moving: moving,
    );
    if (!_socketReady) {
      _deferredControl = null;
      _deferTimer?.cancel();
      _deferTimer = null;
      _queuedControl = pending;
      return;
    }
    final last = _lastControlAt;
    if (last != null && now.difference(last) < controlInterval) {
      _deferredControl = pending;
      _deferTimer ??= Timer(
        controlInterval - now.difference(last),
        _flushDeferred,
      );
      return;
    }
    _sendControl(action, positionMs);
  }

  void _sendControl(String action, int positionMs) {
    final now = DateTime.now();
    _lastControlAt = now;
    _unconfirmedControls++;
    _controlPendingUntil = now.add(const Duration(seconds: 3));
    _sendJson({
      't': 'control',
      'action': action,
      'positionMs': positionMs,
      'at': clock.serverNow(now.millisecondsSinceEpoch),
    });
  }

  /// Sends a control made at [made] for [positionMs]; one that left playback
  /// running is further on by now, a pause stays where it was made.
  void _sendLate(_PendingControl made) {
    final elapsed = DateTime.now().difference(made.at).inMilliseconds;
    _sendControl(made.action, made.positionMs + (made.moving ? elapsed : 0));
  }

  void _flushDeferred() {
    _deferTimer = null;
    final deferred = _deferredControl;
    _deferredControl = null;
    if (deferred == null || _endReason != null) return;
    if (!_socketReady) {
      _queuedControl = deferred;
      return;
    }
    _sendLate(deferred);
  }

  void _flushControl() {
    final queued = _queuedControl;
    if (queued == null) return;
    _queuedControl = null;
    _sendLate(queued);
  }

  /// The host's position while playing, for drift (every few seconds).
  void heartbeat(int positionMs) {
    final room = _room;
    if (!isHost || room == null || !room.playback.playing) return;
    // The room is about to hear of a change; this position predates it.
    if (controlPending) return;
    _sendJson({
      't': 'heartbeat',
      'seq': room.playback.seq,
      'positionMs': positionMs,
      'at': clock.serverNow(DateTime.now().millisecondsSinceEpoch),
    });
  }

  String? _nameOf(String pid) {
    for (final person in _room?.participants ?? const <PartyParticipant>[]) {
      if (person.pid == pid) return person.name;
    }
    return null;
  }

  /// A quick reaction for everyone. Shown here at once; false when it was
  /// not sent (not connected, an older room, or too soon after the last).
  bool react(String emoji) {
    if (!_socketReady || !supportsReactions) return false;
    if (!partyReactions.containsKey(emoji)) return false;
    final now = DateTime.now();
    final last = _lastReactionAt;
    if (last != null && now.difference(last) < reactionInterval) return false;
    _lastReactionAt = now;
    _sendJson({'t': 'react', 'emoji': emoji});
    final you = _you;
    if (you != null) {
      _reactions.add(PartyReaction(pid: you, emoji: emoji, name: _nameOf(you)));
    }
    return true;
  }

  /// A chat line for everyone; it appears in [messages] once the room
  /// relays it. False when it was not sent (empty, not connected, an older
  /// room, or too soon after the last).
  bool sendChat(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty || !_socketReady || !supportsChat) return false;
    final now = DateTime.now();
    final last = _lastChatAt;
    if (last != null && now.difference(last) < chatInterval) return false;
    _lastChatAt = now;
    _sendJson({
      't': 'chat',
      'id': 'c${now.millisecondsSinceEpoch.toRadixString(36)}-${_chatIds++}',
      'text': line.runes.length <= maxChatChars
          ? line
          : String.fromCharCodes(line.runes.take(maxChatChars)),
    });
    return true;
  }

  /// Host: everyone opens the player.
  void startWatching() {
    if (isHost) _sendJson({'t': 'start'});
  }

  /// Host: a different episode or title for everyone.
  void changeContent(PartyContent content) {
    if (!isHost) return;
    _pendingContent = content;
    _sendJson({'t': 'content', 'content': content.toJson()});
  }

  void updateSettings({bool? guestControl, bool? waitForAll}) {
    if (!isHost) return;
    _sendJson({
      't': 'settings',
      'guestControl': ?guestControl,
      'waitForAll': ?waitForAll,
    });
  }

  void remove(String pid) {
    if (isHost && pid != _you) _sendJson({'t': 'kick', 'pid': pid});
  }

  void makeHost(String pid) {
    if (isHost && pid != _you) _sendJson({'t': 'transfer', 'pid': pid});
  }

  /// Host: ends the party for everyone.
  Future<void> endParty() async {
    if (isHost) _sendJson({'t': 'end'});
    await _close(PartyEndReason.left);
  }

  /// Leaves; a leaving host hands the party to the next participant.
  Future<void> leave() async {
    _sendJson({'t': 'leave'});
    await _close(PartyEndReason.left);
  }

  Future<void> _close(PartyEndReason reason) async {
    final socket = _socket;
    _end(reason);
    if (socket != null) {
      try {
        await socket.close(1000, 'Left.');
      } catch (_) {
        // Already closed.
      }
    }
  }

  void _end(PartyEndReason reason) {
    if (_endReason != null) return;
    _reportEnd(reason);
    _endReason = reason;
    _retry?.cancel();
    _silence?.cancel();
    _textPing?.cancel();
    _deferTimer?.cancel();
    _deferTimer = null;
    _deferredControl = null;
    _account.removeListener(_accountChanged);
    _lifecycle?.dispose();
    _lifecycle = null;
    final socket = _socket;
    _socket = null;
    _socketReady = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (socket != null && reason != PartyEndReason.left) {
      unawaited(socket.close(1000).catchError((Object _) {}));
    }
    if (active.value == this) active.value = null;
    _connection = PartyConnection.ended;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_endReason == null) {
      _sendJson({'t': 'leave'});
      _end(PartyEndReason.left);
    }
    _disposed = true;
    unawaited(_playback.close());
    unawaited(_reactions.close());
    super.dispose();
  }
}

/// A sentence for [reason], for the screen that shows the party ended.
String partyEndMessage(PartyEndReason reason) => switch (reason) {
  PartyEndReason.left => 'You left the party.',
  PartyEndReason.ended => 'The party has ended.',
  PartyEndReason.removed => 'The host removed you from the party.',
  PartyEndReason.replaced => 'You joined this party from another device.',
  PartyEndReason.notFound => 'No party has that code. Check it and try again.',
  PartyEndReason.full => 'This party is full.',
  PartyEndReason.signedOut => 'Sign in to join the party.',
  PartyEndReason.failed =>
    'Lost the connection to the party. Check your connection and join again.',
};
