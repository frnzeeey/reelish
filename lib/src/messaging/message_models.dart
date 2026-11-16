// Private messages as the app keeps them: one message, one conversation and
// the delivery states. The shapes here are what the local store writes, so
// they stay readable across versions (docs/messaging/README.md).
import 'package:flutter/foundation.dart';

import '../social/friends_controller.dart';

/// Where a message is on its way.
enum MessageStatus {
  /// Saved here, not yet accepted by Reelish (offline, or on its way).
  sending,

  /// Accepted by Reelish and waiting in the friend's mailbox.
  sent,

  /// Saved on one of the friend's devices.
  delivered,

  /// Refused (not friends any more, too long, daily limit); not retried.
  failed;

  static MessageStatus parse(Object? value) => switch (value) {
    'sent' => sent,
    'delivered' => delivered,
    'failed' => failed,
    _ => sending,
  };
}

/// A message taken away: its text is gone from this device either way.
enum MessageRemoval {
  none,

  /// Its sender unsent it: shown as unsent, on both sides.
  unsent,

  /// Deleted by this account for itself: not shown. Kept as a marker so a
  /// redelivered copy does not bring it back.
  deleted;

  static MessageRemoval parse(Object? value) => switch (value) {
    'u' => unsent,
    'd' => deleted,
    _ => none,
  };
}

/// One message in a conversation.
@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversation,
    required this.outgoing,
    required this.text,
    required this.at,
    required this.status,
    this.error,
    this.removal = MessageRemoval.none,
  });

  /// The sender's id for it; unique per sender, so a retry is one message.
  final String id;
  final String conversation;

  /// Sent by this account (from this or another of its devices).
  final bool outgoing;
  final String text;

  /// Reelish's time once accepted; this device's time while sending.
  final DateTime at;
  final MessageStatus status;

  /// Why it failed: the server's code.
  final String? error;

  /// Unsent by its sender, or deleted here; [MessageRemoval.none] otherwise.
  final MessageRemoval removal;

  /// Its key in a conversation: a friend cannot reuse one of your ids.
  String get key => '${outgoing ? 'o' : 'i'}:$id';

  /// Shown in the chat: everything but what this account deleted.
  bool get visible => removal != MessageRemoval.deleted;

  bool get unsent => removal == MessageRemoval.unsent;

  ChatMessage copyWith({
    DateTime? at,
    MessageStatus? status,
    String? error,
    bool clearError = false,
  }) => ChatMessage(
    id: id,
    conversation: conversation,
    outgoing: outgoing,
    text: text,
    at: at ?? this.at,
    status: status ?? this.status,
    error: clearError ? null : error ?? this.error,
    removal: removal,
  );

  /// The same message unsent or deleted: its text is dropped.
  ChatMessage removed(MessageRemoval removal) => ChatMessage(
    id: id,
    conversation: conversation,
    outgoing: outgoing,
    text: '',
    at: at,
    status: status,
    error: error,
    removal: removal,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'c': conversation,
    'o': outgoing,
    't': text,
    'at': at.millisecondsSinceEpoch,
    's': status.name,
    if (error != null) 'e': error,
    if (removal != MessageRemoval.none)
      'x': removal == MessageRemoval.unsent ? 'u' : 'd',
  };

  static ChatMessage? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final conversation = value['c'];
    final text = value['t'];
    final at = value['at'];
    if (id is! String ||
        conversation is! String ||
        text is! String ||
        at is! int) {
      return null;
    }
    final error = value['e'];
    return ChatMessage(
      id: id,
      conversation: conversation,
      outgoing: value['o'] == true,
      text: text,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      status: MessageStatus.parse(value['s']),
      error: error is String ? error : null,
      removal: MessageRemoval.parse(value['x']),
    );
  }
}

/// A conversation as the list shows it.
@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.peer,
    this.last,
    this.unread = 0,
  });

  final String id;

  /// The friend, as last seen in a message or the friends list.
  final SocialPerson peer;
  final ChatMessage? last;

  /// Messages from the friend not yet seen here.
  final int unread;

  DateTime? get lastAt => last?.at;

  Conversation copyWith({
    SocialPerson? peer,
    ChatMessage? last,
    bool clearLast = false,
    int? unread,
  }) => Conversation(
    id: id,
    peer: peer ?? this.peer,
    last: clearLast ? null : last ?? this.last,
    unread: unread ?? this.unread,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'peer': peer.toJson(),
    if (last != null) 'last': last!.toJson(),
    'unread': unread,
  };

  static Conversation? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final peer = SocialPerson.fromJson(value['peer']);
    if (id is! String || peer == null) return null;
    final unread = value['unread'];
    return Conversation(
      id: id,
      peer: peer,
      last: ChatMessage.fromJson(value['last']),
      unread: unread is int && unread > 0 ? unread : 0,
    );
  }
}

