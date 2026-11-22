// Reelish Connect: the page that gathers what can be shared as a QR code or
// a link (your invitation, your friend code) and says where the rest is
// shared from (titles, watch parties). Opened from Together on every
// interface; built from the settings components, so touch, the remote and
// the mouse all work as on Together's other pages.

import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/device_capabilities.dart';
import '../screens/social/friends_privacy_screen.dart';
import '../screens/watch_party/join_party_screen.dart';
import '../navigation/app_transitions.dart';
import '../social/social_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/tv/tv_focus.dart';
import 'invite_controller.dart';
import 'share_sheet.dart';
import 'share_target.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.onBack, this.invites, this.social});

  final VoidCallback? onBack;
  final InviteController? invites;
  final SocialController? social;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final _invites = widget.invites ?? InviteController.instance;
  late final _social = widget.social ?? SocialController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_invites.refresh());
    unawaited(_social.refreshIfStale());
  }

  static String _spaced(String code) =>
      '${code.substring(0, 4)}-${code.substring(4)}';

  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _enterInvite() async {
    final String? entered;
    if (DeviceCapabilities.isTv) {
      entered = await TvTextEntryDialog.show(
        context,
        title: 'Invite code',
        initialValue: '',
        hint: 'ABCD-2345',
      );
    } else {
      entered = await showDialog<String>(
        context: context,
        builder: (_) => const _InviteCodeDialog(),
      );
    }
    if (entered == null || entered.trim().isEmpty || !mounted) return;
    final code = entered.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    final result = await _invites.accept(code);
    if (mounted) _say(result.message);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_invites, _social]),
    builder: (context, _) => SettingsPage(
      title: 'Reelish Connect',
      subtitle: 'Share the experience. Bring everyone closer.',
      icon: ReelishIcons.share,
      onBack: widget.onBack,
      footer: null,
      children: [
        _inviteSection(),
        _friendSection(),
        const _Explainer(
          label: 'SHARE MOVIES AND SERIES',
          text:
              'Choose Share on any movie or series page for its link and QR '
              'code. It opens that title in Reelish for whoever scans it. A '
              'share is where to find the title, never a video: Reelish plays '
              'sources each person chooses.',
        ),
        SettingsSection(
          label: 'WATCH PARTY',
          description:
              'When you host, the waiting room shows the party’s QR code: '
              'friends scan it to join. Party codes keep working too.',
          children: [
            SettingsTile(
              icon: ReelishIcons.dialpad,
              title: 'Join with a code',
              description: 'Type a friend’s party code',
              onTap: () => unawaited(
                Navigator.of(context).push(
                  AppPageRoute<void>(
                    context: context,
                    builder: (_) => const JoinPartyScreen(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _inviteSection() {
    final code = _invites.code;
    final tiles = <Widget>[
      if (code != null)
        SettingsTile(
          icon: ReelishIcons.invite,
          title: 'Your invitation',
          value: _spaced(code),
          description: 'Show its QR code, or share the link',
          onTap: () => unawaited(
            ShareSheet.show(
              context,
              AppInvite(code),
              title: 'Your Reelish invitation',
              note: 'It opens a page with Reelish for their phone, TV or PC.',
            ),
          ),
        )
      else if (_invites.failed)
        SettingsTile(
          icon: ReelishIcons.refresh,
          title: 'Couldn’t load your invitation',
          description: 'Check your connection and try again',
          onTap: () => unawaited(_invites.refresh()),
        )
      else
        const SettingsTile(
          icon: ReelishIcons.invite,
          title: 'Loading your invitation…',
          enabled: false,
        ),
      if (code != null)
        SettingsTile(
          icon: ReelishIcons.people,
          title: 'Joined with your invitation',
          value: '${_invites.joined}',
          showChevron: false,
        ),
      if (code != null && !_invites.invited)
        SettingsTile(
          icon: ReelishIcons.mail,
          title: 'Got an invite code?',
          description: 'Enter it so your friend knows you joined',
          onTap: () => unawaited(_enterInvite()),
        ),
    ];
    return SettingsSection(
      label: 'INVITE FRIENDS',
      description:
          'Bring your people in. Your invitation shows them how to get '
          'Reelish, and counts who joined with it.',
      children: tiles,
    );
  }

  Widget _friendSection() {
    final profile = _social.profile;
    final Widget tile;
    if (profile != null) {
      tile = SettingsTile(
        icon: ReelishIcons.personAdd,
        title: 'Your friend QR code',
        value: profile.formattedCode,
        description: 'Friends scan it to send you a request',
        onTap: () => unawaited(
          ShareSheet.show(
            context,
            FriendShare(profile.friendCode),
            title: 'Add me on Reelish',
            note: profile.findByCode
                ? 'You choose who becomes a friend: a scan only sends a '
                      'request.'
                : 'Found by friend code is off in Friends & privacy, so this '
                      'code finds no one until you turn it on.',
          ),
        ),
      );
    } else if (_social.known) {
      tile = SettingsTile(
        icon: ReelishIcons.personAdd,
        title: 'Turn on Friends',
        description: 'Get a friend code people can scan',
        onTap: () => Navigator.of(context).push(
          AppPageRoute<void>(
            context: context,
            builder: (context) => Scaffold(
              backgroundColor: GlassTheme.background,
              body: FriendsPrivacyScreen(
                controller: _social,
                onBack: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ),
      );
    } else if (_social.failed) {
      tile = SettingsTile(
        icon: ReelishIcons.refresh,
        title: 'Couldn’t load Friends',
        description: 'Check your connection and try again',
        onTap: () => unawaited(_social.refresh()),
      );
    } else {
      tile = const SettingsTile(
        icon: ReelishIcons.personAdd,
        title: 'Loading…',
        enabled: false,
      );
    }
    return SettingsSection(
      label: 'YOUR FRIEND CODE',
      description:
          'Nothing about you is public: the code only lets someone send a '
          'request, as Friends & privacy allows.',
      children: [tile],
    );
  }
}

/// A heading and a few words, with nothing to press: how something is
/// shared from elsewhere.
class _Explainer extends StatelessWidget {
  const _Explainer({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: SettingsMetrics.sectionGap),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(label: label),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            text,
            style: TextStyle(
              color: GlassTheme.muted,
              fontSize: AppTextSize.label,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

class _InviteCodeDialog extends StatefulWidget {
  const _InviteCodeDialog();

  @override
  State<_InviteCodeDialog> createState() => _InviteCodeDialogState();
}

class _InviteCodeDialogState extends State<_InviteCodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Got an invite code?'),
    content: SizedBox(
      width: 400,
      child: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        maxLength: 9,
        textCapitalization: TextCapitalization.characters,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.pop(context, value),
        decoration: const InputDecoration(
          hintText: 'ABCD-2345',
          helperText: 'The code on your friend’s invitation',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Accept'),
      ),
    ],
  );
}
