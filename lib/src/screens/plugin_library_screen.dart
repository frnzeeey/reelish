import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/plugin_catalog.dart';
import '../navigation/app_transitions.dart';
import '../platform/device_capabilities.dart';
import '../services/plugin_library_query.dart';
import '../services/plugin_library_repository.dart';
import '../services/plugin_library_service.dart';
import '../services/provider_plugin_service.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/plugin_library/plugin_card.dart';
import '../widgets/plugin_library/plugin_filter_bar.dart';
import '../widgets/plugin_library/plugin_install_button.dart';
import '../widgets/plugin_library/plugin_library_notices.dart';
import '../widgets/plugin_library/plugin_search_bar.dart';
import '../widgets/plugin_library/plugin_skeleton.dart';
import '../widgets/plugin_library/plugin_stats.dart';
import '../widgets/provider_installer_modal.dart';
import '../widgets/tv/tv_focus.dart';
import 'plugin_details_screen.dart';

/// Browse the community provider catalog and hand a manifest to the
/// existing installer: the library as its own page, opened from Plugins on
/// phone and TV. Windows shows the same [PluginLibraryView] inside its
/// Plugins page instead, beside the sidebar.
class PluginLibraryScreen extends StatelessWidget {
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
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: GlassTheme.background,
    body: PluginLibraryView(
      repository: repository,
      pluginService: pluginService,
    ),
  );
}

/// The Community Library: search, filters, and a grid of catalog providers
/// that each install through [PluginInstallButton].
///
/// [embedded] drops the back bar and pull-to-refresh for a host page that
/// has its own header ([leading] slivers scroll above the library).
class PluginLibraryView extends StatefulWidget {
  const PluginLibraryView({
    super.key,
    required this.repository,
    required this.pluginService,
    this.embedded = false,
    this.leading = const [],
    this.gutter = AppSpace.md + 4,
  });

  final PluginLibraryRepository repository;
  final ProviderPluginService pluginService;
  final bool embedded;
  final List<Widget> leading;

  /// Horizontal page padding.
  final double gutter;

  /// Below this many providers the curated rails would only repeat cards
  /// the grid already shows a little further down, so they are left out.
  static const railMinimum = 24;

  @override
  State<PluginLibraryView> createState() => _PluginLibraryViewState();
}

class _PluginLibraryViewState extends State<PluginLibraryView> {
  static const _searchDebounce = Duration(milliseconds: 180);
  static const _railLength = 6;
  static const _minCardWidth = 320.0;
  static const _gap = AppSpace.md;

  final _search = TextEditingController();
  PluginLibraryQuery _query = const PluginLibraryQuery();
  PluginAvailability _availability = PluginAvailability.all;
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

