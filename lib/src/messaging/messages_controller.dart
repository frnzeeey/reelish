// Private messages for the signed-in account: the conversations on this
// device, the outbox, and the connection to the account's mailbox on the
// Reelish API (backend/src/messaging/). The connection is open only while a
// Messages screen is showing ([attach]/[detach]) and the app is in the
// foreground; reconnects back off. A message is acknowledged only after it
// is saved here, so a crash at any point means it arrives again (and is
// recognised by its id) rather than being lost. docs/messaging/README.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';
import '../diagnostics/crash_reporter.dart';
import '../social/friends_controller.dart';
import '../social/social_controller.dart';
import 'message_models.dart';
import 'message_store.dart';

/// One open connection to the mailbox; dart:io's WebSocket in the app.
abstract interface class MessageSocket {
  Stream<dynamic> get frames;
  void send(String text);
  Future<void> close([int? code, String? reason]);
  int? get closeCode;
}

typedef MessageSocketConnector =
    Future<MessageSocket> Function(Uri uri, String accessToken);

class _IoMessageSocket implements MessageSocket {
  _IoMessageSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get frames => _socket;

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);

  @override
  int? get closeCode => _socket.closeCode;
}

Future<MessageSocket> _connectIo(Uri uri, String accessToken) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  // Protocol pings are answered by Cloudflare without waking the mailbox,
  // and a missing pong closes a dead connection so it reconnects.
  socket.pingInterval = const Duration(seconds: 30);
  return _IoMessageSocket(socket);
}

/// The state of the connection, for the screens.
enum MessagesConnection {
  /// No Messages screen is open: nothing connects.
  idle,
  connecting,

  /// Connected and caught up.
  online,

  /// Lost or unreachable; trying again with backoff.
  offline,

  /// Friends is off for the account, or the session ended.
  unavailable,
}

class MessagesController extends ChangeNotifier {
  MessagesController({
    AccountController? account,
    AccountApi? api,
    MessageStore? store,
    MessageSocketConnector? connector,
    SocialController? social,
    @visibleForTesting Duration Function(int attempt)? backoff,
    @visibleForTesting this.ackDelay = const Duration(milliseconds: 250),
    @visibleForTesting this.lingerAfterClose = const Duration(seconds: 20),
    @visibleForTesting this.sendSpacing = const Duration(milliseconds: 1100),
    this.lifecycle = true,
  }) : _account = account ?? AccountController.instance,
       _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _store = store ?? MessageStore(),
       _connector = connector ?? _connectIo,
       _social = social ?? SocialController.instance,
       _backoff = backoff ?? _defaultBackoff;

  static final instance = MessagesController();

  /// Longest message; the server may lower it when it connects.
  static const defaultMaxChars = 2000;

  /// Messages a chat shows at first and adds each time "earlier" is asked.
  static const pageSize = 50;

  /// How long to wait after the last saved message before acknowledging.
  final Duration ackDelay;

  /// How long the connection stays after the last Messages screen closes.
  final Duration lingerAfterClose;

  /// Spacing between outbox sends once the quick allowance is used.
  final Duration sendSpacing;

  /// Off in tests: no app lifecycle listener.
  final bool lifecycle;

  final AccountController _account;
  final AccountApi _api;
  final MessageStore _store;
  final MessageSocketConnector _connector;
  final SocialController _social;
  final Duration Function(int attempt) _backoff;

  String? _userId;
  Future<void>? _opening;
  bool _loaded = false;
  List<Conversation> _conversations = [];
  List<PendingSend> _outbox = [];

  /// Conversations read from disk, by id.
  final Map<String, List<ChatMessage>> _histories = {};

  int _viewers = 0;
  String? _visibleConversation;
  MessageSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool _ready = false;
  int _attempt = 0;
  Timer? _retry;
  Timer? _linger;
  Timer? _ackTimer;
  int _savedSeq = 0;
  int _ackedSeq = 0;
  bool _paused = false;
  AppLifecycleListener? _lifecycle;
  MessagesConnection _connection = MessagesConnection.idle;
  int _maxChars = defaultMaxChars;

  /// Frames are handled one at a time, in order, each saved before the next.
  Future<void> _frames = Future<void>.value();

  /// Outbox sends: a small burst, then spaced, below the server's limit.
  int _sendTokens = 10;
  DateTime _tokensAt = DateTime.now();
  final Set<String> _inFlight = {};
  Timer? _outboxTimer;
  bool _disposed = false;

