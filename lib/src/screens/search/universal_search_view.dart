// Universal Search: one place to find movies, series, people and movie
// collections, with genre, year and rating filters and, for the best match,
// whether the viewer's providers list sources. The Search page on TV and
// Windows, and a full-screen page on phones (UniversalSearchScreen). Titles
// open the existing details pages; people and collections open their own.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../discovery/tmdb_genres.dart';
import '../../models/media_item.dart';
import '../../navigation/app_transitions.dart';
import '../../platform/device_capabilities.dart';
import '../../search/playback_availability.dart';
import '../../search/search_models.dart';
import '../../search/universal_search_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/tv/tv_focus.dart';
import 'search_cards.dart';
import 'search_detail_screens.dart';
import 'search_filter_bar.dart';
import 'source_availability.dart';

class UniversalSearchView extends StatefulWidget {
  const UniversalSearchView({
    super.key,
    required this.search,
    required this.onOpenTitle,
    this.availability,
    this.leading,
    this.autofocus = true,
  });

  final UniversalSearchController search;

  /// Opens a movie or series on its existing details page.
  final ValueChanged<MediaItem> onOpenTitle;

  /// Playback discovery for the top result; null hides it.
  final PlaybackAvailability? availability;

  /// Before the search field (the phone page's close button).
  final Widget? leading;
  final bool autofocus;

  @override
  State<UniversalSearchView> createState() => _UniversalSearchViewState();
}

class _UniversalSearchViewState extends State<UniversalSearchView> {
  final _field = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Universal search');
  Object? _checkedTop;

  UniversalSearchController get _search => widget.search;

  @override
  void initState() {
    super.initState();
    _field.text = _search.query;
    _search.addListener(_onSearch);
  }

  @override
  void dispose() {
    _search.removeListener(_onSearch);
    widget.availability?.cancel();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A new query stops the previous source check; a settled one with a
  /// movie as its best match asks the providers about it.
  void _onSearch() {
    final availability = widget.availability;
    if (availability == null) return;
    if (_search.status == SearchStatus.loading) {
      availability.cancel();
      _checkedTop = null;
      return;
    }
    final top = _search.overview.top;
    if (_search.status == SearchStatus.ready &&
        top is MediaItem &&
        PlaybackAvailability.canCheck(top) &&
        !identical(top, _checkedTop)) {
      _checkedTop = top;
      availability.check(top);
    }
  }

  void _typed(String text) {
    setState(() {});
    _search.queryChanged(text);
  }

  void _searchFor(String text) {
    _field.text = text;
    _field.selection = TextSelection.collapsed(offset: text.length);
    setState(() {});
    unawaited(_search.search(text));
  }

  void _clear() {
    _field.clear();
    setState(() {});
    _search.clear();
    if (!DeviceCapabilities.isTv) _focus.requestFocus();
  }

  Future<void> _openPerson(PersonHit person) => Navigator.push(
    context,
    AppPageRoute<void>(
      context: context,
      builder: (_) => PersonScreen(
        id: person.id,
        name: person.name,
        load: _search.person,
        onOpenTitle: widget.onOpenTitle,
      ),
    ),
  );

  Future<void> _openCollection(CollectionHit collection) => Navigator.push(
    context,
    AppPageRoute<void>(
      context: context,
      builder: (_) => CollectionScreen(
        id: collection.id,
        name: collection.name,
        load: _search.collection,
        onOpenTitle: widget.onOpenTitle,
      ),
    ),
  );

  void _open(Object result) => switch (result) {
    MediaItem() => widget.onOpenTitle(result),
    PersonHit() => unawaited(_openPerson(result)),
    CollectionHit() => unawaited(_openCollection(result)),
    _ => null,
  };

  // Windows: the same left edge as the other pages (DesktopMetrics.pagePadding).
  EdgeInsets get _gutter => EdgeInsets.symmetric(
    horizontal: DeviceCapabilities.isTv
        ? 48
        : DeviceCapabilities.isDesktop
        ? 40
        : AppSpace.md,
  );

  /// The search field's width on Windows, so it does not run the width of a
  /// large monitor. Phone and TV keep the full width.
  static const _desktopFieldWidth = 880.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _search,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          // Windows: the field where the other pages put their title.
          padding: _gutter.copyWith(
            top: DeviceCapabilities.isDesktop ? AppSpace.xl : AppSpace.sm,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: DeviceCapabilities.isDesktop
                    ? _desktopFieldWidth
                    : double.infinity,
              ),
              child: Row(
                children: [
                  ?widget.leading,
                  Expanded(child: _input()),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        _Categories(
          selected: _search.category,
          onSelected: _search.setCategory,
          padding: _gutter,
        ),
        if (_search.category.filterable)
          Padding(
            padding: _gutter.copyWith(top: AppSpace.xs),
            child: SearchFilterBar(
              filters: _search.filters,
              genres: _search.genres,
              onChanged: _search.setFilters,
            ),
          ),
        const SizedBox(height: AppSpace.sm),
        Expanded(child: _body()),
      ],
    ),
  );