  bool _installed(ReelishPlugin plugin) =>
      PluginInstallButton.isInstalled(widget.pluginService, plugin.manifestUrl);

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (mounted) setState(() => _query = _query.copyWith(search: value));
    });
  }

  void _setQuery(PluginLibraryQuery query) => setState(() => _query = query);

  void _setAvailability(PluginAvailability value) =>
      setState(() => _availability = value);

  void _clearFilters() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _query = _query.cleared();
      _availability = PluginAvailability.all;
    });
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.repository, widget.pluginService]),
    builder: (context, _) {
      final repository = widget.repository;
      final scroll = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          ...widget.leading,
          if (!widget.embedded)
            SliverSafeArea(
              bottom: false,
              sliver: SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  AppSpace.xs,
                  AppSpace.xxs,
                  widget.gutter,
                  0,
                ),
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
      );
      if (widget.embedded) return scroll;
      return RefreshIndicator(
        color: GlassTheme.primary,
        backgroundColor: GlassTheme.elevatedSurface,
        onRefresh: repository.refresh,
        child: scroll,
      );
    },
  );

  EdgeInsets _pad(double top, [double bottom = 0]) =>
      EdgeInsets.fromLTRB(widget.gutter, top, widget.gutter, bottom);

  List<Widget> _body(BuildContext context, PluginLibraryRepository repository) {
    final ready = repository.status == PluginLibraryStatus.ready;
    final header = SliverPadding(
      padding: _pad(widget.embedded ? AppSpace.xs : AppSpace.xxs),
      sliver: SliverToBoxAdapter(
        child: _Header(
          embedded: widget.embedded,
          stats: ready
              ? PluginStats(
                  stats: repository.stats,
                  updatedAt: repository.snapshot?.catalog.updatedAt,
                )
              : null,
          refreshing: repository.refreshing,
          onRefresh: widget.embedded ? repository.refresh : null,
          onPaste: widget.embedded ? _pasteManifest : null,
        ),
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
    final installedCount = plugins.where(_installed).length;
    final matches = _resultsFor(plugins);
    final results = switch (_availability) {
      PluginAvailability.all => matches,
      PluginAvailability.installed => matches.where(_installed).toList(),
      PluginAvailability.available =>
        matches.where((plugin) => !_installed(plugin)).toList(),
    };
    final browsing =
        !_query.hasFilters && _availability == PluginAvailability.all;
    final curated = browsing && plugins.length > PluginLibraryView.railMinimum;
    final catalog = repository.snapshot!.catalog;
    final showcase = curated ? _showcase(plugins) : null;
    final recent = curated
        ? _recentlyUpdated(plugins, catalog.updatedAt)
        : const <ReelishPlugin>[];
    return [
      header,
      if (repository.showingOfflineCopy)
        SliverPadding(
          padding: _pad(AppSpace.md),
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
        padding: _pad(AppSpace.md),
        sliver: SliverToBoxAdapter(child: _searchField()),
      ),
      SliverPadding(
        padding: _pad(AppSpace.xs),
        sliver: SliverToBoxAdapter(
          child: PluginFilterBar(
            query: _query,
            facets: repository.facets,
            onChanged: _setQuery,
            availability: _availability,
            installedCount: installedCount,
            onAvailabilityChanged: _setAvailability,
          ),
        ),
      ),
      if (showcase != null && showcase.plugins.isNotEmpty) ...[
        _sectionHeading(showcase.title, showcase.detail),
        _rail(showcase.plugins),
      ],
      if (recent.isNotEmpty) ...[
        _sectionHeading('Recently updated', 'Last 30 days'),
        _rail(recent),
      ],
      _sectionHeading(
        browsing
            ? 'All plugins'
            : switch (_availability) {
                PluginAvailability.installed => 'Installed',
                PluginAvailability.available => 'Not installed',
                PluginAvailability.all => 'Results',
              },
        results.length == 1 ? '1 provider' : '${results.length} providers',
      ),
      if (results.isEmpty)
        SliverToBoxAdapter(child: _emptyState(installedCount))
      else
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: widget.gutter),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) => SliverGrid.builder(
              // A new key per query replays the entrance animation so a filter
              // change reads as a transition.
              key: ValueKey(_queryKey),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columnsFor(constraints.crossAxisExtent),
                mainAxisExtent: PluginCard.heightFor(context),
                crossAxisSpacing: _gap,
                mainAxisSpacing: _gap,
              ),
              itemCount: results.length,
              itemBuilder: (context, index) =>
                  _Entrance(index: index, child: _card(results[index])),
            ),
          ),
        ),
      if (results.isNotEmpty)
        SliverPadding(
          padding: _pad(AppSpace.lg),
          sliver: SliverToBoxAdapter(
            child: PluginManualInstallPrompt(onPaste: _pasteManifest),
          ),
        ),
      SliverPadding(
        padding: _pad(results.isEmpty ? AppSpace.lg : AppSpace.sm, 40),
        sliver: SliverToBoxAdapter(
          child: SafeArea(
            top: false,
            child: PluginSafetyNotice(attribution: _attribution(catalog)),
          ),
        ),
      ),
    ];
  }

  Widget _searchField() {
    // A remote has no keyboard of its own: TV edits the query in the
    // system's on-screen keyboard dialog, as TV Search does.
    if (DeviceCapabilities.isTv) {
      return TvTextField(
        value: _search.text,
        hint: 'Search plugins, authors or sources',
        title: 'Search plugins',
        icon: Symbols.search_rounded,
        textInputAction: TextInputAction.search,
        onChanged: (value) {
          _search.text = value;
          _onSearchChanged(value);
        },
      );
    }
    return Semantics(
      label: 'Search plugins',
      textField: true,
      child: PluginSearchBar(
        controller: _search,
        onChanged: _onSearchChanged,
        onClear: _clearSearch,
      ),
    );
  }

  Widget _emptyState(int installedCount) => switch (_availability) {
    PluginAvailability.installed when installedCount == 0 => PluginMessageState(
      icon: Symbols.extension_rounded,
      title: 'Nothing installed from the library yet',
      message:
          'Install a provider below and it appears here. Providers added '
          'from a pasted manifest are managed in Plugins.',
      actionLabel: 'Show all plugins',
      actionIcon: Symbols.storefront_rounded,
      onAction: () => _setAvailability(PluginAvailability.all),
    ),
    PluginAvailability.available
        when installedCount > 0 && !_query.hasFilters =>
      PluginMessageState(
        icon: Symbols.check_circle_rounded,
        title: 'Everything here is installed',
        message:
            'Every provider in the catalog is already installed. Paste a '
            'manifest URL to add one that is not listed.',
        actionLabel: 'Show installed',
        actionIcon: Symbols.extension_rounded,
        onAction: () => _setAvailability(PluginAvailability.installed),
        secondaryLabel: 'Paste a manifest',
        onSecondary: _pasteManifest,
      ),
    _ => PluginMessageState(
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
  };

  String get _queryKey =>
      '${_query.search}|${_query.language}|${_query.contentType}|'
      '${_query.sort}|$_availability';

  Widget _card(ReelishPlugin plugin) => PluginCard(
    key: ValueKey(plugin.id),
    plugin: plugin,
    search: _query.search,
    installed: _installed(plugin),
    onOpen: () => _openDetails(plugin),
    action: PluginInstallButton(
      plugin: plugin,
      pluginService: widget.pluginService,
      compact: true,
    ),
  );

  Widget _sectionHeading(String title, String detail) => SliverPadding(
    padding: _pad(AppSpace.lg, AppSpace.sm),
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
                  fontSize: AppTextSize.title,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Text(
              detail,
              maxLines: 1,
              style: const TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.label,
              ),
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
          final width = (constraints.maxWidth * .84).clamp(280.0, 360.0);
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: widget.gutter),
            itemCount: plugins.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpace.sm),
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

  /// As many [_minCardWidth] cards as fit, up to five.
  static int _columnsFor(double width) =>
      ((width + _gap) / (_minCardWidth + _gap)).floor().clamp(1, 5);

  List<Widget> _loading() => [
    SliverPadding(
      padding: _pad(AppSpace.md),
      sliver: SliverToBoxAdapter(
        child: Semantics(
          label: 'Loading plugins',
          child: const SizedBox(height: 3, child: LinearProgressIndicator()),
        ),
      ),
    ),
    SliverPadding(
      padding: _pad(AppSpace.md, 40),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) => SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columnsFor(constraints.crossAxisExtent),
            mainAxisExtent: PluginCard.heightFor(context),
            crossAxisSpacing: _gap,
            mainAxisSpacing: _gap,
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
      _HeaderActions(
        refreshing: refreshing,
        onRefresh: onRefresh,
        onPaste: onPaste,
      ),
    ],
  );
}

