// Messages on Windows with room for both: the conversation list on the left
// and the open conversation beside it, instead of one replacing the other.
// Phones, TV and narrow windows keep the list and push the chat over it
// (openMessages in friends_screen.dart decides). Escape closes the open
// conversation before it leaves the page.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../messaging/message_models.dart';
import '../../messaging/messages_controller.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/empty_state.dart';
import 'messages_screen.dart';

class MessagesSplitView extends StatefulWidget {
  const MessagesSplitView({
    super.key,
    required this.chat,
    this.messages,
    this.onBack,
    this.openOptions,
  });

  /// The narrowest window that shows the list and a chat side by side.
  static const minWidth = 900.0;

  /// The list's width beside the chat.
  static const listWidth = 380.0;

  /// The chat for [conversation]; [close] empties the pane (after the
  /// conversation is deleted).
  final Widget Function(Conversation conversation, VoidCallback close) chat;

  /// [MessagesController.instance] when null.
  final MessagesController? messages;
  final VoidCallback? onBack;

  /// A conversation's options, from the list; [close] empties the pane.
  final void Function(Conversation conversation, VoidCallback close)?
  openOptions;

  @override
  State<MessagesSplitView> createState() => _MessagesSplitViewState();
}

class _MessagesSplitViewState extends State<MessagesSplitView> {
  late final MessagesController _messages =
      widget.messages ?? MessagesController.instance;

  /// The open conversation, as it was chosen: the chat reads its messages
  /// from the controller itself, as when it opens over the list.
  Conversation? _selected;

  @override
  void initState() {
    super.initState();
    _messages.addListener(_closeIfGone);
  }

  @override
  void dispose() {
    _messages.removeListener(_closeIfGone);
    super.dispose();
  }

  void _close() {
    if (mounted) setState(() => _selected = null);
  }

  /// A deleted conversation closes its pane. The controller can change while
  /// the chat builds (opening it marks it read), so the pane changes after
  /// the frame, never during it; and the chat is built outside any listener
  /// of the controller for the same reason.
  void _closeIfGone() {
    final id = _selected?.id;
    if (id == null || _messages.conversations.any((c) => c.id == id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selected?.id == id) _close();
    });
  }

  /// Escape closes the open conversation first; with none open it passes on
  /// to the window's Back (DesktopShortcuts), which leaves Messages.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        _selected == null) {
      return KeyEventResult.ignored;
    }
    _close();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _onKey,
    child: _panes(),
  );

  Widget _panes() {
    final selected = _selected;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: MessagesSplitView.listWidth,
          child: MessagesScreen(
            messages: _messages,
            onBack: widget.onBack,
            selectedId: selected?.id,
            openChat: (conversation) {
              // Read now, from the tap: the chat marks it read as it starts,
              // and that change, made while the list beside it has already
              // built in the same frame, would mark the list dirty mid-build.
              unawaited(_messages.markRead(conversation.id));
              setState(() => _selected = conversation);
            },
            openOptions: widget.openOptions == null
                ? null
                : (conversation) => widget.openOptions!(conversation, _close),
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: GlassTheme.divider),
        Expanded(
          child: selected == null
              ? const _NoConversation()
              : KeyedSubtree(
                  key: ValueKey(selected.id),
                  child: widget.chat(selected, _close),
                ),
        ),
      ],
    );
  }
}

/// The chat pane before a conversation is chosen.
class _NoConversation extends StatelessWidget {
  const _NoConversation();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: ReelishIcons.chat,
    title: 'Choose a conversation',
    message: 'It opens here, beside the list.',
  );
}