  Widget _input() {
    const hint = 'Movies, series, people, collections';
    if (DeviceCapabilities.isTv) {
      return TvTextField(
        value: _field.text,
        hint: hint,
        title: 'Search',
        icon: ReelishIcons.search,
        textInputAction: TextInputAction.search,
        autofocus: widget.autofocus,
        onChanged: (text) {
          _field.text = text;
          _typed(text);
        },
        onSubmitted: _searchFor,
      );
    }
    return TextField(
      controller: _field,
      focusNode: _focus,
      autofocus: widget.autofocus,
      textInputAction: TextInputAction.search,
      onChanged: _typed,
      onSubmitted: _searchFor,
      maxLength: 100,
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        prefixIcon: const Icon(ReelishIcons.search),
        suffixIcon: _field.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: _clear,
                icon: const Icon(ReelishIcons.close),
              ),
      ),
    );
  }

  Widget _body() {
    switch (_search.status) {
      case SearchStatus.landing:
        return _Landing(
          recent: _search.recent,
          padding: _gutter,
          onSearch: _searchFor,
          onClearRecent: () => unawaited(_search.clearRecent()),
          onBrowseGenre: (id) =>
              _search.setFilters(_search.filters.copyWith(genres: {id})),
          genres: _search.genres,
        );
      case SearchStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case SearchStatus.failed:
        return _Message(
          icon: ReelishIcons.offline,
          title: 'Search didn’t work',
          body: 'Check your connection and try again.',
          action: ('Try again', () => unawaited(_search.retry())),
        );
      case SearchStatus.ready:
        return _search.category == SearchCategory.all
            ? _overview()
            : _categoryGrid();
    }
  }

  String get _nothingFound => _search.query.isEmpty
      ? 'Nothing fits these filters'
      : 'No results for “${_search.query}”';

  Widget? _clearFiltersAction() => _search.filters.isEmpty
      ? null
      : TextButton(
          onPressed: _search.clearFilters,
          child: const Text('Clear filters'),
        );

  Widget _overview() {
    final o = _search.overview;
    if (o.isEmpty) {
      return _Message(
        icon: ReelishIcons.searchOff,
        title: _nothingFound,
        body: _search.filters.isEmpty
            ? 'Check the spelling, or try a shorter name.'
            : 'Try fewer or wider filters.',
        action: _search.filters.isEmpty
            ? null
            : ('Clear filters', _search.clearFilters),
      );
    }
    final top = o.top;
    return ListView(
      padding: EdgeInsets.only(bottom: AppSpace.xl),
      children: [
        if (o.yearFromQuery != null)
          _Note(
            padding: _gutter,
            text:
                'Nothing is called “${_search.query}”, so these are from '
                '${o.yearFromQuery}.',
          ),
        if (_search.filtering)
          _Note(
            padding: _gutter,
            text: _search.query.isEmpty
                ? 'Popular movies and series that fit your filters. People '
                      'and collections aren’t filtered.'
                : 'Filters apply to movies and series, so people and '
                      'collections are hidden. Filters look through the '
                      'best matches, not every title on TMDB.',
            action: _clearFiltersAction(),
          ),
        if (top != null) ...[
          _SectionTitle(title: 'Top result', padding: _gutter),
          Padding(
            padding: _gutter,
            child: _TopResult(
              result: top,
              onOpen: () => _open(top),
              availability: top is MediaItem ? widget.availability : null,
            ),
          ),
        ],
        _row('Movies', SearchCategory.movies, [
          for (final m in o.movies) _titleCard(m),
        ]),
        _row('Series', SearchCategory.series, [
          for (final s in o.series) _titleCard(s),
        ]),
        _row('People', SearchCategory.people, [
          for (final p in o.people)
            SearchPersonCard(person: p, onOpen: () => _open(p)),
        ]),
        _row('Collections', SearchCategory.collections, [
          for (final c in o.collections)
            SearchCollectionCard(collection: c, onOpen: () => _open(c)),
        ]),
      ],
    );
  }

  Widget _titleCard(MediaItem item) =>
      SearchTitleCard(item: item, onOpen: () => _open(item));

  Widget _row(String title, SearchCategory category, List<Widget> cards) {
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          title: title,
          padding: _gutter,
          // "See all" opens the category with its own paging. Not on TV:
          // a column of them at the edge would draw the remote away from
          // the rows, and the category chips above do the same.
          onSeeAll:
              DeviceCapabilities.isTv ||
                  (_search.query.isEmpty && !category.filterable)
              ? null
              : () => _search.setCategory(category),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: _gutter,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final card in cards.take(20))
                Padding(
                  padding: const EdgeInsets.only(right: AppSpace.sm),
                  child: card,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _categoryGrid() {
    final items = _search.items;
    if (items.isEmpty) {
      final browsing = _search.query.isEmpty;
      return _Message(
        icon: ReelishIcons.searchOff,
        title: browsing && !_search.category.filterable
            ? 'Type a name to find ${_search.category.label.toLowerCase()}'
            : _nothingFound,
        body: _search.filters.isEmpty || !_search.category.filterable
            ? 'Check the spelling, or try a shorter name.'
            : 'Try fewer or wider filters.',
        action: _search.filters.isEmpty || !_search.category.filterable
            ? null
            : ('Clear filters', _search.clearFilters),
      );
    }
    final width = switch (_search.category) {
      SearchCategory.people => SearchSizes.portrait + 16,
      SearchCategory.collections => SearchSizes.collection,
      _ => SearchSizes.poster,
    };
    return NotificationListener<ScrollNotification>(
      onNotification: (note) {
        if (note.metrics.extentAfter < 600) unawaited(_search.loadMore());
        return false;
      },
      child: SingleChildScrollView(
        padding: _gutter.copyWith(bottom: AppSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.md,
              children: [
                for (final item in items)
                  SizedBox(
                    width: width,
                    child: switch (item) {
                      MediaItem() => _titleCard(item),
                      PersonHit() => SearchPersonCard(
                        person: item,
                        onOpen: () => _open(item),
                      ),
                      CollectionHit() => SearchCollectionCard(
                        collection: item,
                        onOpen: () => _open(item),
                      ),
                      _ => const SizedBox.shrink(),
                    },
                  ),
              ],
            ),
            if (_search.loadingMore)
              const Padding(
                padding: EdgeInsets.all(AppSpace.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_search.hasMore)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.md),
                child: Center(
                  child: OutlinedButton(
                    onPressed: () => unawaited(_search.loadMore()),
                    child: const Text('Show more'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Categories extends StatelessWidget {
  const _Categories({
    required this.selected,
    required this.onSelected,
    required this.padding,
  });

  final SearchCategory selected;
  final ValueChanged<SearchCategory> onSelected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: padding,
    child: Row(
      children: [
        for (final category in SearchCategory.values)
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.xs),
            child: ChoiceChip(
              label: Text(category.label),
              selected: category == selected,
              onSelected: (_) => onSelected(category),
            ),
          ),
      ],
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.padding,
    this.onSeeAll,
  });

  final String title;
  final EdgeInsets padding;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding.copyWith(top: AppSpace.md, bottom: AppSpace.xs),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: AppTextSize.title,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (onSeeAll != null)
          TextButton(onPressed: onSeeAll, child: const Text('See all')),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.padding, this.action});

  final String text;
  final EdgeInsets padding;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding.copyWith(top: AppSpace.xs),
    child: Row(
      children: [
        Icon(ReelishIcons.info, size: 16, color: GlassTheme.muted),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: GlassTheme.muted,
              fontSize: AppTextSize.label,
            ),
          ),
        ),
        ?action,
      ],
    ),
  );
}