  MessagesConnection get connection => _connection;
  bool get loaded => _loaded && _userId == _account.userId;
  int get maxChars => _maxChars;

  /// Conversations with a message, newest first.
  List<Conversation> get conversations => loaded
      ? [
          for (final c in _conversations)
            if (c.last != null) c,
        ]
      : const [];

  /// Messages from friends not yet seen on this device.
  int get unread =>
      loaded ? _conversations.fold(0, (sum, c) => sum + c.unread) : 0;

  Conversation? conversation(String id) {
    for (final c in _conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The messages of [conversation] read so far; [load] reads them.
  List<ChatMessage> messagesOf(String conversation) =>
      _histories[conversation] ?? const [];

  bool hasHistory(String conversation) => _histories.containsKey(conversation);

  static Duration _defaultBackoff(int attempt) {
    final seconds = const [1, 2, 4, 8, 15, 30, 60][attempt.clamp(0, 6)];
    // Up to a fifth more, so devices do not all return at once.
    return Duration(
      milliseconds: seconds * 1000 + Random().nextInt(seconds * 200 + 1),
    );
  }

  // ---- Account and storage ----

  /// Reads this account's conversations from disk, once per account.
  Future<void> ensureLoaded() {
    final userId = _account.status == AccountStatus.signedIn
        ? _account.userId
        : null;
    if (userId == null) return Future<void>.value();
    if (_userId == userId && (_loaded || _opening != null)) {
      return _opening ?? Future<void>.value();
    }
    _account.removeListener(_accountChanged);
    _account.addListener(_accountChanged);
    return _opening = _open(userId).whenComplete(() => _opening = null);
  }

  Future<void> _open(String userId) async {
    _disconnect();
    _userId = userId;
    _loaded = false;
    _conversations = [];
    _outbox = [];
    _histories.clear();
    _savedSeq = _ackedSeq = 0;
    final index = await _store.open(userId);
    if (_userId != userId) return;
    _conversations = index.conversations..sort(_newestFirst);
    _outbox = index.outbox;
    // The outbox sends text kept in its conversations: read those now.
    for (final conversation in {for (final p in _outbox) p.conversation}) {
      final read = await _store.messages(conversation);
      if (_userId != userId) return;
      _histories[conversation] = read;
    }
    _loaded = true;
    notifyListeners();
    if (_viewers > 0) _connectSoon();
  }

  static int _newestFirst(Conversation a, Conversation b) {
    final at = a.lastAt;
    final bt = b.lastAt;
    if (at == null || bt == null) return at == null ? 1 : -1;
    return bt.compareTo(at);
  }

  /// Another account, or none: everything here belonged to the previous one.
  void _accountChanged() {
    final userId = _account.status == AccountStatus.signedIn
        ? _account.userId
        : null;
    if (userId == _userId) return;
    _disconnect();
    _userId = null;
    _loaded = false;
    _conversations = [];
    _outbox = [];
    _histories.clear();
    _setConnection(MessagesConnection.idle);
    if (userId != null) unawaited(ensureLoaded());
  }

  /// Reads [conversation]'s history from disk (once).
  Future<List<ChatMessage>> load(String conversation) async {
    await ensureLoaded();
    final known = _histories[conversation];
    if (known != null) return known;
    final read = await _store.messages(conversation);
    // Something may have arrived while reading: merged in.
    final arrived = _histories[conversation] ?? const <ChatMessage>[];
    final byKey = {for (final m in read) m.key: m};
    for (final m in arrived) {
      byKey[m.key] = m;
    }
    final all = byKey.values.toList()..sort(_oldestFirst);
    _histories[conversation] = all;
    notifyListeners();
    return all;
  }

  static int _oldestFirst(ChatMessage a, ChatMessage b) {
    final order = a.at.compareTo(b.at);
    return order != 0 ? order : a.key.compareTo(b.key);
  }

  /// Friends was turned off: every message on this device goes too.
  Future<void> forget() async {
    _disconnect();
    _conversations = [];
    _outbox = [];
    _histories.clear();
    _savedSeq = _ackedSeq = 0;
    notifyListeners();
    await _store.wipe();
  }

  // ---- Screens ----

  /// A Messages screen is showing: connect while any is.
  void attach() {
    _viewers += 1;
    _linger?.cancel();
    _lifecycle ??= lifecycle
        ? AppLifecycleListener(onPause: _onPause, onResume: _onResume)
        : null;
    unawaited(ensureLoaded().then((_) => _connectSoon()));
  }

  /// A Messages screen closed; the connection lingers briefly in case
  /// another opens, and longer while something waits to be sent.
  void detach() {
    _viewers = max(0, _viewers - 1);
    if (_viewers > 0) return;
    _linger?.cancel();
    _linger = Timer(lingerAfterClose, () {
      if (_viewers > 0) return;
      if (_outbox.isNotEmpty && _connection == MessagesConnection.online) {
        _linger = Timer(lingerAfterClose * 3, _idle);
        return;
      }
      _idle();
    });
  }

  void _idle() {
    if (_viewers > 0) return;
    unawaited(_closeAfterAck());
    _setConnection(MessagesConnection.idle);
  }

  /// Acknowledges what is saved, then closes. (Anything not acknowledged
  /// arrives again next time and is recognised.)
  Future<void> _closeAfterAck() async {
    _ackTimer?.cancel();
    _ackTimer = null;
    final socket = _socket;
    await _frames;
    await _sendAck();
    if (socket != _socket) return;
    if (_paused || _viewers == 0) {
      _disconnect();
    } else if (_ready) {
      // A Messages screen opened again meanwhile: keep the connection.
      _setConnection(MessagesConnection.online);
    }
  }

  /// The chat open on screen: its messages arrive already read.
  void setVisible(String? conversation) {
    _visibleConversation = conversation;
    if (conversation != null) unawaited(markRead(conversation));
  }

  /// Marks [conversation] as seen.
  Future<void> markRead(String conversation) async {
    final index = _conversations.indexWhere((c) => c.id == conversation);
    if (index < 0 || _conversations[index].unread == 0) return;
    _conversations[index] = _conversations[index].copyWith(unread: 0);
    notifyListeners();
    await _saveIndex();
  }

  /// The conversation with [friend], creating it here if it has no messages.
  Conversation open(SocialPerson friend) {
    final id = friend.conversation!;
    final existing = conversation(id);
    if (existing != null) {
      if (_peerChanged(existing.peer, friend)) {
        final updated = existing.copyWith(peer: _peerFrom(friend));
        _conversations[_conversations.indexOf(existing)] = updated;
        unawaited(_saveIndex());
        return updated;
      }
      return existing;
    }
    final created = Conversation(id: id, peer: _peerFrom(friend));
    _conversations.add(created);
    return created;
  }

  static SocialPerson _peerFrom(SocialPerson p) => SocialPerson(
    handle: p.handle,
    displayName: p.displayName,
    avatar: p.avatar,
    conversation: p.conversation,
  );

  static bool _peerChanged(SocialPerson a, SocialPerson b) =>
      a.handle != b.handle ||
      a.displayName != b.displayName ||
      a.avatar != b.avatar;

  // ---- Sending ----

  /// Sends [text] to the friend in [conversation]. Saved first; sent now
  /// when connected, or as soon as the connection returns. Returns an error
  /// to show, or null.
  Future<String?> send(Conversation conversation, String text) async {
    final body = text.trim();
    if (body.isEmpty) return null;
    if (body.length > _maxChars) {
      return 'A message can be up to $_maxChars characters.';
    }
    await load(conversation.id);
    final message = ChatMessage(
      id: _newId(),
      conversation: conversation.id,
      outgoing: true,
      text: body,
      at: DateTime.now(),
      status: MessageStatus.sending,
    );
    _outbox = [
      ..._outbox,
      PendingSend(
        id: message.id,
        conversation: conversation.id,
        to: conversation.peer.handle,
      ),
    ];
    await _apply([message], peer: conversation.peer);
    await _saveIndex();
    _pumpOutbox();
    if (_connection == MessagesConnection.idle) _connectSoon();
    return null;
  }

  /// Sends a message that failed again, under the same id.
  Future<void> retry(ChatMessage message) async {
    if (!message.outgoing || message.status != MessageStatus.failed) return;
    final peer = conversation(message.conversation)?.peer;
    if (peer == null) return;
    _outbox = [
      ..._outbox,
      PendingSend(
        id: message.id,
        conversation: message.conversation,
        to: peer.handle,
      ),
    ];
    await _apply([
      message.copyWith(status: MessageStatus.sending, clearError: true),
    ]);
    await _saveIndex();
    _pumpOutbox();
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Sends what waits in the outbox, oldest first, within the rate limit.
  void _pumpOutbox() {
    if (!_ready || _socket == null) return;
    _outboxTimer?.cancel();
    for (final pending in _outbox) {
      if (_inFlight.contains(pending.id)) continue;
      final text = _textOf(pending);
      if (text == null) {
        if (!hasHistory(pending.conversation)) continue;
        // Its message is gone (should not happen): dropped from the outbox.
        _inFlight.add(pending.id);
        unawaited(_settle(pending.id, null));
        continue;
      }
      if (!_takeToken()) {
        _outboxTimer = Timer(sendSpacing, _pumpOutbox);
        return;
      }
      _inFlight.add(pending.id);
      _sendJson({
        't': 'send',
        'to': pending.to,
        'id': pending.id,
        'text': text,
      });
    }
  }

  String? _textOf(PendingSend pending) {
    for (final m in messagesOf(pending.conversation)) {
      if (m.outgoing && m.id == pending.id) return m.text;
    }
    return null;
  }

  bool _takeToken() {
    final now = DateTime.now();
    final refill =
        now.difference(_tokensAt).inMilliseconds ~/
        max(1, sendSpacing.inMilliseconds);
    if (refill > 0) {
      _sendTokens = min(10, _sendTokens + refill);
      _tokensAt = now;
    }
    if (_sendTokens <= 0) return false;
    _sendTokens -= 1;
    return true;
  }

  /// Takes [id] out of the outbox (accepted or refused).
  Future<void> _settle(String id, ChatMessage? updated) async {
    _inFlight.remove(id);
    _outbox = [
      for (final p in _outbox)
        if (p.id != id) p,
    ];
    if (updated != null) await _apply([updated]);
    await _saveIndex();
  }

  // ---- Connection ----

  void _connectSoon() {
    if (_disposed || _paused || (_viewers == 0 && _outbox.isEmpty)) return;
    if (_socket != null || _connection == MessagesConnection.connecting) return;
    if (_connection == MessagesConnection.unavailable) return;
    _retry?.cancel();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final userId = _userId;
    if (_disposed || userId == null || !_loaded) return;
    final uri = _api.messagesSocket();
    if (uri == null) return _setConnection(MessagesConnection.unavailable);
    _setConnection(MessagesConnection.connecting);
    String? token;
    try {
      token = await _account.accessToken();
    } on AccountApiException {
      // Offline: retried below.
    }
    if (_disposed || _userId != userId || _paused) return;
    if (token == null && _account.status != AccountStatus.signedIn) {
      return _setConnection(MessagesConnection.unavailable);
    }
    final MessageSocket socket;
    try {
      if (token == null) throw const SocketException('No session token.');
      socket = await _connector(
        uri,
        token,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      CrashReporter.instance.note('messages connect failed');
      return _scheduleReconnect();
    }
    if (_disposed || _userId != userId || _paused || _socket != null) {
      unawaited(socket.close(1000));
      return;
    }
    _socket = socket;
    _subscription = socket.frames.listen(
      (data) => _frames = _frames
          .then((_) => _onFrame(socket, data))
          // A frame that could not be saved is not acknowledged; it comes
          // again on the next connection.
          .catchError((Object _) {}),
      onDone: () => _onClosed(socket),
      onError: (Object _) => _onClosed(socket),
      cancelOnError: true,
    );
  }

  void _scheduleReconnect() {
    if (_disposed || _paused) return;
    if (_viewers == 0 && _outbox.isEmpty) {
      return _setConnection(MessagesConnection.idle);
    }
    _setConnection(MessagesConnection.offline);
    _retry?.cancel();
    _retry = Timer(_backoff(_attempt), _connect);
    _attempt += 1;
  }

  void _onClosed(MessageSocket socket) {
    if (socket != _socket) return;
    _dropSocket();
    if (_disposed) return;
    switch (socket.closeCode) {
      case 4003:
        // Friends was turned off (here or on another device).
        return _setConnection(MessagesConnection.unavailable);
      case 4401:
        // The session ended; a new token is fetched on the next attempt,
        // and a signed-out account stops there.
        if (_account.status != AccountStatus.signedIn) {
          return _setConnection(MessagesConnection.unavailable);
        }
    }
    _scheduleReconnect();
  }

  void _dropSocket() {
    _socket = null;
    _ready = false;
    _inFlight.clear();
    _outboxTimer?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _disconnect() {
    _retry?.cancel();
    _linger?.cancel();
    _ackTimer?.cancel();
    _ackTimer = null;
    final socket = _socket;
    _dropSocket();
    if (socket != null) unawaited(socket.close(1000).catchError((Object _) {}));
  }

  void _onPause() {
    _paused = true;
    _retry?.cancel();
    unawaited(_closeAfterAck());
    if (_connection != MessagesConnection.unavailable) {
      _setConnection(MessagesConnection.idle);
    }
  }

  void _onResume() {
    _paused = false;
    _attempt = 0;
    if (_viewers > 0 || _outbox.isNotEmpty) _connectSoon();
  }

  /// After the user turned Friends back on: try again.
  void reset() {
    if (_connection != MessagesConnection.unavailable) return;
    _setConnection(MessagesConnection.idle);
    _attempt = 0;
    _connectSoon();
  }

  void _setConnection(MessagesConnection value) {
    if (_connection == value) return;
    _connection = value;
    notifyListeners();
  }

  void _sendJson(Map<String, Object?> frame) {
    try {
      _socket?.send(jsonEncode(frame));
    } catch (_) {
      // Closing: its close handler reconnects.
    }
  }

  // ---- Frames ----

  Future<void> _onFrame(MessageSocket socket, dynamic data) async {
    if (socket != _socket || data is! String) return;
    Map<String, dynamic> frame;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) return;
      frame = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    switch (frame['t']) {
      case 'ready':
        _ready = true;
        _attempt = 0;
        final limits = frame['limits'];
        final chars = limits is Map ? limits['maxChars'] : null;
        if (chars is int && chars > 0) _maxChars = chars;
        _pumpOutbox();
      case 'synced':
        _setConnection(MessagesConnection.online);
        // What waited in the mailbox is on this device now.
        _social.clearWaitingMessages();
      case 'event':
        await _onEvent(frame);
      case 'receipt':
        await _onReceipt(frame);
      case 'sent':
        await _onSent(frame);
      case 'send_error':
        await _onSendError(frame);
    }
  }

  Future<void> _onEvent(Map<String, dynamic> frame) async {
    final seq = frame['seq'];
    if (seq is! int) return;
    switch (frame['kind']) {
      case 'message':
        await _onMessage(frame);
      case 'receipt':
        await _onReceipt(frame, deferIndex: true);
    }
    // Saved: may be acknowledged.
    if (seq > _savedSeq) _savedSeq = seq;
    _ackTimer ??= Timer(ackDelay, _flushAck);
  }

  void _flushAck() {
    _ackTimer?.cancel();
    _ackTimer = null;
    unawaited(_sendAck());
  }

  /// Acknowledges what is saved. The conversation list is written first, so
  /// nothing the server is about to delete exists here only in a file the
  /// list does not know of.
  Future<void> _sendAck() async {
    final socket = _socket;
    final seq = _savedSeq;
    if (seq <= _ackedSeq || socket == null) return;
    if (_indexDirty) await _saveIndex();
    if (socket != _socket || seq <= _ackedSeq) return;
    _ackedSeq = seq;
    _sendJson({'t': 'ack', 'seq': seq});
  }

  Future<void> _onMessage(Map<String, dynamic> frame) async {
    final id = frame['id'];
    final conv = frame['conv'];
    final text = frame['text'];
    final at = frame['at'];
    final peer = SocialPerson.fromJson(frame['peer']);
    if (id is! String ||
        conv is! String ||
        !conversationIdPattern.hasMatch(conv) ||
        text is! String ||
        at is! int ||
        peer == null) {
      return;
    }
    final outgoing = frame['out'] == true;
    final message = ChatMessage(
      id: id,
      conversation: conv,
      outgoing: outgoing,
      text: text,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      status: outgoing ? MessageStatus.sent : MessageStatus.delivered,
    );
    final history = await load(conv);
    final person = SocialPerson(
      handle: peer.handle,
      displayName: peer.displayName,
      avatar: peer.avatar,
      conversation: conv,
    );
    // Seen already (a redelivery after an interrupted acknowledgement, or
    // this device's own message copied back): nothing changes, unless the
    // app stopped before the conversation list was saved.
    final known = history.where((m) => m.key == message.key).firstOrNull;
    if (known != null) {
      if (conversation(conv)?.last == null) {
        await _apply([known], peer: person, deferIndex: true);
      }
      return;
    }
    final seen = _visibleConversation == conv && _viewers > 0;
    await _apply(
      [message],
      peer: person,
      unreadDelta: outgoing || seen ? 0 : 1,
      deferIndex: true,
    );
  }

  Future<void> _onReceipt(
    Map<String, dynamic> frame, {
    bool deferIndex = false,
  }) async {
    final conv = frame['conv'];
    final ids = frame['ids'];
    if (conv is! String ||
        !conversationIdPattern.hasMatch(conv) ||
        ids is! List) {
      return;
    }
    final delivered = {
      for (final id in ids)
        if (id is String) id,
    };
    final history = await load(conv);
    final changed = [
      for (final m in history)
        if (m.outgoing &&
            delivered.contains(m.id) &&
            m.status != MessageStatus.delivered)
          m.copyWith(status: MessageStatus.delivered),
    ];
    if (changed.isNotEmpty) await _apply(changed, deferIndex: deferIndex);
  }

  Future<void> _onSent(Map<String, dynamic> frame) async {
    final id = frame['id'];
    final at = frame['at'];
    if (id is! String) return;
    final pending = _outbox.where((p) => p.id == id).firstOrNull;
    if (pending == null) return;
    final message = messagesOf(
      pending.conversation,
    ).where((m) => m.outgoing && m.id == id).firstOrNull;
    await _settle(
      id,
      message == null || message.status == MessageStatus.delivered
          ? null
          : message.copyWith(
              status: MessageStatus.sent,
              at: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
            ),
    );
  }

  /// Refused for good, or for now (`unavailable`, `rate_limited`): those
  /// stay in the outbox and go again after the next connection.
  Future<void> _onSendError(Map<String, dynamic> frame) async {
    final id = frame['id'];
    final code = frame['code'];
    if (id is! String) return;
    final pending = _outbox.where((p) => p.id == id).firstOrNull;
    if (pending == null) return;
    if (code == 'unavailable' || code == 'rate_limited') {
      _inFlight.remove(id);
      _outboxTimer?.cancel();
      _outboxTimer = Timer(const Duration(seconds: 15), _pumpOutbox);
      return;
    }
    final message = messagesOf(
      pending.conversation,
    ).where((m) => m.outgoing && m.id == id).firstOrNull;
    await _settle(
      id,
      message?.copyWith(
        status: MessageStatus.failed,
        error: code is String ? code : 'failed',
      ),
    );
  }

  /// Saves [messages] (new or changed) and updates the conversation list,
  /// which is written now, or with the next acknowledgement when
  /// [deferIndex] (a batch from the mailbox writes it once).
  Future<void> _apply(
    List<ChatMessage> messages, {
    SocialPerson? peer,
    int unreadDelta = 0,
    bool deferIndex = false,
  }) async {
    if (messages.isEmpty) return;
    final conv = messages.first.conversation;
    final history = [...(_histories[conv] ?? const <ChatMessage>[])];
    for (final message in messages) {
      final index = history.indexWhere((m) => m.key == message.key);
      if (index >= 0) {
        history[index] = message;
      } else {
        history.add(message);
      }
    }
    history.sort(_oldestFirst);
    _histories[conv] = history;

    final existing = conversation(conv);
    final last = history.isEmpty ? null : history.last;
    final updated =
        (existing ??
                Conversation(
                  id: conv,
                  peer: peer ?? SocialPerson(handle: '?'),
                ))
            .copyWith(
              peer: peer,
              last: last,
              unread: (existing?.unread ?? 0) + unreadDelta,
            );
    _conversations = [
      updated,
      for (final c in _conversations)
        if (c.id != conv) c,
    ]..sort(_newestFirst);
    notifyListeners();
    await _store.write(conv, messages, all: history);
    if (existing == null ||
        unreadDelta != 0 ||
        peer != null ||
        existing.last?.key != last?.key ||
        existing.last?.status != last?.status) {
      if (deferIndex) {
        _indexDirty = true;
      } else {
        await _saveIndex();
      }
    }
  }

  /// The conversation list changed since it was last written.
  bool _indexDirty = false;

  Future<void> _saveIndex() {
    _indexDirty = false;
    return _store.saveIndex(_conversations, _outbox).catchError((Object _) {
      _indexDirty = true;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _disconnect();
    _outboxTimer?.cancel();
    _lifecycle?.dispose();
    _account.removeListener(_accountChanged);
    super.dispose();
  }
}
