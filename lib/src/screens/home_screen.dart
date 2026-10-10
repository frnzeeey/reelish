import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../models/app_update.dart';
import '../models/episode_context.dart';
import '../models/episode_progress.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/resume_summary.dart';
import '../models/stream_source.dart';
import '../navigation/app_transitions.dart';
import '../platform/device_capabilities.dart';
import '../services/media_catalog_rules.dart';
import '../services/media_discovery_ranking.dart';
import '../services/paged_feed_controller.dart';
import '../services/perf_timeline.dart';
import '../services/storage_service.dart';
import '../services/tmdb_response_cache.dart';
import '../services/stream_discovery.dart';
import '../services/tmdb_service.dart';
import '../services/plugin_library_repository.dart';
import '../services/provider_plugin_service.dart';
import '../services/playback_settings_controller.dart';
import '../services/accent_settings_controller.dart';
import '../theme/glass_theme.dart';
import '../widgets/provider_installer_modal.dart';
import '../widgets/app_update_flow.dart';
import '../widgets/category_chip.dart';
import '../widgets/glass_box.dart';
import '../widgets/media_card.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/settings/tmdb_attribution.dart';
import '../widgets/soft_glass_dock.dart';
import '../widgets/player/custom_video_player.dart';
import '../widgets/player/episode_panel.dart';
import '../widgets/player/stream_selector_sheet.dart';
import '../widgets/provider_search_dialog.dart';
import '../widgets/tv/tv_focus.dart';
import 'tv/tv_details_screen.dart';
import 'tv/tv_home_shell.dart';
import 'tv/tv_pages.dart';
import 'plugins_screen.dart';
import 'library_screen.dart';
import 'player_screen.dart';
import 'media_details_screen.dart';
import 'playback_settings_screen.dart';

/// One independently loaded single-request list (Trending, search). Its
/// fields change only inside the home screen's setState. The catalog rows
/// page and use [PagedFeedController] instead.
class _HomeFeed {
  List<MediaItem> items = const [];
  bool loading = false;
  String? error;

