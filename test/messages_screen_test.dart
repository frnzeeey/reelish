import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/messaging/message_models.dart';
import 'package:onfeed/src/messaging/message_store.dart';
import 'package:onfeed/src/messaging/messages_controller.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/social/messages_screen.dart';
import 'package:onfeed/src/social/friends_controller.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:onfeed/src/theme/reelish_icons.dart';
import 'package:onfeed/src/widgets/tv/tv_focus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const conv = 'conversation_abcdef12345';

/// Keeps everything in memory: widget tests run without real file I/O.
class MemoryMessageStore extends MessageStore {
  final files = <String, List<ChatMessage>>{};
  MessageIndex index = (
    conversations: <Conversation>[],
    outbox: <PendingSend>[],
  );

  @override
  Future<MessageIndex> open(String userId) async =>
      (conversations: [...index.conversations], outbox: [...index.outbox]);

  @override
  Future<List<ChatMessage>> messages(String conversation) async => [
    ...?files[conversation],
  ];

  @override
  Future<void> write(
    String conversation,
    List<ChatMessage> messages, {
    required List<ChatMessage> all,
  }) async => files[conversation] = [...all];

  @override
  Future<void> saveIndex(
    List<Conversation> conversations,
    List<PendingSend> outbox,
  ) async => index = (conversations: [...conversations], outbox: [...outbox]);

  @override
  Future<void> wipe() async {
    files.clear();
    index = (conversations: <Conversation>[], outbox: <PendingSend>[]);
  }
}

class FakeSocket implements MessageSocket {
  final _incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  @override
  int? closeCode;

