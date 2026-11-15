// Settings → Notifications: one switch for all alerts on this device, then
// what to be told about (new episodes, My list updates, people and
// collections followed, reminders, messages), how (as they happen or as a
// daily or weekly summary, with quiet hours), who and what is followed, and
// the alerts shown lately. Phone and Windows; not offered on TV.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../theme/reelish_icons.dart';

import '../notifications/episode_alerts.dart';
import '../notifications/smart_alerts.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/settings_components.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key, this.alerts, this.onBack});

  /// Defaults to [EpisodeAlerts.instance].
  final EpisodeAlerts? alerts;
  final VoidCallback? onBack;

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  EpisodeAlerts get _alerts => widget.alerts ?? EpisodeAlerts.instance;

  /// Alerts unseen when the page opened: they keep their dot while it
  /// stays open, and are marked seen as it opens.
  late final Set<String> _unseen = {
    for (final r in _alerts.recent)
      if (!r.read) r.event.key,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_alerts.markRecentRead());
    });
  }

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

  static String _reminderLabel(int days) =>
      days == 0 ? 'Off' : 'After $days days without watching';

  /// One choice of several, in a dialog; null when dismissed.
  Future<T?> _choose<T>({
    required String title,
    required List<(T, String)> options,
    required T selected,
  }) => showDialog<T>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final (value, label) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, value),
            child: Row(
              children: [
                Icon(
                  value == selected
                      ? ReelishIcons.radioOn
                      : ReelishIcons.radioOff,
                  size: 20,
                  color: value == selected
                      ? GlassTheme.primary
                      : GlassTheme.muted,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: Text(label)),
              ],
            ),
          ),
      ],
    ),
  );

  Future<void> _chooseReminder() async {
    final value = await _choose<int>(
      title: 'Unfinished series',
      options: [
        for (final days in UnfinishedReminders.choices)
          (days, _reminderLabel(days)),
      ],
      selected: _alerts.settings.reminderDays,
    );
    if (value != null) await _alerts.setReminderDays(value);
  }

  Future<void> _chooseFrequency() async {
    final value = await _choose<AlertFrequency>(
      title: 'How alerts arrive',
      options: [for (final f in AlertFrequency.values) (f, f.label)],
      selected: _alerts.settings.frequency,
    );
    if (value != null) await _alerts.setFrequency(value);
  }

  Future<void> _chooseQuiet() async {
    // A sentinel for Off, since null means the dialog was dismissed.
    const off = QuietHours(0, 0);
    final value = await _choose<QuietHours>(
      title: 'Quiet hours',
      options: [
        (off, 'Off'),
        for (final preset in QuietHours.presets) (preset, preset.label),
      ],
      selected: _alerts.settings.quiet ?? off,
    );
    if (value != null) await _alerts.setQuietHours(value == off ? null : value);
  }

  void _open(AlertEvent event) {
    final target = AlertTarget.of(event.target, event.name);
    final open = AlertRoutes.open;
    if (target != null && open != null) open(target);
  }

  static IconData _iconOf(AlertCategory category) => switch (category) {
    AlertCategory.episode => ReelishIcons.playCircle,
    AlertCategory.popular => ReelishIcons.fire,
    AlertCategory.watchlist => ReelishIcons.bookmarks,
    AlertCategory.reminder => ReelishIcons.history,
    AlertCategory.person => ReelishIcons.person,
    AlertCategory.franchise => ReelishIcons.stack,
    AlertCategory.wrapped => ReelishIcons.star,
  };

  @override
  Widget build(BuildContext context) {
    final alerts = _alerts;
    return ListenableBuilder(
      listenable: alerts,
      builder: (context, _) {
        final settings = alerts.settings;
        final on = settings.enabled;
        final follows = alerts.follows;
        final recent = alerts.recent;
        return SettingsPage(
          title: 'Notifications',
          subtitle: 'New episodes, My list and what you follow.',
          icon: ReelishIcons.bell,
          onBack: widget.onBack,
          children: [
            SettingsSection(
              label: 'NOTIFICATIONS',
              description: !Platform.isWindows
                  ? 'Reelish checks every few hours, even when it is closed.'
                  : 'Reelish checks every few hours while it is open.',
              children: [
                SettingsSwitchTile(
                  icon: ReelishIcons.bellRing,
                  title: 'Allow notifications',
                  description: on
                      ? _status(alerts)
                      : alerts.error ?? 'Off: no notifications',
                  value: on,
                  onChanged: (value) => alerts.setEnabled(value),
                ),
              ],
            ),
            SettingsSection(
              label: 'NEW EPISODES',
              children: [
                SettingsSwitchTile(
                  icon: ReelishIcons.bookmarks,
                  title: 'Series on My list',
                  description: 'A new episode of a series you saved',
                  value: settings.myList,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(myList: value),
                ),
                SettingsSwitchTile(
                  icon: ReelishIcons.playCircle,
                  title: 'Series you are watching',
                  description:
                      'Series in Continue watching; not episodes you have '
                      'already seen',
                  value: settings.watching,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(watching: value),
                ),
                SettingsSwitchTile(
                  icon: ReelishIcons.fire,
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
            SettingsSection(
              label: 'UPDATES',
              description:
                  'Dates come from TMDB. Whether a title plays in Reelish '
                  'depends on your sources.',
              children: [
                SettingsSwitchTile(
                  icon: ReelishIcons.calendar,
                  title: 'My list updates',
                  description:
                      'A new season announced or dated, a movie dated or '
                      'released',
                  value: settings.watchlist,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(watchlist: value),
                ),
                SettingsSwitchTile(
                  icon: ReelishIcons.person,
                  title: 'People you follow',
                  description:
                      'New films and series they star in or direct; not '
                      'cameos or talk shows',
                  value: settings.people,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(people: value),
                ),
                SettingsSwitchTile(
                  icon: ReelishIcons.stack,
                  title: 'Collections you follow',
                  description: 'A new film announced or released',
                  value: settings.franchises,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(franchises: value),
                ),
                SettingsTile(
                  icon: ReelishIcons.history,
                  title: 'Unfinished series',
                  description:
                      'A reminder about a series you left, at most one a '
                      'day; worked out on this device',
                  value: _reminderLabel(settings.reminderDays),
                  enabled: on,
                  onTap: () => unawaited(_chooseReminder()),
                ),
                SettingsSwitchTile(
                  icon: ReelishIcons.chat,
                  title: 'Messages from friends',
                  description:
                      'Who sent you a message, never what it says; checked '
                      'with episodes, so it can take a few hours',
                  value: settings.messages,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(messages: value),
                ),
                SettingsSwitchTile(
                  icon: ReelishIcons.star,
                  title: 'Reelish Wrapped',
                  description:
                      'Once in January, when your recap of the year is out',
                  value: settings.wrapped,
                  enabled: on,
                  onChanged: (value) => alerts.setSources(wrapped: value),
                ),
              ],
            ),
            SettingsSection(
              label: 'DELIVERY',
              children: [
                SettingsTile(
                  icon: ReelishIcons.bell,
                  title: 'How alerts arrive',
                  description: settings.frequency == AlertFrequency.instant
                      ? 'Each check shows what it found'
                      : 'Everything found waits for one summary',
                  value: settings.frequency.label,
                  enabled: on,
                  onTap: () => unawaited(_chooseFrequency()),
                ),
                SettingsTile(
                  icon: ReelishIcons.clock,
                  title: 'Quiet hours',
                  description:
                      'Nothing is shown; what is found waits until after',
                  value: settings.quiet?.label ?? 'Off',
                  enabled: on,
                  onTap: () => unawaited(_chooseQuiet()),
                ),
              ],
            ),
            SettingsSection(
              label: 'FOLLOWING',
              description: follows.people.isEmpty && follows.collections.isEmpty
                  ? 'Follow people and movie collections from their pages '
                        'in Search.'
                  : 'Kept on this device.',
              children: [
                for (final MapEntry(:key, :value) in follows.people.entries)
                  SettingsTile(
                    icon: ReelishIcons.person,
                    title: value,
                    description: 'Person',
                    mergeSemantics: false,
                    trailing: TextButton(
                      onPressed: () => unawaited(
                        alerts.setFollowPerson(key, value, follow: false),
                      ),
                      child: const Text('Unfollow'),
                    ),
                  ),
                for (final MapEntry(:key, :value)
                    in follows.collections.entries)
                  SettingsTile(
                    icon: ReelishIcons.stack,
                    title: value,
                    description: 'Collection',
                    mergeSemantics: false,
                    trailing: TextButton(
                      onPressed: () => unawaited(
                        alerts.setFollowCollection(key, value, follow: false),
                      ),
                      child: const Text('Unfollow'),
                    ),
                  ),
              ],
            ),
            SettingsSection(
              label: 'RECENT',
              description: recent.isEmpty
                  ? 'Alerts you get will be listed here.'
                  : null,
              children: [
                for (final r in recent)
                  SettingsTile(
                    icon: _iconOf(r.event.category),
                    title: r.event.title,
                    description: r.event.body,
                    trailing: _unseen.contains(r.event.key)
                        ? Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: GlassTheme.primary,
                              shape: BoxShape.circle,
                            ),
                          )
                        : null,
                    onTap: AlertRoutes.open == null
                        ? null
                        : () => _open(r.event),
                  ),
              ],
            ),
            if (on)
              SettingsSection(
                children: [
                  SettingsTile(
                    icon: ReelishIcons.refresh,
                    title: 'Check now',
                    description:
                        'The first check only notes what is out, so you are '
                        'not alerted about older news',
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
