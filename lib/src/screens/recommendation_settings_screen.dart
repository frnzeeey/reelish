// Settings → Recommendations: personalised rows on or off, the genres the
// viewer likes, titles hidden from recommendations, and a reset. Phone, TV
// and Windows (in its Settings pane) show this same page.

import 'package:flutter/material.dart';

import '../discovery/discovery_controller.dart';
import '../discovery/discovery_data.dart';
import '../discovery/tmdb_genres.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/settings/settings_components.dart';

class RecommendationSettingsScreen extends StatelessWidget {
  const RecommendationSettingsScreen({super.key, this.discovery, this.onBack});

  /// Defaults to [DiscoveryController.active], Home's.
  final DiscoveryController? discovery;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final discovery = this.discovery ?? DiscoveryController.active;
    if (discovery == null) {
      return SettingsPage(
        title: 'Recommendations',
        icon: ReelishIcons.sparkle,
        onBack: onBack,
        children: const [
          SettingsParagraph(text: 'Recommendations are not available yet.'),
        ],
      );
    }
    return ListenableBuilder(
      listenable: discovery,
      builder: (context, _) {
        final data = discovery.data;
        final picked = data.favoriteGenres.toSet();
        final hidden = data.feedback.values
            .where((entry) => entry.kind == FeedbackKind.notInterested)
            .toList();
        final watched = data.activity.length;
        return SettingsPage(
          title: 'Recommendations',
          subtitle: 'Shape the rows picked for you on Home.',
          icon: ReelishIcons.sparkle,
          onBack: onBack,
          children: [
            SettingsSection(
              label: 'DISCOVERY',
              children: [
                SettingsSwitchTile(
                  icon: ReelishIcons.sparkle,
                  title: 'Personalised rows on Home',
                  description: discovery.personalization
                      ? 'Home leads with rows picked for you'
                      : 'Off: Home shows the same rows for everyone, and '
                            'nothing is learned from what you watch',
                  value: discovery.personalization,
                  onChanged: discovery.setPersonalization,
                ),
              ],
            ),
            SettingsSection(
              label: 'GENRES YOU LIKE',
              description:
                  'Picked genres count from the start, alongside what you '
                  'watch, and follow your account to your other devices. '
                  'Choose as many as you like, or none.',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in TmdbGenres.pickable)
                        FilterChip(
                          label: Text(TmdbGenres.nameOf(id) ?? ''),
                          selected: picked.contains(id),
                          showCheckmark: false,
                          selectedColor: GlassTheme.primary.withValues(
                            alpha: .22,
                          ),
                          side: BorderSide(
                            color: picked.contains(id)
                                ? GlassTheme.primary
                                : GlassTheme.border,
                          ),
                          onSelected: (selected) =>
                              discovery.setFavoriteGenres([
                                for (final genre in data.favoriteGenres)
                                  if (genre != id) genre,
                                if (selected) id,
                              ]),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            SettingsSection(
              label: 'YOUR RECOMMENDATIONS',
              description:
                  'Worked out on this device from what this account watches '
                  'and saves, and kept apart from other accounts. To find '
                  'similar titles Reelish asks TMDB, through the Reelish '
                  'API, about a few titles you watched and the genres you '
                  'picked, as it does when you open a title. Only the genres '
                  'and whether these rows are on are kept with your account.',
              children: [
                SettingsTile(
                  icon: ReelishIcons.playCircle,
                  title: 'Titles they are based on',
                  description: watched == 0
                      ? 'Nothing watched yet with this account'
                      : 'Titles watched on this device with this account',
                  value: '$watched',
                ),
                SettingsTile(
                  icon: ReelishIcons.dislike,
                  title: 'Show hidden titles again',
                  description: hidden.isEmpty
                      ? 'Nothing hidden'
                      : 'Titles you marked Not interested',
                  value: hidden.isEmpty ? null : '${hidden.length}',
                  enabled: hidden.isNotEmpty,
                  onTap: hidden.isEmpty ? null : discovery.showHiddenAgain,
                ),
                SettingsTile(
                  icon: ReelishIcons.restart,
                  title: 'Reset recommendations',
                  description:
                      'Forget what they learned from your viewing and '
                      'feedback. Your history and My list stay.',
                  onTap: () => _confirmReset(context, discovery),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmReset(
    BuildContext context,
    DiscoveryController discovery,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset recommendations?'),
        content: const Text(
          'Recommendations start over from the genres you picked and what '
          'you watch from now on. Your watch history and My list are not '
          'changed.',
        ),
        actions: [
          TextButton(
            // The safe choice is focused, so Select never resets by accident
            // on a remote.
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await discovery.reset();
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Recommendations reset')));
  }
}
