// People in Friends: the avatar friends chose (a built-in preset or an
// initial), a person row for lists, a recommendation card, and the Add
// friend and Report dialogs.
// Shared by phone, TV and Windows; text entry uses the remote-friendly
// dialog on TV. Never shows anything a person did not choose to share.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../account/profile_controller.dart';
import '../../platform/device_capabilities.dart';
import '../../social/friends_controller.dart';
import '../../social/recommendations_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../artwork_image.dart';
import '../tv/tv_focus.dart';

/// A person's chosen avatar preset, or the first letter of what they show.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.person, this.size = 40});

  final SocialPerson person;
  final double size;

  @override
  Widget build(BuildContext context) {
    final preset = AvatarPreset.byId(person.avatar);
    if (preset != null) {
      return ClipOval(
        child: Image.asset(
          preset.asset,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        ),
      );
    }
    final label = person.displayName ?? person.handle;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: GlassTheme.primary.withValues(alpha: .18),
        border: Border.all(color: GlassTheme.primary.withValues(alpha: .35)),
      ),
      child: Text(
        label.characters.first.toUpperCase(),
        style: TextStyle(
          color: GlassTheme.textPrimary,
          fontSize: size * .42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A person in a list: avatar, name and handle, and [trailing] actions.
/// Tapping it (when [onTap] is given) opens them.
class PersonTile extends StatelessWidget {
  const PersonTile({
    super.key,
    required this.person,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final SocialPerson person;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (person.displayName != null) '@${person.handle}',
      ?subtitle,
    ].join(' · ');
    final tile = AnimatedOpacity(
      duration: AppMotion.resolve(context, AppMotion.hover),
      opacity: enabled ? 1 : .45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                PersonAvatar(person: person),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        person.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: AppTextSize.titleSmall,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (details.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          details,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GlassTheme.muted,
                            fontSize: AppTextSize.label,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ] else if (onTap != null)
                  Icon(
                    ReelishIcons.chevronRight,
                    color: GlassTheme.muted,
                    size: 22,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // One item for a screen reader, unless it holds buttons of its own
    // (Accept, Decline, Cancel), which must stay separately reachable.
    return trailing == null ? MergeSemantics(child: tile) : tile;
  }
}

/// Asks for a friend code or handle and sends the request; returns the
/// result once one was sent, or null when the person gave up.
Future<AddFriendResult?> showAddFriend(
  BuildContext context,
  FriendsController friends,
) async {
  if (DeviceCapabilities.isTv) {
    var value = '';
    for (;;) {
      if (!context.mounted) return null;
      final entered = await TvTextEntryDialog.show(
        context,
        title: 'Friend code or @handle',
        initialValue: value,
        hint: 'ABCD-2345',
      );
      if (entered == null || entered.trim().isEmpty) return null;
      value = entered;
      final result = await friends.add(entered);
      if (result.error == null) return result;
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(result.error!)));
      }
    }
  }
  return showDialog<AddFriendResult>(
    context: context,
    builder: (_) => _AddFriendDialog(friends: friends),
  );
}

class _AddFriendDialog extends StatefulWidget {
  const _AddFriendDialog({required this.friends});

  final FriendsController friends;

  @override
  State<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<_AddFriendDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _controller.text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await widget.friends.add(_controller.text);
    if (!mounted) return;
    if (result.error == null) {
      Navigator.pop(context, result);
      return;
    }
    setState(() {
      _sending = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add a friend'),
    content: SizedBox(
      width: 400,
      child: TextField(
        controller: _controller,
        autofocus: true,
        enabled: !_sending,
        autocorrect: false,
        maxLength: 21,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => unawaited(_send()),
        decoration: InputDecoration(
          hintText: 'ABCD-2345 or @handle',
          helperText:
              'Their friend code, or their @handle if they let people find '
              'them by it.',
          helperMaxLines: 3,
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _sending ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _sending ? null : () => unawaited(_send()),
        child: _sending
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Send request'),
      ),
    ],
  );
}

/// What a report says: a reason, an optional note and whether to block too.
typedef ReportChoice = ({ReportReason reason, String note, bool block});

/// Asks why [person] is being reported. Null when cancelled.
Future<ReportChoice?> showReportPerson(
  BuildContext context,
  SocialPerson person,
) => showDialog<ReportChoice>(
  context: context,
  builder: (_) => _ReportDialog(person: person),
);

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.person});

  final SocialPerson person;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final _note = TextEditingController();
  ReportReason? _reason;
  bool _block = true;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Report @${widget.person.handle}'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Reports go to Reelish. The person is not told who reported '
              'them.',
              style: TextStyle(color: GlassTheme.muted),
            ),
            const SizedBox(height: AppSpace.sm),
            for (final (index, reason) in ReportReason.values.indexed)
              ListTile(
                autofocus: index == 0,
                contentPadding: EdgeInsets.zero,
                selected: reason == _reason,
                leading: Icon(
                  reason == _reason
                      ? ReelishIcons.radioOn
                      : ReelishIcons.radioOff,
                  color: reason == _reason
                      ? GlassTheme.primary
                      : GlassTheme.muted,
                ),
                title: Text(reason.label),
                onTap: () => setState(() => _reason = reason),
              ),
            // A remote has no comfortable way to type a note.
            if (!DeviceCapabilities.isTv)
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  hintText: 'Anything else (optional)',
                ),
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _block,
              onChanged: (value) => setState(() => _block = value),
              title: const Text('Also block them'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _reason == null
            ? null
            : () => Navigator.pop(context, (
                reason: _reason!,
                note: _note.text,
                block: _block,
              )),
        child: const Text('Report'),
      ),
    ],
  );
}

