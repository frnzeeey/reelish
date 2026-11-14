// Private messages with friends: the conversation list and a conversation.
// Opened from Friends (and a friend's page) on phone, TV and Windows. The
// composer is a text field with a mouse or touch; on TV, Select opens the
// remote-friendly text dialog. Messages live on this device
// (MessagesController); docs/messaging/README.md.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../messaging/message_models.dart';
import '../../messaging/messages_controller.dart';
import '../../platform/device_capabilities.dart';
import '../../social/friends_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/settings/settings_components.dart';
import '../../widgets/social/social_widgets.dart';
import '../../widgets/tv/tv_focus.dart';

/// "14:05" today, "Mon" this week, "Mar 4" before.
String messageTime(DateTime at, {DateTime? now}) {
  final local = at.toLocal();
  final today = now ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  final day = DateTime(local.year, local.month, local.day);
  final daysAgo = DateTime(
    today.year,
    today.month,
    today.day,
  ).difference(day).inDays;
  if (daysAgo <= 0) return time;
  if (daysAgo < 7) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[local.weekday - 1]} $time';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final date = '${months[local.month - 1]} ${local.day}';
  return local.year == today.year ? date : '$date, ${local.year}';
}

/// What the connection means to the person, or null when all is well.
String? connectionNote(MessagesConnection connection) => switch (connection) {
  MessagesConnection.connecting => 'Connecting…',
  MessagesConnection.offline =>
    'Offline. Messages are saved here and sent when Reelish is reachable.',
  MessagesConnection.unavailable =>
    'Messages are unavailable. Check that Friends is on and you are signed '
        'in.',
  MessagesConnection.idle || MessagesConnection.online => null,
};

/// Keeps the connection open while the widget is on screen.
mixin _Attached<T extends StatefulWidget> on State<T> {
  MessagesController get messages;

  @override
  void initState() {
    super.initState();
    messages.attach();
  }

  @override
  void dispose() {
    messages.detach();
    super.dispose();
  }
}

/// Every conversation on this device, newest first.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({
    super.key,
    this.messages,
    this.onBack,
    required this.openChat,
  });

  /// [MessagesController.instance] when null.
  final MessagesController? messages;
  final VoidCallback? onBack;

  /// Opens a conversation (the caller pushes [ChatScreen]).
  final void Function(Conversation conversation) openChat;

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen>
    with _Attached<MessagesScreen> {
  @override
  late final MessagesController messages =
      widget.messages ?? MessagesController.instance;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: messages,
    builder: (context, _) {
      final conversations = messages.conversations;
      final note = connectionNote(messages.connection);
      return SettingsPage(
        title: 'Messages',
        subtitle: 'Private, between you and each friend',
        icon: ReelishIcons.chat,
        onBack: widget.onBack,
        footer: null,
        children: [
          if (note != null) _Banner(note),
          if (!messages.loaded)
            const Padding(
              padding: EdgeInsets.all(AppSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (conversations.isEmpty)
            const SettingsSection(
              description:
                  'No messages yet. Open a friend from your friends list and '
                  'choose Message.',
              children: [],
            )
          else
            SettingsSection(
              children: [
                for (final conversation in conversations)
                  ConversationTile(
                    conversation: conversation,
                    onTap: () => widget.openChat(conversation),
                  ),
              ],
            ),
          const _PrivacyNote(),
        ],
      );
    },
  );
}

/// A conversation in a list: the friend, the last message and when.
class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  final Conversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final last = conversation.last;
    final preview = last == null
        ? null
        : '${last.outgoing ? 'You: ' : ''}'
              '${last.text.replaceAll(RegExp(r'\s+'), ' ')}';
    final unread = conversation.unread;
    return Semantics(
      label: unread > 0
          ? '${conversation.peer.label}, $unread unread'
          : conversation.peer.label,
      child: PersonTile(
        person: conversation.peer,
        subtitle: [
          ?preview,
          if (last != null) messageTime(last.at),
        ].join(' · '),
        onTap: onTap,
        trailing: unread > 0 ? _UnreadBadge(unread) : null,
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: GlassTheme.primary,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: AppTextSize.caption,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.md),
    child: Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: GlassTheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: GlassTheme.border),
        ),
        child: Row(
          children: [
            Icon(ReelishIcons.offline, color: GlassTheme.muted, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.label,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 0, 6, AppSpace.lg),
    child: Text(
      'Messages are kept on your devices. Reelish holds a message only until '
      'your friend’s devices have it (at most 14 days), and sends it over an '
      'encrypted connection. Messages are not end-to-end encrypted.',
      style: TextStyle(
        color: GlassTheme.muted,
        fontSize: AppTextSize.caption,
        height: 1.4,
      ),
    ),
  );
}

