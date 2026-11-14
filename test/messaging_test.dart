import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/messaging/message_models.dart';
import 'package:onfeed/src/messaging/message_store.dart';
import 'package:onfeed/src/messaging/messages_controller.dart';
import 'package:onfeed/src/social/friends_controller.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const conv = 'conversation_abcdef12345';
const other = 'conversation_zyxwvu98765';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

StoredSession _session(String userId) => StoredSession(
  sessionId: 's-$userId',
  accessToken: 'access-$userId',
  accessExpiresAt: _now() + 900,
  refreshToken: 'refresh-$userId',
  refreshExpiresAt: _now() + 86400,
  userId: userId,
  username: 'viewer',
);

ChatMessage _message(
  String id, {
  bool outgoing = false,
  String text = 'hi',
  int at = 1000,
  MessageStatus status = MessageStatus.delivered,
  String conversation = conv,
}) => ChatMessage(
  id: id,
  conversation: conversation,
  outgoing: outgoing,
  text: text,
  at: DateTime.fromMillisecondsSinceEpoch(at),
  status: status,
);

class FakeSocket implements MessageSocket {
  final _incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  @override
  int? closeCode;
  bool closed = false;

  @override
  Stream<dynamic> get frames => _incoming.stream;

  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, dynamic>);

  void receive(Map<String, Object?> frame) => _incoming.add(jsonEncode(frame));

  Future<void> drop([int? code]) async {
    closeCode = code;
    await _incoming.close();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  List<Map<String, dynamic>> of(String t) =>
      sent.where((f) => f['t'] == t).toList();
}

Map<String, Object?> _event(
  int seq,
  String id, {
  String text = 'hello',
  bool out = false,
  String conversation = conv,
  String handle = 'ana',
}) => {
  't': 'event',
  'seq': seq,
  'kind': 'message',
  'conv': conversation,
  'id': id,
  'out': out,
  'peer': {'handle': handle, 'displayName': 'Ana', 'avatar': null},
  'text': text,
  'at': 5000 + seq,
};

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

