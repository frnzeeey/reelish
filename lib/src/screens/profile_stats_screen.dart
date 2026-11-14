// Profile > Viewing statistics: what the viewer has watched recently, counted
// from this account's history and episode progress on this device
// (ViewingStats). Private: nothing is sent, and no one else can see it.
// The same page on phone, TV and Windows; each panel takes focus so the
// remote scrolls through it, and reads as one sentence to a screen reader.
import 'package:flutter/material.dart';

import '../discovery/tmdb_genres.dart';
import '../models/viewing_stats.dart';
import '../platform/device_capabilities.dart';
import '../services/storage_service.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/settings/settings_components.dart';

class ProfileStatsScreen extends StatefulWidget {
  const ProfileStatsScreen({super.key, required this.storage, this.onBack});

  final StorageService storage;
  final VoidCallback? onBack;

  @override
  State<ProfileStatsScreen> createState() => _ProfileStatsScreenState();
}

class _ProfileStatsScreenState extends State<ProfileStatsScreen> {
  late final Future<ViewingStats> _stats = _load();

  /// Local reads only: no network request.
  Future<ViewingStats> _load() async {
    final history = await widget.storage.history();
    final series = await widget.storage.allSeriesProgress();
    return ViewingStats.from(history: history, series: series);
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Viewing statistics',
    subtitle: 'Only you see these.',
    icon: ReelishIcons.insights,
    onBack: widget.onBack,
    footer: null,
    children: [
      FutureBuilder<ViewingStats>(
        future: _stats,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const _Note(
              'Your history could not be read on this device.',
            );
          }
          final stats = snapshot.data;
          if (stats == null) {
            return const Padding(
              padding: EdgeInsets.all(AppSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (stats.isEmpty) {
            return const _Note(
              'Nothing to count yet. Movies and episodes you watch for more '
              'than a minute and a half show up here.',
            );
          }
          return _Stats(stats: stats);
        },
      ),
      const SettingsSection(
        label: 'ABOUT THESE NUMBERS',
        children: [
          SettingsParagraph(
            text:
                'Counted from your recent activity on this account: your '
                'last 50 titles and 100 series, which sync between your '
                'devices and are kept for a year. A title counts as finished '
                'from 90% of its length, and as started after a minute and '
                'a half. Watch time is an estimate from where you stopped '
                'in each title.\n\nThese are counted on this device and '
                'never sent anywhere. Friends cannot see them.',
          ),
        ],
      ),
    ],
  );
}

class _Stats extends StatelessWidget {
  const _Stats({required this.stats});

  final ViewingStats stats;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Tile(
        value: '${stats.moviesFinished}',
        label: stats.moviesFinished == 1 ? 'Movie finished' : 'Movies finished',
      ),
      _Tile(
        value: '${stats.episodesFinished}',
        label: stats.episodesFinished == 1
            ? 'Episode finished'
            : 'Episodes finished',
      ),
      _Tile(
        value: '${stats.seriesWatched}',
        label: 'Series watched',
        detail: 'At least one episode finished',
      ),
      _Tile(
        value: '${stats.moviesInProgress + stats.episodesInProgress}',
        label: 'In progress',
        detail:
            '${stats.moviesInProgress} '
            '${stats.moviesInProgress == 1 ? 'movie' : 'movies'}, '
            '${stats.episodesInProgress} '
            '${stats.episodesInProgress == 1 ? 'episode' : 'episodes'}',
      ),
      _Tile(
        value: ViewingStats.formatHours(stats.estimatedWatchMs),
        label: 'Watch time',
        detail: 'Estimated',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          label: 'AT A GLANCE',
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.sm),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const spacing = AppSpace.sm;
                  final columns = constraints.maxWidth >= 560 ? 3 : 2;
                  final width =
                      (constraints.maxWidth - spacing * (columns - 1)) /
                      columns;
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final tile in tiles)
                        SizedBox(width: width, child: tile),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        SettingsSection(
          label: 'TOP GENRES',
          children: [
            if (stats.genres.isEmpty)
              const _Note('Genres show once titles with known genres count.')
            else
              _Genres(stats: stats),
          ],
        ),
        SettingsSection(
          label: 'FINISHED, BY MONTH',
          children: [_Months(months: stats.months)],
        ),
      ],
    );
  }
}

