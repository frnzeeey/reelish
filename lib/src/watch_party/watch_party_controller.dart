// This device's place in a watch party: the room's WebSocket (reconnected
// with backoff and a fresh session token), the clock offset to the server,
// and the room as last described. Screens and the player read it; only the
// server decides the room's state.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';
import '../account/profile_controller.dart';
import 'party_models.dart';
import 'playback_sync.dart';

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
  return _withToken(
    session,
    (token) => client.createParty(
      token,
      content: content.toJson(),
      settings: settings.toJson(),
      profile: _profileJson(profile ?? ProfileController.instance, session),
    ),
  );
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
  }) : _account = account ?? AccountController.instance,
       _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _profile = profile ?? ProfileController.instance,
       _connector = connector ?? _connectIo,
       _backoff = backoff ?? _defaultBackoff;

  /// How long reconnecting keeps trying before the party is given up; long
  /// enough for a phone that spent a while in the background.
  final Duration maxOutage;

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
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
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

  void _onMessage(dynamic data) {
    if (data is! String || data == 'pong') return;
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
        if (serverTime is int) clock.seed(serverTime, now);
        _setRoom(room);
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
        if (playback.seq < room.playback.seq) return;
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

  void _setConnection(PartyConnection next) {
    if (_connection == next) return;
    _connection = next;
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
  void control(String action, int positionMs) {
    if (!canControl) return;
    _sendJson({
      't': 'control',
      'action': action,
      'positionMs': positionMs,
      'at': clock.serverNow(DateTime.now().millisecondsSinceEpoch),
    });
  }

  /// The host's position while playing, for drift (every few seconds).
  void heartbeat(int positionMs) {
    final room = _room;
    if (!isHost || room == null || !room.playback.playing) return;
    _sendJson({
      't': 'heartbeat',
      'seq': room.playback.seq,
      'positionMs': positionMs,
      'at': clock.serverNow(DateTime.now().millisecondsSinceEpoch),
    });
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
    _endReason = reason;
    _retry?.cancel();
    _account.removeListener(_accountChanged);
    _lifecycle?.dispose();
    _lifecycle = null;
    final socket = _socket;
    _socket = null;
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