/// A message waiting to be accepted by Reelish, in sending order.
@immutable
class PendingSend {
  const PendingSend({
    required this.id,
    required this.conversation,
    required this.to,
  });

  final String id;
  final String conversation;

  /// The friend's handle, as the server takes it.
  final String to;

  Map<String, Object?> toJson() => {'id': id, 'c': conversation, 'to': to};

  static PendingSend? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final conversation = value['c'];
    final to = value['to'];
    if (id is! String || conversation is! String || to is! String) return null;
    return PendingSend(id: id, conversation: conversation, to: to);
  }
}

/// This account's own settings for one conversation, kept by Reelish in the
/// account's mailbox and given to each of its devices (never to the friend).
@immutable
class ConversationPrefs {
  const ConversationPrefs({this.muted = false, this.nickname, this.clearedAt});

  static const none = ConversationPrefs();

  /// No alerts for it; its messages still arrive.
  final bool muted;

  /// What this account calls the friend here; their own name when null.
  final String? nickname;

  /// Deleted for this account at this Reelish time: earlier messages are
  /// gone from its devices, newer ones bring the conversation back.
  final DateTime? clearedAt;

  bool get isEmpty => !muted && nickname == null && clearedAt == null;

  Map<String, Object?> toJson(String conversation) => {
    'c': conversation,
    if (muted) 'm': true,
    if (nickname != null) 'n': nickname,
    if (clearedAt != null) 'cl': clearedAt!.millisecondsSinceEpoch,
  };

  /// Stored here (`toJson`): its conversation and the settings.
  static (String, ConversationPrefs)? fromJson(Object? value) {
    if (value is! Map) return null;
    final conversation = value['c'];
    if (conversation is! String) return null;
    final nickname = value['n'];
    final cleared = value['cl'];
    return (
      conversation,
      ConversationPrefs(
        muted: value['m'] == true,
        nickname: nickname is String ? nickname : null,
        clearedAt: cleared is int
            ? DateTime.fromMillisecondsSinceEpoch(cleared)
            : null,
      ),
    );
  }

  /// As the mailbox sends them: `{conv, muted, nickname, clearedAt}`.
  static (String, ConversationPrefs)? fromServer(Object? value) {
    if (value is! Map) return null;
    final conversation = value['conv'];
    if (conversation is! String) return null;
    final nickname = value['nickname'];
    final cleared = value['clearedAt'];
    return (
      conversation,
      ConversationPrefs(
        muted: value['muted'] == true,
        nickname: nickname is String ? cleanNickname(nickname) : null,
        clearedAt: cleared is int
            ? DateTime.fromMillisecondsSinceEpoch(cleared)
            : null,
      ),
    );
  }
}

/// Longest nickname; the server enforces the same.
const maxNicknameChars = 32;

final _unsafeNickname = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff]',
);

/// A nickname as Reelish stores it: one line, no control, bidirectional or
/// zero-width characters, spaces collapsed; null when empty or too long.
String? cleanNickname(String value) {
  final text = value
      .replaceAll(_unsafeNickname, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.isEmpty || text.length > maxNicknameChars ? null : text;
}

/// Why a delete, unsend or setting change did not happen, for people.
String messageActionErrorText(String code) => switch (code) {
  'offline' => 'You are offline. Try again when Reelish is reachable.',
  'invalid_nickname' => 'A nickname can be 1 to $maxNicknameChars characters.',
  'not_friends' => 'This message can no longer be unsent.',
  'too_many' => 'You have settings for too many conversations.',
  _ => 'That did not work. Try again.',
};

/// What Reelish answered when a message could not be sent, for people.
String messageErrorText(String? code) => switch (code) {
  'not_friends' => 'Not sent: you are no longer friends.',
  'too_long' => 'Not sent: the message is too long.',
  'empty' => 'Not sent: the message is empty.',
  'daily_limit' => 'Not sent: you have sent many messages today.',
  _ => 'Not sent.',
};