/// One conversation: its messages and the composer.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversation,
    this.messages,
    this.onBack,
    this.onOpenFriend,
  });

  final Conversation conversation;

  /// [MessagesController.instance] when null.
  final MessagesController? messages;
  final VoidCallback? onBack;

  /// Opens the friend's page (block, report, remove).
  final VoidCallback? onOpenFriend;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with _Attached<ChatScreen> {
  @override
  late final MessagesController messages =
      widget.messages ?? MessagesController.instance;

  final _scroll = ScrollController();
  final _draft = TextEditingController();
  final _field = FocusNode(debugLabel: 'Message');
  int _shown = MessagesController.pageSize;
  int _lastCount = 0;
  bool _loading = true;

  String get _id => widget.conversation.id;

  @override
  void initState() {
    super.initState();
    messages.setVisible(_id);
    messages.addListener(_changed);
    unawaited(
      messages.load(_id).then((_) {
        if (!mounted) return;
        setState(() => _loading = false);
        _toBottom(jump: true);
      }),
    );
  }

  @override
  void dispose() {
    messages.removeListener(_changed);
    messages.setVisible(null);
    _scroll.dispose();
    _draft.dispose();
    _field.dispose();
    super.dispose();
  }

  /// New messages: follow them when already at the bottom.
  void _changed() {
    final count = messages.messagesOf(_id).length;
    if (count == _lastCount) return;
    final atBottom =
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 120;
    _lastCount = count;
    unawaited(messages.markRead(_id));
    if (atBottom) _toBottom();
  }

  void _toBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump || MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(end);
      } else {
        unawaited(
          _scroll.animateTo(
            end,
            duration: AppMotion.resolve(context, AppMotion.standard),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  Future<void> _send(String text) async {
    final conversation = messages.conversation(_id) ?? widget.conversation;
    final error = await messages.send(conversation, text);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    _draft.clear();
    _toBottom();
  }

  Future<void> _sendDraft() => _send(_draft.text);

  Future<void> _writeOnTv() async {
    final text = await TvTextEntryDialog.show(
      context,
      title: 'Message ${widget.conversation.peer.label}',
      hint: 'Write a message',
      textInputAction: TextInputAction.send,
    );
    if (text != null && text.trim().isNotEmpty) await _send(text);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: messages,
    builder: (context, _) {
      final peer = messages.conversation(_id)?.peer ?? widget.conversation.peer;
      final all = messages.messagesOf(_id);
      final shown = all.length > _shown
          ? all.sublist(all.length - _shown)
          : all;
      final note = connectionNote(messages.connection);
      return TvReadableWidth(
        child: Column(
          children: [
            _ChatHeader(
              peer: peer,
              status: note,
              onBack: widget.onBack,
              onOpenFriend: widget.onOpenFriend,
            ),
            Expanded(
              child: TvKeyScroll(
                controller: _scroll,
                builder: (context, controller) => _loading
                    ? const Center(child: CircularProgressIndicator())
                    : all.isEmpty
                    ? _EmptyChat(peer: peer)
                    : ListView.builder(
                        controller: controller,
                        padding: const EdgeInsets.fromLTRB(
                          AppSpace.md,
                          AppSpace.sm,
                          AppSpace.md,
                          AppSpace.md,
                        ),
                        itemCount: shown.length + (all.length > _shown ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (all.length > _shown) {
                            if (index == 0) {
                              return Center(
                                child: TextButton(
                                  onPressed: () => setState(
                                    () => _shown += MessagesController.pageSize,
                                  ),
                                  child: const Text('Earlier messages'),
                                ),
                              );
                            }
                            index -= 1;
                          }
                          final message = shown[index];
                          final previous = index > 0 ? shown[index - 1] : null;
                          return _Bubble(
                            message: message,
                            grouped:
                                previous != null &&
                                previous.outgoing == message.outgoing &&
                                message.at.difference(previous.at).inMinutes <
                                    5,
                            onRetry: () => unawaited(messages.retry(message)),
                          );
                        },
                      ),
              ),
            ),
            _Composer(
              controller: _draft,
              focusNode: _field,
              maxChars: messages.maxChars,
              onSend: () => unawaited(_sendDraft()),
              onTvWrite: () => unawaited(_writeOnTv()),
            ),
          ],
        ),
      );
    },
  );
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.peer,
    required this.status,
    this.onBack,
    this.onOpenFriend,
  });

  final SocialPerson peer;
  final String? status;
  final VoidCallback? onBack;
  final VoidCallback? onOpenFriend;

  @override
  Widget build(BuildContext context) {
    final details = Row(
      children: [
        PersonAvatar(person: peer, size: 36),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  peer.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: AppTextSize.titleSmall,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                status ?? '@${peer.handle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.label,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 16, 8),
        child: Row(
          children: [
            if (onBack != null) ...[
              IconButton(
                tooltip: 'Back',
                onPressed: onBack,
                icon: const Icon(ReelishIcons.back),
              ),
              const SizedBox(width: 4),
            ],
            Expanded(child: details),
            if (onOpenFriend != null)
              IconButton(
                tooltip: 'About ${peer.label}',
                onPressed: onOpenFriend,
                icon: Icon(ReelishIcons.info, color: GlassTheme.muted),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.peer});

  final SocialPerson peer;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PersonAvatar(person: peer, size: 72),
          const SizedBox(height: AppSpace.md),
          Text(
            'Say hello to ${peer.label}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: AppTextSize.title,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Only the two of you can read this conversation.',
            textAlign: TextAlign.center,
            style: TextStyle(color: GlassTheme.muted),
          ),
        ],
      ),
    ),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.grouped,
    required this.onRetry,
  });

  final ChatMessage message;

  /// Close to the one before, from the same side: less space between.
  final bool grouped;
  final VoidCallback onRetry;

  String get _statusLabel => switch (message.status) {
    MessageStatus.sending => 'Sending',
    MessageStatus.sent => 'Sent',
    MessageStatus.delivered => message.outgoing ? 'Delivered' : '',
    MessageStatus.failed => messageErrorText(message.error),
  };

  @override
  Widget build(BuildContext context) {
    final mine = message.outgoing;
    final failed = message.status == MessageStatus.failed;
    final maxWidth = MediaQuery.sizeOf(context).width * .78;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(200, 560)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? GlassTheme.primary : GlassTheme.elevatedSurface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 6),
          bottomRight: Radius.circular(mine ? 6 : 18),
        ),
        border: mine ? null : Border.all(color: GlassTheme.border),
      ),
      child: SelectableText(
        message.text,
        style: TextStyle(
          // White on the accent fill; theme text on a surface.
          color: mine ? Colors.white : GlassTheme.textPrimary,
          fontSize: AppTextSize.body,
          height: 1.35,
        ),
      ),
    );
    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          messageTime(message.at),
          style: TextStyle(
            color: failed ? GlassTheme.primary : GlassTheme.muted,
            fontSize: AppTextSize.caption,
          ),
        ),
        if (mine) ...[
          const SizedBox(width: 4),
          Icon(
            switch (message.status) {
              MessageStatus.sending => ReelishIcons.clock,
              MessageStatus.sent => ReelishIcons.check,
              MessageStatus.delivered => ReelishIcons.checkCircleFilled,
              MessageStatus.failed => ReelishIcons.error,
            },
            size: 14,
            color: failed ? GlassTheme.primary : GlassTheme.muted,
          ),
        ],
        if (failed) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${messageErrorText(message.error)} Tap to retry.',
              style: TextStyle(
                color: GlassTheme.primary,
                fontSize: AppTextSize.caption,
              ),
            ),
          ),
        ],
      ],
    );
    Widget body = Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [bubble, const SizedBox(height: 3), meta],
    );
    if (failed && message.error != 'not_friends') {
      body = DeviceCapabilities.usesTvLayout
          ? TvFocusable(
              onSelect: onRetry,
              focusScale: 1.02,
              semanticLabel: 'Retry sending',
              child: body,
            )
          : InkWell(
              onTap: onRetry,
              borderRadius: BorderRadius.circular(18),
              child: body,
            );
    }
    return Semantics(
      label: [
        mine ? 'You' : 'Them',
        messageTime(message.at),
        if (mine) _statusLabel,
      ].where((part) => part.isNotEmpty).join(', '),
      child: Padding(
        padding: EdgeInsets.only(top: grouped ? 2 : AppSpace.sm),
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: body,
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.maxChars,
    required this.onSend,
    required this.onTvWrite,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int maxChars;
  final VoidCallback onSend;
  final VoidCallback onTvWrite;

  @override
  Widget build(BuildContext context) {
    final padding = EdgeInsets.fromLTRB(
      AppSpace.md,
      AppSpace.sm,
      AppSpace.md,
      AppSpace.sm + MediaQuery.paddingOf(context).bottom,
    );
    if (DeviceCapabilities.isTv) {
      return Padding(
        padding: padding,
        child: TvFocusable(
          autofocus: true,
          focusScale: 1.02,
          borderRadius: 16,
          semanticLabel: 'Write a message',
          onSelect: onTvWrite,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            color: GlassTheme.surface,
            child: Row(
              children: [
                Icon(ReelishIcons.keyboard, color: GlassTheme.muted),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Write a message',
                    style: TextStyle(
                      color: GlassTheme.muted,
                      fontSize: AppTextSize.body,
                    ),
                  ),
                ),
                Icon(ReelishIcons.send, color: GlassTheme.primary),
              ],
            ),
          ),
        ),
      );
    }
    // Enter sends with a keyboard; Shift+Enter adds a line.
    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): onSend,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onSend,
      },
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        minLines: 1,
        maxLines: 5,
        maxLength: maxChars,
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        textCapitalization: TextCapitalization.sentences,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration(
          hintText: 'Message',
          counterText: '',
          filled: true,
          fillColor: GlassTheme.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            borderSide: BorderSide(color: GlassTheme.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            borderSide: BorderSide(color: GlassTheme.border),
          ),
        ),
      ),
    );
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: field),
          const SizedBox(width: AppSpace.sm),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => IconButton.filled(
              tooltip: 'Send',
              onPressed: value.text.trim().isEmpty ? null : onSend,
              icon: const Icon(ReelishIcons.send),
            ),
          ),
        ],
      ),
    );
  }
}
