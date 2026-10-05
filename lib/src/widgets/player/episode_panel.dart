import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/episode_context.dart';
import '../../models/episode_progress.dart';
import '../../theme/glass_theme.dart';
import '../category_chip.dart';
import 'paused_overlay.dart';

/// Lists a series' episodes by season, with thumbnails, runtimes, synopses
/// and the viewer's progress. A side panel in landscape and on large
/// screens, a draggable bottom sheet in portrait; the video stays visible
/// behind it and keeps playing. Pops the chosen episode, or null.
class EpisodePanel extends StatefulWidget {
  const EpisodePanel({
    super.key,
    required this.seriesTitle,
    required this.episodes,
    required this.progress,
    this.current,
    this.currentIsPlaying = true,
    this.previous,
    this.next,
    this.today,
    this.scrollController,
  });

  final String seriesTitle;

  /// Every listed episode, ordered by season, then number.
  final List<EpisodeRef> episodes;
  final SeriesProgress progress;

  /// The playing (or last watched) episode: highlighted, and shown first.
  final EpisodeRef? current;

  /// Whether [current] is playing now (marked `Playing`; choosing it just
  /// closes the panel) or was watched last (marked `Last watched`).
  final bool currentIsPlaying;

  String get currentLabel => currentIsPlaying ? 'Playing' : 'Last watched';

  /// Shown as Previous/Next buttons when set.
  final EpisodeRef? previous;
  final EpisodeRef? next;

  /// For tests; episodes airing after it cannot be chosen.
  final DateTime? today;

  /// Given by the bottom sheet so dragging and scrolling work together.
  final ScrollController? scrollController;

  static const _sideWidth = 420.0;

  /// Opens the panel in the layout that fits the screen.
  static Future<EpisodeRef?> show(
    BuildContext context, {
    required String seriesTitle,
    required List<EpisodeRef> episodes,
    required SeriesProgress progress,
    EpisodeRef? current,
    bool currentIsPlaying = true,
    EpisodeRef? previous,
    EpisodeRef? next,
  }) {
    final size = MediaQuery.sizeOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    EpisodePanel panel([ScrollController? controller]) => EpisodePanel(
      seriesTitle: seriesTitle,
      episodes: episodes,
      progress: progress,
      current: current,
      currentIsPlaying: currentIsPlaying,
      previous: previous,
      next: next,
      scrollController: controller,
    );
    if (size.width > size.height || size.width >= 840) {
      return showGeneralDialog<EpisodeRef>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Close episodes',
        barrierColor: Colors.black38,
        transitionDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 280),
        pageBuilder: (context, _, _) => Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: math.min(_sideWidth, math.max(300, size.width * .46)),
            height: double.infinity,
            child: SafeArea(
              left: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                child: _PanelSurface(child: panel()),
              ),
            ),
          ),
        ),
        transitionBuilder: (context, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween(
              begin: const Offset(.18, 0),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(opacity: curved, child: child),
          );
        },
      );
    }
    return showModalBottomSheet<EpisodeRef>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .62,
        minChildSize: .35,
        maxChildSize: .94,
        builder: (context, controller) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: _PanelSurface(showHandle: true, child: panel(controller)),
        ),
      ),
    );
  }

  @override
  State<EpisodePanel> createState() => _EpisodePanelState();
}

class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.child, this.showHandle = false});

  final Widget child;
  final bool showHandle;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xF2141419),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(26),
      side: const BorderSide(color: Color(0x1FFFFFFF)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        if (showHandle)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        Expanded(child: child),
      ],
    ),
  );
}

class _EpisodePanelState extends State<EpisodePanel> {
  late final ScrollController _scroll =
      widget.scrollController ?? ScrollController();
  late final List<int> _seasons = [
    for (final (index, ref) in widget.episodes.indexed)
      if (index == 0 || widget.episodes[index - 1].season != ref.season)
        ref.season,
  ];
  late int? _season =
      widget.current != null && _seasons.contains(widget.current!.season)
      ? widget.current!.season
      : _seasons.firstOrNull;
  final _currentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  @override
  void dispose() {
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
  }

  List<EpisodeRef> get _episodes =>
      widget.episodes.where((ref) => ref.season == _season).toList();

