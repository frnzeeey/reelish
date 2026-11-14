// This device's copy of an account's private messages: the only lasting copy,
// since Reelish deletes a message once every device of the recipient has it.
// Kept in the app's support folder, per account:
//
//   messages/<account>/index.json        conversations and the outbox
//   messages/<account>/<conversation>.jsonl  one message per line
//
// A conversation file is only appended to (a status change is a new line for
// the same message; the last line wins), so a crash can at most cut its
// last line, which is skipped on reading. It is rewritten, through a
// temporary file and a rename, when it has grown well past its messages.
// The index is always written that way. docs/messaging/README.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../social/friends_controller.dart' show conversationIdPattern;
import 'message_models.dart';

/// What [MessageStore.open] reads back.
typedef MessageIndex = ({
  List<Conversation> conversations,
  List<PendingSend> outbox,
});

class MessageStore {
  MessageStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  static const _version = 1;

  /// Lines a conversation file may have per message before it is rewritten.
  static const _compactRatio = 2;

  Directory? _folder;
  String? _userId;

  /// Writes run one at a time, in order, so lines never interleave.
  Future<void> _writes = Future<void>.value();

  /// Line counts per conversation file, to know when to rewrite it.
  final Map<String, int> _lines = {};

  /// Account ids become folder names: anything else in them is replaced.
  static String _folderName(String userId) =>
      userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<Directory> _accountFolder(String userId) async {
    final base = await _directory();
    return Directory(
      '${base.path}${Platform.pathSeparator}messages'
      '${Platform.pathSeparator}${_folderName(userId)}',
    );
  }

  /// Reads [userId]'s conversations and outbox; empty when there are none.
  Future<MessageIndex> open(String userId) async {
    await _writes;
    _userId = userId;
    _lines.clear();
    _folder = null;
    try {
      final folder = _folder = await _accountFolder(userId);
      final file = File('${folder.path}${Platform.pathSeparator}index.json');
      if (!await file.exists()) {
        return (conversations: <Conversation>[], outbox: <PendingSend>[]);
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) throw const FormatException('index');
      final conversations = decoded['conversations'];
      final outbox = decoded['outbox'];
      return (
        conversations: [
          if (conversations is List)
            for (final entry in conversations)
              if (Conversation.fromJson(entry) case final conversation?
                  when conversationIdPattern.hasMatch(conversation.id))
                conversation,
        ],
        outbox: [
          if (outbox is List)
            for (final entry in outbox) ?PendingSend.fromJson(entry),
        ],
      );
    } catch (_) {
      // An unreadable index: start the list again. The conversation files
      // stay, and a conversation opened from Friends reads its history.
      return (conversations: <Conversation>[], outbox: <PendingSend>[]);
    }
  }

  File? _conversationFile(String conversation) {
    final folder = _folder;
    if (folder == null || !conversationIdPattern.hasMatch(conversation)) {
      return null;
    }
    return File('${folder.path}${Platform.pathSeparator}$conversation.jsonl');
  }

  /// Every message in [conversation], oldest first.
  Future<List<ChatMessage>> messages(String conversation) async {
    await _writes;
    final file = _conversationFile(conversation);
    if (file == null || !await file.exists()) return [];
    final byKey = <String, ChatMessage>{};
    var lines = 0;
    try {
      final stream = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        if (line.isEmpty) continue;
        lines += 1;
        try {
          final message = ChatMessage.fromJson(jsonDecode(line));
          if (message != null && message.conversation == conversation) {
            byKey[message.key] = message;
          }
        } catch (_) {
          // A line cut short by a crash: skipped.
        }
      }
    } catch (_) {
      // Unreadable: what was read so far.
    }
    _lines[conversation] = lines;
    return byKey.values.toList()..sort(_byTime);
  }

  static int _byTime(ChatMessage a, ChatMessage b) {
    final order = a.at.compareTo(b.at);
    return order != 0 ? order : a.key.compareTo(b.key);
  }

  /// Adds or updates [messages] in [conversation], on disk before this
  /// returns. [all] is the conversation afterwards, used to rewrite the file
  /// when it has grown too long.
  Future<void> write(
    String conversation,
    List<ChatMessage> messages, {
    required List<ChatMessage> all,
  }) => _queue(() async {
    final file = _conversationFile(conversation);
    if (file == null || messages.isEmpty) return;
    await file.parent.create(recursive: true);
    final lines = (_lines[conversation] ?? 0) + messages.length;
    if (lines > all.length * _compactRatio + 50) {
      await _replace(
        file,
        [for (final m in all) jsonEncode(m.toJson())].join('\n'),
      );
      _lines[conversation] = all.length;
      return;
    }
    final text = StringBuffer();
    for (final message in messages) {
      text.writeln(jsonEncode(message.toJson()));
    }
    await file.writeAsString(
      text.toString(),
      mode: FileMode.append,
      flush: true,
    );
    _lines[conversation] = lines;
  });

  /// Saves the conversation list and the outbox.
  Future<void> saveIndex(
    List<Conversation> conversations,
    List<PendingSend> outbox,
  ) => _queue(() async {
    final folder = _folder;
    if (folder == null) return;
    await folder.create(recursive: true);
    await _replace(
      File('${folder.path}${Platform.pathSeparator}index.json'),
      jsonEncode({
        'v': _version,
        'conversations': [for (final c in conversations) c.toJson()],
        'outbox': [for (final p in outbox) p.toJson()],
      }),
    );
  });

  /// Deletes every message of the open account from this device.
  Future<void> wipe() => _queue(() async {
    final userId = _userId;
    if (userId == null) return;
    _lines.clear();
    final folder = await _accountFolder(userId);
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  /// Writes through a temporary file, so a crash leaves the old or the new.
  static Future<void> _replace(File file, String contents) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _queue(Future<void> Function() write) {
    final next = _writes.then((_) => write());
    // A failed write does not stop the ones after it.
    _writes = next.catchError((Object _) {});
    return next;
  }
}
