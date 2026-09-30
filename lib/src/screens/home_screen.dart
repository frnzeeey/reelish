import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:feather_icon_font/feather_icon_font.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../navigation/app_transitions.dart';
import '../services/github_update_service.dart';
import '../services/storage_service.dart';
import '../services/stream_discovery.dart';
import '../services/tmdb_service.dart';
import '../services/nuvio_plugin_service.dart';
import '../services/playback_settings_controller.dart';
import '../theme/glass_theme.dart';
import '../widgets/nuvio_plugin_installer_modal.dart';
import '../widgets/category_chip.dart';
import '../widgets/glass_box.dart';
import '../widgets/media_card.dart';
import '../widgets/soft_glass_dock.dart';
import '../widgets/player/episode_selector_sheet.dart';
import '../widgets/player/stream_selector_sheet.dart';
import 'plugins_screen.dart';
import 'library_screen.dart';
import 'player_screen.dart';
import 'media_details_screen.dart';
import 'playback_settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _nuvioPlugins = NuvioPluginService();
  final _storage = StorageService();
  final _playbackSettings = PlaybackSettingsController();
  final _tmdb = TmdbService();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _spotlightController = PageController();
  final ValueNotifier<int> _spotlightPageValue = ValueNotifier(0);
  List<MediaItem> _items = [], _history = [];
  List<MediaItem> _spotlightItems = [];
  List<MediaItem> _recommendations = [];
  List<MediaItem> _newReleases = [];
  String? _catalogError;
  final Map<String, List<MediaItem>> _recommendationCache = {};
  bool _loading = true,
      _loadingNewReleases = false,
      _newReleasesLoaded = false,
      _resolvingStreams = false;
  bool _searchVisible = false;
  String _category = 'For you';
  int _tab = 0;
  bool _openingDetails = false;
  int _recommendationRequest = 0;
  int _spotlightPage = 0;
  int _libraryRefreshToken = 0;
  Timer? _debounce;
  Timer? _spotlightTimer;
  bool _checkingForUpdate = false;
  bool _updatePromptOpen = false;
  DateTime? _lastUpdateCheckAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nuvioPlugins.addListener(_onPluginChange);
    _startSpotlightTimer();
    _start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForUpdate());
    });
  }

  void _startSpotlightTimer() {
    _spotlightTimer?.cancel();
    _spotlightTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted ||
          MediaQuery.disableAnimationsOf(context) ||
          _searchVisible ||
          _tab != 0 ||
          _category != 'For you' ||
          _search.text.trim().isNotEmpty ||
          _spotlightItems.length < 2 ||
          !_spotlightController.hasClients) {
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
    unawaited(_load());
    await _nuvioPlugins.load();
    await _loadHistory();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkForUpdate());
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _startSpotlightTimer();
      }
    } else {
      _spotlightTimer?.cancel();
      _spotlightTimer = null;
    }
  }

  Future<void> _checkForUpdate() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final now = DateTime.now();
    final lastCheck = _lastUpdateCheckAt;
    if (_checkingForUpdate ||
        _updatePromptOpen ||
        (lastCheck != null &&
            now.difference(lastCheck) < const Duration(hours: 6))) {
      return;
    }
    _lastUpdateCheckAt = now;
    _checkingForUpdate = true;
    try {
      final update = await GitHubUpdateService.checkForUpdate();
      if (!mounted || update == null) return;
      _updatePromptOpen = true;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Update available'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reelish ${update.version} is ready to download.'),
                if (update.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(update.notes.trim()),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                unawaited(_downloadAndInstallUpdate(update));
              },
              child: const Text('Download and install'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Update checks should never interrupt normal app use.
    } finally {
      _updatePromptOpen = false;
      _checkingForUpdate = false;
    }
  }

  Future<void> _downloadAndInstallUpdate(GitHubUpdate update) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    var received = 0;
    var total = 0;
    StateSetter? setProgress;
    var progressDialogOpen = true;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, updateDialogState) {
            setProgress = updateDialogState;
            final progress = total > 0 ? received / total : null;
            return AlertDialog(
              title: const Text('Downloading update'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 12),
                  Text(
                    total > 0
                        ? '${(received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB'
                        : '${(received / 1048576).toStringAsFixed(1)} MB',
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    void closeProgressDialog() {
      if (progressDialogOpen && mounted) {
        progressDialogOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    try {
      final apk = await GitHubUpdateService.downloadApk(
        update,
        onProgress: (downloaded, expected) {
          received = downloaded;
          total = expected;
          setProgress?.call(() {});
        },
      );
      closeProgressDialog();
      final result = await GitHubUpdateService.installApk(apk);
      if (!mounted) return;
      if (result == 'permission_required') {
        // Android returns here after the user enables installs from Reelish;
        // allow another check immediately so the update prompt can retry.
        _lastUpdateCheckAt = null;
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Allow installs from Reelish, then return to continue the update.',
            ),
          ),
        );
      } else if (result != 'installer_opened') {
        messenger.showSnackBar(
          const SnackBar(content: Text("Could not open Android's installer.")),
        );
      }
    } catch (_) {
      closeProgressDialog();
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not download the update. Try again later.'),
          ),
        );
      }
    }
  }

  void _onPluginChange() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _load({String? query}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _catalogError = null;
      });
    }
    if (query == null && _category == 'For you') {
      unawaited(_loadNewReleases());
    }
    Object? loadError;
    Future<List<MediaItem>> safe(Future<List<MediaItem>> future) async {
      try {
        return await future;
      } catch (error) {
        loadError ??= error;
        return [];
      }
    }

    final results = await Future.wait([
      if (query != null)
        safe(_tmdb.search(query))
      else if (_category == 'Trending')
        safe(_tmdb.trending())
      else
        safe(_tmdb.popular('movie')),
      if (query == null && _category != 'Trending')
        safe(_tmdb.popular('series')),
    ]);
    final combined = <String, MediaItem>{};
    for (final list in results) {
      for (final item in list) {
        combined.putIfAbsent('${item.type}:${item.id}', () => item);
      }
    }
    final values = combined.values.toList();
    if (!mounted) return;
    setState(() {
      _items = values;
      _spotlightItems = _tmdb.spotlight([..._newReleases, ...values]);
      _loading = false;
      _catalogError = loadError == null
          ? null
          : _catalogFailureMessage(loadError!);
    });
    if (query == null && _category == 'For you') {
      unawaited(_loadTopRecommendations(values));
    }
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

  Future<void> _loadNewReleases() async {
    if (_newReleasesLoaded || _loadingNewReleases) return;
    if (mounted) setState(() => _loadingNewReleases = true);
    try {
      final releases = await _tmdb.newReleases();
      if (!mounted) return;
      setState(() {
        _newReleases = releases;
        _spotlightItems = _tmdb.spotlight([...releases, ..._items]);
        _newReleasesLoaded = true;
        _loadingNewReleases = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingNewReleases = false);
    }
  }

  Future<void> _loadTopRecommendations(List<MediaItem> items) async {
    final request = ++_recommendationRequest;
    final seeds = <MediaItem>[];
    for (final type in ['movie', 'series']) {
      final candidates = items.where((item) => item.type == type).toList()
        ..sort((a, b) {
          final ratingA = double.tryParse(a.rating) ?? 0;
          final ratingB = double.tryParse(b.rating) ?? 0;
          return ratingB.compareTo(ratingA);
        });
      if (candidates.isNotEmpty) seeds.add(candidates.first);
    }
    if (seeds.isEmpty) {
      if (mounted) setState(() => _recommendations = []);
      return;
    }
    final cacheKey =
        'top:${seeds.map((item) => '${item.type}:${item.id}').join('|')}';
    final cached = _recommendationCache[cacheKey];
    if (cached != null) {
      if (mounted) setState(() => _recommendations = cached);
      return;
    }
    if (mounted) setState(() => _recommendations = []);
    try {
      final seedKeys = seeds.map((item) => '${item.type}:${item.id}').toSet();
      final lists = await Future.wait(
        seeds.map((item) => _tmdb.recommendations(item)),
      );
      final seen = <String>{};
      final recommendations =
          lists
              .expand((list) => list)
              .where(
                (item) =>
                    !seedKeys.contains('${item.type}:${item.id}') &&
                    seen.add('${item.type}:${item.id}'),
              )
              .toList()
            ..sort((a, b) {
              final ratingA = double.tryParse(a.rating) ?? 0;
              final ratingB = double.tryParse(b.rating) ?? 0;
              return ratingB.compareTo(ratingA);
            });
      _recommendationCache[cacheKey] = recommendations;
      if (!mounted || request != _recommendationRequest) return;
      setState(() => _recommendations = recommendations.take(10).toList());
    } catch (_) {
      if (!mounted || request != _recommendationRequest) return;
      setState(() => _recommendations = []);
    }
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
    _spotlightTimer?.cancel();
    try {
      await Navigator.push<void>(
        context,
        AppPageRoute<void>(
          context: context,
          details: true,
          builder: (_) => MediaDetailsScreen(
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
      }
    }
  }

  Future<void> _loadHistory() async {
    final value = await _storage.history();
    if (mounted) setState(() => _history = value);
  }

  void _searchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _load(query: value.trim().isEmpty ? null : value),
    );
  }

  Future<void> _openItem(
    MediaItem item, {
    BuildContext? presentationContext,
    int? selectedSeason,
    int? selectedEpisode,
  }) async {
    var searchDialogOpen = false;
    void dismissSearchDialog() {
      if (!searchDialogOpen) return;
      searchDialogOpen = false;
      if (presentationContext?.mounted == true) {
        Navigator.of(presentationContext!, rootNavigator: true).pop();
      }
    }

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
      final selected = await EpisodeSelectorSheet.show(
        presentationContext ?? context,
        item.name,
        episodeList,
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
        showDialog<void>(
          context: presentationContext!,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (_) => PopScope(
            canPop: false,
            child: Dialog(
              backgroundColor: Colors.transparent,
              child: GlassBox(
                padding: const EdgeInsets.all(22),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: GlassTheme.primary),
                    const SizedBox(width: 18),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Searching providers…',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Finding a stream for ${item.name}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: GlassTheme.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } else if (mounted) {
      setState(() => _resolvingStreams = true);
    }
    try {
      // Resolve IMDb metadata for subtitles in parallel with stream discovery.
      // Nuvio providers need the TMDB ID already present on the selected item;
      // serially waiting for this optional lookup delays every playback start.
      final externalIdsFuture = _tmdb.resolveIds(item);
      final episodeCode = season != null && episode != null
          ? ' S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
          : '';
      // Legacy items may carry an IMDb ID and need a TMDB lookup before
      // providers can search. Bound this optional lookup so a slow TMDB
      // response cannot delay provider discovery and playback startup.
      final pluginId = await _tmdb
          .resolveTmdbId(item)
          .timeout(const Duration(seconds: 3), onTimeout: () => '');
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
          cacheKey: streamCacheKey,
        );
        sourceFromCache = source != null;
      }
      if (source == null) {
        discovery = _nuvioPlugins.discoverStreams(
          pluginItem,
          season: season,
          episode: episode,
          allowedPluginIds: playback.allowedProviderIds,
          allowTorrents: allowTorrents,
        );
        source = await discovery.firstSource;
        if (source != null && !playback.autoStreamSelection) {
          await Future.any([
            discovery.finished,
            Future<void>.delayed(
              Duration(seconds: playback.streamSelectionTimeoutSeconds),
            ),
          ]);
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
              _nuvioPlugins.lastLookupMessage ??
                  'No source was returned for this title.',
            ),
            action: SnackBarAction(
              label: 'PLUGINS',
              onPressed: () {
                setState(() => _tab = 1);
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
      _spotlightTimer?.cancel();
      try {
        await Navigator.push<void>(
          context,
          AppPageRoute<void>(
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
              onRefreshSources: () => _nuvioPlugins.streams(
                pluginItem,
                season: season,
                episode: episode,
                allowedPluginIds: playback.allowedProviderIds,
                allowTorrents: allowTorrents,
              ),
              onNextEpisode: season == null || episode == null
                  ? null
                  : () => _playNextEpisode(
                      item,
                      season!,
                      episode!,
                      presentationContext: presentationContext,
                    ),
            ),
          ),
        );
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

  Future<void> _playNextEpisode(
    MediaItem item,
    int season,
    int episode, {
    BuildContext? presentationContext,
  }) async {
    try {
      final episodes = await _tmdb.allEpisodes(item);
      episodes.sort((a, b) {
        final seasonComparison = ((a['season_number'] as num?) ?? 0).compareTo(
          (b['season_number'] as num?) ?? 0,
        );
        if (seasonComparison != 0) return seasonComparison;
        return ((a['episode_number'] as num?) ?? 0).compareTo(
          (b['episode_number'] as num?) ?? 0,
        );
      });
      final nextEpisode = episodes.where((entry) {
        final entrySeason = (entry['season_number'] as num?)?.toInt() ?? 0;
        final entryEpisode = (entry['episode_number'] as num?)?.toInt() ?? 0;
        return entrySeason > season ||
            (entrySeason == season && entryEpisode > episode);
      }).firstOrNull;
      if (nextEpisode == null) {
        if (mounted) {
          ScaffoldMessenger.of(presentationContext ?? context).showSnackBar(
            const SnackBar(
              content: Text('There is no next episode available.'),
            ),
          );
        }
        return;
      }
      final nextSeason = (nextEpisode['season_number'] as num?)?.toInt();
      final nextNumber = (nextEpisode['episode_number'] as num?)?.toInt();
      if (nextSeason == null || nextNumber == null || !mounted) return;
      final detailContext = presentationContext?.mounted == true
          ? presentationContext
          : null;
      Navigator.of(context).pop();
      await Future<void>.delayed(Duration.zero);
      if (mounted) {
        await _openItem(
          item,
          presentationContext: detailContext,
          selectedSeason: nextSeason,
          selectedEpisode: nextNumber,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(presentationContext ?? context).showSnackBar(
          const SnackBar(content: Text('Could not find the next episode.')),
        );
      }
    }
  }

  List<MediaItem> get _shown {
    if (_category == 'Movies')
      return _items.where((e) => e.type == 'movie').toList();
    if (_category == 'Series')
      return _items.where((e) => e.type == 'series').toList();
    if (_category == 'Continue watching')
      return _history.where((e) => e.resumeMs > 0).toList();
    return _items;
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
    _spotlightPageValue.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _nuvioPlugins.removeListener(_onPluginChange);
    _nuvioPlugins.dispose();
    super.dispose();
  }

  Widget _section(
    String title,
    List<MediaItem> items, {
    bool showRanks = false,
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
                FeatherIcons.chevronRight,
                size: 14,
                color: GlassTheme.muted,
              ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        SizedBox(
          height: 264,
          child: ListView.separated(
            padding: const EdgeInsets.only(right: 18),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 13),
            itemBuilder: (context, index) {
              final item = items[index];
              final card = MediaCard(
                item: item,
                progress: item.resumeMs > 0 ? .36 : 0,
                onTap: () => _showDetails(item),
                onFavorite: () async {
                  await _storage.toggleFavorite(item);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${item.name} saved to your list'),
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
                            fontSize: index == 9 ? 138 : 190,
                            height: .82,
                            letterSpacing: index == 9 ? -12 : -8,
                            fontWeight: FontWeight.w900,
                            foreground: Paint()
                              ..style = PaintingStyle.stroke
                              ..strokeWidth = 1
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
          ),
        ),
      ],
    ),
  );

  Widget _brandMark() => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      boxShadow: const [BoxShadow(color: GlassTheme.coralGlow, blurRadius: 18)],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset('assets/icons/reelish_icon.png', fit: BoxFit.cover),
    ),
  );

  Widget _brandHeader() {
    final transitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 18, 12),
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
                          prefixIcon: const Icon(FeatherIcons.search),
                          hintText: 'Find your next favorite',
                          suffixIcon: value.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: () {
                                    _search.clear();
                                    _searchChanged('');
                                  },
                                  icon: const Icon(FeatherIcons.x),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Close search',
                    onPressed: _closeSearch,
                    icon: const Icon(FeatherIcons.x),
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
                    icon: const Icon(FeatherIcons.search),
                  ),
                  const SizedBox(width: 5),
                  IconButton(
                    tooltip: 'Your library',
                    onPressed: () => setState(() => _tab = 2),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: .09),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(FeatherIcons.user),
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
                      if (category == 'Trending') _load();
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
    final movies = _items.where((item) => item.type == 'movie').toList();
    final series = _items.where((item) => item.type == 'series').toList();
    final spotlights = _spotlightItems;
    final continueWatching = _history
        .where((item) => item.resumeMs > 0)
        .toList();
    final showHero =
        !searchActive && _category == 'For you' && _items.isNotEmpty;

    return RefreshIndicator(
      onRefresh: () => _load(query: isSearch ? _search.text : null),
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _brandHeader()),
          SliverToBoxAdapter(
            child: AnimatedSize(
              duration: sectionCollapseDuration,
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: showHero && spotlights.isNotEmpty
                  ? _featuredCarousel(spotlights)
                  : const SizedBox.shrink(),
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
          if (_nuvioPlugins.repositories.isEmpty)
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
                        child: const Icon(
                          FeatherIcons.link,
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
                        onPressed: () => NuvioPluginInstallerModal.show(
                          context,
                          _nuvioPlugins,
                        ),
                        icon: const Icon(FeatherIcons.plus),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          if (!_loading && _catalogError != null && _items.isNotEmpty)
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
                        FeatherIcons.cloudOff,
                        color: GlassTheme.muted,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _catalogError!,
                          style: const TextStyle(
                            color: GlassTheme.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Retry catalog',
                        onPressed: () =>
                            _load(query: isSearch ? _search.text.trim() : null),
                        icon: const Icon(FeatherIcons.refreshCw),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!_loading && _items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 34,
                ),
                child: Column(
                  children: [
                    Icon(
                      _catalogError == null
                          ? FeatherIcons.film
                          : FeatherIcons.cloudOff,
                      size: 34,
                      color: GlassTheme.muted,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _catalogError ??
                          (isSearch
                              ? 'No results matching ${_search.text.trim()}'
                              : 'Nothing to show just yet'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _catalogError == null
                          ? 'Try another search or refresh your picks.'
                          : 'Your API key is not shown in this message. Retry after checking the connection or key.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: GlassTheme.muted),
                    ),
                    if (_catalogError != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () =>
                            _load(query: isSearch ? _search.text.trim() : null),
                        icon: const Icon(FeatherIcons.refreshCw),
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
          if (_category == 'For you' &&
              !isSearch &&
              _recommendations.isNotEmpty)
            SliverToBoxAdapter(
              child: _section(
                'Top 10 recommendations',
                _recommendations.take(10).toList(),
                showRanks: true,
              ),
            ),
          if (_category == 'For you' && !isSearch && _loadingNewReleases)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(18, 12, 18, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'New releases',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 14),
                    Center(
                      child: CircularProgressIndicator(
                        color: GlassTheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_category == 'For you' && !isSearch && _newReleases.isNotEmpty)
            SliverToBoxAdapter(child: _section('New releases', _newReleases)),
          if ((_category == 'Movies' || _category == 'Trending') &&
              _shown.isNotEmpty)
            SliverToBoxAdapter(
              child: _section(
                _category == 'Trending' ? 'Trending now' : 'Movies',
                _shown,
              ),
            ),
          if (_category == 'Series' && _shown.isNotEmpty)
            SliverToBoxAdapter(child: _section('Series to get into', _shown)),
          if (_category == 'For you' && isSearch && _shown.isNotEmpty)
            SliverToBoxAdapter(child: _section('Search results', _shown)),
          if (_category == 'For you' && !isSearch && movies.isNotEmpty)
            SliverToBoxAdapter(child: _section('Popular movies', movies)),
          if (_category == 'For you' && !isSearch && series.isNotEmpty)
            SliverToBoxAdapter(
              child: _section('Series worth the queue', series),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 20),
              child: Text(
                'Movie and TV metadata from TMDB. This product is not endorsed or certified by TMDB.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GlassTheme.muted, fontSize: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _featuredCarousel(List<MediaItem> items) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
    child: Column(
      children: [
        SizedBox(
          height: 425,
          child: PageView.builder(
            controller: _spotlightController,
            itemCount: items.length > 1 ? null : items.length,
            onPageChanged: _onSpotlightPageChanged,
            itemBuilder: (context, page) => _featured(
              items[page % items.length],
              imageCacheHeight: (425 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
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
  );

  Widget _featured(
    MediaItem item, {
    required int imageCacheHeight,
  }) => ClipRRect(
    borderRadius: BorderRadius.circular(28),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (item.background.isNotEmpty)
          Image.network(
            item.background,
            fit: BoxFit.cover,
            cacheHeight: imageCacheHeight,
            errorBuilder: (_, __, ___) =>
                ColoredBox(color: GlassTheme.elevatedSurface),
          )
        else
          ColoredBox(color: GlassTheme.elevatedSurface),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xAA080B12), Color(0x00080B12), Color(0xF2080B12)],
              stops: [0, .32, 1],
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
                child: const Text(
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
                  color: Colors.white70,
                  fontSize: 12,
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
                    color: Colors.white70,
                    height: 1.35,
                    fontSize: 12,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () => _showDetails(item),
                    icon: const Icon(FeatherIcons.info),
                    label: const Text(
                      'Details',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: .35),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () async {
                      await _storage.toggleFavorite(item);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${item.name} saved to your list'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(FeatherIcons.plus, size: 19),
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
  @override
  Widget build(BuildContext context) {
    final availablePlugins = [
      for (final repository in _nuvioPlugins.repositories)
        for (final plugin in repository.plugins)
          (
            id: '${repository.url}|${plugin.id}',
            name: plugin.name,
            repository: repository.name,
          ),
    ];
    final pages = [
      TabPageTransition(active: _tab == 0, child: _home()),
      TabPageTransition(
        active: _tab == 1,
        child: PluginsScreen(pluginService: _nuvioPlugins),
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
        child: ProfileScreen(
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
              },
            ),
          ),
          if (_resolvingStreams)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.72),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: GlassTheme.primary),
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
            ),
        ],
      ),
    );
  }
}
