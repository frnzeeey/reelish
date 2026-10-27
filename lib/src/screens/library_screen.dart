import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/media_item.dart';
import '../models/resume_summary.dart';
import '../services/storage_service.dart';
import '../theme/glass_theme.dart';
import '../viewmodels/library_view_model.dart';
import '../widgets/media_card.dart';

enum _LibraryFilter { all, continueWatching, favorites }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.storage,
    required this.onPlay,
    this.refreshToken = 0,
    this.onHistoryChanged,
    this.onFavoritesChanged,
  });

  final StorageService storage;
  final ValueChanged<MediaItem> onPlay;
  final int refreshToken;

  /// After a title's watch history was removed and saved, so Home's
  /// Continue watching follows at once (the Windows library does the same).
  final VoidCallback? onHistoryChanged;

  /// After My list changed and was saved, so Home's hearts follow.
  final VoidCallback? onFavoritesChanged;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final _model = LibraryViewModel(storage: widget.storage);
  _LibraryFilter _filter = _LibraryFilter.all;

  // The page renders from the shared LibraryViewModel.
  List<MediaItem> get _history => _model.history;
  List<MediaItem> get _favorites => _model.favorites;
  bool get _loading => _model.loading;

  List<MediaItem> get _continueWatching =>
      _history.where((item) => item.resumeMs > 0).toList();

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) unawaited(_load());
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

  Future<void> _load() => _model.load();
  ResumeSummary _resumeSummary(MediaItem item) => _model.resumeSummary(item);
  // Home is told only once the change is saved. A failed one says so (as on
  // Windows) and the library shows what is saved, which is unchanged.
  Future<void> _removeHistory(MediaItem item) async {
    try {
      await _model.removeFromHistory(item);
    } catch (_) {
      _failed('Could not remove it. Try again.');
      return;
    }
    widget.onHistoryChanged?.call();
  }

  Future<void> _toggleFavorite(MediaItem item) async {
    try {
      await _model.toggleFavorite(item);
    } catch (_) {
      _failed('Could not update My list. Try again.');
      return;
    }
    widget.onFavoritesChanged?.call();
  }

  void _failed(String message) {
    unawaited(_load().catchError((Object _) {}));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final continuing = _continueWatching;
    return Scaffold(
      body: _loading
          ? Center(child: CircularProgressIndicator(color: GlassTheme.primary))
          : RefreshIndicator(
              onRefresh: _load,
              color: GlassTheme.primary,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: _LibraryHeader(
                        historyCount: _history.length,
                        favoriteCount: _favorites.length,
                        onRefresh: _load,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 74,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                        children: [
                          _FilterChip(
                            label: 'Everything',
                            count: _history.length + _favorites.length,
                            selected: _filter == _LibraryFilter.all,
                            onTap: () =>
                                setState(() => _filter = _LibraryFilter.all),
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: 'Continue',
                            count: continuing.length,
                            selected:
                                _filter == _LibraryFilter.continueWatching,
                            onTap: () => setState(
                              () => _filter = _LibraryFilter.continueWatching,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: 'Favorites',
                            count: _favorites.length,
                            selected: _filter == _LibraryFilter.favorites,
                            onTap: () => setState(
                              () => _filter = _LibraryFilter.favorites,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_filter == _LibraryFilter.all ||
                      _filter == _LibraryFilter.continueWatching)
                    SliverToBoxAdapter(
                      child: _MediaSection(
                        title: 'Continue watching',
                        subtitle: 'Pick up where you left off',
                        items: continuing,
                        emptyTitle: 'Nothing in progress',
                        emptyMessage:
                            'Titles you pause while watching will show up here.',
                        onPlay: widget.onPlay,
                        onRemove: _removeHistory,
                        resumeOf: _resumeSummary,
                      ),
                    ),
                  if (_filter == _LibraryFilter.all ||
                      _filter == _LibraryFilter.favorites)
                    SliverToBoxAdapter(
                      child: _MediaSection(
                        title: 'Your favorites',
                        subtitle: 'Saved for another night',
                        items: _favorites,
                        emptyTitle: 'Your watchlist is waiting',
                        emptyMessage:
                            'Save a movie or series from its details page and it will appear here.',
                        onPlay: widget.onPlay,
                        onFavorite: _toggleFavorite,
                        favorite: true,
                      ),
                    ),
                  if (_filter == _LibraryFilter.all)
                    SliverToBoxAdapter(
                      child: _MediaSection(
                        title: 'Recently watched',
                        subtitle: 'Your latest activity',
                        items: _history,
                        emptyTitle: 'Your history is clear',
                        emptyMessage:
                            'Start watching something and it will be listed here.',
                        onPlay: widget.onPlay,
                        onRemove: _removeHistory,
                        resumeOf: _resumeSummary,
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 128)),
                ],
              ),
            ),
    );
  }
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({
    required this.historyCount,
    required this.favoriteCount,
    required this.onRefresh,
  });

  final int historyCount;
  final int favoriteCount;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YOUR SPACE',
                  style: TextStyle(
                    color: GlassTheme.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.8,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'My library',
                  style: TextStyle(
                    fontSize: 30,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.8,
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: 'Refresh library',
            onPressed: onRefresh,
            style: IconButton.styleFrom(
              foregroundColor: GlassTheme.primary,
              backgroundColor: GlassTheme.primary.withValues(alpha: .1),
            ),
            icon: const Icon(Symbols.refresh_rounded),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'Everything you are watching and saving, all in one place.',
        style: TextStyle(color: GlassTheme.muted, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 17),
      Row(
        children: [
          _LibraryStat(
            icon: Symbols.play_circle_rounded,
            value: '$historyCount',
            label: 'watched',
          ),
          const SizedBox(width: 9),
          _LibraryStat(
            icon: Symbols.favorite_rounded,
            value: '$favoriteCount',
            label: 'saved',
          ),
        ],
      ),
    ],
  );
}

class _LibraryStat extends StatelessWidget {
  const _LibraryStat({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: GlassTheme.primary),
        const SizedBox(width: 7),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: GlassTheme.muted),
        ),
      ],
    ),
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? GlassTheme.primary : GlassTheme.surface,
    borderRadius: BorderRadius.circular(30),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(30),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: selected ? GlassTheme.primary : GlassTheme.border,
          ),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? GlassTheme.background : GlassTheme.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: selected
                    ? GlassTheme.background.withValues(alpha: .12)
                    : Colors.white.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: selected ? GlassTheme.background : GlassTheme.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MediaSection extends StatelessWidget {
  const _MediaSection({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.onPlay,
    this.onRemove,
    this.onFavorite,
    this.favorite = false,
    this.resumeOf,
  });

  final String title;
  final String subtitle;
  final List<MediaItem> items;
  final String emptyTitle;
  final String emptyMessage;
  final ValueChanged<MediaItem> onPlay;
  final ValueChanged<MediaItem>? onRemove;
  final ValueChanged<MediaItem>? onFavorite;
  final bool favorite;

  /// Real progress for watch-history cards; null for other sections.
  final ResumeSummary Function(MediaItem item)? resumeOf;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: GlassTheme.muted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              if (items.isNotEmpty)
                Text(
                  '${items.length} ${items.length == 1 ? 'title' : 'titles'}',
                  style: const TextStyle(
                    color: GlassTheme.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _LibraryEmptyState(
              title: emptyTitle,
              message: emptyMessage,
              icon: favorite
                  ? Symbols.favorite_rounded
                  : Symbols.movie_filter_rounded,
            ),
          )
        else
          SizedBox(
            height: 264,
            // Cards never overlap; the row shares one backdrop blur pass.
            child: BackdropGroup(
              child: ListView.separated(
                key: PageStorageKey<String>('library-row-$title'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final resume = item.resumeMs > 0
                      ? resumeOf?.call(item) ?? ResumeSummary.unknown
                      : ResumeSummary.unknown;
                  return Stack(
                    children: [
                      MediaCard(
                        item: item,
                        isFavorite: favorite,
                        onTap: () => onPlay(item),
                        progress: resume.fraction,
                        // Remove takes the badge's corner.
                        showTypeBadge: onRemove == null,
                        onFavorite: favorite && onFavorite != null
                            ? () => onFavorite!(item)
                            : null,
                      ),
                      if (title == 'Continue watching')
                        Positioned(
                          left: 7,
                          top: 7,
                          // Ends before the Remove button, so a long label
                          // (or large text) shortens instead of covering it.
                          right: onRemove == null ? 7 : 7 + 34 + 6,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .7),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: .15),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Symbols.play_arrow_rounded,
                                    fill: 1,
                                    size: 12,
                                    color: GlassTheme.primary,
                                  ),
                                  const SizedBox(width: 3),
                                  Flexible(
                                    child: Text(
                                      resume.label.isEmpty
                                          ? 'RESUME'
                                          : resume.label.toUpperCase(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // Last, so it is always on top and can be tapped.
                      if (onRemove != null)
                        Positioned(
                          top: 7,
                          right: 7,
                          child: Material(
                            color: Colors.black.withValues(alpha: .72),
                            shape: const CircleBorder(),
                            child: IconButton(
                              tooltip: 'Remove from watch history',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints.tightFor(
                                width: 34,
                                height: 34,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const Icon(Symbols.close_rounded, size: 17),
                              onPressed: () => onRemove!(item),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
      ],
    ),
  );
}

class _LibraryEmptyState extends StatelessWidget {
  const _LibraryEmptyState({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: GlassTheme.primary.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, size: 19, color: GlassTheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                style: const TextStyle(
                  color: GlassTheme.muted,
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