class _TopResult extends StatelessWidget {
  const _TopResult({
    required this.result,
    required this.onOpen,
    this.availability,
  });

  final Object result;
  final VoidCallback onOpen;
  final PlaybackAvailability? availability;

  @override
  Widget build(BuildContext context) {
    final (
      String name,
      String facts,
      String about,
      String image,
      bool round,
    ) = switch (result) {
      MediaItem(:final name, :final description, :final poster) => (
        name,
        titleFacts(result as MediaItem),
        description,
        poster,
        false,
      ),
      PersonHit(:final name, :final role, :final knownFor, :final profileUrl) =>
        (
          name,
          role,
          knownFor.isEmpty ? '' : 'Known for ${knownFor.join(', ')}',
          profileUrl,
          true,
        ),
      CollectionHit(:final name, :final overview, :final posterUrl) => (
        name,
        'Movie collection',
        overview,
        posterUrl,
        false,
      ),
      _ => ('', '', '', '', false),
    };
    final imageWidth = DeviceCapabilities.isTv ? 130.0 : 100.0;
    final item = result is MediaItem ? result as MediaItem : null;
    return Container(
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: GlassTheme.border),
      ),
      padding: const EdgeInsets.all(AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SearchTap(
            label: '$name, $facts. Top result.',
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: imageWidth,
                    height: round ? imageWidth : imageWidth * 1.5,
                    child: image.isEmpty
                        ? ColoredBox(color: GlassTheme.elevatedSurface)
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(
                              round ? imageWidth : AppRadius.md,
                            ),
                            child: ArtworkImage.network(
                              image,
                              fit: BoxFit.cover,
                              excludeFromSemantics: true,
                              errorBuilder: (_, _, _) =>
                                  ColoredBox(color: GlassTheme.elevatedSurface),
                            ),
                          ),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GlassTheme.textPrimary,
                            fontSize: AppTextSize.titleLarge,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          facts,
                          style: TextStyle(
                            color: GlassTheme.primary,
                            fontSize: AppTextSize.label,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (about.isNotEmpty) ...[
                          const SizedBox(height: AppSpace.xs),
                          Text(
                            about,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: GlassTheme.muted,
                              fontSize: AppTextSize.bodySmall,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (item != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xs,
                AppSpace.xs,
                AppSpace.xs,
                0,
              ),
              child: switch (availability) {
                final availability? when PlaybackAvailability.canCheck(item) =>
                  SourceAvailabilityPanel(
                    availability: availability,
                    item: item,
                  ),
                _ when item.type == 'series' => Text(
                  'Providers look series up one episode at a time: open it to '
                  'choose an episode.',
                  style: TextStyle(
                    color: GlassTheme.muted,
                    fontSize: AppTextSize.caption,
                  ),
                ),
                _ => const SizedBox.shrink(),
              },
            ),
        ],
      ),
    );
  }
}

