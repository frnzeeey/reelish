// Follow a person or a movie collection for alerts about their new work
// (EpisodeAlerts.setFollowPerson / setFollowCollection). Shown only where
// alerts exist (Android phones and tablets, and Windows) and someone is
// signed in; following is kept on this device, per account, and asks the
// Reelish API nothing until the next alert check.
import 'dart:async';

import 'package:flutter/material.dart';

import '../notifications/episode_alerts.dart';
import '../notifications/episode_check.dart';
import '../theme/design_tokens.dart';
import '../theme/reelish_icons.dart';

class FollowAlertButton extends StatelessWidget {
  const FollowAlertButton.person({
    super.key,
    required this.id,
    required this.name,
    this.alerts,
  }) : person = true;

  const FollowAlertButton.collection({
    super.key,
    required this.id,
    required this.name,
    this.alerts,
  }) : person = false;

  final int id;
  final String name;
  final bool person;

  /// Defaults to [EpisodeAlerts.instance].
  final EpisodeAlerts? alerts;

  @override
  Widget build(BuildContext context) {
    final given = this.alerts;
    // Not on TV: alerts are not offered there.
    if (given == null && !EpisodeAlerts.supported) {
      return const SizedBox.shrink();
    }
    final alerts = given ?? EpisodeAlerts.instance;
    return ListenableBuilder(
      listenable: alerts,
      builder: (context, _) {
        if (!alerts.signedIn) return const SizedBox.shrink();
        final following = person
            ? alerts.followsPerson(id)
            : alerts.followsCollection(id);
        final label = following ? 'Following' : 'Follow';
        final icon = Icon(
          following ? ReelishIcons.check : ReelishIcons.bellRing,
          size: 18,
        );
        final button = following
            ? OutlinedButton.icon(
                onPressed: () => unawaited(_toggle(context, alerts, false)),
                icon: icon,
                label: Text(label),
              )
            : FilledButton.tonalIcon(
                onPressed: () => unawaited(_toggle(context, alerts, true)),
                icon: icon,
                label: Text(label),
              );
        return Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Semantics(
            label: following
                ? 'Following $name for alerts. Unfollow'
                : 'Follow $name for alerts',
            excludeSemantics: true,
            button: true,
            child: button,
          ),
        );
      },
    );
  }

  Future<void> _toggle(
    BuildContext context,
    EpisodeAlerts alerts,
    bool follow,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final done = person
        ? await alerts.setFollowPerson(id, name, follow: follow)
        : await alerts.setFollowCollection(id, name, follow: follow);
    if (!follow) return;
    final settings = alerts.settings;
    final categoryOn = person ? settings.people : settings.franchises;
    final String message;
    if (!done) {
      message =
          'You can follow up to ${EpisodeAlertStore.maxFollows} '
          '${person ? 'people' : 'collections'}. Unfollow one in Settings > '
          'Notifications first.';
    } else if (!settings.enabled || !categoryOn) {
      message =
          'Following $name. Turn on notifications in Settings > '
          'Notifications to hear about their new work.';
    } else {
      message = person
          ? 'Following $name. Reelish will tell you about new films and '
                'series they star in or direct.'
          : 'Following $name. Reelish will tell you about new films in it.';
    }
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