/// Asks before an action that affects another person; the safe choice is
/// focused, so Select on a remote never confirms by accident.
Future<bool> confirmSocial(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: GlassTheme.danger,
                    foregroundColor: Colors.white,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// A title a friend sent: poster, title and year, who sent it and their note,
/// a dot while unopened, and Remove. Tapping opens the title.
class RecommendationTile extends StatelessWidget {
  const RecommendationTile({
    super.key,
    required this.item,
    required this.onOpen,
    this.onRemove,
    this.sentByMe = false,
  });

  final Recommendation item;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  /// One this account sent: [Recommendation.from] is the friend it went to.
  final bool sentByMe;

  @override
  Widget build(BuildContext context) {
    final media = item.media;
    final from = item.from;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final poster = media.poster.isEmpty
        ? ColoredBox(
            color: GlassTheme.surface,
            child: Icon(ReelishIcons.movie, color: GlassTheme.muted),
          )
        : ArtworkImage.network(
            media.poster,
            fit: BoxFit.cover,
            cacheWidth: (44 * ratio).round(),
            errorBuilder: (_, _, _) => ColoredBox(color: GlassTheme.surface),
          );
    return Semantics(
      label: item.read ? null : 'New',
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: SizedBox(width: 44, height: 66, child: poster),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (!item.read) ...[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: GlassTheme.primary,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            media.year.isEmpty
                                ? media.name
                                : '${media.name} (${media.year})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: AppTextSize.titleSmall,
                              fontWeight: item.read
                                  ? FontWeight.w600
                                  : FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      from == null
                          ? (sentByMe
                                ? 'To someone no longer on Friends'
                                : 'From someone no longer on Friends')
                          : '${sentByMe ? 'To' : 'From'} ${from.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: GlassTheme.muted,
                        fontSize: AppTextSize.label,
                      ),
                    ),
                    if (item.message case final message?) ...[
                      const SizedBox(height: 3),
                      Text(
                        '“$message”',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: AppTextSize.bodySmall,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  tooltip: 'Remove',
                  onPressed: onRemove,
                  icon: Icon(ReelishIcons.close, color: GlassTheme.muted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
