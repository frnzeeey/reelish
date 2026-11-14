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

  /// Its key in a conversation: a friend cannot reuse one of your ids.
  String get key => '${outgoing ? 'o' : 'i'}:$id';

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
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'c': conversation,
    'o': outgoing,
    't': text,
    'at': at.millisecondsSinceEpoch,
    's': status.name,
    if (error != null) 'e': error,
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

  Conversation copyWith({SocialPerson? peer, ChatMessage? last, int? unread}) =>
      Conversation(
        id: id,
        peer: peer ?? this.peer,
        last: last ?? this.last,
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

/// What Reelish answered when a message could not be sent, for people.
String messageErrorText(String? code) => switch (code) {
  'not_friends' => 'Not sent: you are no longer friends.',
  'too_long' => 'Not sent: the message is too long.',
  'empty' => 'Not sent: the message is empty.',
  'daily_limit' => 'Not sent: you have sent many messages today.',
  _ => 'Not sent.',
};