  /// Scrolls the current episode into view when its season is shown.
  ///
  /// Cards are built lazily, so a far-down episode may not exist yet: jump
  /// towards its estimated offset, and once a frame has built it, scroll it
  /// precisely into view. The list's own length estimate grows as it
  /// builds, so a few jumps may be needed.
  void _revealCurrent([int attempt = 0]) {
    final current = widget.current;
    if (!mounted || current == null || current.season != _season) return;
    final index = _episodes.indexWhere(current.isSameEpisode);
    if (index < 0 || !_scroll.hasClients) return;
    final target = _currentKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        alignment: .25,
        duration: attempt == 0 || MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (attempt >= 6) return;
    // Average card height from the list's own (growing) length estimate,
    // so the jump neither stops short nor overshoots past the card.
    final position = _scroll.position;
    final cardExtent =
        (position.maxScrollExtent + position.viewportDimension) /
        _episodes.length;
    _scroll.jumpTo(
      math.min(position.maxScrollExtent, math.max(0, (index - 1) * cardExtent)),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _revealCurrent(attempt + 1),
    );
  }

  void _selectSeason(int season) {
    if (season == _season) return;
    setState(() => _season = season);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  void _choose(EpisodeRef episode) {
    // Choosing the playing episode just closes the panel.
    final current = widget.current;
    final isPlaying =
        widget.currentIsPlaying &&
        current != null &&
        current.isSameEpisode(episode);
    Navigator.pop(context, isPlaying ? null : episode);
  }

  @override
  Widget build(BuildContext context) {
    final today = widget.today ?? DateTime.now();
    final episodes = _episodes;
    final previous = widget.previous;
    final next = widget.next;
    // The header, seasons and Previous/Next stay put; only the episodes
    // scroll, so revealing a late episode never hides the season picker.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'EPISODES',
                      style: TextStyle(
                        color: GlassTheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.8,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.seriesTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.3,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close episodes',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        if (_seasons.length > 1)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final season in _seasons)
                  Semantics(
                    selected: season == _season,
                    child: CategoryChip(
                      label: 'Season $season',
                      selected: season == _season,
                      onTap: () => _selectSeason(season),
                    ),
                  ),
              ],
            ),
          )
        else if (_season != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 4),
            child: Text(
              'Season $_season',
              style: const TextStyle(
                color: GlassTheme.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (previous != null || next != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Row(
              children: [
                Expanded(
                  child: _NavigationButton(
                    episode: previous,
                    forward: false,
                    onPressed: previous == null
                        ? null
                        : () => _choose(previous),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _NavigationButton(
                    episode: next,
                    forward: true,
                    onPressed: next == null ? null : () => _choose(next),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              if (episodes.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No episodes are listed for this series.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: GlassTheme.muted),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  // Built lazily: a long season only loads the thumbnails
                  // on screen.
                  sliver: SliverList.builder(
                    itemCount: episodes.length,
                    itemBuilder: (context, index) {
                      final episode = episodes[index];
                      final isCurrent =
                          widget.current?.isSameEpisode(episode) ?? false;
                      return _EpisodeCard(
                        key: isCurrent
                            ? _currentKey
                            : ValueKey(episode.episode),
                        episode: episode,
                        progress: widget.progress.of(
                          episode.season,
                          episode.episode,
                        ),
                        currentLabel: isCurrent ? widget.currentLabel : null,
                        aired: episode.airedBy(today),
                        onTap: () => _choose(episode),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NavigationButton extends StatelessWidget {
  const _NavigationButton({
    required this.episode,
    required this.forward,
    required this.onPressed,
  });

  final EpisodeRef? episode;
  final bool forward;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final episode = this.episode;
    final label = forward ? 'Next' : 'Previous';
    final icon = Icon(
      forward ? Icons.skip_next_rounded : Icons.skip_previous_rounded,
      size: 20,
    );
    final text = Flexible(
      child: Text(
        episode == null
            ? label
            : '$label · S${episode.season} E${episode.episode}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: episode == null
          ? 'No ${label.toLowerCase()} episode'
          : '$label episode: season ${episode.season}, episode '
                '${episode.episode}${episode.title.isEmpty ? '' : ', ${episode.title}'}',
      excludeSemantics: true,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white30,
          backgroundColor: const Color(0x14FFFFFF),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: forward ? [text, icon] : [icon, text],
        ),
      ),
    );
  }
}

class _EpisodeCard extends StatefulWidget {
  const _EpisodeCard({
    super.key,
    required this.episode,
    required this.progress,
    required this.currentLabel,
    required this.aired,
    required this.onTap,
  });

  final EpisodeRef episode;
  final EpisodeProgress? progress;

  /// `Playing` or `Last watched` on the current episode; null otherwise.
  final String? currentLabel;
  final bool aired;
  final VoidCallback onTap;

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _expanded = false;

  static String _date(DateTime date) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final progress = widget.progress;
    final current = widget.currentLabel != null;
    final accent = GlassTheme.primary;
    final runtime = episode.runtimeMinutes == null
        ? ''
        : PauseCardContent.formatRuntime(
            Duration(minutes: episode.runtimeMinutes!),
          );
    final status = !widget.aired
        ? (episode.airDate == null
              ? 'Not aired yet'
              : 'Airs ${_date(episode.airDate!)}')
        : progress == null
        ? ''
        : progress.isWatched
        ? 'Watched'
        : progress.isInProgress
        ? (progress.timeLeft.isEmpty ? 'Started' : progress.timeLeft)
        : '';
    final meta = [runtime, status].where((s) => s.isNotEmpty).join(' · ');
    final longSynopsis = episode.overview.length > 110;
    final semantics = [
      'Season ${episode.season}, episode ${episode.episode}',
      if (episode.title.isNotEmpty) episode.title,
      if (runtime.isNotEmpty) runtime,
      if (current) widget.currentLabel!,
      if (status.isNotEmpty) status,
      if (progress != null && progress.isInProgress)
        '${(progress.fraction * 100).round()} percent watched',
    ].join('. ');

    final card = Material(
      color: current ? accent.withValues(alpha: .10) : const Color(0x0AFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: current ? accent.withValues(alpha: .7) : Colors.transparent,
          width: 1.2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.aired ? widget.onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(
                url: episode.thumbnail,
                progress: progress,
                current: current,
                dimmed: !widget.aired,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Wraps rather than overflows on narrow panels with
                    // large text.
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'E${episode.episode.toString().padLeft(2, '0')}',
                          style: TextStyle(
                            color: current ? accent : GlassTheme.muted,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .6,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (current) ...[
                          _CurrentBadge(label: widget.currentLabel!),
                        ],
                        if (!current && (progress?.isWatched ?? false)) ...[
                          const Icon(
                            Icons.check_circle_rounded,
                            size: 14,
                            color: Colors.white54,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      episode.title.isEmpty
                          ? 'Episode ${episode.episode}'
                          : episode.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: widget.aired ? Colors.white : Colors.white54,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GlassTheme.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (episode.overview.isNotEmpty)
                      Padding(
                        // Room on the right for the expand button.
                        padding: EdgeInsets.only(
                          top: 5,
                          right: longSynopsis ? 30 : 0,
                        ),
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: Text(
                            episode.overview,
                            maxLines: _expanded ? 8 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xB3FFFFFF),
                              fontSize: 12.5,
                              height: 1.4,
                            ),
                          ),
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

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Stack(
        children: [
          // The card reads as one item; the expand button stays a separate,
          // reachable control.
          Semantics(
            button: widget.aired,
            enabled: widget.aired,
            selected: current,
            label: semantics,
            excludeSemantics: true,
            child: card,
          ),
          if (longSynopsis)
            Positioned(
              right: 2,
              bottom: 0,
              child: Semantics(
                button: true,
                label: _expanded ? 'Show less' : 'Show full synopsis',
                excludeSemantics: true,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                  color: Colors.white60,
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: AnimatedRotation(
                    turns: _expanded ? .5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.expand_more_rounded),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// `▶ PLAYING`: an icon and a word as well as the accent color.
class _CurrentBadge extends StatelessWidget {
  const _CurrentBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: GlassTheme.primary,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            label == 'Playing'
                ? Icons.equalizer_rounded
                : Icons.history_rounded,
            size: 12,
            color: GlassTheme.background,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: GlassTheme.background,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: .6,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 16:9 episode still with progress along its bottom edge.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.url,
    required this.progress,
    required this.current,
    required this.dimmed,
  });

  static const width = 124.0;

  final String url;
  final EpisodeProgress? progress;
  final bool current;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: GlassTheme.elevatedSurface,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: Colors.white.withValues(alpha: .28),
          size: 26,
        ),
      ),
    );
    final progress = this.progress;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url.isEmpty)
              placeholder
            else
              Image.network(
                url,
                fit: BoxFit.cover,
                // A 300 px still, decoded at the size it is shown.
                cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                excludeFromSemantics: true,
                frameBuilder: (context, child, frame, synchronous) =>
                    synchronous
                    ? child
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: frame == null ? placeholder : child,
                      ),
                errorBuilder: (_, _, _) => placeholder,
              ),
            if (dimmed) const ColoredBox(color: Color(0x99000000)),
            if (current)
              const ColoredBox(
                color: Color(0x59000000),
                child: Center(
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            if (progress != null &&
                (progress.isInProgress || progress.isWatched))
              Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: 3,
                  child: LinearProgressIndicator(
                    value: progress.isWatched ? 1 : progress.fraction,
                    backgroundColor: const Color(0x66000000),
                    color: progress.isWatched
                        ? Colors.white70
                        : GlassTheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