/// Waits (up to 5 s) for [condition].
Future<void> eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('reelish_messages_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('MessageStore', () {
    MessageStore store() => MessageStore(directory: () async => root);

    test('saves and reads back; the last line for a message wins', () async {
      final s = store();
      await s.open('user-1');
      final first = _message(
        'm1',
        status: MessageStatus.sending,
        outgoing: true,
      );
      await s.write(conv, [first], all: [first]);
      final updated = first.copyWith(status: MessageStatus.delivered);
      await s.write(conv, [updated], all: [updated]);
      final read = await store().open('user-1').then((_) => s.messages(conv));
      expect(read.single.status, MessageStatus.delivered);
    });

    test('a friend cannot overwrite your message by reusing its id', () async {
      final s = store();
      await s.open('user-1');
      final mine = _message('same', outgoing: true, text: 'mine');
      final theirs = _message('same', text: 'theirs', at: 2000);
      await s.write(conv, [mine, theirs], all: [mine, theirs]);
      final read = await s.messages(conv);
      expect(read.map((m) => m.text), ['mine', 'theirs']);
    });

    test('skips a line cut short by a crash', () async {
      final s = store();
      await s.open('user-1');
      final message = _message('m1');
      await s.write(conv, [message], all: [message]);
      final file = File(
        '${root.path}${Platform.pathSeparator}messages'
        '${Platform.pathSeparator}user-1${Platform.pathSeparator}$conv.jsonl',
      );
      await file.writeAsString(
        '{"id":"m2","c":"$conv","t":"cut',
        mode: FileMode.append,
      );
      expect((await s.messages(conv)).map((m) => m.id), ['m1']);
    });

    test(
      'keeps the conversation list and the outbox; wipe removes all',
      () async {
        final s = store();
        await s.open('user-1');
        final message = _message('m1');
        await s.write(conv, [message], all: [message]);
        await s.saveIndex(
          [
            Conversation(
              id: conv,
              peer: const SocialPerson(handle: 'ana'),
              last: message,
              unread: 2,
            ),
          ],
          [const PendingSend(id: 'p1', conversation: conv, to: 'ana')],
        );
        final again = await store().open('user-1');
        expect(again.conversations.single.unread, 2);
        expect(again.conversations.single.peer.handle, 'ana');
        expect(again.outbox.single.id, 'p1');
        // Another account on this device sees none of it.
        expect((await store().open('user-2')).conversations, isEmpty);

        await s.wipe();
        expect((await store().open('user-1')).conversations, isEmpty);
        expect(await s.messages(conv), isEmpty);
      },
    );

    test('rewrites a file that has grown past its messages', () async {
      final s = store();
      await s.open('user-1');
      var message = _message(
        'm1',
        outgoing: true,
        status: MessageStatus.sending,
      );
      for (var i = 0; i < 80; i++) {
        message = message.copyWith(
          status: i.isEven ? MessageStatus.sent : MessageStatus.delivered,
        );
        await s.write(conv, [message], all: [message]);
      }
      final file = File(
        '${root.path}${Platform.pathSeparator}messages'
        '${Platform.pathSeparator}user-1${Platform.pathSeparator}$conv.jsonl',
      );
      final lines = (await file.readAsLines()).where((l) => l.isNotEmpty);
      expect(lines.length, lessThan(60));
      expect((await s.messages(conv)).single.status, message.status);
    });

    test('refuses conversation ids that are not safe file names', () async {
      final s = store();
      await s.open('user-1');
      final bad = _message('m1', conversation: '../../escape_attempt_x');
      await s.write(bad.conversation, [bad], all: [bad]);
      expect(await s.messages(bad.conversation), isEmpty);
      expect(
        await File('${root.path}/escape_attempt_x.jsonl').exists(),
        isFalse,
      );
    });
  });

  group('MessagesController', () {
    late List<FakeSocket> sockets;
    late AccountController account;
    late AccountApi api;

    Future<MessagesController> controller({
      String userId = 'user-1',
      Future<MessageSocket> Function(Uri, String)? connector,
    }) async {
      api = AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      account = AccountController(
        api: api,
        store: MemorySessionStore(_session(userId)),
      );
      await account.restore();
      final made = MessagesController(
        account: account,
        api: api,
        store: MessageStore(directory: () async => root),
        social: SocialController(account: account, api: api),
        connector:
            connector ??
            (uri, token) async {
              expect(
                uri.toString(),
                'wss://api.reelish.test/api/v1/messages/socket',
              );
              expect(token, 'access-$userId');
              final socket = FakeSocket();
              sockets.add(socket);
              return socket;
            },
        backoff: (_) => const Duration(milliseconds: 10),
        ackDelay: const Duration(milliseconds: 5),
        lingerAfterClose: const Duration(milliseconds: 10),
        sendSpacing: const Duration(milliseconds: 5),
        lifecycle: false,
      );
      addTearDown(made.dispose);
      await made.ensureLoaded();
      return made;
    }

    setUp(() => sockets = []);

    Future<FakeSocket> connected(MessagesController messages) async {
      messages.attach();
      await settle();
      final socket = sockets.last;
      socket.receive({
        't': 'ready',
        'serverTime': 1,
        'limits': {'maxChars': 2000},
      });
      socket.receive({'t': 'synced', 'seq': 0});
      await settle();
      return socket;
    }

    test('saves an arriving message, then acknowledges it', () async {
      final messages = await controller();
      final socket = await connected(messages);
      expect(messages.connection, MessagesConnection.online);

      socket.receive(_event(7, 'a1', text: 'Hello there'));
      await settle();
      expect(socket.of('ack').single['seq'], 7);
      // On disk before the acknowledgement: a fresh store reads it.
      final disk = MessageStore(directory: () async => root);
      await disk.open('user-1');
      expect((await disk.messages(conv)).single.text, 'Hello there');

      final conversation = messages.conversations.single;
      expect(conversation.peer.handle, 'ana');
      expect(conversation.unread, 1);
      expect(messages.unread, 1);
      await messages.markRead(conv);
      expect(messages.unread, 0);
    });

    test('a redelivered message is stored and counted once', () async {
      final messages = await controller();
      final socket = await connected(messages);
      socket.receive(_event(1, 'a1'));
      await settle();
      // The connection dropped before the acknowledgement arrived.
      socket.receive(_event(1, 'a1'));
      socket.receive(_event(2, 'a2'));
      await settle();
      expect(messages.messagesOf(conv).map((m) => m.id), ['a1', 'a2']);
      expect(messages.unread, 2);
      expect(socket.of('ack').last['seq'], 2);
    });

    test('acknowledges a batch once, after all of it is saved', () async {
      final messages = await controller();
      final socket = await connected(messages);
      for (var seq = 1; seq <= 30; seq++) {
        socket.receive(_event(seq, 'b$seq'));
      }
      await eventually(() => socket.of('ack').lastOrNull?['seq'] == 30);
      // Grouped: far fewer acknowledgements (mailbox writes) than messages,
      // each covering only what was already saved.
      expect(socket.of('ack').length, lessThan(30));
      final acks = socket.of('ack').map((f) => f['seq'] as int).toList();
      expect(acks, orderedEquals([...acks]..sort()));
      expect(messages.messagesOf(conv), hasLength(30));
    });

    test(
      'sends offline messages when connected, and marks them sent and delivered',
      () async {
        final messages = await controller();
        final conversation = messages.open(
          const SocialPerson(handle: 'ana', conversation: conv),
        );
        // Not connected yet: saved as sending, kept in the outbox.
        messages.attach();
        expect(await messages.send(conversation, '  First  '), isNull);
        var mine = messages.messagesOf(conv).single;
        expect(mine.text, 'First');
        expect(mine.status, MessageStatus.sending);

        await settle();
        final socket = sockets.single;
        socket.receive({'t': 'ready', 'serverTime': 1});
        await settle();
        final sent = socket.of('send').single;
        expect(sent, {
          't': 'send',
          'to': 'ana',
          'id': mine.id,
          'text': 'First',
        });

        socket.receive({'t': 'sent', 'id': mine.id, 'conv': conv, 'at': 9000});
        await settle();
        mine = messages.messagesOf(conv).single;
        expect(mine.status, MessageStatus.sent);
        expect(mine.at.millisecondsSinceEpoch, 9000);

        socket.receive({
          't': 'event',
          'seq': 3,
          'kind': 'receipt',
          'conv': conv,
          'ids': [mine.id],
          'at': 9100,
        });
        await settle();
        expect(
          messages.messagesOf(conv).single.status,
          MessageStatus.delivered,
        );
        expect(socket.of('ack').last['seq'], 3);

        // A restart: history and an empty outbox come back from disk.
        final again = await controller();
        await again.load(conv);
        expect(again.messagesOf(conv).single.status, MessageStatus.delivered);
        expect(again.conversations.single.last?.text, 'First');
      },
    );

    test(
      'resends an unaccepted message with the same id after a reconnect',
      () async {
        final messages = await controller();
        final socket = await connected(messages);
        final conversation = messages.open(
          const SocialPerson(handle: 'ana', conversation: conv),
        );
        await messages.send(conversation, 'Are you there?');
        await settle();
        final id = socket.of('send').single['id'];
        // Lost before the answer.
        await socket.drop();
        await settle();
        expect(sockets, hasLength(2));
        final next = sockets.last;
        next.receive({'t': 'ready', 'serverTime': 1});
        await settle();
        expect(next.of('send').single['id'], id);
      },
    );

    test(
      'a pending message survives a restart and goes out afterwards',
      () async {
        final first = await controller();
        final conversation = first.open(
          const SocialPerson(handle: 'ana', conversation: conv),
        );
        await first.send(conversation, 'Written offline');
        final again = await controller();
        final socket = await connected(again);
        expect(socket.of('send').single['text'], 'Written offline');
      },
    );

    test('a refused message is marked failed and can be retried', () async {
      final messages = await controller();
      final socket = await connected(messages);
      final conversation = messages.open(
        const SocialPerson(handle: 'ana', conversation: conv),
      );
      await messages.send(conversation, 'Hi');
      await settle();
      final id = socket.of('send').single['id'] as String;
      socket.receive({'t': 'send_error', 'id': id, 'code': 'not_friends'});
      await settle();
      final failed = messages.messagesOf(conv).single;
      expect(failed.status, MessageStatus.failed);
      expect(failed.error, 'not_friends');

      await messages.retry(failed);
      await settle();
      expect(socket.of('send').map((f) => f['id']), [id, id]);
      expect(messages.messagesOf(conv).single.status, MessageStatus.sending);
    });

    test('a passing refusal keeps the message waiting', () async {
      final messages = await controller();
      final socket = await connected(messages);
      final conversation = messages.open(
        const SocialPerson(handle: 'ana', conversation: conv),
      );
      await messages.send(conversation, 'Hi');
      await settle();
      final id = socket.of('send').single['id'] as String;
      socket.receive({'t': 'send_error', 'id': id, 'code': 'unavailable'});
      await settle();
      expect(messages.messagesOf(conv).single.status, MessageStatus.sending);
    });

    test('refuses a message longer than the limit', () async {
      final messages = await controller();
      final conversation = messages.open(
        const SocialPerson(handle: 'ana', conversation: conv),
      );
      final error = await messages.send(conversation, 'x' * 2001);
      expect(error, contains('2000'));
      expect(messages.messagesOf(conv), isEmpty);
    });

    test(
      'adds a message sent from another of this account’s devices',
      () async {
        final messages = await controller();
        final socket = await connected(messages);
        socket.receive(
          _event(4, 'o1', out: true, text: 'From my phone', handle: 'ben'),
        );
        await settle();
        final copy = messages.messagesOf(conv).single;
        expect(copy.outgoing, isTrue);
        expect(copy.status, MessageStatus.sent);
        expect(messages.unread, 0);
        expect(messages.conversations.single.peer.handle, 'ben');
      },
    );

    test('ignores frames with an unsafe conversation id', () async {
      final messages = await controller();
      final socket = await connected(messages);
      socket.receive(_event(1, 'x1', conversation: '../escape'));
      await settle();
      expect(messages.conversations, isEmpty);
    });

    test('reconnects with backoff, but not once Friends is off', () async {
      final messages = await controller();
      final socket = await connected(messages);
      await socket.drop();
      await settle();
      expect(sockets, hasLength(2));
      await sockets.last.drop(4003);
      await settle();
      expect(messages.connection, MessagesConnection.unavailable);
      expect(sockets, hasLength(2));
    });

    test('closes the connection when no Messages screen is open', () async {
      final messages = await controller();
      final socket = await connected(messages);
      messages.detach();
      await settle();
      expect(socket.closed, isTrue);
      expect(messages.connection, MessagesConnection.idle);
    });

    test('keeps two conversations apart', () async {
      final messages = await controller();
      final socket = await connected(messages);
      socket.receive(_event(1, 'a1', text: 'to ana'));
      socket.receive(
        _event(2, 'b1', text: 'to ben', conversation: other, handle: 'ben'),
      );
      await settle();
      expect(messages.conversations.map((c) => c.id), [other, conv]);
      expect(messages.messagesOf(conv).single.text, 'to ana');
      expect(messages.messagesOf(other).single.text, 'to ben');
    });

    test('Friends turned off deletes the messages on this device', () async {
      final messages = await controller();
      final socket = await connected(messages);
      socket.receive(_event(1, 'a1'));
      await settle();
      await messages.forget();
      expect(messages.conversations, isEmpty);
      final again = await controller();
      expect(again.conversations, isEmpty);
    });

    test('another account on the device does not see the messages', () async {
      final messages = await controller();
      final socket = await connected(messages);
      socket.receive(_event(1, 'a1'));
      await settle();
      final second = await controller(userId: 'user-2');
      expect(second.conversations, isEmpty);
    });
  });
}