  /// Incremented for each load; a response for an older number is dropped.
  int request = 0;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.accentSettings,
    this.tmdbService,
    this.updateChecker,
  });

  final AccentSettingsController accentSettings;
  final TmdbService? tmdbService;
  final Future<UpdateCheckResult> Function()? updateChecker;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _providerPlugins = ProviderPluginService();
  // Loaded the first time the Plugin Library opens.
  final _pluginLibrary = PluginLibraryRepository();
  final _storage = StorageService();
  final _playbackSettings = PlaybackSettingsController();
  late final TmdbService _tmdb;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _spotlightController = PageController();
  final _homeScrollController = ScrollController();
  final ValueNotifier<int> _spotlightPageValue = ValueNotifier(0);
  List<MediaItem> _continueWatching = const [];

  // Each catalog row pages on its own; loading one never reloads another.
  // Page 1 of New movies and Series worth the queue is the source for the
  // spotlight, the Movies and Series tabs and the Top 10 seeds, so those
  // two start with Home. New releases and Top 10 wait until they approach
  // the screen.
  late final PagedFeedController _movies;
  late final PagedFeedController _series;
  late final PagedFeedController _releases;
  late final PagedFeedController _top10;

  /// The titles Top 10 was built from, chosen when its page 1 loads.
  List<MediaItem> _top10Seeds = const [];
  Set<String> _top10SeedKeys = const {};

  /// What Home itself shows from the catalog rows: their first-load status
  /// and page 1. Home rebuilds only when this changes, so a row loading a
  /// later page rebuilds just that row.
  Object? _catalogSignature;

  /// Kept apart from the catalog rows so Trending never leaks into them.
  final _trending = _HomeFeed();

  /// Results for the current query; leaving search shows the other feeds
  /// unchanged.
  final _searchFeed = _HomeFeed();
  Set<String> _favoriteKeys = {};
  List<MediaItem> _spotlightItems = [];
  bool _resolvingStreams = false;
  bool _searchVisible = false;
  String _category = 'For you';
  int _tab = 0;
  bool _openingDetails = false;
  int _spotlightPage = 0;
  int _libraryRefreshToken = 0;
  Timer? _debounce;
  Timer? _spotlightTimer;

  /// The page the TV navigation rail shows. TV only; mobile uses [_tab].
  TvDestination _tvDestination = TvDestination.home;

  @override
  void initState() {
    super.initState();
    _tmdb = widget.tmdbService ?? TmdbService();
    _createCatalogFeeds();
    WidgetsBinding.instance.addObserver(this);
    _providerPlugins.addListener(_onPluginChange);
    _startSpotlightTimer();
    _start();
    unawaited(_loadFavorites());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PerfTimeline.markOnce('HOME_USABLE');
      unawaited(_checkForUpdate());
    });
  }

  void _startSpotlightTimer() {
    _spotlightTimer?.cancel();
    // The TV hero follows focus instead of rotating on its own.
    if (DeviceCapabilities.isTv) return;
    _spotlightTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted ||
          MediaQuery.disableAnimationsOf(context) ||
          _searchVisible ||
          _tab != 0 ||
          _category != 'For you' ||
          _search.text.trim().isNotEmpty ||
          _spotlightItems.length < 2 ||
          !_spotlightController.hasClients ||
          (_homeScrollController.hasClients &&
              (_homeScrollController.position.pixels > 0 ||
                  _homeScrollController.position.isScrollingNotifier.value))) {
        return;
      }
      _spotlightController.animateToPage(
        _spotlightPage + 1,
        duration: const Duration(milliseconds: 480),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  Future<void> _start() async {
    await _playbackSettings.load();
    // Page 1 of the two rows the spotlight is built from. Every other row,
    // and every later page, waits until it is needed.
    unawaited(_movies.ensureLoaded());
    unawaited(_series.ensureLoaded());
    // History is local data and does not depend on plugin repository loading.
    // Start it now so remote manifest requests cannot delay the resume row.
    unawaited(_loadHistory());
    // Before any torrent can start: deletes torrent data when a clear is
    // pending or it has grown too large.
    unawaited(_storage.cleanTorrentDataAtStartup());
    await _providerPlugins.load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkForUpdate());
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _startSpotlightTimer();
        _revalidateStaleFeeds();
      }
    } else {
      _spotlightTimer?.cancel();
      _spotlightTimer = null;
    }
  }

  /// Runs in the background on start and resume; it shows nothing unless a
  /// newer release exists. Throttling and caching live in the update service.
  Future<void> _checkForUpdate() =>
      AppUpdateFlow.checkAutomatically(context, checker: widget.updateChecker);

  void _onPluginChange() {
    if (!mounted) return;
    setState(() {});
  }

  void _createCatalogFeeds() {
    _movies = PagedFeedController(
      label: 'NewMovies',
      staleAfter: TmdbCacheTtl.catalog,
      fetch: (page, {previous, required forceRefresh, onRevalidated}) =>
          _tmdb.newMoviesPage(
            page: page,
            forceRefresh: forceRefresh,
            onRevalidated: onRevalidated,
          ),
    );
    _series = PagedFeedController(
      label: 'SeriesWorthTheQueue',
      staleAfter: TmdbCacheTtl.catalog,
      fetch: (page, {previous, required forceRefresh, onRevalidated}) =>
          _tmdb.streamingSeriesPage(
            page: page,
            forceRefresh: forceRefresh,
            onRevalidated: onRevalidated,
          ),
    );
    _releases = PagedFeedController(
      label: 'NewReleases',
      staleAfter: TmdbCacheTtl.newReleases,
      fetch: (page, {previous, required forceRefresh, onRevalidated}) =>
          _tmdb.newReleasesPage(
            page: page,
            previous: previous,
            forceRefresh: forceRefresh,
            onRevalidated: onRevalidated,
          ),
    );
    _top10 = PagedFeedController(
      label: 'Top10',
      targetCount: 10,
      staleAfter: TmdbCacheTtl.recommendations,
      select: (candidates) => MediaDiscoveryRanking.recommendations(
        candidates,
        excludedKeys: _top10SeedKeys,
      ),
      fetch: _fetchTop10Page,
    );
    for (final feed in _catalogFeeds) {
      feed.addListener(_onCatalogFeedChanged);
    }
  }

  List<PagedFeedController> get _catalogFeeds => [
    _movies,
    _series,
    _releases,
    _top10,
  ];

  /// Top 10 comes from the recommendations of the best movie and the best
  /// series on page 1 of the catalog, ranked with vote-weighted scores.
  /// The seeds are chosen again whenever page 1 of Top 10 is loaded.
  Future<CatalogPage> _fetchTop10Page(
    int page, {
    CatalogPage? previous,
    required bool forceRefresh,
    void Function(CatalogPage)? onRevalidated,
  }) {
    if (page == 1) {
      final catalog = [..._movies.firstPageItems, ..._series.firstPageItems];
      _top10Seeds = [
        for (final type in const ['movie', 'series'])
          MediaDiscoveryRanking.recommendationSeed(catalog, type),
      ].whereType<MediaItem>().toList();
      _top10SeedKeys = _top10Seeds.map(MediaCatalogFilter.key).toSet();
    }
    if (_top10Seeds.isEmpty) {
      return Future.value(const CatalogPage(items: [], page: 1, totalPages: 1));
    }
    return _tmdb.recommendationCandidatesPage(
      _top10Seeds,
      page: page,
      previous: previous,
      forceRefresh: forceRefresh,
      onRevalidated: onRevalidated,
    );
  }

  /// Rebuilds Home when a catalog row's first-load status or page 1
  /// changes. Later pages only rebuild their own row.
  void _onCatalogFeedChanged() {
    final signature = [
      for (final feed in [_movies, _series, _releases])
        (
          feed.state.status,
          feed.state.firstPageVersion,
          feed.state.items.isNotEmpty,
        ),
    ];
    if (listEquals(signature, _catalogSignature as List?)) return;
    _catalogSignature = signature;
    if (!mounted) return;
    setState(_refreshSpotlight);
    if (_movies.state.items.isNotEmpty || _series.state.items.isNotEmpty) {
      _markContentVisible([..._movies.state.items, ..._series.state.items]);
    }
  }

  /// Quietly renews rows whose page 1 has outlived its cache lifetime.
  void _revalidateStaleFeeds() {
    for (final feed in _catalogFeeds) {
      feed.revalidateIfStale();
    }
  }

  /// The catalog rows behind the selected tab.
  List<PagedFeedController> get _tabCatalogFeeds => switch (_category) {
    'Movies' => [_movies],
    'Series' => [_series],
    _ => [_movies, _series],
  };

  bool get _catalogSettled =>
      [_movies, _series].every(
        (feed) =>
            feed.state.status == PagedFeedStatus.ready ||
            feed.state.status == PagedFeedStatus.failed,
      ) &&
      (_movies.state.items.isNotEmpty || _series.state.items.isNotEmpty);

  /// The list the current view shows while searching or on Trending. The
  /// catalog tabs show their rows instead.
  _HomeFeed get _activeFeed =>
      _search.text.trim().isNotEmpty ? _searchFeed : _trending;

  bool get _showsCatalog =>
      _search.text.trim().isEmpty && _category != 'Trending';

  Future<void> _reloadActiveFeed({bool forceRefresh = false}) async {
    final query = _search.text.trim();
    if (query.isNotEmpty) return _loadSearch(query, forceRefresh: forceRefresh);
    if (_category == 'Trending') {
      return _loadTrending(forceRefresh: forceRefresh);
    }
    await Future.wait([
      for (final feed in _tabCatalogFeeds)
        forceRefresh ? feed.refresh() : feed.retry(),
    ]);
  }

  /// Starts a load of [feed] and returns its request number. Existing items
  /// stay visible; the spinner shows only while the feed is empty.
  int _beginFeedLoad(_HomeFeed feed) {
    final request = ++feed.request;
    if (mounted) {
      setState(() {
        feed.loading = feed.items.isEmpty;
        feed.error = null;
      });
    }
    return request;
  }

  /// The spotlight is built from page 1 of each row, so paging a row never
  /// reshuffles it.
  void _refreshSpotlight() {
    _spotlightItems = _tmdb.spotlight([
      ..._releases.firstPageItems.take(20),
      ..._movies.firstPageItems,
      ..._series.firstPageItems,
    ]);
  }

  /// Loads a single-request feed. Background refreshes replace its items
  /// unless a newer load of the same feed has started.
  Future<void> _loadFeed(
    _HomeFeed feed,
    Future<List<MediaItem>> Function(
      void Function(List<MediaItem>) onRevalidated,
    )
    fetch, {
    bool clearOnError = false,
  }) async {
    final request = _beginFeedLoad(feed);
    void apply(List<MediaItem> items) {
      if (!mounted || request != feed.request) return;
      setState(() {
        feed.items = items;
        feed.loading = false;
        feed.error = null;
      });
      _markContentVisible(items);
    }

    try {
      apply(await fetch(apply));
    } catch (error) {
      if (!mounted || request != feed.request) return;
      setState(() {
        if (clearOnError) feed.items = const [];
        feed.loading = false;
        feed.error = _catalogFailureMessage(error);
      });
    }
  }

  /// Trending is served from the TMDB cache when revisited, so switching
  /// back to the tab costs no request while the cached list is fresh.
  Future<void> _loadTrending({bool forceRefresh = false}) => _loadFeed(
    _trending,
    (onRevalidated) => _tmdb.trending(
      forceRefresh: forceRefresh,
      onRevalidated: onRevalidated,
    ),
  );

  /// A failed search clears its results, so an earlier query's titles never
  /// appear under a new query.
  Future<void> _loadSearch(String query, {bool forceRefresh = false}) =>
      _loadFeed(
        _searchFeed,
        (onRevalidated) => _tmdb.search(
          query,
          forceRefresh: forceRefresh,
          onRevalidated: onRevalidated,
        ),
        clearOnError: true,
      );

  /// Pull-to-refresh: reloads the visible list, and on For you also
  /// refreshes the deferred rows that have already been requested. Each
  /// refreshed row restarts at page 1. Top 10 waits for the catalog so its
  /// seeds come from the refreshed page 1.
  Future<void> _refreshVisibleHome() async {
    if (!_showsCatalog || _category != 'For you') {
      return _reloadActiveFeed(forceRefresh: true);
    }
    bool requested(PagedFeedController feed) =>
        feed.state.status != PagedFeedStatus.idle;
    Future<void> catalogThenTop10() async {
      await Future.wait([_movies.refresh(), _series.refresh()]);
      if (requested(_top10)) await _top10.refresh();
    }

    await Future.wait([
      catalogThenTop10(),
      if (requested(_releases)) _releases.refresh(),
    ]);
  }

  String _catalogFailureMessage(Object error) {
    final message = error.toString();
    if (message.contains('TMDB API key is not configured')) {
      return 'TMDB is not configured. Add a valid API key, then restart the app.';
    }
    final status = RegExp(
      r'TMDB request failed \((\d{3})\)',
    ).firstMatch(message)?.group(1);
    if (status == '401' || status == '403') {
      return 'TMDB rejected the API key. Check that the configured key is active.';
    }
    if (status == '429') {
      return 'TMDB is rate limiting requests. Wait a moment and retry.';
    }
    return 'Could not load titles from TMDB. Check your connection and retry.';
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _search.clear();
    setState(() => _searchVisible = false);
    _searchChanged('');
  }

  Future<void> _showDetails(MediaItem item) async {
    if (_openingDetails) return;
    _openingDetails = true;
    PerfTimeline.begin('DETAIL_OPEN');
    _spotlightTimer?.cancel();
    try {
      await Navigator.push<void>(
        context,
        AppPageRoute<void>(
          context: context,
          details: true,
          builder: (_) => DeviceCapabilities.isTv
              ? TvMediaDetailsScreen(
                  item: item,
                  tmdb: _tmdb,
                  isFavorite: _favoriteKeys.contains(_favoriteKey(item)),
                  onToggleFavorite: () => _toggleFavorite(item),
                  onPlay: (detailsContext) =>
                      _openItem(item, presentationContext: detailsContext),
                  onPlayEpisode: (detailsContext, season, episode) =>
                      _openItem(
                        item,
                        presentationContext: detailsContext,
                        selectedSeason: season,
                        selectedEpisode: episode,
                      ),
                )
              : MediaDetailsScreen(
                  item: item,
                  tmdb: _tmdb,
                  onPlay: (detailsContext) =>
                      _openItem(item, presentationContext: detailsContext),
                  onPlayEpisode: (detailsContext, season, episode) => _openItem(
                    item,
                    presentationContext: detailsContext,
                    selectedSeason: season,
                    selectedEpisode: episode,
                  ),
                ),
        ),
      );
    } finally {
      _openingDetails = false;
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _startSpotlightTimer();
        // Home kept its rows while Details was open; only rows past their
        // cache lifetime fetch again, quietly.
        _revalidateStaleFeeds();
      }
    }
  }

  Future<void> _loadHistory() async {
    final value = await _storage.history();
    // Series cards follow the episode watched last, so load each series'
    // per-episode progress with the history.
    final progress = <String, SeriesProgress>{};
    for (final item in value) {
      if (item.type != 'series' || item.resumeMs <= 0) continue;
      try {
        progress[_favoriteKey(item)] = await _storage.seriesProgress(item);
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _continueWatching = value.where((item) => item.resumeMs > 0).toList();
        _seriesProgress = progress;
      });
    }
  }

  /// Per-episode progress of the series in watch history, by `type:id`.
  Map<String, SeriesProgress> _seriesProgress = const {};

  ResumeSummary _resumeSummary(MediaItem item) =>
      ResumeSummary.of(item, series: _seriesProgress[_favoriteKey(item)]);

  String _favoriteKey(MediaItem item) => '${item.type}:${item.id}';

  Future<void> _loadFavorites() async {
    final value = await _storage.favorites();
    if (!mounted) return;
    setState(() => _favoriteKeys = value.map(_favoriteKey).toSet());
  }

  Future<bool> _toggleFavorite(MediaItem item) async {
    await _storage.toggleFavorite(item);
    final favorites = await _storage.favorites();
    if (!mounted) return false;
    final keys = favorites.map(_favoriteKey).toSet();
    setState(() => _favoriteKeys = keys);
    return keys.contains(_favoriteKey(item));
  }

  void _markContentVisible(List<MediaItem> items) {
    if (items.isEmpty) return;
    PerfTimeline.markOnce('HOME_CONTENT_VISIBLE');
    PerfTimeline.end('SEARCH_TYPED', 'RESULTS_VISIBLE', finish: true);
  }

  void _searchChanged(String value) {
    final query = value.trim();
    if (query.isNotEmpty) PerfTimeline.begin('SEARCH_TYPED');
    _debounce?.cancel();
    if (query.isEmpty) {
      // Search never replaced the catalog or Trending, so leaving it only
      // drops the results and any pending search response.
      _searchFeed.request++;
      if (!mounted) return;
      setState(() {
        _searchFeed.items = const [];
        _searchFeed.loading = false;
        _searchFeed.error = null;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _loadSearch(query),
    );
  }

  /// Set while a play request is resolving, so a double tap cannot start a
  /// second resolution or push a second player. Released just before the
  /// player opens: the next-episode flow starts a new request while the
  /// earlier call is still awaiting its player route.
  Object? _playbackStart;

  /// Finds streams for [item] (for a series, one episode) and opens the
  /// player. When a player switches episodes, [handOff] comes from that
  /// player: the search shows over it, a failure leaves it playing, and on
  /// success it releases its video engine and the new episode's player
  /// replaces it.
  Future<void> _openItem(
    MediaItem item, {
    BuildContext? presentationContext,
    EpisodeHandOff? handOff,
    int? selectedSeason,
    int? selectedEpisode,
  }) async {
    if (_playbackStart != null) return;
    final token = Object();
    _playbackStart = token;
    void release() {
      if (identical(_playbackStart, token)) _playbackStart = null;
    }

    try {
      await _resolveAndOpenPlayer(
        item,
        presentationContext: presentationContext,
        handOff: handOff,
        selectedSeason: selectedSeason,
        selectedEpisode: selectedEpisode,
        beforePlayerOpens: release,
      );
    } finally {
      release();
    }
  }

  Future<void> _resolveAndOpenPlayer(
    MediaItem item, {
    BuildContext? presentationContext,
    EpisodeHandOff? handOff,
    int? selectedSeason,
    int? selectedEpisode,
    required VoidCallback beforePlayerOpens,
  }) async {
    // The screen the player belongs to (the details page, or null for home)
    // stays with the new player. Progress and errors show over the playing
    // player when switching episodes.
    final ownerContext = presentationContext;
    final replacePlayer = handOff != null;
    presentationContext = handOff?.context ?? presentationContext;
    var searchDialogOpen = false;
    void dismissSearchDialog() {
      if (!searchDialogOpen) return;
      searchDialogOpen = false;
      if (presentationContext?.mounted == true) {
        Navigator.of(presentationContext!, rootNavigator: true).pop();
      }
    }

    // The search can take up to a minute when providers are slow, so the
    // viewer can stop it. Completes when Cancel is pressed.
    final searchCancelled = Completer<void>();
    void cancelSearch() {
      if (searchCancelled.isCompleted) return;
      searchCancelled.complete();
      dismissSearchDialog();
    }

    /// [future]'s value, or null once the search is cancelled.
    Future<T?> unlessCancelled<T>(Future<T> future) =>
        Future.any<T?>([future, searchCancelled.future.then((_) => null)]);

    PerfTimeline.begin('PLAY_PRESSED');
    int? season = selectedSeason, episode = selectedEpisode;
    if (item.type == 'series' && (season == null || episode == null)) {
      var episodeList = <Map<String, dynamic>>[];
      try {
        episodeList = await _tmdb.allEpisodes(item);
      } catch (_) {}
      if (!mounted || presentationContext?.mounted == false) return;
      if (episodeList.isEmpty) {
        ScaffoldMessenger.of(presentationContext ?? context).showSnackBar(
          const SnackBar(
            content: Text('No episode list is available for this series.'),
          ),
        );
        return;
      }
      final episodes = EpisodeRef.listFromTmdb(episodeList);
      var progress = SeriesProgress.empty;
      try {
        progress = await _storage.seriesProgress(item);
      } catch (_) {}
      if (!mounted || presentationContext?.mounted == false) return;
      // Opens on the episode watched last, so continuing is one tap.
      final last = progress.last;
      final lastWatched = last == null
          ? null
          : episodes
                .where(
                  (ref) =>
                      ref.season == last.season && ref.episode == last.episode,
                )
                .firstOrNull;
      final selected = await EpisodePanel.show(
        presentationContext ?? context,
        seriesTitle: item.name,
        episodes: episodes,
        progress: progress,
        current: lastWatched,
        currentIsPlaying: false,
      );
      if (selected == null ||
          !mounted ||
          presentationContext?.mounted == false) {
        return;
      }
      season = selected.season;
      episode = selected.episode;
    }
    if (presentationContext?.mounted == true) {
      searchDialogOpen = true;
      unawaited(
        ProviderSearchDialog.show(
          presentationContext!,
          title: item.name,
          season: season,
          episode: episode,
          onCancel: cancelSearch,
        ),
      );
    } else if (mounted) {
      setState(() => _resolvingStreams = true);
    }
    try {
      // Resolve IMDb metadata for subtitles in parallel with stream discovery.
      // Providers need the TMDB ID already present on the selected item;
      // serially waiting for this optional lookup delays every playback start.
      final externalIdsFuture = _tmdb.resolveIds(item);
      final episodeCode = season != null && episode != null
          ? ' S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
          : '';
      // Legacy items may carry an IMDb ID and need a TMDB lookup before
      // providers can search. Bound this optional lookup so a slow TMDB
      // response cannot delay provider discovery and playback startup.
      final pluginId =
          await unlessCancelled(
            _tmdb
                .resolveTmdbId(item)
                .timeout(const Duration(seconds: 3), onTimeout: () => ''),
          ) ??
          '';
      if (searchCancelled.isCompleted) return;
      final pluginItem = pluginId.isEmpty ? item : item.copyWith(id: pluginId);
      final playback = _playbackSettings.value;
      final streamCacheKey = item.type == 'series'
          ? '${item.type}:${item.id}:s${season ?? 0}:e${episode ?? 0}'
          : '${item.type}:${item.id}';
      final allowTorrents =
          playback.p2pStreaming &&
          defaultTargetPlatform == TargetPlatform.android;
      StreamDiscovery? discovery;
      StreamSource? source;
      var sourceFromCache = false;
      if (playback.reuseLastLink) {
        source = await _storage.lastStream(
          item,
          maxAge: Duration(hours: playback.lastLinkCacheHours),
          allowTorrents: allowTorrents,
          allowedProviderIds: playback.allowedProviderIds,
          cacheKey: streamCacheKey,
        );
        sourceFromCache = source != null;
      }
      if (source == null) {
        discovery = _providerPlugins.discoverStreams(
          pluginItem,
          season: season,
          episode: episode,
          allowedPluginIds: playback.allowedProviderIds,
          allowTorrents: allowTorrents,
        );
        source = await unlessCancelled<StreamSource?>(
          discovery.startingSource(),
        );
        if (searchCancelled.isCompleted) {
          discovery.cancel();
          return;
        }
        PerfTimeline.end('PLAY_PRESSED', 'FIRST_SOURCE');
        unawaited(
          discovery.finished.then(
            (_) => PerfTimeline.end('PLAY_PRESSED', 'PROVIDERS_FINISHED'),
          ),
        );
        if (source != null && !playback.autoStreamSelection) {
          await unlessCancelled(
            Future.any([
              discovery.finished,
              Future<void>.delayed(
                Duration(seconds: playback.streamSelectionTimeoutSeconds),
              ),
            ]),
          );
          if (searchCancelled.isCompleted) {
            discovery.cancel();
            return;
          }
          final available = discovery.sources;
          if (available.isNotEmpty) {
            dismissSearchDialog();
            source = await StreamSelectorSheet.show(
              presentationContext ?? context,
              available,
              available.first,
            );
            if (source == null) {
              discovery.cancel();
              return;
            }
          }
        }
      }
      dismissSearchDialog();
      if (!mounted) {
        discovery?.cancel();
        return;
      }
      final resolvedItem = await externalIdsFuture.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => item,
      );
      final subtitleQuery =
          '${item.name}$episodeCode${item.year.isNotEmpty ? ' ${item.year}' : ''}';
      final playableItem = resolvedItem.copyWith(subtitleQuery: subtitleQuery);
      if (presentationContext == null) {
        setState(() => _resolvingStreams = false);
      }
      if (source == null) {
        discovery?.cancel();
        ScaffoldMessenger.of(presentationContext ?? context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text(
              (discovery == null
                      ? _providerPlugins.lastLookupMessage
                      : discovery.message) ??
                  'No source was returned for this title.',
            ),
            action: SnackBarAction(
              label: 'PLUGINS',
              onPressed: () {
                setState(() {
                  _tab = 1;
                  _tvDestination = TvDestination.plugins;
                });
                if (presentationContext?.mounted == true) {
                  Navigator.of(presentationContext!).pop();
                }
              },
            ),
          ),
        );
        return;
      }
      final selectedSource = source;
      if (!mounted) {
        discovery?.cancel();
        return;
      }
      // Titles for the player and whether a next episode exists; resolved in
      // the background from the (usually cached) TMDB episode list.
      final episodeContext = season != null && episode != null
          ? _episodeContext(item, season, episode)
          : null;
      // IMDb id for OpenSubtitles; the player searches subtitles once it plays.
      final imdbId = externalIdsFuture.then(
        (value) => value.externalId,
        onError: (Object _) => '',
      );
      // Genres, runtime and synopsis for the pause screen; usually a cache
      // hit from the details page. The player works without it.
      final details = _tmdb
          .details(item)
          .then<MediaDetails?>((value) => value, onError: (Object _) => null);
      beforePlayerOpens();
      PerfTimeline.end('PLAY_PRESSED', 'PLAYER_OPEN');
      _spotlightTimer?.cancel();
      final route = AppPageRoute<void>(
        context: context,
        builder: (_) => PlayerScreen(
          item: playableItem,
          source: selectedSource,
          sources: discovery?.sources ?? [selectedSource],
          discovery: discovery,
          storage: _storage,
          playbackSettings: _playbackSettings,
          sourceFromCache: sourceFromCache,
          streamCacheKey: streamCacheKey,
          onRediscover: () {
            // Recovery can happen after the user changes source
            // preferences while the player is open. Read the controller
            // here instead of capturing the initial discovery snapshot.
            final current = _playbackSettings.value;
            return _providerPlugins.discoverStreams(
              pluginItem,
              season: season,
              episode: episode,
              allowedPluginIds: current.allowedProviderIds,
              allowTorrents:
                  current.p2pStreaming &&
                  defaultTargetPlatform == TargetPlatform.android,
            );
          },
          episodeLabel: season == null || episode == null
              ? ''
              : 'Season $season · Episode $episode',
          episodeContext: episodeContext,
          season: season,
          episode: episode,
          imdbId: imdbId,
          details: details,
          // Every episode change (the panel, Previous/Next, auto-play)
          // goes through this same flow.
          onPlayEpisode: season == null || episode == null
              ? null
              : (target, handOff) => _openItem(
                  item,
                  presentationContext: ownerContext,
                  handOff: handOff,
                  selectedSeason: target.season,
                  selectedEpisode: target.episode,
                ),
        ),
      );
      try {
        if (replacePlayer) {
          // The previous episode's player frees its engine first; then it is
          // replaced (it is the top route).
          await handOff.release();
          if (!mounted) return;
          await Navigator.pushReplacement<void, void>(context, route);
        } else {
          await Navigator.push<void>(context, route);
        }
      } finally {
        discovery?.cancel();
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          _startSpotlightTimer();
        }
      }
      await _loadHistory();
    } finally {
      dismissSearchDialog();
      if (mounted && presentationContext == null && _resolvingStreams) {
        setState(() => _resolvingStreams = false);
      }
    }
  }

  Future<void> _openPlaybackSettings(
    List<({String id, String name, String repository})> plugins,
  ) async {
    await Navigator.push<void>(
      context,
      AppPageRoute<void>(
        context: context,
        builder: (settingsContext) => Scaffold(
          backgroundColor: GlassTheme.background,
          body: PlaybackSettingsScreen(
            controller: _playbackSettings,
            plugins: plugins,
            onBack: () => Navigator.of(settingsContext).pop(),
          ),
        ),
      ),
    );
  }

  Future<void> _openAppearanceSettings() async {
    await Navigator.push<void>(
      context,
      AppPageRoute<void>(
        context: context,
        builder: (settingsContext) => Scaffold(
          backgroundColor: GlassTheme.background,
          body: AppearanceSettingsScreen(
            controller: widget.accentSettings,
            onBack: () => Navigator.of(settingsContext).pop(),
          ),
        ),
      ),
    );
  }

  Future<EpisodeContext?> _episodeContext(
    MediaItem item,
    int season,
    int episode,
  ) async {
    try {
      return EpisodeContext.fromTmdb(
        await _tmdb.allEpisodes(item),
        season: season,
        episode: episode,
      );
    } catch (_) {
      return null; // The player falls back to season and episode numbers.
    }
  }

  /// Items for the selected category, from the feed the view shows.
  List<MediaItem> get _shown {
    final items = _activeFeed.items;
    if (_category == 'Movies') {
      return items.where(MediaCatalogFilter.isMovie).toList();
    }
    if (_category == 'Series') {
      return items.where(MediaCatalogFilter.isSeries).toList();
    }
    if (_category == 'Continue watching') return _continueWatching;
    return items;
  }

  void _onSpotlightPageChanged(int page) {
    _spotlightPage = page;
    _spotlightPageValue.value = page;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _spotlightTimer?.cancel();
    _playbackSettings.dispose();
    _spotlightController.dispose();
    _homeScrollController.dispose();
    _spotlightPageValue.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _providerPlugins.removeListener(_onPluginChange);
    _providerPlugins.dispose();
    _pluginLibrary.dispose();
    for (final timer in _gateTimers.values) {
      timer.cancel();
    }
    // Requests still running for these rows finish without touching them.
    for (final feed in _catalogFeeds) {
      feed.removeListener(_onCatalogFeedChanged);
      feed.dispose();
    }
    super.dispose();
  }

  /// How far from the end of a row the next page is requested: about three
  /// cards, so it usually arrives before the viewer reaches the end.
  static const _loadMoreLead = 480.0;

  /// Calls [onNearEnd] when a row is scrolled, or laid out, within
  /// [_loadMoreLead] of its end. The controller ignores repeated calls
  /// while a page loads, so this can fire on every scroll update.
  bool _onRowScroll(ScrollMetrics metrics, int depth, VoidCallback onNearEnd) {
    if (depth != 0 ||
        metrics.axis != Axis.horizontal ||
        metrics.extentAfter >= _loadMoreLead) {
      return false;
    }
    // Layout can report metrics mid-frame; a row must not rebuild then.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) onNearEnd();
      });
    } else {
      onNearEnd();
    }
    return false;
  }

  /// One catalog row, rebuilt only by its own controller. Before its first
  /// titles arrive it shows [placeholder].
  Widget _pagedRow(
    String title,
    PagedFeedController feed, {
    bool showRanks = false,
    bool showPlaceholder = true,
    bool reserveSpace = false,
  }) => ListenableBuilder(
    listenable: feed,
    builder: (context, _) {
      final state = feed.state;
      if (state.items.isEmpty) {
        return showPlaceholder
            ? _deferredSectionPlaceholder(
                title,
                state.status,
                feed.retry,
                reserveSpace: reserveSpace,
              )
            : const SizedBox.shrink();
      }
      return _section(
        title,
        state.items,
        showRanks: showRanks,
        storageKey: 'row:$title',
        onNearEnd: state.hasMore ? feed.loadMore : null,
        trailing: state.isLoadingMore
            ? const SizedBox(
                width: 48,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : state.error != null
            ? SizedBox(
                width: 64,
                child: Center(
                  child: IconButton(
                    tooltip: 'Retry loading $title',
                    onPressed: () => unawaited(feed.retry()),
                    icon: const Icon(Symbols.refresh_rounded),
                  ),
                ),
              )
            : null,
      );
    },
  );

  Widget _section(
    String title,
    List<MediaItem> items, {
    bool showRanks = false,
    String? storageKey,
    VoidCallback? onNearEnd,
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 8, 0, 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.35,
                  ),
                ),
              ),
              const Icon(
                Symbols.chevron_right_rounded,
                size: 14,
                color: GlassTheme.muted,
              ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        SizedBox(
          height: 264,
          // Cards' frosted panels never overlap, so the whole row shares one
          // backdrop blur pass instead of one per panel.
          child: BackdropGroup(
            child: NotificationListener<ScrollMetricsNotification>(
              // Also covers a row too short to scroll that has more pages.
              onNotification: (notification) =>
                  onNearEnd != null &&
                  _onRowScroll(
                    notification.metrics,
                    notification.depth,
                    onNearEnd,
                  ),
              child: NotificationListener<ScrollUpdateNotification>(
                onNotification: (notification) =>
                    onNearEnd != null &&
                    _onRowScroll(
                      notification.metrics,
                      notification.depth,
                      onNearEnd,
                    ),
                child: _rowList(items, showRanks, storageKey, trailing),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _rowList(
    List<MediaItem> items,
    bool showRanks,
    String? storageKey,
    Widget? trailing,
  ) => ListView.separated(
    // Keeps each row's scroll position across tab switches and
    // rebuilds.
    key: storageKey == null ? null : PageStorageKey(storageKey),
    padding: const EdgeInsets.only(right: 18),
    scrollDirection: Axis.horizontal,
    itemCount: items.length + (trailing == null ? 0 : 1),
    separatorBuilder: (_, _) => const SizedBox(width: 13),
    itemBuilder: (context, index) {
      if (index == items.length) return trailing!;
      final item = items[index];
      // Real progress for watch-history entries; catalog items
      // have none.
      final resume = item.resumeMs > 0
          ? _resumeSummary(item)
          : ResumeSummary.unknown;
      final card = MediaCard(
        item: item,
        isFavorite: _favoriteKeys.contains(_favoriteKey(item)),
        progress: resume.fraction,
        progressLabel: resume.label,
        onTap: () => _showDetails(item),
        onFavorite: () async {
          final isFavorite = await _toggleFavorite(item);
          if (mounted) {
            ScaffoldMessenger.of(this.context).showSnackBar(
              SnackBar(
                content: Text(
                  isFavorite
                      ? '${item.name} saved to your list'
                      : '${item.name} removed from your list',
                ),
              ),
            );
          }
        },
      );
      if (!showRanks) return card;

      final rank = '${index + 1}';
      return SizedBox(
        width: 194,
        height: 264,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              bottom: -7,
              child: IgnorePointer(
                child: Text(
                  rank,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 190,
                    height: .82,
                    letterSpacing: index == 9 ? -24 : -8,
                    fontWeight: FontWeight.w900,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 3
                      ..color = Colors.white.withValues(alpha: .78),
                  ),
                ),
              ),
            ),
            Positioned(left: 48, top: 0, child: card),
          ],
        ),
      );
    },
  );

  Widget _brandMark() => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      boxShadow: [BoxShadow(color: GlassTheme.coralGlow, blurRadius: 18)],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset('assets/icons/reelish_icon.png', fit: BoxFit.cover),
    ),
  );

  Widget _brandHeader({bool spotlight = false}) {
    final transitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Padding(
      padding: spotlight
          ? const EdgeInsets.fromLTRB(35, 26, 35, 12)
          : const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: AnimatedSwitcher(
        duration: transitionDuration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          // New header content rises in; the outgoing content reverses down.
          final position = Tween<Offset>(
            begin: const Offset(0, .12),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: position, child: child),
          );
        },
        child: _searchVisible
            ? Row(
                key: const ValueKey('header-search'),
                children: [
                  Expanded(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _search,
                      builder: (context, value, _) => TextField(
                        controller: _search,
                        focusNode: _searchFocus,
                        onChanged: _searchChanged,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Symbols.search_rounded),
                          hintText: 'Find your next favorite',
                          suffixIcon: value.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: () {
                                    _search.clear();
                                    _searchChanged('');
                                  },
                                  icon: const Icon(Symbols.close_rounded),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Close search',
                    onPressed: _closeSearch,
                    icon: const Icon(Symbols.close_rounded),
                  ),
                ],
              )
            : Row(
                key: const ValueKey('brand-header'),
                children: [
                  _brandMark(),
                  const SizedBox(width: 10),
                  const Text.rich(
                    TextSpan(
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1.2,
                      ),
                      children: [
                        TextSpan(text: 'reel'),
                        TextSpan(
                          text: 'ish',
                          style: TextStyle(color: Color(0xFFFF7889)),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Search',
                    onPressed: () {
                      setState(() => _searchVisible = true);
                      _searchFocus.requestFocus();
                    },
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: .09),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Symbols.search_rounded),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _filtersAndSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 39,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final category in [
                  'For you',
                  'Movies',
                  'Series',
                  'Trending',
                  'Continue watching',
                ])
                  CategoryChip(
                    label: category,
                    selected: _category == category,
                    onTap: () {
                      setState(() => _category = category);
                      // Trending has its own list; the catalog other tabs
                      // use is never replaced, so they need no reload.
                      if (category == 'Trending' && !_trending.loading) {
                        unawaited(_loadTrending());
                      }
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _home() {
    final isSearch = _search.text.trim().isNotEmpty;
    final searchActive = _searchVisible || isSearch;
    final sectionCollapseDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final spotlights = _spotlightItems;
    final continueWatching = _continueWatching;
    final catalogHasItems =
        _movies.state.items.isNotEmpty || _series.state.items.isNotEmpty;
    final showHero = !searchActive && _category == 'For you' && catalogHasItems;

    // The spinner, error and empty message for the whole view. On the
    // catalog tabs they appear only while none of the tab's rows has
    // titles; once one has, a failed row shows its own Retry instead.
    final bool feedLoading;
    final String? feedError;
    final bool feedHasItems;
    if (_showsCatalog) {
      final feeds = _tabCatalogFeeds;
      feedHasItems = feeds.any((feed) => feed.state.items.isNotEmpty);
      feedLoading =
          !feedHasItems &&
          feeds.any(
            (feed) =>
                feed.state.status == PagedFeedStatus.idle ||
                feed.state.status == PagedFeedStatus.loading,
          );
      final error = feeds.map((feed) => feed.state.error).nonNulls.firstOrNull;
      feedError = feedHasItems || feedLoading || error == null
          ? null
          : _catalogFailureMessage(error);
    } else {
      final feed = _activeFeed;
      feedLoading = feed.loading;
      feedError = feed.error;
      feedHasItems = feed.items.isNotEmpty;
    }
    // A catalog row shows its own loading or Retry placeholder only when
    // the view's spinner or message is not already covering it.
    final rowPlaceholders = feedHasItems;

    return RefreshIndicator(
      onRefresh: _refreshVisibleHome,
      child: CustomScrollView(
        key: const PageStorageKey('home-feed'),
        controller: _homeScrollController,
        slivers: [
          SliverToBoxAdapter(
            child: AnimatedSize(
              duration: sectionCollapseDuration,
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: showHero && spotlights.isNotEmpty
                  ? _featuredCarousel(spotlights)
                  : _brandHeader(),
            ),
          ),
          SliverToBoxAdapter(child: _filtersAndSearch()),
          SliverToBoxAdapter(
            child: AnimatedSize(
              duration: sectionCollapseDuration,
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child:
                  !searchActive &&
                      continueWatching.isNotEmpty &&
                      _category != 'Continue watching'
                  ? _section('Pick up where you left off', continueWatching)
                  : const SizedBox.shrink(),
            ),
          ),
          if (_providerPlugins.repositories.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                child: GlassBox(
                  radius: 22,
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: GlassTheme.primary.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Symbols.link_rounded,
                          color: GlassTheme.primary,
                        ),
                      ),
                      const SizedBox(width: 13),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Make it yours',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Add a source to start watching.',
                              style: TextStyle(
                                color: GlassTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: () => ProviderInstallerModal.show(
                          context,
                          _providerPlugins,
                        ),
                        icon: const Icon(Symbols.add_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (feedLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          if (!feedLoading && feedError != null && feedHasItems)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                child: GlassBox(
                  radius: 16,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Symbols.cloud_off_rounded,
                        color: GlassTheme.muted,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          feedError,
                          style: const TextStyle(
                            color: GlassTheme.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Retry catalog',
                        onPressed: () => _reloadActiveFeed(),
                        icon: const Icon(Symbols.refresh_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!feedLoading && !feedHasItems)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 34,
                ),
                child: Column(
                  children: [
                    Icon(
                      feedError == null
                          ? Symbols.movie_rounded
                          : Symbols.cloud_off_rounded,
                      size: 34,
                      color: GlassTheme.muted,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      feedError ??
                          (isSearch
                              ? 'No results matching ${_search.text.trim()}'
                              : 'Nothing to show just yet'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      feedError == null
                          ? 'Try another search or refresh your picks.'
                          : 'Your API key is not shown in this message. Retry after checking the connection or key.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: GlassTheme.muted),
                    ),
                    if (feedError != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => _reloadActiveFeed(),
                        icon: const Icon(Symbols.refresh_rounded),
                        label: const Text('Retry'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (_category == 'Continue watching' && continueWatching.isNotEmpty)
            SliverToBoxAdapter(
              child: _section('Continue watching', continueWatching),
            ),
          if (_category == 'For you' && !isSearch)
            _deferredSectionGate(
              enabled: _catalogSettled,
              feed: _top10,
              child: _pagedRow(
                'Top 10 recommendations',
                _top10,
                showRanks: true,
                reserveSpace: _catalogSettled,
              ),
            ),
          if (_category == 'For you' && !isSearch)
            _deferredSectionGate(
              enabled: _catalogSettled,
              feed: _releases,
              child: _pagedRow(
                'New releases',
                _releases,
                reserveSpace: _catalogSettled,
              ),
            ),
          if (((_category == 'Movies' && isSearch) ||
                  _category == 'Trending') &&
              _shown.isNotEmpty)
            SliverToBoxAdapter(
              child: _section(
                _category == 'Trending' ? 'Trending now' : 'Movies',
                _shown,
              ),
            ),
          if (_category == 'Movies' && !isSearch)
            SliverToBoxAdapter(
              child: _pagedRow(
                'Movies',
                _movies,
                showPlaceholder: rowPlaceholders,
              ),
            ),
          if (_category == 'Series' && isSearch && _shown.isNotEmpty)
            SliverToBoxAdapter(child: _section('Series to get into', _shown)),
          if (_category == 'Series' && !isSearch)
            SliverToBoxAdapter(
              child: _pagedRow(
                'Series to get into',
                _series,
                showPlaceholder: rowPlaceholders,
              ),
            ),
          if (_category == 'For you' && isSearch && _shown.isNotEmpty)
            SliverToBoxAdapter(child: _section('Search results', _shown)),
          if (_category == 'For you' && !isSearch)
            SliverToBoxAdapter(
              child: _pagedRow(
                'New movies',
                _movies,
                showPlaceholder: rowPlaceholders,
              ),
            ),
          if (_category == 'For you' && !isSearch)
            SliverToBoxAdapter(
              child: _pagedRow(
                'Series worth the queue',
                _series,
                showPlaceholder: rowPlaceholders,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),
          // Clears the floating dock so the TMDB notice stays readable.
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              18,
              0,
              18,
              SettingsMetrics.dockClearance +
                  MediaQuery.paddingOf(context).bottom,
            ),
            sliver: const SliverToBoxAdapter(child: TmdbAttributionFooter()),
          ),
        ],
      ),
    );
  }

  /// The navigation dock floats over about this much of Home's bottom edge.
  static const _dockOverlap = 100.0;

  /// Starts a deferred row's first load as it nears the screen.
  ///
  /// Only an idle row loads automatically. A failed row stays failed while
  /// visible; otherwise each rebuild after the failure would start another
  /// request. Its Retry button and pull-to-refresh are the only ways to try
  /// again.
  Widget _deferredSectionGate({
    required bool enabled,
    required PagedFeedController feed,
    required Widget child,
  }) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final approaching =
          enabled &&
          feed.state.status == PagedFeedStatus.idle &&
          _isApproaching(context, constraints);
      if (!approaching) {
        _gateTimers.remove(feed)?.cancel();
      } else {
        // Loads only once the row has stayed near the screen briefly:
        // a layout animation (the spotlight growing in) or a fling can
        // pass a row by without it being needed.
        _gateTimers[feed] ??= Timer(_gateDwell, () {
          _gateTimers.remove(feed);
          // The row may have left the view (another tab, a search) since.
          if (mounted && _category == 'For you' && _showsCatalog) {
            unawaited(feed.ensureLoaded());
          }
        });
      }
      return SliverToBoxAdapter(child: child);
    },
  );

  static const _gateDwell = Duration(milliseconds: 300);
  final Map<PagedFeedController, Timer> _gateTimers = {};

  /// Before the first scroll only a row the viewer can actually see loads;
  /// the bottom of Home is under the dock. Once Home is scrolled, a row
  /// inside the cache area just below the screen starts early so it is
  /// usually ready when it arrives.
  bool _isApproaching(BuildContext context, SliverConstraints constraints) {
    final hidden = _dockOverlap + MediaQuery.paddingOf(context).bottom;
    if (constraints.remainingPaintExtent > hidden) return true;
    final scrolled =
        _homeScrollController.hasClients && _homeScrollController.offset > 0;
    return scrolled && constraints.remainingCacheExtent > 0;
  }

  /// What a row shows before its first titles. With [reserveSpace], an idle
  /// or loading row keeps the height of a loaded one, so rows below it do
  /// not slide into view (and start loading) before they are reached.
  Widget _deferredSectionPlaceholder(
    String title,
    PagedFeedStatus status,
    VoidCallback onRetry, {
    bool reserveSpace = false,
  }) {
    if (status == PagedFeedStatus.ready) return const SizedBox.shrink();
    if (reserveSpace && status != PagedFeedStatus.failed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -.35,
              ),
            ),
            const SizedBox(height: 13),
            SizedBox(
              height: 264,
              child: status == PagedFeedStatus.loading
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      );
    }
    if (status == PagedFeedStatus.idle) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      child: GlassBox(
        radius: 18,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (status == PagedFeedStatus.loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Symbols.refresh_rounded, size: 15),
                label: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _featuredCarousel(List<MediaItem> items) => Stack(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Column(
          children: [
            SizedBox(
              height: 483,
              child: PageView.builder(
                controller: _spotlightController,
                itemCount: items.length > 1 ? null : items.length,
                onPageChanged: _onSpotlightPageChanged,
                itemBuilder: (context, page) => _featured(
                  items[page % items.length],
                  imageCacheHeight:
                      (483 * MediaQuery.devicePixelRatioOf(context)).round(),
                ),
              ),
            ),
            if (items.length > 1) ...[
              const SizedBox(height: 12),
              ValueListenableBuilder<int>(
                valueListenable: _spotlightPageValue,
                builder: (context, page, _) => Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var index = 0; index < items.length; index++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        width: index == page % items.length ? 16 : 5,
                        height: 5,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: index == page % items.length
                              ? GlassTheme.primary
                              : Colors.white.withValues(alpha: .35),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: _brandHeader(spotlight: true),
      ),
    ],
  );

  Widget _featured(MediaItem item, {required int imageCacheHeight}) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.background.isNotEmpty)
              Image.network(
                item.background,
                fit: BoxFit.cover,
                cacheHeight: imageCacheHeight,
                errorBuilder: (_, _, _) =>
                    ColoredBox(color: GlassTheme.elevatedSurface),
              )
            else
              ColoredBox(color: GlassTheme.elevatedSurface),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x77000000),
                    Color(0x26000000),
                    Color(0x00000000),
                    Color(0xD90B0B0F),
                    GlassTheme.background,
                  ],
                  stops: [0, .2, .46, .82, 1],
                ),
              ),
            ),
            Positioned(
              left: 21,
              right: 21,
              bottom: 22,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: GlassTheme.primary.withValues(alpha: .15),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: GlassTheme.primary.withValues(alpha: .35),
                      ),
                    ),
                    child: Text(
                      'REELISH SPOTLIGHT',
                      style: TextStyle(
                        color: GlassTheme.primary,
                        fontSize: 9,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 11),
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 35,
                      height: 1.02,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    [
                      item.year,
                      item.type == 'series' ? 'Series' : 'Movie',
                      if (item.rating.isNotEmpty) '${item.rating}/10',
                    ].where((value) => value.isNotEmpty).join('  |  '),
                    style: const TextStyle(
                      color: Color(0xC7FFFFFF),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      item.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xC7FFFFFF),
                        height: 1.35,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: GlassTheme.primary,
                          foregroundColor: GlassTheme.background,
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 15,
                          ),
                        ),
                        onPressed: () => _showDetails(item),
                        icon: const Icon(Symbols.info_rounded),
                        label: const Text(
                          'Details',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: .35),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 19,
                            vertical: 15,
                          ),
                        ),
                        onPressed: () async {
                          final isFavorite = await _toggleFavorite(item);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  isFavorite
                                      ? '${item.name} saved to your list'
                                      : '${item.name} removed from your list',
                                ),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Symbols.add_rounded, size: 19),
                        label: const Text('My list'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
  /// Why the TV catalog is empty, once both rows have failed; null while
  /// either has titles or is still loading.
  String? get _tvCatalogError {
    final feeds = [_movies, _series];
    if (feeds.any(
      (feed) =>
          feed.state.items.isNotEmpty ||
          feed.state.status == PagedFeedStatus.idle ||
          feed.state.status == PagedFeedStatus.loading,
    )) {
      return null;
    }
    final error = feeds.map((feed) => feed.state.error).nonNulls.firstOrNull;
    return error == null ? null : _catalogFailureMessage(error);
  }

  /// The same refreshes the mobile dock runs when a tab opens.
  void _onTvDestinationChanged(TvDestination destination) {
    setState(() {
      _tvDestination = destination;
      if (destination == TvDestination.library) _libraryRefreshToken++;
    });
    if (destination == TvDestination.library) unawaited(_loadHistory());
    if (destination == TvDestination.home) {
      unawaited(_loadFavorites());
      _revalidateStaleFeeds();
    }
  }

  /// The TV interface: the same catalog, storage, plugins and play flow as
  /// mobile, presented for a remote. See [TvHomeShell].
  Widget _buildTv(
    List<({String id, String name, String repository})> availablePlugins,
  ) {
    final catalog = TvCatalog(
      tmdb: _tmdb,
      movies: _movies,
      series: _series,
      releases: _releases,
      top10: _top10,
      spotlight: _spotlightItems,
      continueWatching: _continueWatching,
      catalogSettled: _catalogSettled,
      resumeFraction: (item) => _resumeSummary(item).fraction,
      favoriteKeys: _favoriteKeys,
      hasSources: _providerPlugins.repositories.isNotEmpty,
      catalogError: _tvCatalogError,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        TvHomeShell(
          destination: _tvDestination,
          onDestinationChanged: _onTvDestinationChanged,
          pageBuilder: (context, destination) => switch (destination) {
            TvDestination.home => TvHomePage(
              catalog: catalog,
              onOpen: _showDetails,
              onRetry: () => unawaited(_reloadActiveFeed()),
              onAddSource: () =>
                  ProviderInstallerModal.show(context, _providerPlugins),
            ),
            TvDestination.movies => TvCatalogPage(
              title: 'Movies',
              feed: _movies,
              onOpen: _showDetails,
              isFavorite: catalog.isFavorite,
            ),
            TvDestination.series => TvCatalogPage(
              title: 'Series',
              feed: _series,
              onOpen: _showDetails,
              isFavorite: catalog.isFavorite,
            ),
            TvDestination.search => TvSearchPage(
              tmdb: _tmdb,
              onOpen: _showDetails,
              isFavorite: catalog.isFavorite,
            ),
            TvDestination.library => TvLibraryPage(
              storage: _storage,
              onOpen: _showDetails,
              refreshToken: _libraryRefreshToken,
            ),
            TvDestination.plugins => TvReadableWidth(
              maxWidth: 900,
              child: PluginsScreen(
                pluginService: _providerPlugins,
                pluginLibrary: _pluginLibrary,
              ),
            ),
            TvDestination.settings => SettingsScreen(
              accentSettings: widget.accentSettings,
              onAppearanceSettings: () =>
                  unawaited(_openAppearanceSettings()),
              onPlaybackSettings: () =>
                  unawaited(_openPlaybackSettings(availablePlugins)),
            ),
          },
        ),
        if (_resolvingStreams) _resolvingOverlay(),
      ],
    );
  }

  Widget _resolvingOverlay() => ColoredBox(
    color: Colors.black.withValues(alpha: 0.72),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: GlassTheme.primary),
          const SizedBox(height: 16),
          Text(
            'Searching providers…',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'This can take a moment while sources are checked.',
            style: TextStyle(color: GlassTheme.muted, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final availablePlugins = [
      for (final repository in _providerPlugins.repositories)
        for (final plugin in repository.plugins)
          (
            id: '${repository.url}|${plugin.id}',
            name: plugin.name,
            repository: repository.name,
          ),
    ];
    if (DeviceCapabilities.isTv) return _buildTv(availablePlugins);
    final pages = [
      TabPageTransition(active: _tab == 0, child: _home()),
      TabPageTransition(
        active: _tab == 1,
        child: PluginsScreen(
          pluginService: _providerPlugins,
          pluginLibrary: _pluginLibrary,
        ),
      ),
      TabPageTransition(
        active: _tab == 2,
        child: LibraryScreen(
          storage: _storage,
          onPlay: _showDetails,
          refreshToken: _libraryRefreshToken,
        ),
      ),
      TabPageTransition(
        active: _tab == 3,
        child: SettingsScreen(
          accentSettings: widget.accentSettings,
          onAppearanceSettings: () => unawaited(_openAppearanceSettings()),
          onPlaybackSettings: () =>
              unawaited(_openPlaybackSettings(availablePlugins)),
        ),
      ),
    ];
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            bottom: false,
            child: IndexedStack(index: _tab, children: pages),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: RepaintBoundary(
              child: SoftGlassDock(
                selectedIndex: _tab,
                onSelected: (value) {
                  setState(() {
                    _tab = value;
                    if (value == 2) _libraryRefreshToken++;
                  });
                  if (value == 2) {
                    unawaited(_loadHistory());
                  }
                  if (value == 0) {
                    unawaited(_loadFavorites());
                    _revalidateStaleFeeds();
                  }
                },
              ),
            ),
          ),
          if (_resolvingStreams) _resolvingOverlay(),
        ],
      ),
    );
  }
}
