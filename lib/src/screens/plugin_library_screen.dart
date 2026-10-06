import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/plugin_catalog.dart';
import '../navigation/app_transitions.dart';
import '../services/plugin_library_query.dart';
import '../services/plugin_library_repository.dart';
import '../services/plugin_library_service.dart';
import '../services/provider_plugin_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/plugin_library/plugin_card.dart';
import '../widgets/plugin_library/plugin_filter_bar.dart';
import '../widgets/plugin_library/plugin_formatting.dart';
import '../widgets/plugin_library/plugin_install_button.dart';
import '../widgets/plugin_library/plugin_library_notices.dart';
import '../widgets/plugin_library/plugin_search_bar.dart';
import '../widgets/plugin_library/plugin_skeleton.dart';
import '../widgets/plugin_library/plugin_stats.dart';
import '../widgets/provider_installer_modal.dart';
import 'plugin_details_screen.dart';

/// Browse the community provider catalog and hand a manifest to the
/// existing installer.
class PluginLibraryScreen extends StatefulWidget {
  const PluginLibraryScreen({
    super.key,
    required this.repository,
    required this.pluginService,
  });

  final PluginLibraryRepository repository;
  final ProviderPluginService pluginService;

  static Future<void> open(
    BuildContext context, {
    required PluginLibraryRepository repository,
    required ProviderPluginService pluginService,
  }) => Navigator.push<void>(
    context,
    AppPageRoute<void>(
      context: context,
      builder: (_) => PluginLibraryScreen(
        repository: repository,
        pluginService: pluginService,
      ),
    ),
  );

  @override
  State<PluginLibraryScreen> createState() => _PluginLibraryScreenState();
}

class _PluginLibraryScreenState extends State<PluginLibraryScreen> {
  static const _searchDebounce = Duration(milliseconds: 180);
  static const _railLength = 6;

  final _search = TextEditingController();
  PluginLibraryQuery _query = const PluginLibraryQuery();
  Timer? _debounce;

  // Filtering is memoized on the catalog list and query, so unrelated
  // rebuilds (installs, refresh state) never re-run it.
  List<ReelishPlugin>? _resultsSource;
  PluginLibraryQuery? _resultsQuery;
  List<ReelishPlugin> _results = const [];

  @override
  void initState() {
    super.initState();
    unawaited(widget.repository.load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  List<ReelishPlugin> _resultsFor(List<ReelishPlugin> plugins) {
    if (!identical(plugins, _resultsSource) || _query != _resultsQuery) {
      _resultsSource = plugins;
      _resultsQuery = _query;
      _results = _query.apply(plugins);
    }
    return _results;
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (mounted) setState(() => _query = _query.copyWith(search: value));
    });
  }

  void _setQuery(PluginLibraryQuery query) => setState(() => _query = query);