  @override
  Stream<dynamic> get frames => _incoming.stream;

  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, dynamic>);

  void receive(Map<String, Object?> frame) => _incoming.add(jsonEncode(frame));

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// Unmounts, and lets the connection's linger timer run out.
Future<void> done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  late MemoryMessageStore store;
  late List<FakeSocket> sockets;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = MemoryMessageStore();
    sockets = [];
  });

  Future<MessagesController> controller(WidgetTester tester) async {
    final api = AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    final account = AccountController(
      api: api,
      store: MemorySessionStore(
        StoredSession(
          sessionId: 's1',
          accessToken: 'access',
          accessExpiresAt: _now() + 900,
          refreshToken: 'refresh',
          refreshExpiresAt: _now() + 86400,
          userId: 'u1',
          username: 'viewer',
        ),
      ),
    );
    await account.restore();
    final messages = MessagesController(
      account: account,
      api: api,
      store: store,
      social: SocialController(account: account, api: api),
      connector: (uri, token) async {
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
      backoff: (_) => const Duration(seconds: 30),
      ackDelay: Duration.zero,
      lingerAfterClose: Duration.zero,
      sendSpacing: const Duration(milliseconds: 1),
      lifecycle: false,
    );
    addTearDown(messages.dispose);
    await messages.ensureLoaded();
    return messages;
  }

  Conversation conversation(MessagesController messages) => messages.open(
    const SocialPerson(handle: 'ana', displayName: 'Ana', conversation: conv),
  );

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('an empty conversation invites a first message', (tester) async {
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(ChatScreen(conversation: conversation(messages), messages: messages)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Say hello to Ana'), findsOneWidget);
    expect(
      find.text('Only the two of you can read this conversation.'),
      findsOneWidget,
    );
    await done(tester);
  });

  testWidgets('sending shows the message as sending, then sent', (
    tester,
  ) async {
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(ChatScreen(conversation: conversation(messages), messages: messages)),
    );
    await tester.pumpAndSettle();
    final socket = sockets.single;
    socket.receive({'t': 'ready', 'serverTime': 1});
    socket.receive({'t': 'synced', 'seq': 0});
    await tester.pump();

    // Send stays off until there is something to send.
    final send = find.widgetWithIcon(IconButton, ReelishIcons.send);
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Movie night?');
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('Movie night?'), findsOneWidget);
    final frame = socket.sent.singleWhere((f) => f['t'] == 'send');
    expect(frame['to'], 'ana');
    expect(frame['text'], 'Movie night?');
    expect(messages.messagesOf(conv).single.status, MessageStatus.sending);

    socket.receive({'t': 'sent', 'id': frame['id'], 'conv': conv, 'at': 1000});
    await tester.pumpAndSettle();
    expect(messages.messagesOf(conv).single.status, MessageStatus.sent);
    // The field is cleared for the next message.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await done(tester);
  });

  testWidgets(
    'Windows: Enter sends',
    (tester) async {
      final messages = await controller(tester);
      await tester.pumpWidget(
        app(
          ChatScreen(conversation: conversation(messages), messages: messages),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Hello from the desk');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(messages.messagesOf(conv).single.text, 'Hello from the desk');
      await done(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a refused message says why and offers a retry', (tester) async {
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(ChatScreen(conversation: conversation(messages), messages: messages)),
    );
    await tester.pumpAndSettle();
    final socket = sockets.single;
    socket.receive({'t': 'ready', 'serverTime': 1});
    await tester.enterText(find.byType(TextField), 'Hi');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    final id = socket.sent.singleWhere((f) => f['t'] == 'send')['id'];
    socket.receive({'t': 'send_error', 'id': id, 'code': 'daily_limit'});
    await tester.pumpAndSettle();
    expect(
      find.textContaining('you have sent many messages today'),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('Tap to retry'));
    await tester.pumpAndSettle();
    expect(socket.sent.where((f) => f['t'] == 'send'), hasLength(2));
    await done(tester);
  });

  testWidgets('the list shows conversations with unread counts', (
    tester,
  ) async {
    final messages = await controller(tester);
    Conversation? opened;
    await tester.pumpWidget(
      app(
        MessagesScreen(
          messages: messages,
          onBack: () {},
          openChat: (c) => opened = c,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No messages yet'), findsOneWidget);
    expect(find.textContaining('not end-to-end encrypted'), findsOneWidget);

    final socket = sockets.single;
    socket.receive({'t': 'ready', 'serverTime': 1});
    socket.receive({
      't': 'event',
      'seq': 1,
      'kind': 'message',
      'conv': conv,
      'id': 'm1',
      'out': false,
      'peer': {'handle': 'ana', 'displayName': 'Ana', 'avatar': null},
      'text': 'Are you watching tonight?',
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    socket.receive({'t': 'synced', 'seq': 1});
    await tester.pumpAndSettle();
    expect(find.text('Ana'), findsOneWidget);
    expect(find.textContaining('Are you watching tonight?'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.text('Ana'));
    expect(opened?.id, conv);
    await done(tester);
  });

  testWidgets('says when offline, and keeps what was written', (tester) async {
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(ChatScreen(conversation: conversation(messages), messages: messages)),
    );
    await tester.pumpAndSettle();
    await sockets.single.close();
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Later then');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Later then'), findsOneWidget);
    expect(store.index.outbox.single.to, 'ana');
    await done(tester);
  });

  testWidgets('TV: the composer opens the remote-friendly text entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    addTearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(ChatScreen(conversation: conversation(messages), messages: messages)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Write a message'), findsOneWidget);
    // Focused at once; Select opens the dialog.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TvTextEntryDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'From the couch');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(messages.messagesOf(conv).single.text, 'From the couch');
    await done(tester);
  });

  test('times read naturally', () {
    final now = DateTime(2026, 11, 14, 18);
    expect(messageTime(DateTime(2026, 11, 14, 9, 5), now: now), '09:05');
    expect(messageTime(DateTime(2026, 11, 12, 21, 30), now: now), 'Thu 21:30');
    expect(messageTime(DateTime(2026, 10, 2, 8), now: now), 'Oct 2');
    expect(messageTime(DateTime(2025, 10, 2, 8), now: now), 'Oct 2, 2025');
  });
}
