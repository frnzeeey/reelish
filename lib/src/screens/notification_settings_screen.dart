// Settings → Notifications: new-episode alerts for series on My list,
// series being watched, and popular series. Phone and Windows.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../notifications/episode_alerts.dart';
import '../widgets/settings/settings_components.dart';

class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key, this.alerts, this.onBack});

  /// Defaults to [EpisodeAlerts.instance].
  final EpisodeAlerts? alerts;
  final VoidCallback? onBack;

  static String _status(EpisodeAlerts alerts) {
    if (alerts.checking) return 'Checking…';
    final error = alerts.error;
    if (error != null) return error;
    final at = alerts.lastChecked;
    if (at == null) return 'Not checked yet';
    final ago = DateTime.now().difference(at);
    if (ago.inMinutes < 1) return 'Checked just now';
    if (ago.inHours < 1) return 'Checked ${ago.inMinutes} min ago';
    if (ago.inDays < 1) return 'Checked ${ago.inHours} h ago';
    return 'Checked ${ago.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final alerts = this.alerts ?? EpisodeAlerts.instance;
    return ListenableBuilder(
      listenable: alerts,
      builder: (context, _) {
        final settings = alerts.settings;
        final on = settings.enabled;
        return SettingsPage(
          title: 'Notifications',
          subtitle: 'Know when new episodes are out.',
          icon: Symbols.notifications_rounded,
          onBack: onBack,
          children: [
            SettingsSection(
              label: 'NEW EPISODES',
              description: !Platform.isWindows
                  ? 'Reelish checks every few hours, even when it is closed.'
                  : 'Reelish checks every few hours while it is open.',
              children: [
                SettingsSwitchTile(
                  icon: Symbols.notifications_active_rounded,
                  title: 'New episode alerts',
                  description: on
                      ? _status(alerts)
                      : alerts.error ?? 'Off: no notifications',
                  value: on,
                  onChanged: (value) => alerts.setEnabled(value),
                ),
              ],
            ),
            SettingsSection(
              label: 'ALERT ME ABOUT',
              children: [
                SettingsSwitchTile(
                  icon: Symbols.bookmarks_rounded,
                  title: 'Series on My list',
                  description: 'A new episode of a series you saved',
                  value: settings.myList,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(myList: value),
                ),
                SettingsSwitchTile(
                  icon: Symbols.play_circle_rounded,
                  title: 'Series you are watching',
                  description: 'Series in Continue watching',
                  value: settings.watching,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(watching: value),
                ),
                SettingsSwitchTile(
                  icon: Symbols.local_fire_department_rounded,
                  title: 'Popular series',
                  description:
                      'Today’s most popular series with a new episode; at '
                      'most one summary a day',
                  value: settings.popular,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(popular: value),
                ),
              ],
            ),
            if (on)
              SettingsSection(
                children: [
                  SettingsTile(
                    icon: Symbols.refresh_rounded,
                    title: 'Check now',
                    description:
                        'The first check only notes what is out, so you are '
                        'not alerted about older episodes',
                    enabled: !alerts.checking,
                    trailing: alerts.checking
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: alerts.checkNow,
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
