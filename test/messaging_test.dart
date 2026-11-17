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

/// Controllers made by the current test.
final _live = <MessagesController>[];

/// Lets timers run, then waits until every frame each controller received
/// has been handled: a fixed delay alone fails on a slow machine.
Future<void> settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 40));
  for (final controller in [..._live]) {
    await controller.framesHandled;
  }
}

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

    test(
      'reads files written before deleting, unsending and settings',
      () async {
        // index.json and a conversation line exactly as the previous version
        // wrote them: no `prefs`, no `x`.
        final folder = Directory(
          '${root.path}${Platform.pathSeparator}messages'
          '${Platform.pathSeparator}user-1',
        );
        await folder.create(recursive: true);
        final line = jsonEncode({
          'id': 'm1',
          'c': conv,
          'o': false,
          't': 'From before',
          'at': 1000,
          's': 'delivered',
        });
        await File(
          '${folder.path}${Platform.pathSeparator}$conv.jsonl',
        ).writeAsString('$line\n');
        await File(
          '${folder.path}${Platform.pathSeparator}index.json',
        ).writeAsString(
          jsonEncode({
            'v': 1,
            'conversations': [
              {
                'id': conv,
                'peer': {'handle': 'ana'},
                'last': jsonDecode(line),
                'unread': 1,
              },
            ],
            'outbox': <Object>[],
          }),
        );
        final s = store();
        final index = await s.open('user-1');
        expect(index.conversations.single.unread, 1);
        expect(index.prefs, isEmpty);
        final read = (await s.messages(conv)).single;
        expect(read.text, 'From before');
        expect(read.removal, MessageRemoval.none);
        expect(read.visible, isTrue);
      },
    );

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
      Duration ackDelay = const Duration(milliseconds: 5),
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
        ackDelay: ackDelay,
        lingerAfterClose: const Duration(milliseconds: 10),
        sendSpacing: const Duration(milliseconds: 5),
        lifecycle: false,
      );
      addTearDown(made.dispose);
      _live.add(made);
      await made.ensureLoaded();
      return made;
    }

    setUp(() {
      sockets = [];
      _live.clear();
    });

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
      await eventually(() => socket.of('ack').isNotEmpty);
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
      await eventually(() => socket.of('ack').lastOrNull?['seq'] == 2);
    });

    test('acknowledges a batch once, after all of it is saved', () async {
      // The app's own grouping window: with the tests' 5 ms a slow machine
      // can save each message after the last acknowledgement went out.
      final messages = await controller(
        ackDelay: const Duration(milliseconds: 250),
      );
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
        await eventually(() => socket.of('ack').lastOrNull?['seq'] == 3);

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

    // ---- Deleting, unsending, nicknames and mute ----

    /// Connects, with the settings the mailbox gives on connecting.
    Future<FakeSocket> connectedWith(
      MessagesController messages,
      List<Map<String, Object?>> prefs,
    ) async {
      messages.attach();
      await settle();
      final socket = sockets.last;
      socket.receive({
        't': 'ready',
        'serverTime': 1,
        'limits': {'maxChars': 2000},
        'prefs': prefs,
      });
      socket.receive({'t': 'synced', 'seq': 0});
      await settle();
      return socket;
    }

    /// Answers the last request of type [t] as the mailbox would: the
    /// settings broadcast first (when given), then `done`, or `failed`.
    Future<void> answer(
      FakeSocket socket,
      String t, {
      Map<String, Object?>? prefs,
      String? refused,
    }) async {
      await eventually(() => socket.of(t).isNotEmpty);
      final ref = socket.of(t).last['ref'];
      if (prefs != null) {
        socket.receive({
          't': 'prefs',
          'prefs': [prefs],
        });
      }
      socket.receive(
        refused == null
            ? {'t': 'done', 'ref': ref, 'conv': conv}
            : {'t': 'failed', 'ref': ref, 'code': refused},
      );
    }

    Map<String, Object?> pref({
      bool muted = false,
      String? nickname,
      int? clearedAt,
    }) => {
      'conv': conv,
      'muted': muted,
      'nickname': nickname,
      'clearedAt': clearedAt,
    };

    Future<String> fileText(String userId) async {
      final file = File(
        '${root.path}${Platform.pathSeparator}messages'
        '${Platform.pathSeparator}$userId${Platform.pathSeparator}$conv.jsonl',
      );
      return await file.exists() ? file.readAsString() : '';
    }

    test(
      'a new device gets the account’s nickname and mute; they survive a '
      'restart, and a muted conversation stays out of the total unread',
      () async {
        final messages = await controller();
        await connectedWith(messages, [pref(muted: true, nickname: 'Annie')]);
        final socket = sockets.last;
        socket.receive(_event(1, 'a1'));
        await settle();
        final conversation = messages.conversations.single;
        // Delivered and counted on the conversation, not in the total.
        expect(conversation.unread, 1);
        expect(messages.unread, 0);
        final shown = messages.displayPeer(conversation);
        expect(shown.label, 'Annie');
        expect(shown.handle, 'ana');
        // The friend's own name is kept, not overwritten.
        expect(conversation.peer.displayName, 'Ana');

        // Restarted offline: the settings were saved with the list (written
        // just before the acknowledgement).
        await eventually(() => socket.of('ack').lastOrNull?['seq'] == 1);
        final again = await controller();
        expect(again.prefsOf(conv).muted, isTrue);
        expect(again.prefsOf(conv).nickname, 'Annie');
        // Reset on another device: the next connection's list wins.
        await connectedWith(again, []);
        expect(again.prefsOf(conv).isEmpty, isTrue);
        expect(again.unread, 1);
      },
    );

    test('nickname and mute go to the mailbox, apply its answer, and say why '
        'when they cannot', () async {
      final messages = await controller();
      // Not connected: nothing is changed only here.
      expect(
        await messages.setMuted(conv, true),
        messageActionErrorText('offline'),
      );
      final socket = await connectedWith(messages, []);

      final naming = messages.setNickname(conv, '  Big \n  Ana ');
      await answer(socket, 'pref', prefs: pref(nickname: 'Big Ana'));
      expect(await naming, isNull);
      expect(socket.of('pref').last, containsPair('nickname', 'Big Ana'));
      expect(messages.prefsOf(conv).nickname, 'Big Ana');

      // Empty or too long: refused here, never sent.
      final sent = socket.of('pref').length;
      expect(
        await messages.setNickname(conv, '   '),
        messageActionErrorText('invalid_nickname'),
      );
      expect(
        await messages.setNickname(conv, 'x' * 33),
        messageActionErrorText('invalid_nickname'),
      );
      expect(socket.of('pref'), hasLength(sent));

      final muting = messages.setMuted(conv, true);
      await answer(socket, 'pref', refused: 'too_many');
      expect(await muting, messageActionErrorText('too_many'));
      expect(messages.isMuted(conv), isFalse);

      // The connection drops before the answer.
      final lost = messages.setMuted(conv, true);
      await eventually(() => socket.of('pref').length == sent + 2);
      await socket.drop();
      expect(await lost, messageActionErrorText('offline'));
    });

    test('delete for me: gone here once the mailbox agrees, its text off the '
        'disk, and a redelivered copy does not bring it back', () async {
      final messages = await controller();
      final socket = await connectedWith(messages, []);
      socket.receive(_event(1, 'a1', text: 'Secret plan'));
      socket.receive(_event(2, 'a2', text: 'Second'));
      await settle();
      final target = messages.messagesOf(conv).first;

      final deleting = messages.deleteForMe(target);
      await answer(socket, 'hide');
      expect(await deleting, isNull);
      expect(socket.of('hide').single['keys'], ['i:a1']);
      expect(messages.messagesOf(conv).map((m) => m.id), ['a2']);
      expect(await fileText('user-1'), isNot(contains('Secret plan')));
      // Was unread: no longer counted.
      expect(messages.conversations.single.unread, 1);

      // The same message again (an interrupted acknowledgement).
      socket.receive(_event(1, 'a1', text: 'Secret plan'));
      await settle();
      expect(messages.messagesOf(conv).map((m) => m.id), ['a2']);
      final again = await controller();
      expect((await again.load(conv)).where((m) => m.visible), hasLength(1));
    });

    test(
      'delete for me on another device of the account applies here',
      () async {
        final messages = await controller();
        final socket = await connectedWith(messages, []);
        socket.receive(_event(1, 'a1'));
        socket.receive(_event(2, 'a2'));
        socket.receive({
          't': 'event',
          'seq': 3,
          'kind': 'hide',
          'conv': conv,
          'keys': ['i:a2', 'i:unknown-1'],
          'at': 9000,
        });
        await settle();
        expect(messages.messagesOf(conv).map((m) => m.id), ['a1']);
        expect(messages.conversations.single.last?.id, 'a1');
        await eventually(() => socket.of('ack').lastOrNull?['seq'] == 3);
      },
    );

    test('unsend: own message shown as unsent on both sides; a friend can only '
        'unsend their own messages', () async {
      final messages = await controller();
      final socket = await connectedWith(messages, []);
      final conversation = messages.open(
        const SocialPerson(handle: 'ana', conversation: conv),
      );
      await messages.send(conversation, 'Wrong chat, sorry');
      await eventually(() => socket.of('send').isNotEmpty);
      final mine = socket.of('send').single['id'] as String;
      socket.receive({'t': 'sent', 'id': mine, 'conv': conv, 'at': 9000});
      await settle();

      final unsending = messages.unsend(messages.messagesOf(conv).single);
      await answer(socket, 'unsend');
      expect(await unsending, isNull);
      expect(socket.of('unsend').single, containsPair('to', 'ana'));
      final unsent = messages.messagesOf(conv).single;
      expect(unsent.unsent, isTrue);
      expect(unsent.text, isEmpty);
      expect(await fileText('user-1'), isNot(contains('Wrong chat')));
      expect(MessagesController.canUnsend(unsent), isFalse);

      // The friend unsends one of theirs.
      socket.receive(_event(1, 'b1', text: 'Their oops'));
      socket.receive({
        't': 'event',
        'seq': 2,
        'kind': 'unsend',
        'conv': conv,
        'id': 'b1',
        'out': false,
        'at': 9100,
      });
      await settle();
      final theirs = messages.messagesOf(conv).firstWhere((m) => m.id == 'b1');
      expect(theirs.unsent, isTrue);
      expect(messages.conversations.single.unread, 0);

      // Naming one of this account's ids from the friend's side cannot
      // touch it: only their incoming messages match.
      await messages.send(conversation, 'Keep this');
      await eventually(() => socket.of('send').length == 2);
      final keep = socket.of('send').last['id'] as String;
      socket.receive({
        't': 'event',
        'seq': 3,
        'kind': 'unsend',
        'conv': conv,
        'id': keep,
        'out': false,
        'at': 9200,
      });
      await settle();
      final kept = messages.messagesOf(conv).firstWhere((m) => m.id == keep);
      expect(kept.unsent, isFalse);
      expect(kept.text, 'Keep this');

      // From this account's other device (`out`): it applies.
      socket.receive({
        't': 'event',
        'seq': 4,
        'kind': 'unsend',
        'conv': conv,
        'id': keep,
        'out': true,
        'at': 9300,
      });
      await settle();
      expect(
        messages.messagesOf(conv).firstWhere((m) => m.id == keep).unsent,
        isTrue,
      );
    });

    test('deleting a conversation clears it on this device; older copies stay '
        'gone and a newer message starts it again', () async {
      final messages = await controller();
      final socket = await connectedWith(messages, []);
      socket.receive(_event(1, 'a1', text: 'Old news'));
      socket.receive(_event(2, 'a2'));
      await settle();
      expect(messages.conversations, hasLength(1));

      final deleting = messages.deleteConversation(conv);
      await answer(socket, 'pref', prefs: pref(clearedAt: 5002));
      expect(await deleting, isNull);
      expect(socket.of('pref').single, containsPair('clear', true));
      expect(messages.conversations, isEmpty);
      expect(messages.messagesOf(conv), isEmpty);
      expect(messages.unread, 0);
      expect(await fileText('user-1'), isEmpty);

      // A redelivered older message does not come back.
      socket.receive(_event(1, 'a1', text: 'Old news'));
      await settle();
      expect(messages.conversations, isEmpty);

      // A new one starts the conversation again, with only itself.
      socket.receive(_event(3, 'a3', text: 'Still there?'));
      await settle();
      expect(messages.messagesOf(conv).map((m) => m.id), ['a3']);
      expect(messages.conversations.single.unread, 1);

      // Another device of the account, offline meanwhile, catches up.
      final other = MessagesController(
        account: account,
        api: api,
        store: MessageStore(directory: () async => root),
        social: SocialController(account: account, api: api),
        lifecycle: false,
      );
      addTearDown(other.dispose);
      _live.add(other);
      await other.ensureLoaded();
      expect(other.messagesOf(conv), isEmpty);
      expect((await other.load(conv)).map((m) => m.id), ['a3']);
    });

    test('a device that was offline drops what came before a deletion made on '
        'another device', () async {
      final first = await controller();
      final socket = await connectedWith(first, []);
      socket.receive(_event(1, 'a1'));
      socket.receive(_event(2, 'a2'));
      await settle();
      // The conversation list is written just before the acknowledgement,
      // not with each frame: wait for it, or a slow machine reads the list
      // below before it exists.
      await eventually(() => socket.of('ack').lastOrNull?['seq'] == 2);
      first.detach();

      final again = await controller();
      await connectedWith(again, [pref(clearedAt: 5001)]);
      expect((await again.load(conv)).map((m) => m.id), ['a2']);
      expect(again.conversations.single.last?.id, 'a2');
    });
  });
}
