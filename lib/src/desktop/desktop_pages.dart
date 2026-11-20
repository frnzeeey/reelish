import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../theme/reelish_icons.dart';

import '../discovery/discovery_data.dart';
import '../discovery/discovery_engine.dart';
import '../models/media_item.dart';
import '../viewmodels/home_catalog.dart';
import '../viewmodels/home_view_model.dart';
import '../services/paged_feed_controller.dart';
import '../services/storage_service.dart';
import '../theme/glass_theme.dart';
import '../viewmodels/library_view_model.dart';
import '../widgets/discovery_prompt_card.dart';
import '../widgets/settings/tmdb_attribution.dart';
import 'desktop_collections.dart';
import 'desktop_hero.dart';
import 'desktop_top_ten.dart';
import 'desktop_widgets.dart';

/// Desktop Home: the featured hero, then the catalog rows Home loads on
/// every platform. Rows below the fold are built, and so load, only as the
/// page nears them.
class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({
    super.key,
    required this.catalog,
    required this.onOpen,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.onRetry,
    required this.onAddSource,
    this.onJoinParty,
    this.onChooseGenres,
    this.onDismissGenres,
  });

  final TvCatalog catalog;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPlay;

  /// Open the genre step / dismiss its card, when
  /// [TvCatalog.showGenrePrompt] offers it.
  final VoidCallback? onChooseGenres, onDismissGenres;
  final Future<bool> Function(MediaItem item) onToggleFavorite;
  final VoidCallback onRetry;
  final VoidCallback onAddSource;

  /// Opens Join a party; without it Home has no Watch together row.
  final VoidCallback? onJoinParty;

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _DesktopHomePageState extends State<DesktopHomePage> {
  List<MediaItem> _trending = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadTrending());
  }

  /// Served from the TMDB cache when fresh, as on TV.
  Future<void> _loadTrending() async {
    void apply(List<MediaItem> items) {
      if (mounted) setState(() => _trending = items);
    }

    try {
      apply(await widget.catalog.tmdb.trending(onRevalidated: apply));
    } catch (_) {
      // An extra row; Home works without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final catalogEmpty =
        catalog.movies.state.items.isEmpty &&
        catalog.series.state.items.isEmpty;
    final error = catalog.catalogError;
    if (catalogEmpty && error != null) {
      return DesktopMessage(
        icon: ReelishIcons.offline,
        title: 'Could not load titles',
        message: error,
        actionLabel: 'Retry',
        onAction: widget.onRetry,
      );
    }
    final spotlight = catalog.spotlight.isNotEmpty
        ? catalog.spotlight
        : catalog.movies.state.items.take(5).toList();
    final rows = <Widget>[
      if (spotlight.isNotEmpty)
        DesktopHero(
          key: const ValueKey('hero'),
          items: spotlight,
          onPlay: widget.onPlay,
          onDetails: widget.onOpen,
          isFavorite: catalog.isFavorite,
          onToggleFavorite: widget.onToggleFavorite,
          logoOf: catalog.tmdb.logo,
        )
      else
        const SizedBox(key: ValueKey('hero-space'), height: 32),
      // With no source yet, how to get one comes first: under Top 10 it was
      // below the fold of a 1280 × 720 window.
      if (!catalog.hasSources)
        _AddSourceBanner(
          key: const ValueKey('add-source'),
          onAddSource: widget.onAddSource,
        ),
      // Windows shows Top 10 right under the Spotlight; phone and TV Home
      // keep it further down. It still loads only once Movies and Series
      // (its seeds) have, showing its placeholders until then.
      DesktopTopTenRow(
        key: const ValueKey('row:top10'),
        feed: catalog.top10,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        onToggleFavorite: widget.onToggleFavorite,
        loadWhenShown: catalog.catalogSettled,
      ),
      if (catalog.showGenrePrompt)
        if ((widget.onChooseGenres, widget.onDismissGenres) case (
          final onChoose?,
          final onDismiss?,
        ))
          DiscoveryPromptCard(
            key: const ValueKey('genre-prompt'),
            onChoose: onChoose,
            onDismiss: onDismiss,
            padding: const EdgeInsets.fromLTRB(
              DesktopMetrics.pagePadding,
              8,
              DesktopMetrics.pagePadding,
              8,
            ),
          ),
      // Personalised rows, right under Top 10; none on a cold start.
      if (catalog.discovery case final discovery?)
        for (final section in discovery.sections)
          DesktopMediaRow(
            key: ValueKey('row:discovery:${section.id}'),
            title: section.title,
            items: section.items,
            onOpen: widget.onOpen,
            isFavorite: catalog.isFavorite,
            onToggleFavorite: widget.onToggleFavorite,
            // The mixed row says why each title is there; the others say
            // it in their title.
            captionOf: section.kind == DiscoverySectionKind.forYou
                ? section.reasonFor
                : null,
            removeLabel: 'Not interested',
            onRemove: (item) =>
                discovery.giveFeedback(FeedbackKind.notInterested, item),
          ),
      // Continue watching is in the sidebar on Windows, not a row here.
      if (_trending.isNotEmpty)
        DesktopMediaRow(
          key: const ValueKey('row:trending'),
          title: 'Trending now',
          items: HomeViewModel.distinctTrending([
            for (final section
                in catalog.discovery?.sections ?? const <DiscoverySection>[])
              ...section.items,
            ...catalog.top10.state.items,
          ], _trending),
          onOpen: widget.onOpen,
          isFavorite: catalog.isFavorite,
          onToggleFavorite: widget.onToggleFavorite,
        ),
      if (widget.onJoinParty case final onJoin?)
        _WatchTogetherRow(key: const ValueKey('join-party'), onJoin: onJoin),
      DesktopPagedRow(
        key: const ValueKey('row:movies'),
        title: 'New movies',
        feed: catalog.movies,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        onToggleFavorite: widget.onToggleFavorite,
      ),
      DesktopPagedRow(
        key: const ValueKey('row:series'),
        title: 'Series worth the queue',
        feed: catalog.series,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        onToggleFavorite: widget.onToggleFavorite,
      ),
      DesktopPagedRow(
        key: const ValueKey('row:releases'),
        title: 'New releases',
        feed: catalog.releases,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        onToggleFavorite: widget.onToggleFavorite,
        loadWhenShown: catalog.catalogSettled,
      ),
      const Padding(
        key: ValueKey('footer'),
        padding: EdgeInsets.fromLTRB(
          DesktopMetrics.pagePadding,
          32,
          DesktopMetrics.pagePadding,
          40,
        ),
        child: TmdbAttributionFooter(),
      ),
    ];
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: rows.length,
      // Rows keep their state when one above appears or goes.
      findChildIndexCallback: (key) {
        final index = rows.indexWhere((row) => row.key == key);
        return index < 0 ? null : index;
      },
      itemBuilder: (context, index) => rows[index],
    );
  }
}

