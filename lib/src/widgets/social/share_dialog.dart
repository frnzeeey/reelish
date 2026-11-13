// Share with friends: pick up to ten friends, add a short note (not on TV,
// where typing is awkward) and send a title from its details page. A failed
// send keeps the dialog open and reuses its key, so trying again never sends
// twice. Shared by phone, TV and Windows.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../platform/device_capabilities.dart';
import '../../social/friends_controller.dart';
import '../../social/recommendations_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import 'social_widgets.dart';

const _maxRecipients = 10;

/// Shares [item] with friends; shows what happened as a snack bar.
Future<void> shareWithFriends(
  BuildContext context,
  MediaItem item, {
  FriendsController? friends,
  RecommendationsController? recommendations,
}) async {
  final result = await showDialog<ShareResult>(
    context: context,
    builder: (_) => _ShareDialog(
      item: item,
      friends: friends ?? FriendsController.instance,
      recommendations: recommendations ?? RecommendationsController.instance,
    ),
  );
  if (result == null || !context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(shareSummary(result))));
}

/// What a send did, in one sentence.
String shareSummary(ShareResult result) {
  final sent = result.sent;
  final to = switch (sent.length) {
    0 => '',
    1 => 'Sent to @${sent.first}',
    2 => 'Sent to @${sent[0]} and @${sent[1]}',
    _ => 'Sent to ${sent.length} friends',
  };
  if (result.notSent.isEmpty) return to;
  final missed = result.notSent.length == 1
      ? '@${result.notSent.first} does not take recommendations right now'
      : '${result.notSent.length} friends do not take recommendations right now';
  return to.isEmpty ? 'Not sent: $missed.' : '$to. $missed.';
}

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({
    required this.item,
    required this.friends,
    required this.recommendations,
  });

  final MediaItem item;
  final FriendsController friends;
  final RecommendationsController recommendations;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  /// One key for this share, kept across retries.
  final _clientId = newClientId();
  final _message = TextEditingController();
  final _chosen = <String>{};
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.friends.loaded) unawaited(widget.friends.load());
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _chosen.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await widget.recommendations.send(
      widget.item,
      recipients: _chosen.toList(),
      clientId: _clientId,
      message: _message.text,
    );
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.friends,
    builder: (context, _) {
      final friends = widget.friends.friends;
      final Widget list;
      if (friends.isEmpty && widget.friends.loading) {
        list = const Padding(
          padding: EdgeInsets.all(AppSpace.lg),
          child: Center(child: CircularProgressIndicator()),
        );
      } else if (friends.isEmpty) {
        list = Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
          child: Text(
            widget.friends.failed
                ? 'Your friends could not be loaded. Check your connection.'
                : 'Add friends in Profile > Friends to share titles with them.',
            style: TextStyle(color: GlassTheme.muted),
          ),
        );
      } else {
        list = ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (index, person) in friends.indexed)
                CheckboxListTile(
                  autofocus: index == 0,
                  contentPadding: EdgeInsets.zero,
                  value: _chosen.contains(person.handle),
                  onChanged:
                      _sending ||
                          (!_chosen.contains(person.handle) &&
                              _chosen.length >= _maxRecipients)
                      ? null
                      : (on) => setState(
                          () => on == true
                              ? _chosen.add(person.handle)
                              : _chosen.remove(person.handle),
                        ),
                  secondary: PersonAvatar(person: person, size: 36),
                  title: Text(
                    person.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: person.displayName == null
                      ? null
                      : Text('@${person.handle}'),
                ),
            ],
          ),
        );
      }
      return AlertDialog(
        title: Text('Share “${widget.item.name}”'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Only the friends you choose see it.',
                  style: TextStyle(color: GlassTheme.muted),
                ),
                const SizedBox(height: AppSpace.sm),
                list,
                if (friends.isNotEmpty && !DeviceCapabilities.isTv)
                  TextField(
                    controller: _message,
                    enabled: !_sending,
                    maxLength: 200,
                    maxLines: 3,
                    minLines: 1,
                    decoration: const InputDecoration(
                      hintText: 'Add a note (optional)',
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: Text(
                      _error!,
                      style: TextStyle(color: GlassTheme.danger),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _sending || _chosen.isEmpty
                ? null
                : () => unawaited(_send()),
            child: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _chosen.length > 1 ? 'Send to ${_chosen.length}' : 'Send',
                  ),
          ),
        ],
      );
    },
  );
}
