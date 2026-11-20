// Together: the place in the navigation for the people you watch with
// (Watch Party, messages and friends) on phone, Android TV and Windows. It is
// the Friends page (friends_screen.dart) with a Watch Party section on top,
// so Friends opened from Profile and Together stay one page. TogetherUpdates
// counts what is new there for the badge on the dock, rail and sidebar.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../messaging/messages_controller.dart';
import '../../navigation/app_transitions.dart';
import '../../social/social_controller.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/settings/settings_components.dart';
import '../watch_party/join_party_screen.dart';
import 'friends_screen.dart';

class TogetherScreen extends StatelessWidget {
  const TogetherScreen({super.key, this.bottomClearance = 20});

  /// Space below the page, for the phone dock.
  final double bottomClearance;

  @override
  Widget build(BuildContext context) => FriendsScreen(
    title: 'Together',
    bottomClearance: bottomClearance,
    leading: [
      SettingsSection(
        label: 'WATCH PARTY',
        description:
            'Watch in sync with friends, wherever they are. Hosts start a '
            'party from a title\'s page.',
        children: [
          SettingsTile(
            icon: ReelishIcons.createRoom,
            title: 'Join a watch party',
            description: 'Enter the code a friend shared',
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
  );
}

/// What is new in Together: friend requests, messages waiting or unread,
/// and titles friends recommended. The saved counts first, then the server's
/// at most every [SocialController.staleAfter] (nothing while Friends is
/// off); messages are read from this device. Nothing polls.
class TogetherUpdates extends StatefulWidget {
  const TogetherUpdates({
    super.key,
    required this.builder,
    this.social,
    this.messages,
  });

  final Widget Function(BuildContext context, int count) builder;

  /// [SocialController.instance] when null.
  final SocialController? social;

  /// [MessagesController.instance] when null.
  final MessagesController? messages;

  /// The number shown on the badge for [social] and [messages].
  static int count(SocialController social, MessagesController messages) {
    final counts = social.counts;
    return counts.incoming + counts.unread + counts.messages + messages.unread;
  }

  @override
  State<TogetherUpdates> createState() => _TogetherUpdatesState();
}

class _TogetherUpdatesState extends State<TogetherUpdates> {
  late final SocialController _social =
      widget.social ?? SocialController.instance;
  late final MessagesController _messages =
      widget.messages ?? MessagesController.instance;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _refresh();
  }

  void _refresh() {
    unawaited(_social.refreshIfStale());
    unawaited(_messages.ensureLoaded());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_social, _messages]),
    builder: (context, _) =>
        widget.builder(context, TogetherUpdates.count(_social, _messages)),
  );
}
