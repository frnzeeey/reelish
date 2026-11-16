// Private messages with friends: the conversation list and a conversation.
// Opened from Friends (and a friend's page) on phone, TV and Windows. The
// composer is a text field with a mouse or touch; on TV, Select opens the
// remote-friendly text dialog. Messages live on this device
// (MessagesController); docs/messaging/README.md. A message's actions (Copy,
// Unsend, Delete for you): long press on a phone opens a sheet, right click
// on Windows adds them to the text's menu, Select on TV opens a dialog (a
// failed message retries, as before). Nickname, mute and deleting a
// conversation are in ConversationOptionsScreen.
import 'dart:async';
import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
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
    this.openOptions,
  });

  /// [MessagesController.instance] when null.
  final MessagesController? messages;
  final VoidCallback? onBack;

  /// Opens a conversation (the caller pushes [ChatScreen]).
  final void Function(Conversation conversation) openChat;

  /// Opens a conversation's options (long press or right click on it).
  final void Function(Conversation conversation)? openOptions;

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
                    messages: messages,
                    onTap: () => widget.openChat(conversation),
                    onOptions: widget.openOptions == null
                        ? null
                        : () => widget.openOptions!(conversation),
                  ),
              ],
            ),
          const _PrivacyNote(),
        ],
      );
    },
  );
}

/// What a conversation list shows of [last].
String messagePreview(ChatMessage last) {
  if (last.unsent) {
    return last.outgoing ? 'You unsent a message' : 'Message unsent';
  }
  return '${last.outgoing ? 'You: ' : ''}'
      '${last.text.replaceAll(RegExp(r'\s+'), ' ')}';
}

