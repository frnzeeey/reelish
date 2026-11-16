import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/gestures.dart';
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
import 'package:onfeed/src/screens/social/conversation_options_screen.dart';
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
    prefs: <String, ConversationPrefs>{},
  );

  @override
  Future<MessageIndex> open(String userId) async => (
    conversations: [...index.conversations],
    outbox: [...index.outbox],
    prefs: {...index.prefs},
  );

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
  Future<void> replace(String conversation, List<ChatMessage> all) async =>
      files[conversation] = [...all];

  @override
  Future<void> saveIndex(
    List<Conversation> conversations,
    List<PendingSend> outbox, {
    Map<String, ConversationPrefs> prefs = const {},
  }) async => index = (
    conversations: [...conversations],
    outbox: [...outbox],
    prefs: {...prefs},
  );

  @override
  Future<void> wipe() async {
    files.clear();
    index = (
      conversations: <Conversation>[],
      outbox: <PendingSend>[],
      prefs: <String, ConversationPrefs>{},
    );
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

  // ---- Deleting, unsending, nicknames and mute ----

  /// Connects [socket] with the account's settings.
  Future<void> ready(
    WidgetTester tester,
    FakeSocket socket, [
    List<Map<String, Object?>> prefs = const [],
  ]) async {
    socket.receive({'t': 'ready', 'serverTime': 1, 'prefs': prefs});
    socket.receive({'t': 'synced', 'seq': 0});
    await tester.pump();
  }

  Map<String, Object?> incoming(int seq, String id, String text) => {
    't': 'event',
    'seq': seq,
    'kind': 'message',
    'conv': conv,
    'id': id,
    'out': false,
    'peer': {'handle': 'ana', 'displayName': 'Ana', 'avatar': null},
    'text': text,
    'at': DateTime.now().millisecondsSinceEpoch,
  };

  /// Answers the last request of type [t]: settings first, then `done`.
  Future<void> answer(
    WidgetTester tester,
    FakeSocket socket,
    String t, {
    Map<String, Object?>? prefs,
  }) async {
    final ref = socket.sent.lastWhere((f) => f['t'] == t)['ref'];
    if (prefs != null) {
      socket.receive({
        't': 'prefs',
        'prefs': [prefs],
      });
    }
    socket.receive({'t': 'done', 'ref': ref, 'conv': conv});
    await tester.pumpAndSettle();
  }

  testWidgets(
    'long press on a message offers Delete for you, which asks first and '
    'removes it only for this account',
    (tester) async {
      final messages = await controller(tester);
      await tester.pumpWidget(
        app(
          ChatScreen(conversation: conversation(messages), messages: messages),
        ),
      );
      await tester.pumpAndSettle();
      final socket = sockets.single;
      await ready(tester, socket);
      socket.receive(incoming(1, 'm1', 'Spoilers ahead'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Spoilers ahead'));
      await tester.pumpAndSettle();
      // A sheet of the message's actions, not the text selection toolbar.
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Select all'), findsNothing);
      // Theirs: Copy and Delete for you, no Unsend.
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Unsend for everyone'), findsNothing);
      await tester.tap(find.text('Delete for you'));
      await tester.pumpAndSettle();
      expect(find.text('Delete for you?'), findsOneWidget);
      expect(find.textContaining('Ana still has their copy'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pump();
      expect(socket.sent.lastWhere((f) => f['t'] == 'hide')['keys'], ['i:m1']);
      // Still shown until Reelish agrees.
      expect(find.text('Spoilers ahead'), findsOneWidget);
      await answer(tester, socket, 'hide');
      expect(find.text('Spoilers ahead'), findsNothing);
      expect(find.text('Deleted for you'), findsOneWidget);
      await done(tester);
    },
  );

  testWidgets('a sent message can be unsent for both, and says so', (
    tester,
  ) async {
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(ChatScreen(conversation: conversation(messages), messages: messages)),
    );
    await tester.pumpAndSettle();
    final socket = sockets.single;
    await ready(tester, socket);
    await tester.enterText(find.byType(TextField), 'Wrong person');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    final id = socket.sent.singleWhere((f) => f['t'] == 'send')['id'];
    socket.receive({'t': 'sent', 'id': id, 'conv': conv, 'at': 1000});
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Wrong person'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unsend for everyone'));
    await tester.pumpAndSettle();
    expect(find.text('Unsend for everyone?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Unsend'));
    await tester.pump();
    final frame = socket.sent.lastWhere((f) => f['t'] == 'unsend');
    expect(frame['to'], 'ana');
    expect(frame['id'], id);
    await answer(tester, socket, 'unsend');
    expect(find.text('Wrong person'), findsNothing);
    expect(find.text('You unsent a message'), findsOneWidget);
    await done(tester);
  });

  testWidgets(
    'Windows: right click on a message offers its actions',
    (tester) async {
      final messages = await controller(tester);
      await tester.pumpWidget(
        app(
          ChatScreen(conversation: conversation(messages), messages: messages),
        ),
      );
      await tester.pumpAndSettle();
      final socket = sockets.single;
      await ready(tester, socket);
      socket.receive(incoming(1, 'm1', 'From the desk'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('From the desk'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete for you'), findsOneWidget);
      await done(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('TV: Select on a message offers its actions', (tester) async {
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
    final socket = sockets.single;
    await ready(tester, socket);
    socket.receive(incoming(1, 'm1', 'Movie at eight'));
    await tester.pumpAndSettle();
    // From the composer, up reaches the message.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(find.text('Delete for you'), findsOneWidget);
    expect(find.text('Unsend for everyone'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await done(tester);
  });

  testWidgets('long press, Copy text puts the message on the clipboard', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(ChatScreen(conversation: conversation(messages), messages: messages)),
    );
    await tester.pumpAndSettle();
    final socket = sockets.single;
    await ready(tester, socket);
    socket.receive(incoming(1, 'm1', 'Code: 4512'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Code: 4512'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy text'));
    await tester.pumpAndSettle();
    expect(copied, ['Code: 4512']);
    expect(find.text('Copied'), findsOneWidget);
    await done(tester);
  });

  /// TV, with a big screen.
  void onTv(WidgetTester tester) {
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
  }

  testWidgets('TV: Select on a failed message retries it, as before', (
    tester,
  ) async {
    onTv(tester);
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(ChatScreen(conversation: conversation(messages), messages: messages)),
    );
    await tester.pumpAndSettle();
    final socket = sockets.single;
    await ready(tester, socket);
    await messages.send(conversation(messages), 'Hi');
    await tester.pumpAndSettle();
    final id = socket.sent.singleWhere((f) => f['t'] == 'send')['id'];
    socket.receive({'t': 'send_error', 'id': id, 'code': 'daily_limit'});
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(socket.sent.where((f) => f['t'] == 'send'), hasLength(2));
    await done(tester);
  });

  testWidgets(
    'TV: Up and Down show every line of a message taller than the screen',
    (tester) async {
      onTv(tester);
      final messages = await controller(tester);
      await tester.pumpWidget(
        app(
          ChatScreen(conversation: conversation(messages), messages: messages),
        ),
      );
      await tester.pumpAndSettle();
      final socket = sockets.single;
      await ready(tester, socket);
      // More than twice the list's height, with a message on each side that
      // focus could jump to.
      final tall = List.filled(_tallLines, 'line').join('\n');
      socket.receive(incoming(1, 'm0', 'First one'));
      socket.receive(incoming(2, 'm1', tall));
      socket.receive(incoming(3, 'm2', 'Short one'));
      await tester.pumpAndSettle();
      final list = find.byType(ListView);
      final message = find.text(tall);
      final height = tester.getRect(message).height;
      expect(height, greaterThan(tester.getRect(list).height * 2));

      /// The parts of the tall message on screen so far (its own offsets).
      final seen = <(double, double)>[];
      void look() {
        final rect = tester.getRect(message);
        final view = tester.getRect(list);
        final top = max(rect.top, view.top) - rect.top;
        final bottom = min(rect.bottom, view.bottom) - rect.top;
        if (bottom > top) seen.add((top, bottom));
      }

      /// Whether every line was on screen at some point.
      bool all() {
        final parts = [...seen]..sort((a, b) => a.$1.compareTo(b.$1));
        var reached = 0.0;
        for (final (top, bottom) in parts) {
          if (top > reached + 1) return false;
          reached = max(reached, bottom);
        }
        return reached >= height - 1;
      }

      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        look();
      }

      /// Presses [key] until focus is on [text]'s message.
      Future<void> until(LogicalKeyboardKey key, String text) async {
        for (var i = 0; i < 20; i++) {
          await press(key);
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused != null &&
              find
                  .descendant(
                    of: find.byElementPredicate((e) => e == focused),
                    matching: find.text(text),
                  )
                  .evaluate()
                  .isNotEmpty) {
            return;
          }
        }
        fail('focus never reached "$text"');
      }

      // Up from the composer, through the tall one, to the first message.
      look();
      await until(LogicalKeyboardKey.arrowUp, 'First one');
      expect(all(), isTrue, reason: 'going up skipped part of it: $seen');
      // And back down to the short one.
      seen.clear();
      look();
      await until(LogicalKeyboardKey.arrowDown, 'Short one');
      expect(all(), isTrue, reason: 'going down skipped part of it: $seen');
      await done(tester);
    },
  );

  testWidgets(
    'the list shows a nickname with the real handle, a muted conversation, '
    'and long press opens its options',
    (tester) async {
      final messages = await controller(tester);
      Conversation? options;
      await tester.pumpWidget(
        app(
          MessagesScreen(
            messages: messages,
            onBack: () {},
            openChat: (_) {},
            openOptions: (c) => options = c,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final socket = sockets.single;
      await ready(tester, socket, [
        {'conv': conv, 'muted': true, 'nickname': 'Annie', 'clearedAt': null},
      ]);
      socket.receive(incoming(1, 'm1', 'Hi there'));
      await tester.pumpAndSettle();
      expect(find.text('Annie'), findsOneWidget);
      expect(find.text('Ana'), findsNothing);
      expect(find.textContaining('@ana'), findsOneWidget);
      expect(find.byIcon(ReelishIcons.volumeOff), findsOneWidget);
      expect(messages.unread, 0);
      await tester.longPress(find.text('Annie'));
      expect(options?.id, conv);
      await done(tester);
    },
  );

  testWidgets(
    'conversation options: nickname, mute and delete, each saved by Reelish',
    (tester) async {
      // Every option on screen at once.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final messages = await controller(tester);
      final start = conversation(messages);
      var deleted = false;
      await tester.pumpWidget(
        app(
          ConversationOptionsScreen(
            conversation: start,
            messages: messages,
            onBack: () {},
            onDeleted: () => deleted = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final socket = sockets.single;
      await ready(tester, socket);

      await tester.tap(find.text('Set nickname'));
      await tester.pumpAndSettle();
      expect(find.text('Nickname for @ana'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Annie');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(
        socket.sent.lastWhere((f) => f['t'] == 'pref')['nickname'],
        'Annie',
      );
      await answer(
        tester,
        socket,
        'pref',
        prefs: {
          'conv': conv,
          'muted': false,
          'nickname': 'Annie',
          'clearedAt': null,
        },
      );
      expect(find.text('Edit nickname'), findsOneWidget);
      expect(find.textContaining('Their name: Ana'), findsOneWidget);

      await tester.tap(find.text('Mute conversation'));
      await tester.pump();
      expect(socket.sent.lastWhere((f) => f['t'] == 'pref')['muted'], isTrue);
      await answer(
        tester,
        socket,
        'pref',
        prefs: {
          'conv': conv,
          'muted': true,
          'nickname': 'Annie',
          'clearedAt': null,
        },
      );
      expect(messages.isMuted(conv), isTrue);
      expect(find.text('Conversation muted'), findsOneWidget);

      await tester.tap(find.text('Delete conversation'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ana keeps their copy'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pump();
      expect(socket.sent.lastWhere((f) => f['t'] == 'pref')['clear'], isTrue);
      await answer(
        tester,
        socket,
        'pref',
        prefs: {
          'conv': conv,
          'muted': true,
          'nickname': 'Annie',
          'clearedAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
      expect(deleted, isTrue);
      await done(tester);
    },
  );

  testWidgets('conversation options say so when offline', (tester) async {
    final messages = await controller(tester);
    await tester.pumpWidget(
      app(
        ConversationOptionsScreen(
          conversation: conversation(messages),
          messages: messages,
          onBack: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Never connected: nothing to send the change over.
    await tester.tap(find.text('Mute conversation'));
    await tester.pumpAndSettle();
    expect(find.text(messageActionErrorText('offline')), findsOneWidget);
    expect(messages.isMuted(conv), isFalse);
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

/// Lines in the TV test's tall message: a little taller than the list.
const _tallLines = 110;