class _Landing extends StatelessWidget {
  const _Landing({
    required this.recent,
    required this.padding,
    required this.onSearch,
    required this.onClearRecent,
    required this.onBrowseGenre,
    required this.genres,
  });

  final List<String> recent;
  final EdgeInsets padding;
  final ValueChanged<String> onSearch;
  final VoidCallback onClearRecent;
  final ValueChanged<int> onBrowseGenre;
  final GenreCatalog genres;

  @override
  Widget build(BuildContext context) => ListView(
    padding: padding.copyWith(bottom: AppSpace.xl),
    children: [
      if (recent.isNotEmpty) ...[
        Row(
          children: [
            Expanded(
              child: Text(
                'Recent searches',
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: AppTextSize.title,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            TextButton(onPressed: onClearRecent, child: const Text('Clear')),
          ],
        ),
        Wrap(
          spacing: AppSpace.xs,
          runSpacing: AppSpace.xs,
          children: [
            for (final query in recent)
              ActionChip(
                avatar: const Icon(ReelishIcons.history, size: 16),
                label: Text(query),
                onPressed: () => onSearch(query),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
      ],
      Text(
        'Browse by genre',
        style: TextStyle(
          color: GlassTheme.textPrimary,
          fontSize: AppTextSize.title,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: AppSpace.xs),
      Wrap(
        spacing: AppSpace.xs,
        runSpacing: AppSpace.xs,
        children: [
          for (final id in genres.pickable)
            ActionChip(
              label: Text(genres.nameOf(id) ?? ''),
              onPressed: () => onBrowseGenre(id),
            ),
        ],
      ),
      const SizedBox(height: AppSpace.lg),
      Text(
        'Search finds movies, series, actors, directors and movie '
        'collections. Filters narrow movies and series by genre, year and '
        'TMDB rating.',
        style: TextStyle(color: GlassTheme.muted, fontSize: AppTextSize.label),
      ),
    ],
  );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: GlassTheme.muted),
          const SizedBox(height: AppSpace.sm),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: AppTextSize.title,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(color: GlassTheme.muted),
          ),
          if (action case (final label, final onPressed)) ...[
            const SizedBox(height: AppSpace.md),
            DeviceCapabilities.isTv
                ? TvFocusable(
                    onSelect: onPressed,
                    autofocus: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.lg,
                        vertical: AppSpace.sm,
                      ),
                      child: Text(label),
                    ),
                  )
                : OutlinedButton(onPressed: onPressed, child: Text(label)),
          ],
        ],
      ),
    ),
  );
}