class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.refreshing,
    required this.onRefresh,
    required this.onPaste,
  });

  final bool refreshing;
  final Future<void> Function() onRefresh;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Paste a manifest URL',
        onPressed: onPaste,
        icon: const Icon(Symbols.add_link_rounded),
      ),
      const SizedBox(width: AppSpace.xxs),
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
  const _Header({
    required this.embedded,
    required this.refreshing,
    this.stats,
    this.onRefresh,
    this.onPaste,
  });

  final bool embedded;
  final Widget? stats;
  final bool refreshing;

  /// Given when [embedded]: the actions a standalone page keeps in its bar.
  final Future<void> Function()? onRefresh;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Community Library',
            style: TextStyle(
              fontSize: embedded ? AppTextSize.headline : AppTextSize.display,
              height: 1.05,
              fontWeight: FontWeight.w800,
              letterSpacing: embedded ? -.4 : -.9,
            ),
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        const Text(
          'Discover community providers and expand your streaming sources.',
          style: TextStyle(
            color: GlassTheme.muted,
            fontSize: AppTextSize.body,
            fontWeight: FontWeight.w500,
            height: 1.4,
          ),
        ),
        if (stats case final stats?) ...[
          const SizedBox(height: AppSpace.xxs),
          stats,
        ],
      ],
    );
    if (onRefresh == null || onPaste == null) return text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: text),
        _HeaderActions(
          refreshing: refreshing,
          onRefresh: onRefresh!,
          onPaste: onPaste!,
        ),
      ],
    );
  }
}

/// Fades and lifts the first grid items in once, staggered.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Only the first screenful: cards built later while scrolling (or as
    // remote focus moves down) appear at once instead of fading in under
    // the cursor.
    if (index >= 8 ||
        DeviceCapabilities.isTv ||
        MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    final delay = (index.clamp(0, 6)) * 40;
    final total = AppMotion.page.inMilliseconds + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: AppMotion.enter),
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 12),
          child: child,
        ),
      ),
    );
  }
}
