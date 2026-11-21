// Together: the social home of Reelish, a place in the navigation on phone,
// Android TV and Windows. The Friends page (friends_screen.dart) with the
// greeting and Movie night: people first, then watching together, messages,
// what friends sent, and the people settings last (docs/features/together.md).
// Friends opened from Profile and Together stay one page. TogetherUpdates
// counts what is new there for the badge on the dock, rail and sidebar.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../messaging/messages_controller.dart';
import '../../navigation/app_transitions.dart';
import '../../social/social_controller.dart';
import '../watch_party/join_party_screen.dart';
import 'friends_screen.dart';
import 'together_sections.dart';

/// What Home lends Together: search, where a title's page starts a party.
/// Registered by Home (as SocialTitles.open is) on every interface.
abstract final class TogetherActions {
  static VoidCallback? findTitle;
}

class TogetherScreen extends StatelessWidget {
  const TogetherScreen({super.key, this.bottomClearance = 20});

  /// Space below the page, for the phone dock.
  final double bottomClearance;

  @override
  Widget build(BuildContext context) => FriendsScreen(
    title: 'Together',
    greet: true,
    bottomClearance: bottomClearance,
    movieNight: MovieNightCard(
      onPickTitle: TogetherActions.findTitle,
      onJoin: () => unawaited(
        Navigator.of(context).push(
          AppPageRoute<void>(
            context: context,
            builder: (_) => const JoinPartyScreen(),
          ),
        ),
      ),
    ),
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
