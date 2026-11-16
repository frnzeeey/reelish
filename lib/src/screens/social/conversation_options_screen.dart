// One conversation's options for the signed-in account: a nickname for the
// friend, mute, and deleting the conversation. Every choice is this
// account's own: it is kept in the account's mailbox on the Reelish API and
// reaches its other devices, and the friend never sees it or loses anything
// (MessagesController; docs/messaging/README.md). Opened from a chat's
// header, and from a conversation in a list (long press or right click), on
// phone, TV and Windows.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../messaging/message_models.dart';
import '../../messaging/messages_controller.dart';
import '../../platform/device_capabilities.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/settings/settings_components.dart';
import '../../widgets/social/social_widgets.dart';
import '../../widgets/tv/tv_focus.dart';
import 'messages_screen.dart' show connectionNote;

class ConversationOptionsScreen extends StatefulWidget {
  const ConversationOptionsScreen({
    super.key,
    required this.conversation,
    this.messages,
    this.onBack,
    this.onOpenFriend,
    this.onDeleted,
  });

  final Conversation conversation;

  /// [MessagesController.instance] when null.
  final MessagesController? messages;
  final VoidCallback? onBack;

  /// Opens the friend's page (block, report, remove); hidden when null.
  final VoidCallback? onOpenFriend;

  /// After the conversation was deleted: leaves this page (and the chat).
  final VoidCallback? onDeleted;

  @override
  State<ConversationOptionsScreen> createState() =>
      _ConversationOptionsScreenState();
}

class _ConversationOptionsScreenState extends State<ConversationOptionsScreen> {
  late final MessagesController _messages =
      widget.messages ?? MessagesController.instance;

  /// A change is on its way to Reelish: the options wait for it.
  bool _working = false;

  String get _id => widget.conversation.id;

  @override
  void initState() {
    super.initState();
    // Changes travel over the messages connection: keep it open here.
    _messages.attach();
  }

  @override
  void dispose() {
    _messages.detach();
    super.dispose();
  }

  void _show(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Runs [change]; shows its error, or [done] once it is saved.
  Future<bool> _run(Future<String?> Function() change, String done) async {
    if (_working) return false;
    setState(() => _working = true);
    final error = await change();
    if (!mounted) return false;
    setState(() => _working = false);
    _show(error ?? done);
    return error == null;
  }

  Future<void> _editNickname() async {
    final peer = _messages.conversation(_id)?.peer ?? widget.conversation.peer;
    final current = _messages.prefsOf(_id).nickname ?? '';
    final String? entered;
    if (DeviceCapabilities.isTv) {
      entered = await TvTextEntryDialog.show(
        context,
        title: 'Nickname for @${peer.handle}',
        initialValue: current,
        hint: peer.label,
      );
    } else {
      entered = await showDialog<String>(
        context: context,
        builder: (context) => _NicknameDialog(
          initialValue: current,
          handle: peer.handle,
          hint: peer.label,
        ),
      );
    }
    if (entered == null || !mounted) return;
    if (cleanNickname(entered) == null) {
      _show(messageActionErrorText('invalid_nickname'));
      return;
    }
    await _run(() => _messages.setNickname(_id, entered), 'Nickname saved');
  }

  Future<void> _resetNickname() =>
      _run(() => _messages.setNickname(_id, null), 'Nickname removed');

  Future<void> _setMuted(bool muted) => _run(
    () => _messages.setMuted(_id, muted),
    muted ? 'Conversation muted' : 'Conversation unmuted',
  );

  Future<void> _delete() async {
    final peer = _messages.conversation(_id)?.peer ?? widget.conversation.peer;
    final confirmed = await confirmSocial(
      context,
      title: 'Delete this conversation?',
      message:
          'Its messages are deleted from all your devices. ${peer.label} '
          'keeps their copy and is not told. If they message you again, the '
          'conversation starts over.',
      action: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final deleted = await _run(
      () => _messages.deleteConversation(_id),
      'Conversation deleted',
    );
    if (deleted && mounted) (widget.onDeleted ?? widget.onBack)?.call();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _messages,
    builder: (context, _) {
      final conversation = _messages.conversation(_id) ?? widget.conversation;
      final prefs = _messages.prefsOf(_id);
      final shown = _messages.displayPeer(conversation);
      final peer = conversation.peer;
      final note = connectionNote(_messages.connection);
      final nickname = prefs.nickname;
      return SettingsPage(
        title: 'Conversation',
        subtitle: '@${peer.handle}',
        onBack: widget.onBack,
        footer: null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
            child: Column(
              children: [
                PersonAvatar(person: shown, size: 72),
                const SizedBox(height: AppSpace.md),
                Text(
                  shown.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: AppTextSize.title,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                // The handle always shows, so a nickname cannot pass for
                // someone else; with one, their own name too.
                Text(
                  [
                    '@${peer.handle}',
                    if (nickname != null) 'Their name: ${peer.label}',
                  ].join(' · '),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GlassTheme.muted),
                ),
              ],
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: Text(
                note,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.label,
                ),
              ),
            ),
          if (_working)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpace.md),
              child: LinearProgressIndicator(),
            ),
          SettingsSection(
            label: 'NICKNAME',
            description:
                'Only you see it, in your messages. It does not change '
                '${peer.label}’s profile or what anyone else sees.',
            children: [
              SettingsTile(
                icon: ReelishIcons.edit,
                title: nickname == null ? 'Set nickname' : 'Edit nickname',
                value: nickname,
                enabled: !_working,
                onTap: () => unawaited(_editNickname()),
              ),
              if (nickname != null)
                SettingsTile(
                  icon: ReelishIcons.close,
                  title: 'Remove nickname',
                  description: 'Show ${peer.label} again',
                  enabled: !_working,
                  onTap: () => unawaited(_resetNickname()),
                ),
            ],
          ),
          SettingsSection(
            label: 'NOTIFICATIONS',
            children: [
              SettingsSwitchTile(
                icon: ReelishIcons.volumeOff,
                title: 'Mute conversation',
                description:
                    'No alerts for new messages from ${shown.label}, on any '
                    'of your devices. Messages still arrive.',
                value: prefs.muted,
                enabled: !_working,
                onChanged: (value) => unawaited(_setMuted(value)),
              ),
            ],
          ),
          SettingsSection(
            children: [
              if (widget.onOpenFriend != null)
                SettingsTile(
                  icon: ReelishIcons.person,
                  title: 'View profile',
                  description: 'Block, report or remove ${peer.label}',
                  onTap: widget.onOpenFriend,
                ),
              SettingsTile(
                icon: ReelishIcons.trash,
                title: 'Delete conversation',
                description:
                    'From all your devices. ${peer.label} keeps their copy.',
                enabled: !_working,
                onTap: () => unawaited(_delete()),
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// Asks for a nickname with a mouse, touch or keyboard; TV uses
/// [TvTextEntryDialog].
class _NicknameDialog extends StatefulWidget {
  const _NicknameDialog({
    required this.initialValue,
    required this.handle,
    required this.hint,
  });

  final String initialValue;
  final String handle;
  final String hint;

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Nickname for @${widget.handle}'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: maxNicknameChars,
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _save(),
      decoration: InputDecoration(
        hintText: widget.hint,
        helperText: 'Only you see it',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) => FilledButton(
          onPressed: value.text.trim().isEmpty ? null : _save,
          child: const Text('Save'),
        ),
      ),
    ],
  );
}