class _AddSourceBanner extends StatelessWidget {
  const _AddSourceBanner({super.key, required this.onAddSource});

  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      DesktopMetrics.pagePadding,
      12,
      DesktopMetrics.pagePadding,
      0,
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: GlassTheme.primary.withValues(alpha: .25)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        child: Row(
          children: [
            Icon(ReelishIcons.link, color: GlassTheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add a source to start watching',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Reelish plays titles through plugins you choose. Browsing '
                    'works without one.',
                    style: TextStyle(color: GlassTheme.muted),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: onAddSource,
              icon: const Icon(ReelishIcons.add),
              label: const Text('Add a source'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Watch Party on Home: what it is, how to start one, and the way in with a
/// code, which Together and Settings offer too.
class _WatchTogetherRow extends StatelessWidget {
  const _WatchTogetherRow({super.key, required this.onJoin});

  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      DesktopMetrics.pagePadding,
      12,
      DesktopMetrics.pagePadding,
      0,
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: DesktopSurfaces.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        child: Row(
          children: [
            Icon(ReelishIcons.people, color: GlassTheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Watch together',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Have a code? Join a friend’s party. To host, open a title '
                    'and choose Watch together.',
                    style: TextStyle(color: GlassTheme.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            OutlinedButton.icon(
              onPressed: onJoin,
              icon: const Icon(ReelishIcons.dialpad),
              label: const Text('Join with a code'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Movies or Series: the whole paged feed as a grid that loads more as it
/// is scrolled.
class DesktopCatalogPage extends StatefulWidget {
  const DesktopCatalogPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.feed,
    required this.onOpen,
    required this.isFavorite,
    this.onToggleFavorite,
  });

  final String title;
  final String subtitle;
  final PagedFeedController feed;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item) isFavorite;
  final Future<void> Function(MediaItem item)? onToggleFavorite;

  @override
  State<DesktopCatalogPage> createState() => _DesktopCatalogPageState();
}

class _DesktopCatalogPageState extends State<DesktopCatalogPage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => unawaited(widget.feed.ensureLoaded()),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final position = _scroll.position;
    if (position.extentAfter < position.viewportDimension &&
        widget.feed.state.hasMore) {
      unawaited(widget.feed.loadMore());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.feed,
    builder: (context, _) {
      final state = widget.feed.state;
      if (state.items.isNotEmpty && state.hasMore && !state.isLoadingMore) {
        loadMoreIfShort(_scroll, () => unawaited(widget.feed.loadMore()));
      }
      return CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: DesktopPageHeader(
              title: widget.title,
              subtitle: widget.subtitle,
            ),
          ),
          if (state.items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: state.status == PagedFeedStatus.failed
                  ? DesktopMessage(
                      icon: ReelishIcons.offline,
                      title: 'Could not load ${widget.title.toLowerCase()}',
                      message: 'Check your connection and try again.',
                      actionLabel: 'Retry',
                      onAction: () => unawaited(widget.feed.retry()),
                    )
                  : const Center(child: CircularProgressIndicator()),
            )
          else
            DesktopPosterGrid(
              items: state.items,
              onOpen: widget.onOpen,
              isFavorite: widget.isFavorite,
              onToggleFavorite: widget.onToggleFavorite,
              // One feed, one kind: the page title already says which.
              showType: false,
            ),
          if (state.isLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 40),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      );
    },
  );
}

/// My library: continue watching, My list and history, from local storage.
class DesktopLibraryPage extends StatefulWidget {
  const DesktopLibraryPage({
    super.key,
    required this.storage,
    required this.onOpen,
    required this.refreshToken,
    this.onToggleFavorite,
    this.onHistoryChanged,
  });

  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;

  /// Changes whenever the library may have changed (playback, My list).
  final int refreshToken;

  /// Home's My list toggle, so Home and the library agree; the library
  /// reloads afterwards. Without it, the library saves the change itself.
  final Future<bool> Function(MediaItem item)? onToggleFavorite;

  /// Told after a title is removed from the watch history here, so Home's
  /// Continue watching row follows.
  final VoidCallback? onHistoryChanged;

  @override
  State<DesktopLibraryPage> createState() => _DesktopLibraryPageState();
}

class _DesktopLibraryPageState extends State<DesktopLibraryPage> {
  late final _model = LibraryViewModel(storage: widget.storage);

  // The page renders from the shared LibraryViewModel.
  List<MediaItem> get _history => _model.history;
  List<MediaItem> get _favorites => _model.favorites;
  bool get _loading => _model.loading;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
    unawaited(_model.load());
  }

  @override
  void didUpdateWidget(covariant DesktopLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      unawaited(_model.load());
    }
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _model.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  double _progress(MediaItem item) => _model.resumeSummary(item).fraction;

  Future<void> _toggleFavorite(MediaItem item) async {
    final toggle = widget.onToggleFavorite;
    if (toggle == null) return _model.toggleFavorite(item);
    await toggle(item);
    await _model.load();
  }

  /// Removes [item]'s watch history (and so its resume point), as the phone
  /// library's Remove does. My list is not touched.
  Future<void> _removeFromHistory(MediaItem item) async {
    final index = _model.historyIndexOf(item);
    try {
      await _model.removeFromHistory(item);
    } catch (_) {
      _say('Could not remove it. Try again.');
      return;
    }
    widget.onHistoryChanged?.call();
    // Delete on a poster removes a resume point, so it can be taken back.
    _say(
      '${item.name} removed from your history',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => unawaited(_restoreToHistory(item, index)),
      ),
    );
  }

  Future<void> _restoreToHistory(MediaItem item, int index) async {
    try {
      await _model.restoreToHistory(item, index);
    } catch (_) {
      _say('Could not put it back. Try again.');
      return;
    }
    widget.onHistoryChanged?.call();
  }

  void _say(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final continuing = _model.continueWatching;
    final favoriteKeys = {
      for (final item in _favorites) '${item.type}:${item.id}',
    };
    bool isFavorite(MediaItem item) =>
        favoriteKeys.contains('${item.type}:${item.id}');
    final rows = [
      if (continuing.isNotEmpty)
        DesktopMediaRow(
          title: 'Continue watching',
          items: continuing,
          landscape: true,
          onOpen: widget.onOpen,
          progressOf: _progress,
          captionOf: (item) => _model.resumeSummary(item).label,
          isFavorite: isFavorite,
          onToggleFavorite: _toggleFavorite,
          onRemove: _removeFromHistory,
        ),
      if (_favorites.isNotEmpty)
        DesktopMediaRow(
          title: 'My list',
          items: _favorites,
          onOpen: widget.onOpen,
          isFavorite: isFavorite,
          onToggleFavorite: _toggleFavorite,
        )
      else if (_history.isNotEmpty)
        // Say where saved titles go, rather than leaving the list out.
        const _LibraryHint(
          title: 'My list',
          icon: ReelishIcons.bookmarkAdd,
          message:
              'Nothing saved yet. Choose My list on any title, or press F '
              'on a poster, to keep it here.',
        ),
      if (_history.isNotEmpty)
        DesktopMediaRow(
          title: 'Watch history',
          items: _history,
          onOpen: widget.onOpen,
          isFavorite: isFavorite,
          onToggleFavorite: _toggleFavorite,
          onRemove: _removeFromHistory,
        ),
      DesktopCollectionsSection(
        model: _model,
        storage: widget.storage,
        onOpen: widget.onOpen,
        isFavorite: isFavorite,
        onToggleFavorite: _toggleFavorite,
      ),
    ];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: DesktopPageHeader(
            title: 'My library',
            subtitle: 'Everything you are watching and saving.',
            trailing: _history.isEmpty && _favorites.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _LibraryStat(
                        count: continuing.length,
                        label: 'In progress',
                        icon: ReelishIcons.playCircle,
                      ),
                      const SizedBox(width: 10),
                      _LibraryStat(
                        count: _favorites.length,
                        label: 'On My list',
                        icon: ReelishIcons.bookmark,
                      ),
                      const SizedBox(width: 10),
                      _LibraryStat(
                        count: _history.length,
                        label: 'Watched',
                        icon: ReelishIcons.history,
                      ),
                    ],
                  ),
          ),
        ),
        if (rows.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: DesktopMessage(
              icon: ReelishIcons.bookmark,
              title: 'Nothing here yet',
              message:
                  'Titles you watch, and titles you add to My list from a '
                  'details page, appear here.',
            ),
          )
        else
          SliverList.list(children: [...rows, const SizedBox(height: 40)]),
      ],
    );
  }
}

/// A count in the library header: what is in progress, saved and watched.
class _LibraryStat extends StatelessWidget {
  const _LibraryStat({
    required this.count,
    required this.label,
    required this.icon,
  });

  final int count;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$count $label',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: GlassTheme.textPrimary.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DesktopSurfaces.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              ReelishIcons.filled(icon),
              size: 20,
              color: GlassTheme.primary,
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 18,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: GlassTheme.muted),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// A library section with nothing in it yet, saying how to fill it.
class _LibraryHint extends StatelessWidget {
  const _LibraryHint({
    required this.title,
    required this.icon,
    required this.message,
  });

  final String title;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DesktopSectionTitle(title),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          DesktopMetrics.pagePadding,
          12,
          DesktopMetrics.pagePadding,
          8,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: GlassTheme.textPrimary.withValues(alpha: .03),
            borderRadius: BorderRadius.circular(DesktopSurfaces.radius),
            border: Border.all(color: DesktopSurfaces.hairline),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: GlassTheme.primary.withValues(alpha: .14),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(icon, size: 22, color: GlassTheme.primary),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: GlassTheme.muted, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