/// A conversation in a list: the friend (by the nickname this account gave
/// them, if any), the last message and when, and whether it is muted.
class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
    this.messages,
    this.onOptions,
  });

  final Conversation conversation;
  final VoidCallback onTap;

  /// [MessagesController.instance] when null.
  final MessagesController? messages;

  /// Long press or right click: the conversation's options.
  final VoidCallback? onOptions;

  @override
  Widget build(BuildContext context) {
    final controller = messages ?? MessagesController.instance;
    final person = controller.displayPeer(conversation);
    final muted = controller.isMuted(conversation.id);
    final last = conversation.last;
    final preview = last == null ? null : messagePreview(last);
    final unread = conversation.unread;
    Widget tile = PersonTile(
      person: person,
      subtitle: [?preview, if (last != null) messageTime(last.at)].join(' · '),
      onTap: onTap,
      trailing: muted || unread > 0
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (muted)
                  ExcludeSemantics(
                    child: Icon(
                      ReelishIcons.volumeOff,
                      size: 18,
                      color: GlassTheme.muted,
                    ),
                  ),
                if (muted && unread > 0) const SizedBox(width: 6),
                if (unread > 0) _UnreadBadge(unread, muted: muted),
              ],
            )
          : null,
    );
    if (onOptions != null && !DeviceCapabilities.isTv) {
      tile = GestureDetector(
        onLongPress: onOptions,
        onSecondaryTap: onOptions,
        child: tile,
      );
    }
    return Semantics(
      label: [
        person.label,
        if (unread > 0) '$unread unread',
        if (muted) 'muted',
      ].join(', '),
      onLongPressHint: onOptions == null ? null : 'Conversation options',
      child: tile,
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge(this.count, {this.muted = false});

  final int count;

  /// Quieter in a muted conversation.
  final bool muted;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: muted ? GlassTheme.muted : GlassTheme.primary,
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
    this.onOpenOptions,
  });

  final Conversation conversation;

  /// [MessagesController.instance] when null.
  final MessagesController? messages;
  final VoidCallback? onBack;

  /// Opens the friend's page (block, report, remove).
  final VoidCallback? onOpenFriend;

  /// Opens this conversation's options (nickname, mute, delete).
  final VoidCallback? onOpenOptions;

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

  /// Messages being deleted or unsent: dimmed until Reelish answers.
  final Set<String> _working = {};

  void _show(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  String get _peerLabel {
    final conversation = messages.conversation(_id) ?? widget.conversation;
    return messages.displayPeer(conversation).label;
  }

  Future<void> _act(
    ChatMessage message,
    Future<String?> Function() action,
    String done,
  ) async {
    if (!_working.add(message.key)) return;
    setState(() {});
    final error = await action();
    if (!mounted) return;
    setState(() => _working.remove(message.key));
    _show(error ?? done);
  }

  /// Deletes [message] from this account's devices; the friend keeps it.
  Future<void> _deleteForMe(ChatMessage message) async {
    final peer = _peerLabel;
    final confirmed = await confirmSocial(
      context,
      title: 'Delete for you?',
      message: MessagesController.canUnsend(message)
          ? 'It is deleted from all your devices. $peer still has it. To '
                'remove it for both of you, choose Unsend instead.'
          : 'It is deleted from all your devices. $peer still has their '
                'copy.',
      action: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _act(message, () => messages.deleteForMe(message), 'Deleted for you');
  }

  /// Unsends [message] for both people.
  Future<void> _unsend(ChatMessage message) async {
    final peer = _peerLabel;
    final confirmed = await confirmSocial(
      context,
      title: 'Unsend for everyone?',
      message:
          'It is removed for you and $peer, on all devices, and shows as '
          'unsent. $peer may have read it already.',
      action: 'Unsend',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _act(message, () => messages.unsend(message), 'Message unsent');
  }

  /// What can be done with [message]: a sheet on a phone (long press), a
  /// dialog on TV (Select). Windows uses the text's right-click menu.
  Future<void> _showActions(ChatMessage message) async {
    final actions = <(String, String, IconData)>[
      if (!message.unsent) ('copy', 'Copy text', ReelishIcons.copy),
      if (MessagesController.canUnsend(message))
        ('unsend', 'Unsend for everyone', ReelishIcons.restore),
      if (message.status != MessageStatus.sending)
        ('delete', 'Delete for you', ReelishIcons.trash),
    ];
    if (actions.isEmpty) return;
    final String? choice;
    if (DeviceCapabilities.isTv) {
      choice = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(message.outgoing ? 'Your message' : 'Message'),
          children: [
            for (final (id, label, _) in actions)
              if (id != 'copy')
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, id),
                  child: Text(label),
                ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    } else {
      choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        backgroundColor: GlassTheme.elevatedSurface,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (id, label, icon) in actions)
                ListTile(
                  leading: Icon(
                    icon,
                    color: id == 'copy'
                        ? GlassTheme.primary
                        : GlassTheme.danger,
                  ),
                  title: Text(label),
                  onTap: () => Navigator.pop(context, id),
                ),
            ],
          ),
        ),
      );
    }
    if (!mounted) return;
    switch (choice) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text));
        if (mounted) _show('Copied');
      case 'unsend':
        await _unsend(message);
      case 'delete':
        await _deleteForMe(message);
    }
  }

  /// On TV, Up and Down read every line of a message taller than the screen:
  /// while part of the focused message lies beyond the screen's edge in the
  /// direction pressed, the list scrolls through it (at most 70% of a screen
  /// a press); and focus moving onto such a message lines up the edge it
  /// came from, not the far one, so its middle is not jumped over. Only keys
  /// pressed on something in the list reach this: the composer is outside.
  KeyEventResult _tvReadKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!down && event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus;
    final item = focused?.context?.findRenderObject();
    if (focused == null || item is! RenderBox || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final position = _scroll.position;
    final extent = position.viewportDimension;
    final viewport = RenderAbstractViewport.maybeOf(item);
    if (viewport == null) return KeyEventResult.ignored;
    // Scroll offsets with the item's top at the top of the screen, and its
    // bottom at the bottom.
    final atTop = viewport.getOffsetToReveal(item, 0).offset;
    final atBottom = viewport.getOffsetToReveal(item, 1).offset;
    if (down ? position.pixels < atBottom - 1 : position.pixels > atTop + 1) {
      _scrollTo(
        down
            ? min(atBottom, position.pixels + extent * .7)
            : max(atTop, position.pixels - extent * .7),
      );
      return KeyEventResult.handled;
    }
    if (!focused.focusInDirection(
      down ? TraversalDirection.down : TraversalDirection.up,
    )) {
      // Nothing further this way: TvKeyScroll scrolls the list.
      return KeyEventResult.ignored;
    }
    // The focus manager applies the move in a microtask: look after it.
    scheduleMicrotask(() {
      final now = FocusManager.instance.primaryFocus;
      final next = now?.context?.findRenderObject();
      if (!mounted ||
          identical(now, focused) ||
          next is! RenderBox ||
          !next.attached ||
          next.size.height <= extent ||
          RenderAbstractViewport.maybeOf(next) != viewport) {
        return;
      }
      // Coming up, its end is next to what was just read; coming down, its
      // start.
      _scrollTo(viewport.getOffsetToReveal(next, down ? 0 : 1).offset);
    });
    return KeyEventResult.handled;
  }

  void _scrollTo(double offset) {
    final position = _scroll.position;
    final target = offset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
    } else {
      unawaited(
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  Future<void> _writeOnTv() async {
    final text = await TvTextEntryDialog.show(
      context,
      title: 'Message $_peerLabel',
      hint: 'Write a message',
      textInputAction: TextInputAction.send,
    );
    if (text != null && text.trim().isNotEmpty) await _send(text);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: messages,
    builder: (context, _) {
      final peer = messages.displayPeer(
        messages.conversation(_id) ?? widget.conversation,
      );
      final muted = messages.isMuted(_id);
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
              muted: muted,
              onBack: widget.onBack,
              onOpenFriend: widget.onOpenFriend,
              onOpenOptions: widget.onOpenOptions,
            ),
            Expanded(
              child: TvKeyScroll(
                controller: _scroll,
                builder: (context, controller) => _loading
                    ? const Center(child: CircularProgressIndicator())
                    : all.isEmpty
                    ? _EmptyChat(peer: peer)
                    : Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onKeyEvent: DeviceCapabilities.isTv ? _tvReadKey : null,
                        child: ListView.builder(
                          controller: controller,
                          padding: const EdgeInsets.fromLTRB(
                            AppSpace.md,
                            AppSpace.sm,
                            AppSpace.md,
                            AppSpace.md,
                          ),
                          itemCount:
                              shown.length + (all.length > _shown ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (all.length > _shown) {
                              if (index == 0) {
                                return Center(
                                  child: TextButton(
                                    onPressed: () => setState(
                                      () =>
                                          _shown += MessagesController.pageSize,
                                    ),
                                    child: const Text('Earlier messages'),
                                  ),
                                );
                              }
                              index -= 1;
                            }
                            final message = shown[index];
                            final previous = index > 0
                                ? shown[index - 1]
                                : null;
                            return _Bubble(
                              message: message,
                              grouped:
                                  previous != null &&
                                  previous.outgoing == message.outgoing &&
                                  message.at.difference(previous.at).inMinutes <
                                      5,
                              working: _working.contains(message.key),
                              onRetry: () => unawaited(messages.retry(message)),
                              onDelete: message.status == MessageStatus.sending
                                  ? null
                                  : () => unawaited(_deleteForMe(message)),
                              onUnsend: MessagesController.canUnsend(message)
                                  ? () => unawaited(_unsend(message))
                                  : null,
                              onActions: () => unawaited(_showActions(message)),
                            );
                          },
                        ),
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
    this.muted = false,
    this.onBack,
    this.onOpenFriend,
    this.onOpenOptions,
  });

  /// As this account sees them: a nickname replaces their name, never their
  /// handle, which shows below it.
  final SocialPerson peer;
  final String? status;
  final bool muted;
  final VoidCallback? onBack;
  final VoidCallback? onOpenFriend;
  final VoidCallback? onOpenOptions;

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
                status ?? ['@${peer.handle}', if (muted) 'Muted'].join(' · '),
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
            if (onOpenOptions != null)
              IconButton(
                tooltip: 'Conversation options',
                onPressed: onOpenOptions,
                icon: Icon(ReelishIcons.moreVertical, color: GlassTheme.muted),
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
    this.working = false,
    this.onDelete,
    this.onUnsend,
    this.onActions,
  });

  final ChatMessage message;

  /// Close to the one before, from the same side: less space between.
  final bool grouped;
  final VoidCallback onRetry;

  /// Being deleted or unsent: dimmed until Reelish answers.
  final bool working;

  /// Delete for this account; null while it is still sending.
  final VoidCallback? onDelete;

  /// Unsend for both people; null when it cannot be unsent.
  final VoidCallback? onUnsend;

  /// The message's actions: long press on a phone, Select on TV.
  final VoidCallback? onActions;

  /// Windows: the text stays selectable, and its right-click menu has the
  /// usual Copy and Select all, then Unsend and Delete.
  Widget _menu(BuildContext context, EditableTextState state) {
    void run(VoidCallback action) {
      ContextMenuController.removeAny();
      state.hideToolbar();
      action();
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ...state.contextMenuButtonItems,
        if (onUnsend case final unsend?)
          ContextMenuButtonItem(label: 'Unsend', onPressed: () => run(unsend)),
        if (onDelete case final delete?)
          ContextMenuButtonItem(
            label: 'Delete for you',
            onPressed: () => run(delete),
          ),
      ],
    );
  }

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
    final unsent = message.unsent;
    final retryable = failed && message.error != 'not_friends';
    final phone = !DeviceCapabilities.usesTvLayout;
    final textStyle = TextStyle(
      // White on the accent fill; theme text on a surface.
      color: mine ? Colors.white : GlassTheme.textPrimary,
      fontSize: AppTextSize.body,
      height: 1.35,
    );
    final maxWidth = MediaQuery.sizeOf(context).width * .78;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(200, 560)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        // An unsent message keeps its place, as a quiet outline.
        color: unsent
            ? Colors.transparent
            : mine
            ? GlassTheme.primary
            : GlassTheme.elevatedSurface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 6),
          bottomRight: Radius.circular(mine ? 6 : 18),
        ),
        border: mine && !unsent ? null : Border.all(color: GlassTheme.border),
      ),
      child: unsent
          ? Text(
              mine ? 'You unsent a message' : 'Message unsent',
              style: TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.body,
                fontStyle: FontStyle.italic,
                height: 1.35,
              ),
            )
          : phone
          // A phone's long press opens the message's actions (Copy among
          // them) rather than selecting text.
          ? Text(message.text, style: textStyle)
          : SelectableText(
              message.text,
              contextMenuBuilder: _menu,
              style: textStyle,
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
        if (mine && !unsent) ...[
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
    if (phone) {
      // Tap retries a failed message, as before; long press: its actions.
      body = InkWell(
        onTap: retryable ? onRetry : null,
        onLongPress: onActions,
        borderRadius: BorderRadius.circular(18),
        child: body,
      );
    } else if (retryable) {
      // TV and Windows: Select or a click retries, as before.
      body = TvFocusable(
        onSelect: onRetry,
        focusScale: 1.02,
        semanticLabel: 'Retry sending',
        child: body,
      );
    } else if (DeviceCapabilities.isTv &&
        onActions != null &&
        message.status != MessageStatus.sending) {
      // The remote cannot long press text: Select offers the actions.
      body = TvFocusable(
        onSelect: onActions,
        focusScale: 1.02,
        semanticLabel: 'Message options',
        child: body,
      );
    } else if (unsent && onDelete != null && !DeviceCapabilities.isTv) {
      // Windows: no text to right click; the placeholder offers Delete.
      body = GestureDetector(onSecondaryTap: onDelete, child: body);
    }
    if (working) body = Opacity(opacity: .5, child: body);
    return Semantics(
      label: [
        mine ? 'You' : 'Them',
        if (unsent) 'unsent',
        messageTime(message.at),
        if (mine && !unsent) _statusLabel,
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