  void _clearFilters() {
    _debounce?.cancel();
    _search.clear();
    setState(() => _query = _query.cleared());
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() => _query = _query.copyWith(search: ''));
  }

  void _pasteManifest() =>
      ProviderInstallerModal.show(context, widget.pluginService);

  void _openDetails(ReelishPlugin plugin) => Navigator.push<void>(
    context,
    AppPageRoute<void>(
      context: context,
      details: true,
      builder: (_) => PluginDetailsScreen(
        plugin: plugin,
        pluginService: widget.pluginService,
        catalog: widget.repository.snapshot?.catalog,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: GlassTheme.background,
    body: ListenableBuilder(
      listenable: Listenable.merge([widget.repository, widget.pluginService]),
      builder: (context, _) {
        final repository = widget.repository;
        return RefreshIndicator(
          color: GlassTheme.primary,
          backgroundColor: GlassTheme.elevatedSurface,
          onRefresh: repository.refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverSafeArea(
                bottom: false,
                sliver: SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 20, 0),
                  sliver: SliverToBoxAdapter(
                    child: _TopBar(
                      refreshing: repository.refreshing,
                      onRefresh: repository.refresh,
                      onPaste: _pasteManifest,
                    ),
                  ),
                ),
              ),
              ..._body(context, repository),
            ],
          ),
        );
      },
    ),
  );

  List<Widget> _body(BuildContext context, PluginLibraryRepository repository) {
    const gutter = EdgeInsets.symmetric(horizontal: 20);
    final header = SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
      sliver: SliverToBoxAdapter(
        child: _Header(updatedAt: repository.snapshot?.catalog.updatedAt),
      ),
    );
    switch (repository.status) {
      case PluginLibraryStatus.idle:
      case PluginLibraryStatus.loading:
        return [header, ..._loading()];
      case PluginLibraryStatus.error:
        return [
          header,
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: PluginMessageState(
                icon: Symbols.cloud_off_rounded,
                title: 'Unable to load plugins',
                message:
                    repository.refreshError ??
                    'Check your connection and try again.',
                actionLabel: 'Retry',
                busy: repository.refreshing,
                onAction: repository.retry,
                secondaryLabel: 'Paste a manifest',
                onSecondary: _pasteManifest,
              ),
            ),
          ),
        ];
      case PluginLibraryStatus.ready:
        break;
    }

    final plugins = repository.plugins;
    final results = _resultsFor(plugins);
    final browsing = !_query.hasFilters;
    final catalog = repository.snapshot!.catalog;
    final showcase = _showcase(plugins);
    final recent = _recentlyUpdated(plugins, catalog.updatedAt);
    return [
      header,
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        sliver: SliverToBoxAdapter(child: PluginStats(stats: repository.stats)),
      ),
      if (repository.showingOfflineCopy)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          sliver: SliverToBoxAdapter(
            child: PluginOfflineBanner(
              message: repository.snapshot?.origin == PluginCatalogOrigin.cache
                  ? 'Showing cached plugin data'
                  : 'Showing the catalog included with this version of Reelish',
              retrying: repository.refreshing,
              onRetry: repository.refresh,
            ),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        sliver: SliverToBoxAdapter(
          child: Semantics(
            label: 'Search plugins',
            textField: true,
            child: PluginSearchBar(
              controller: _search,
              onChanged: _onSearchChanged,
              onClear: _clearSearch,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
        sliver: SliverToBoxAdapter(
          child: PluginFilterBar(
            query: _query,
            facets: repository.facets,
            onChanged: _setQuery,
          ),
        ),
      ),
      if (browsing && showcase.plugins.isNotEmpty) ...[
        _sectionHeading(showcase.title, showcase.detail),
        _rail(showcase.plugins),
      ],
      if (browsing && recent.isNotEmpty) ...[
        _sectionHeading('Recently updated', 'Last 30 days'),
        _rail(recent),
      ],
      _sectionHeading(
        browsing ? 'All plugins' : 'Results',
        results.length == 1 ? '1 provider' : '${results.length} providers',
      ),
      if (results.isEmpty)
        SliverToBoxAdapter(
          child: PluginMessageState(
            icon: Symbols.search_off_rounded,
            title: 'No plugins found',
            message:
                'Try a different search or remove some filters. If the '
                'provider is not listed, paste its manifest URL instead.',
            actionLabel: 'Clear filters',
            actionIcon: Symbols.filter_alt_off_rounded,
            onAction: _clearFilters,
            secondaryLabel: 'Paste a manifest',
            onSecondary: _pasteManifest,
          ),
        )
      else
        SliverPadding(
          padding: gutter,
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) => SliverGrid.builder(
              // A new key per query replays the entrance animation so a filter
              // change reads as a transition.
              key: ValueKey(_queryKey),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columnsFor(constraints.crossAxisExtent),
                mainAxisExtent: PluginCard.heightFor(context),
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
              ),
              itemCount: results.length,
              itemBuilder: (context, index) =>
                  _Entrance(index: index, child: _card(results[index])),
            ),
          ),
        ),
      if (results.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          sliver: SliverToBoxAdapter(
            child: PluginManualInstallPrompt(onPaste: _pasteManifest),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(20, results.isEmpty ? 24 : 12, 20, 40),
        sliver: SliverToBoxAdapter(
          child: SafeArea(
            top: false,
            child: PluginSafetyNotice(attribution: _attribution(catalog)),
          ),
        ),
      ),
    ];
  }

  String get _queryKey =>
      '${_query.search}|${_query.language}|${_query.contentType}|${_query.sort}';

  Widget _card(ReelishPlugin plugin) => PluginCard(
    key: ValueKey(plugin.id),
    plugin: plugin,
    search: _query.search,
    installed: PluginInstallButton.isInstalled(
      widget.pluginService,
      plugin.manifestUrl,
    ),
    onOpen: () => _openDetails(plugin),
  );

  Widget _sectionHeading(String title, String detail) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
    sliver: SliverToBoxAdapter(
      child: Semantics(
        header: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              detail,
              maxLines: 1,
              style: const TextStyle(color: GlassTheme.muted, fontSize: 11),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _rail(List<ReelishPlugin> plugins) => SliverToBoxAdapter(
    child: SizedBox(
      height: PluginCard.heightFor(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = (constraints.maxWidth * .84).clamp(260.0, 340.0);
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: plugins.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) =>
                SizedBox(width: width, child: _card(plugins[index])),
          );
        },
      ),
    ),
  );

  /// Featured providers when the catalog marks any; otherwise the providers
  /// with the most sources. The source library has no popularity data, so
  /// nothing is presented as "popular".
  ({String title, String detail, List<ReelishPlugin> plugins}) _showcase(
    List<ReelishPlugin> plugins,
  ) {
    final featured = plugins.where((plugin) => plugin.featured).toList();
    if (featured.isNotEmpty) {
      return (
        title: 'Featured plugins',
        detail: 'Highlighted by the catalog',
        plugins: featured.take(_railLength).toList(),
      );
    }
    final largest = const PluginLibraryQuery(sort: PluginSort.scraperCount)
        .apply(plugins)
        .where((plugin) => plugin.scraperCount > 0)
        .take(_railLength)
        .toList();
    return (
      title: 'Largest collections',
      detail: 'Most sources',
      plugins: largest,
    );
  }

  List<ReelishPlugin> _recentlyUpdated(
    List<ReelishPlugin> plugins,
    DateTime? catalogDate,
  ) {
    final since = (catalogDate ?? DateTime.now().toUtc()).subtract(
      const Duration(days: 30),
    );
    return const PluginLibraryQuery(sort: PluginSort.recentlyUpdated)
        .apply(plugins)
        .where((plugin) => plugin.lastUpdated?.isAfter(since) ?? false)
        .take(_railLength)
        .toList();
  }

  String? _attribution(PluginCatalog catalog) {
    final source = catalog.sourceName;
    if (source == null) return null;
    final curator = catalog.curator == null
        ? ''
        : ', curated by ${catalog.curator}';
    return 'Catalog from the $source$curator. Each provider belongs to its author.';
  }

  static int _columnsFor(double width) => width >= 1320
      ? 4
      : width >= 960
      ? 3
      : width >= 600
      ? 2
      : 1;

  List<Widget> _loading() => [
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      sliver: SliverToBoxAdapter(
        child: Semantics(
          label: 'Loading plugins',
          child: const SizedBox(height: 3, child: LinearProgressIndicator()),
        ),
      ),
    ),
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) => SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columnsFor(constraints.crossAxisExtent),
            mainAxisExtent: PluginCard.heightFor(context),
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
          ),
          itemCount: 6,
          itemBuilder: (_, _) =>
              const PluginShimmer(child: PluginCardSkeleton()),
        ),
      ),
    ),
  ];
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.refreshing,
    required this.onRefresh,
    required this.onPaste,
  });

  final bool refreshing;
  final Future<void> Function() onRefresh;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        tooltip: 'Back to plugins',
        onPressed: () => Navigator.maybePop(context),
        icon: const Icon(Symbols.arrow_back_rounded),
      ),
      const Spacer(),
      IconButton(
        tooltip: 'Paste a manifest URL',
        onPressed: onPaste,
        icon: const Icon(Symbols.add_link_rounded),
      ),
      const SizedBox(width: 4),
      IconButton.filledTonal(
        tooltip: 'Refresh plugin catalog',
        onPressed: refreshing ? null : onRefresh,
        style: IconButton.styleFrom(
          foregroundColor: GlassTheme.primary,
          backgroundColor: GlassTheme.primary.withValues(alpha: .1),
        ),
        icon: refreshing
            ? SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: GlassTheme.primary,
                ),
              )
            : const Icon(Symbols.refresh_rounded),
      ),
    ],
  );
}

class _Header extends StatelessWidget {
  const _Header({this.updatedAt});

  final DateTime? updatedAt;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: GlassTheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              updatedAt == null
                  ? 'COMMUNITY LIBRARY'
                  : 'COMMUNITY LIBRARY · UPDATED ${formatPluginDate(updatedAt!).toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: GlassTheme.primary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Semantics(
        header: true,
        child: const Text(
          'Reelish Plugins',
          style: TextStyle(
            fontSize: 32,
            height: 1.05,
            fontWeight: FontWeight.w800,
            letterSpacing: -.9,
          ),
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Discover community providers and expand your streaming sources.',
        style: TextStyle(color: GlassTheme.muted, fontSize: 14, height: 1.4),
      ),
    ],
  );
}

/// Fades and lifts a grid item in once, staggered for the first few.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final delay = (index.clamp(0, 6)) * 40;
    final total = 260 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 14),
          child: child,
        ),
      ),
    );
  }
}
