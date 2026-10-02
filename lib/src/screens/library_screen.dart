import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/storage_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/media_card.dart';

enum _LibraryFilter { all, continueWatching, favorites }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.storage,
    required this.onPlay,
    this.refreshToken = 0,
  });

  final StorageService storage;
  final ValueChanged<MediaItem> onPlay;
  final int refreshToken;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<MediaItem> _history = [];
  List<MediaItem> _favorites = [];
  bool _loading = true;
  _LibraryFilter _filter = _LibraryFilter.all;

  List<MediaItem> get _continueWatching =>
      _history.where((item) => item.resumeMs > 0).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) unawaited(_load());
  }

  Future<void> _load() async {
    final values = await Future.wait([
      widget.storage.history(),
      widget.storage.favorites(),
    ]);
    if (!mounted) return;
    setState(() {
      _history = values[0];
      _favorites = values[1];
      _loading = false;
    });
  }

  Future<void> _removeHistory(MediaItem item) async {
    await widget.storage.removeHistory(item);
    await _load();
  }

  Future<void> _toggleFavorite(MediaItem item) async {
    await widget.storage.toggleFavorite(item);
    await _load();
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
                            onTap: () => setState(() => _filter = _LibraryFilter.all),
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: 'Continue',
                            count: continuing.length,
                            selected: _filter == _LibraryFilter.continueWatching,
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
            icon: const Icon(Icons.refresh_rounded),
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
            icon: Icons.play_circle_outline_rounded,
            value: '$historyCount',
            label: 'watched',
          ),
          const SizedBox(width: 9),
          _LibraryStat(
            icon: Icons.favorite_border_rounded,
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
        Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11, color: GlassTheme.muted)),
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
                  fontSize: 9,
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
                  ? Icons.favorite_border_rounded
                  : Icons.movie_filter_outlined,
            ),
          )
        else
          SizedBox(
            height: 264,
            child: ListView.separated(
              key: PageStorageKey<String>('library-row-$title'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return Stack(
                  children: [
                    MediaCard(
                      item: item,
                      onTap: () => onPlay(item),
                      onFavorite: favorite && onFavorite != null
                          ? () => onFavorite!(item)
                          : null,
                    ),
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
                            icon: const Icon(Icons.close_rounded, size: 17),
                            onPressed: () => onRemove!(item),
                          ),
                        ),
                      ),
                    if (title == 'Continue watching')
                      Positioned(
                        left: 7,
                        top: 7,
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
                                Icons.play_arrow_rounded,
                                size: 12,
                                color: GlassTheme.primary,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                _resumeLabel(item.resumeMs),
                                style: const TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
      ],
    ),
  );
}

String _resumeLabel(int positionMs) {
  final totalMinutes = positionMs ~/ 60000;
  if (totalMinutes >= 60) {
    return 'PAUSED AT ${totalMinutes ~/ 60}H ${totalMinutes % 60}M';
  }
  return 'PAUSED AT ${totalMinutes}M';
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
              Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
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