/// A panel the remote can land on, so the page scrolls with it, read out as
/// [label].
class _Readable extends StatefulWidget {
  const _Readable({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  State<_Readable> createState() => _ReadableState();
}

class _ReadableState extends State<_Readable> {
  var _focused = false;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: widget.label,
    excludeSemantics: true,
    child: Focus(
      // Only where there is a remote or a keyboard to move with.
      canRequestFocus: DeviceCapabilities.usesTvLayout,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) {
          Scrollable.ensureVisible(
            context,
            alignment: .4,
            duration: AppMotion.resolve(context, AppMotion.standard),
          );
        }
      },
      child: AnimatedContainer(
        duration: AppMotion.resolve(context, AppMotion.hover),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: _focused ? GlassTheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: widget.child,
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.value, required this.label, this.detail});

  final String value;
  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    return _Readable(
      label: [value, label, ?detail].join(', '),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: GlassTheme.glassBackground,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  color: GlassTheme.primary,
                  fontSize: tv ? AppTextSize.headline : AppTextSize.titleLarge,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: tv ? AppTextSize.body : AppTextSize.label,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (detail != null)
              Text(
                detail!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.caption,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The top genres as bars, each its share of titles with known genres.
class _Genres extends StatelessWidget {
  const _Genres({required this.stats});

  final ViewingStats stats;

  @override
  Widget build(BuildContext context) {
    final most = stats.genres.first.titles;
    final tv = DeviceCapabilities.isTv;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.sm),
      child: Column(
        children: [
          for (final genre in stats.genres)
            _Readable(
              label:
                  '${TmdbGenres.nameOf(genre.genreId) ?? 'Other'}, '
                  '${genre.titles} of ${stats.titlesWithGenres} titles',
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.sm,
                  vertical: AppSpace.xs,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: tv ? 200 : 120,
                      child: Text(
                        TmdbGenres.nameOf(genre.genreId) ?? 'Other',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: tv ? AppTextSize.body : AppTextSize.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: genre.titles / most,
                          minHeight: 8,
                          color: GlassTheme.primary,
                          backgroundColor: GlassTheme.textPrimary.withValues(
                            alpha: .08,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    SizedBox(
                      width: 32,
                      child: Text(
                        '${genre.titles}',
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: GlassTheme.muted,
                          fontSize: AppTextSize.label,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Finished movies and episodes in each of the last months, as columns.
class _Months extends StatelessWidget {
  const _Months({required this.months});

  final List<MonthActivity> months;

  static const _names = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    final most = months.fold(
      0,
      (most, m) => m.finished > most ? m.finished : most,
    );
    final height = DeviceCapabilities.isTv ? 120.0 : 96.0;
    final spoken = [
      for (final m in months) '${_names[m.month.month - 1]} ${m.finished}',
    ].join(', ');
    return Padding(
      padding: const EdgeInsets.all(AppSpace.sm),
      child: _Readable(
        label: 'Finished by month: $spoken',
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final m in months)
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${m.finished}',
                        style: TextStyle(
                          color: m.finished == 0
                              ? GlassTheme.muted
                              : GlassTheme.textPrimary,
                          fontSize: AppTextSize.label,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: AppSpace.xxs),
                      SizedBox(
                        height: height,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            widthFactor: .5,
                            heightFactor: most == 0
                                ? .02
                                : (m.finished / most).clamp(.02, 1.0),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: m.finished == 0
                                    ? GlassTheme.textPrimary.withValues(
                                        alpha: .1,
                                      )
                                    : GlassTheme.primary,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        _names[m.month.month - 1],
                        style: TextStyle(
                          color: GlassTheme.muted,
                          fontSize: AppTextSize.caption,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpace.lg),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(color: GlassTheme.muted, height: 1.5),
    ),
  );
}
