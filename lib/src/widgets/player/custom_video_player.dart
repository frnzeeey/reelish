import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import '../../models/episode_context.dart';
import '../../models/media_item.dart';
import '../../models/playback_settings.dart';
import '../../models/stream_source.dart';
import '../../models/subtitle_language.dart';
import '../../services/storage_service.dart';
import '../../services/playback_settings_controller.dart';
import '../../services/stream_discovery.dart';
import '../../services/perf_timeline.dart';
import '../../services/playback_coordinator.dart';
import '../../services/player_engine.dart';
import '../../services/playback_source_policy.dart';
import '../../services/video_quality_selector.dart';
import '../../services/network_target_policy.dart';
import '../../services/subtitle_addon_service.dart';
import '../../services/subtitle_loader.dart';
import 'audio_track_sheet.dart';
import 'gesture_touch_layer.dart';
import 'player_controls.dart';
import 'player_settings_sheet.dart';
import 'stream_selector_sheet.dart';
import 'subtitle_picker_sheet.dart';

class CustomVideoPlayer extends StatefulWidget {
  const CustomVideoPlayer({
    super.key,
    required this.item,
    required this.source,
    required this.sources,
    required this.subtitles,
    required this.storage,
    required this.playbackSettings,
    this.sourceFromCache = false,
    this.streamCacheKey,
    this.discovery,
    this.onRediscover,
    this.onNextEpisode,
    this.episodeLabel = '',
    this.episodeContext,
    this.season,
    this.episode,
    this.imdbId,
  });
  final MediaItem item;
  final StreamSource source;
  final List<StreamSource> sources;
  final List<SubtitleTrack> subtitles;
  final StorageService storage;
  final PlaybackSettingsController playbackSettings;
  final bool sourceFromCache;
  final String? streamCacheKey;
  final StreamDiscovery? discovery;

  /// Starts a fresh progressive provider lookup for this title, used by
  /// Retry and when a cached link has expired.
  final StreamDiscovery Function()? onRediscover;
  final Future<void> Function()? onNextEpisode;

  /// For series, the episode being played, such as `S2 · E3`.
  final String episodeLabel;

  /// Resolves episode titles and whether a next episode can be played.
  final Future<EpisodeContext?>? episodeContext;

  /// Season and episode being played, for subtitle search.
  final int? season;
  final int? episode;

  /// Resolves the IMDb id (`tt…`) used by OpenSubtitles when the item does
  /// not carry one yet. Subtitle search waits for it; playback does not.
  final Future<String>? imdbId;
  @override
  State<CustomVideoPlayer> createState() => _CustomVideoPlayerState();
}

class _CustomVideoPlayerState extends State<CustomVideoPlayer> {
  VideoPlayerController? _controller;
  StreamSource? _source;
  bool _ready = false, _error = false;

  /// Controls visibility. A notifier, so showing or hiding controls rebuilds
  /// only the overlay, never the video surface or the rest of the player.
  final ValueNotifier<bool> _controlsVisible = ValueNotifier(true);
  bool _scrubbing = false;
  int _sheetsOpen = 0;
  bool _landscapeLocked = false;
  bool _orientationDecided = false;

  /// What the viewer sees while no frame is available yet.
  String _status = 'Starting playback…';
  String? _nextStatus;
  final ValueNotifier<SeekFlash?> _seekFlash = ValueNotifier(null);
  DateTime _lastSeekFlashAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _seekFlashId = 0;
  Timer? _nextEpisodeTimer;
  int? _nextEpisodeCountdown;

  /// Episode titles and the next episode, once resolved. While unresolved
  /// (or if the lookup fails) the player falls back to the season/episode
  /// label and still offers the next episode.
  EpisodeContext? _episodes;
  bool _episodesResolved = false;
  double _volume = 1, _brightness = 1;
  BoxFit _fit = BoxFit.contain;
  double _ratio = 0;
  late double _speed;
  SubtitleTrack? _subtitle;
  List<SubtitleCue> _cues = [];
  List<VideoTrack> _videoTracks = [];
  List<VideoAudioTrack> _audioTracks = [];
  VideoTrack? _selectedVideoTrack;
  double _subtitleDelay = 0;
  late PlaybackSettings _playback;
  Timer? _pauseOverlayTimer;
  bool _pauseOverlayVisible = false;
  bool _nextEpisodePromptVisible = false;
  bool _nextEpisodeHandled = false;
  bool _startingNextEpisode = false;
  double? _speedBeforeHold;
  TorrentStreamSession? _torrentSession;
  Timer? _hide, _save, _hint;
  String? _gestureHint;
  String? _errorMessage;
  int _initializationGeneration = 0;
  Completer<void>? _openCancellation;
  int _lastProgressSaveBucket = -1;
  bool _wasPlaying = false;
  final PlaybackCoordinator _playbackCoordinator = PlaybackCoordinator();

  /// The engine new sources start on. It changes for the rest of the session
  /// once the other engine plays a source the preferred one could not.
  PlayerEngine _preferredEngine = PlayerEngineFactory.forCurrentPlatform();

  /// The engine used by the current attempt.
  late PlayerEngine _engine = _preferredEngine;
  late List<StreamSource> _sources;
  final _subtitleAddons = SubtitleAddonService();
  final _subtitleLoader = SubtitleLoader();

  /// Subtitle menu contents; an open menu updates as results arrive.
  final ValueNotifier<SubtitleMenu> _subtitleMenu = ValueNotifier(
    const SubtitleMenu(),
  );
  List<SubtitleTrack> _addonSubtitleResults = const [];
  List<SubtitleTrack> _embeddedSubtitles = const [];

  /// Current text of an embedded (libmpv) subtitle.
  final ValueNotifier<List<String>> _embeddedLines = ValueNotifier(const []);
  final List<StreamSubscription<void>> _embeddedSubscriptions = [];

  /// Set once the viewer picks a subtitle (or Off); automatic selection
  /// then never overrides that choice.
  bool _userChoseSubtitle = false;
  bool _addonSearchStarted = false;
  int _subtitleSearchGeneration = 0;

  /// The viewer's remembered subtitle choice for this title.
  late final Future<RememberedSubtitle?> _remembered;

  /// Whether every subtitle addon has answered (or none applies).
  bool _addonSearchFinished = false;
  bool _handlingFailure = false;
  bool _cachedRefreshAttempted = false;
  StreamSubscription<StreamSource>? _discoverySubscription;
  StreamDiscovery? _rediscovery;

  /// Last playback position of this session, so a source switch or recovery
  /// resumes where the viewer was rather than at the original resume point.
  Duration? _lastPosition;

  /// Recent automatic reconnects per source, to bound retries after the
  /// stream drops during playback.
  final Map<String, List<DateTime>> _runtimeRetries = {};
  final DateTime _playerStartedAt = DateTime.now();
  final NetworkDestinationValidator _networkDestinations =
      NetworkDestinationValidator();
  @override
  void initState() {
    super.initState();
    _playback = widget.playbackSettings.value;
    _speed = _playback.defaultPlaybackSpeed;
    widget.playbackSettings.addListener(_onPlaybackSettingsChanged);
    _sources = List.of(widget.sources);
    _playbackCoordinator.replaceCandidates(_sources);
    _source = widget.source;
    final discovery = widget.discovery;
    if (discovery != null) _listenForSources(discovery);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_resolveEpisodes());
    _remembered = widget.storage
        .rememberedSubtitle(_titleKey)
        .catchError((Object _) => null);
    _initialize(widget.source);
  }

  /// Adds sources from [discovery] as fallback candidates while it runs, and
  /// resumes playback with one when every earlier candidate has failed.
  void _listenForSources(StreamDiscovery discovery) {
    unawaited(_discoverySubscription?.cancel());
    _discoverySubscription = discovery.updates.listen((source) {
      if (!mounted || !source.isPlayable || !_isSourceAllowed(source)) return;
      if (!_playbackCoordinator.addCandidate(source)) return;
      setState(() => _sources.add(source));
      if (_error) {
        final alternative = _playbackCoordinator.nextAfterFailure(
          _source ?? widget.source,
        );
        if (alternative == null) return;
        PlaybackLog.log(
          'Fallback',
          'new source arrived after failure -> ${PlaybackLog.describe(alternative)}',
        );
        setState(() {
          _error = false;
          _errorMessage = null;
        });
        unawaited(_initialize(alternative, resetAttempts: false));
      }
    });
  }

  /// Engine for the first attempt of [source]. Torrents play from the
  /// streamer's loopback HTTP URL, which only libmpv may open on Android.
  PlayerEngine _engineFor(StreamSource source) =>
      source.isTorrent && defaultTargetPlatform == TargetPlatform.android
      ? const MpvPlayerEngine()
      : PlayerEngineFactory.forSource(source.url, _preferredEngine);

  Future<void> _initialize(
    StreamSource source, {
    bool resetAttempts = true,
    PlayerEngine? engine,
    Duration? startupTimeout,
    bool engineFallback = false,
  }) async {
    final failedCandidate = source;
    if (resetAttempts) _playbackCoordinator.reset();
    final attemptEngine = engine ?? _engineFor(source);
    _engine = attemptEngine;
    _playbackCoordinator.beginAttempt(source, attemptEngine.id);
    final attemptClock = Stopwatch()..start();
    PlaybackLog.log(
      'Player',
      'opening engine=${attemptEngine.id.name} '
          'candidate=${_playbackCoordinator.attemptedCount} '
          '${PlaybackLog.describe(source)}',
    );
    if (!mounted) return;
    final previousOpen = _openCancellation;
    if (previousOpen != null && !previousOpen.isCompleted) {
      previousOpen.complete();
    }
    final cancellation = Completer<void>();
    _openCancellation = cancellation;
    final generation = ++_initializationGeneration;
    _handlingFailure = false;
    final old = _controller;
    _controller = null;
    final oldTorrent = _torrentSession;
    _torrentSession = null;
    try {
      await old?.dispose();
      await oldTorrent?.stop();
    } catch (_) {
      // Cleanup failure should not prevent trying the newly selected source.
    }
    if (!mounted || generation != _initializationGeneration) return;
    setState(() {
      _ready = false;
      _error = false;
      _errorMessage = null;
      _status = _nextStatus ?? 'Starting playback…';
      _nextStatus = null;
      _pauseOverlayVisible = false;
    });
    _controlsVisible.value = true;
    _pauseOverlayTimer?.cancel();
    _pauseOverlayTimer = null;
    _source = source;
    _videoTracks = [];
    _audioTracks = [];
    _selectedVideoTrack = null;
    // A new source keeps an OpenSubtitles choice (same title) and a provider
    // subtitle the new source also offers. Embedded tracks belong to the
    // previous file, so they are dropped.
    final keepSubtitle = switch (_subtitle) {
      null => true,
      SubtitleTrack(source: SubtitleSource.addon) => true,
      SubtitleTrack(source: SubtitleSource.embedded) => false,
      final current => [
        ...widget.subtitles,
        ...source.subtitles,
      ].any((track) => track.url == current.url),
    };
    if (!keepSubtitle) {
      _subtitle = null;
      _cues = [];
    }
    _unbindEmbeddedSubtitles();
    try {
      final isTorrent = source.isTorrent;
      if (isTorrent) source = await _prepareTorrent(source);
      // MediaKit/libmpv performs native media requests, so source preparation
      // preflights public hosts before the URL crosses into the native engine.
      // The only bypass is the loopback URL created by Reelish's torrent
      // streamer after validating its magnet and tracker inputs.
      final opened = await _playbackCoordinator.prepareAndOpen(
        source,
        engine: attemptEngine,
        allowLoopback: isTorrent,
        startupTimeout:
            startupTimeout ??
            Duration(
              seconds: widget.sourceFromCache && !_cachedRefreshAttempted
                  ? 7
                  : 20,
            ),
        cancellation: cancellation.future,
      );
      final playable = opened.source;
      final c = opened.controller;
      if (!mounted || generation != _initializationGeneration) {
        await c.dispose();
        return;
      }
      PlaybackLog.log(
        'Player',
        'initialized in ${attemptClock.elapsedMilliseconds}ms '
            '(${DateTime.now().difference(_playerStartedAt).inMilliseconds}ms '
            'since screen open) type=${playable.streamType.name} '
            'engine=${attemptEngine.id.name}',
      );
      _controller = c;
      _bindEmbeddedSubtitles(c);
      // Track menus are optional. Query both concurrently and never make
      // playback wait indefinitely for a backend that does not expose tracks.
      Future<void> loadVideoTracks() async {
        try {
          final tracks = c.isVideoTrackSupportAvailable()
              ? await c.getVideoTracks()
              : <VideoTrack>[];
          if (generation != _initializationGeneration) return;
          _videoTracks = tracks
            ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
          await _applyPreferredVideoTrack(c, generation);
        } catch (_) {
          if (generation == _initializationGeneration) _videoTracks = [];
        }
      }

      Future<void> loadAudioTracks() async {
        try {
          final tracks = c.isAudioTrackSupportAvailable()
              ? await c.getAudioTracks()
              : <VideoAudioTrack>[];
          if (generation == _initializationGeneration) _audioTracks = tracks;
        } catch (_) {
          if (generation == _initializationGeneration) _audioTracks = [];
        }
      }

      await Future.wait<void>([
        loadVideoTracks(),
        loadAudioTracks(),
      ]).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
      await _applyPreferredAudio(c);
      if (_subtitle == null) unawaited(_applyPreferredSubtitle());
      c.addListener(_tick);
      // Engines start at 1x, so only a non-default speed needs a round trip.
      if (_speed != 1) {
        try {
          await c.setPlaybackSpeed(_speed).timeout(const Duration(seconds: 2));
        } catch (_) {
          // Playback at normal speed can proceed if the backend is slow here.
        }
      }
      final resume =
          _lastPosition ?? Duration(milliseconds: widget.item.resumeMs);
      if (resume > Duration.zero) {
        final duration = c.value.duration;
        final safeResume =
            duration > const Duration(seconds: 1) && resume >= duration
            ? duration - const Duration(seconds: 1)
            : resume;
        try {
          await c.seekTo(safeResume).timeout(const Duration(seconds: 2));
        } catch (_) {
          // Some live streams do not support seeking; playback can continue.
        }
      }
      if (!mounted || generation != _initializationGeneration) return;
      await c.play();
      if (mounted && generation == _initializationGeneration) {
        PlaybackLog.log(
          'Player',
          'play accepted after ${attemptClock.elapsedMilliseconds}ms '
              '(${DateTime.now().difference(_playerStartedAt).inMilliseconds}ms '
              'since screen open)',
        );
        _awaitFirstFrame(c, generation, attemptClock);
        if (engineFallback && attemptEngine.id != _preferredEngine.id) {
          // The other engine played what the preferred one could not; try it
          // first for the rest of this session.
          _preferredEngine = attemptEngine;
        }
        setState(() => _ready = true);
        _decideOrientation(c);
        // Subtitle discovery starts once the video plays, never before it.
        unawaited(_searchSubtitleAddons());
        unawaited(
          widget.storage.saveLastStream(
            widget.item,
            _source ?? source,
            cacheKey: widget.streamCacheKey,
          ),
        );
        _scheduleHide();
      }
    } catch (error) {
      await _handleFailure(failedCandidate, error, generation);
    }
  }

  /// Logs when the first frame is actually presented: the position starts
  /// advancing after play. Development builds only.
  void _awaitFirstFrame(
    VideoPlayerController controller,
    int generation,
    Stopwatch attemptClock,
  ) {
    if (!kDebugMode) return;
    final start = controller.value.position;
    late VoidCallback listener;
    listener = () {
      final value = controller.value;
      if (generation != _initializationGeneration || value.hasError) {
        controller.removeListener(listener);
        return;
      }
      if (value.isPlaying && value.position > start) {
        controller.removeListener(listener);
        PlaybackLog.log(
          'Player',
          'first frame after ${attemptClock.elapsedMilliseconds}ms '
              '(${DateTime.now().difference(_playerStartedAt).inMilliseconds}ms '
              'since screen open)',
        );
        PerfTimeline.end('PLAY_PRESSED', 'FIRST_FRAME', finish: true);
      }
    };
    controller.addListener(listener);
  }

  /// Single failure policy for open and mid-playback errors.
  ///
  /// 1. A source that was playing and then dropped is reconnected on the same
  ///    engine with a short backoff (at most twice in two minutes).
  /// 2. Engine-specific failures (format, decoder, rendering, or Media3's
  ///    unspecific "source error") retry the same URL once on the other
  ///    engine. Network, HTTP, DNS and timeout failures do not, because the
  ///    other engine would reach the same server.
  /// 3. Otherwise the next ranked source is tried, up to the coordinator's
  ///    budget of distinct sources, resuming at the current position.
  Future<void> _handleFailure(
    StreamSource failedCandidate,
    Object error,
    int generation,
  ) async {
    if (!mounted ||
        generation != _initializationGeneration ||
        _handlingFailure) {
      return;
    }
    _handlingFailure = true;
    final wasPlaying = _ready;
    final failedEngine = _engine;
    final failedController = _controller;
    _controller = null;
    failedController?.removeListener(_tick);
    _unbindEmbeddedSubtitles();
    try {
      await failedController?.dispose();
      await _torrentSession?.stop();
    } catch (_) {}
    _torrentSession = null;
    if (!mounted || generation != _initializationGeneration) return;

    final failure = PlaybackFailure.classify(error);
    PlaybackLog.log(
      'Failure',
      'kind=${failure.kind.name}'
          '${failure.statusCode == null ? '' : ' status=${failure.statusCode}'} '
          'engine=${failedEngine.id.name} wasPlaying=$wasPlaying '
          '${PlaybackLog.describe(failedCandidate)} '
          'detail="${_safePlaybackError(error.toString())}"',
    );
    if (failure.kind == PlaybackFailureKind.cancelled) return;

    if (wasPlaying && _allowReconnect(failedCandidate)) {
      final attempt = _runtimeRetries[_sourceKey(failedCandidate)]!.length;
      final delay = Duration(seconds: attempt == 1 ? 1 : 3);
      PlaybackLog.log(
        'Fallback',
        'reconnecting same source in ${delay.inSeconds}s (attempt $attempt)',
      );
      setState(() {
        _ready = false;
        _status = 'Reconnecting…';
      });
      await Future<void>.delayed(delay);
      if (!mounted || generation != _initializationGeneration) return;
      _nextStatus = 'Reconnecting…';
      await _initialize(
        failedCandidate,
        resetAttempts: false,
        engine: failedEngine,
      );
      return;
    }

    if (await _refreshAfterCachedFailure(failedCandidate)) return;
    // Rediscovery can take seconds; the viewer may have left or picked
    // another source meanwhile.
    if (!mounted || generation != _initializationGeneration) return;

    final alternateEngine = PlayerEngineFactory.alternateFor(failedEngine);
    if (!wasPlaying &&
        failure.canTryAnotherEngine &&
        alternateEngine != null &&
        PlayerEngineFactory.canOpen(alternateEngine, failedCandidate.url) &&
        _playbackCoordinator.beginAttempt(
          failedCandidate,
          alternateEngine.id,
        )) {
      PlaybackLog.log(
        'Fallback',
        'engine ${failedEngine.id.name} -> ${alternateEngine.id.name} '
            'for the same source',
      );
      await _initialize(
        failedCandidate,
        resetAttempts: false,
        engine: alternateEngine,
        engineFallback: true,
        // A server problem fails fast on either engine; only a slow first
        // open needs the full startup allowance.
        startupTimeout: const Duration(seconds: 12),
      );
      return;
    }

    _playbackCoordinator.recordFailure(failedCandidate);
    final alternative = failure.canTryAnotherSource
        ? _playbackCoordinator.nextAfterFailure(failedCandidate)
        : null;
    if (alternative != null) {
      PlaybackLog.log(
        'Fallback',
        'candidate=${_playbackCoordinator.attemptedCount} -> '
            'candidate=${_playbackCoordinator.attemptedCount + 1} '
            '${PlaybackLog.describe(alternative)}',
      );
      _nextStatus = 'Trying another source…';
      await _initialize(alternative, resetAttempts: false);
      return;
    }

    if (!mounted || generation != _initializationGeneration) return;
    final attempted = _playbackCoordinator.attemptedCount;
    setState(() {
      _error = true;
      _errorMessage = attempted > 1
          ? 'Could not play $attempted sources. ${failure.userMessage}'
          : failure.userMessage;
    });
  }

  String _sourceKey(StreamSource source) =>
      _playbackCoordinator.sourceKey(source);

  /// Allows at most two automatic reconnects per source in two minutes, so a
  /// stream that keeps dropping moves on instead of retrying forever.
  bool _allowReconnect(StreamSource source) {
    final now = DateTime.now();
    final recent = (_runtimeRetries[_sourceKey(source)] ?? [])
      ..removeWhere(
        (time) => now.difference(time) > const Duration(minutes: 2),
      );
    if (recent.length >= 2) return false;
    _runtimeRetries[_sourceKey(source)] = recent..add(now);
    return true;
  }

  String _safePlaybackError(String error) {
    final cleaned = error.replaceFirst('Exception: ', '').trim();
    final normalized = cleaned.toLowerCase();
    if (normalized.contains('failed to open') ||
        normalized.contains('could not open')) {
      // Native player errors may omit the URL scheme while still including a
      // signed URL's path and query. Never show that raw input to the user.
      return 'The selected stream could not be opened. Try another source or provider.';
    }
    if (normalized.contains('failed to recognize file format') ||
        normalized.contains('unrecognizedinputformatexception') ||
        normalized.contains('unrecognized input format')) {
      return 'The provider did not return a recognizable video stream. Try another source or provider.';
    }
    // Signed stream URLs can carry credentials in their query string. Keep
    // the hostname for diagnostics without rendering the signed URL/token.
    return cleaned.replaceAllMapped(
      RegExp(r'https?://[^\s,()]+', caseSensitive: false),
      (match) {
        final uri = Uri.tryParse(match.group(0)!);
        return uri?.host.isNotEmpty == true ? uri!.host : 'the stream URL';
      },
    );
  }

  Future<void> _beginHoldSpeed() async {
    final controller = _controller;
    if (!_playback.holdToSpeed || controller == null || !_ready) return;
    if (_speedBeforeHold != null) return;
    _speedBeforeHold = _speed;
    try {
      await controller.setPlaybackSpeed(_playback.holdSpeed);
    } catch (_) {
      _speedBeforeHold = null;
    }
  }

  Future<void> _endHoldSpeed() async {
    final controller = _controller;
    final previousSpeed = _speedBeforeHold;
    _speedBeforeHold = null;
    if (controller == null || previousSpeed == null) return;
    try {
      await controller.setPlaybackSpeed(previousSpeed);
    } catch (_) {}
  }

  Future<void> _startNextEpisode() async {
    final callback = widget.onNextEpisode;
    if (_startingNextEpisode || callback == null) return;
    _startingNextEpisode = true;
    _nextEpisodeTimer?.cancel();
    if (mounted) setState(() => _nextEpisodePromptVisible = false);
    await callback();
  }

  /// One subtitle line in the viewer's style; nothing when [text] is empty.
  Widget _subtitleBox(String text) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(_playback.subtitleBackgroundColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: _subtitleText(text),
        ),
      ),
    );
  }

  Widget _subtitleText(String text) {
    final weight = _playback.subtitleBold ? FontWeight.w700 : FontWeight.w500;
    final outline = TextStyle(
      fontSize: _playback.subtitleSize,
      fontWeight: weight,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Color(_playback.subtitleOutlineColor),
    );
    final fill = TextStyle(
      fontSize: _playback.subtitleSize,
      fontWeight: weight,
      color: Color(_playback.subtitleTextColor),
      shadows: const [Shadow(blurRadius: 5, color: Colors.black54)],
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        if (_playback.subtitleOutline)
          ExcludeSemantics(
            child: Text(text, textAlign: TextAlign.center, style: outline),
          ),
        Text(text, textAlign: TextAlign.center, style: fill),
      ],
    );
  }

  Future<void> _retryPlayback() async {
    setState(() {
      _error = false;
      _errorMessage = null;
    });
    // Fresh provider links replace expired ones; the first fresh source plays
    // as soon as it arrives instead of waiting for every provider.
    if (await _rediscoverAndPlay(prefer: _source)) return;
    if (mounted) await _initialize(_source!);
  }

  /// Runs provider discovery again and starts the first returned source, or
  /// the one matching [prefer]. Returns false when no source was found.
  Future<bool> _rediscoverAndPlay({StreamSource? prefer}) async {
    final rediscover = widget.onRediscover;
    if (rediscover == null) return false;
    final StreamDiscovery discovery;
    final StreamSource? first;
    if (mounted) setState(() => _status = 'Finding best stream…');
    try {
      discovery = rediscover();
      _rediscovery = discovery;
      first = await discovery.firstSource;
    } catch (_) {
      return false;
    }
    if (!mounted || first == null) return false;
    final fresh = discovery.sources.where(_isSourceAllowed).toList();
    if (fresh.isEmpty) return false;
    PlaybackLog.log('Resolve', 'rediscovery found ${fresh.length} source(s)');
    _sources = fresh;
    _playbackCoordinator
      ..replaceCandidates(fresh)
      ..reset();
    _listenForSources(discovery);
    final match = prefer == null
        ? null
        : fresh
              .where(
                (source) =>
                    source.name == prefer.name &&
                    source.providerName == prefer.providerName &&
                    source.description == prefer.description,
              )
              .firstOrNull;
    await _initialize(match ?? fresh.first);
    return true;
  }

  /// A cached link that fails is usually an expired signed URL. Replace it
  /// with fresh provider results once per session.
  Future<bool> _refreshAfterCachedFailure(StreamSource failed) async {
    if (!widget.sourceFromCache ||
        _cachedRefreshAttempted ||
        failed.url != widget.source.url) {
      return false;
    }
    _cachedRefreshAttempted = true;
    PlaybackLog.log('Fallback', 'cached link failed; rediscovering sources');
    return _rediscoverAndPlay();
  }

  Future<StreamSource> _prepareTorrent(StreamSource source) async {
    if (!Theme.of(context).platform.toString().contains('android')) {
      throw UnsupportedError('Torrent streaming is available on Android only.');
    }
    final topicPattern = RegExp(
      r'^urn:btih:(?:[0-9a-f]{40}|[a-z2-7]{32})$|^urn:btmh:1220[0-9a-f]{64}$',
      caseSensitive: false,
    );
    final rawMagnet = source.url.toLowerCase().startsWith('magnet:')
        ? Uri.tryParse(source.url)
        : null;
    final topic =
        rawMagnet?.queryParametersAll['xt']
            ?.where((value) => topicPattern.hasMatch(value))
            .firstOrNull ??
        (source.infoHash.isEmpty ? null : 'urn:btih:${source.infoHash.trim()}');
    if (topic == null || !topicPattern.hasMatch(topic)) {
      throw Exception('Torrent source has no valid info hash.');
    }
    final trackerCandidates = <String>{
      ...?rawMagnet?.queryParametersAll['tr'],
      ...source.torrentSources
          .where((tracker) => tracker.startsWith('tracker:'))
          .map((tracker) => tracker.substring(8)),
    }.where(StreamSource.isSafeTorrentTracker).toList();
    final trackerUrls = <String>[];
    final trackersToCheck = trackerCandidates.take(8).toList();
    var nextTracker = 0;
    Future<void> validateTrackers() async {
      while (nextTracker < trackersToCheck.length) {
        final tracker = trackersToCheck[nextTracker++];
        try {
          await _networkDestinations.resolveDestination(
            Uri.parse(tracker),
            allowedSchemes: const {'http', 'https', 'udp'},
          );
          trackerUrls.add(tracker);
        } catch (_) {
          // Invalid, private, or unresolvable trackers are omitted. The native
          // torrent engine performs its own peer/DHT networking beyond this
          // Dart preflight, so this check narrows plugin-supplied tracker risk
          // without claiming to pin native sockets.
        }
      }
    }

    await Future.wait(
      List.generate(
        trackersToCheck.length < 4 ? trackersToCheck.length : 4,
        (_) => validateTrackers(),
      ),
    );
    final query = <String, dynamic>{
      'xt': topic,
      if (source.name.isNotEmpty) 'dn': source.name,
      if (trackerUrls.isNotEmpty) 'tr': trackerUrls,
    };
    final magnet = Uri(scheme: 'magnet', queryParameters: query).toString();
    final dir = await widget.storage.torrentCacheDirectory();
    final session = await FlutterTorrentStreamer().startStream(
      magnet,
      dir.path,
    );
    _torrentSession = session;
    List<TorrentFile> files = [];
    final metadataTimer = Stopwatch()..start();
    while (files.isEmpty &&
        metadataTimer.elapsed < const Duration(seconds: 30)) {
      try {
        files = await session.getFiles().timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // Poll again until the bounded metadata deadline expires.
      }
      if (files.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    if (files.isEmpty) throw Exception('Torrent metadata did not load.');
    final videoFiles = files
        .where(
          (f) => RegExp(
            r'\.(mkv|mp4|m4v|webm|mov|avi)$',
            caseSensitive: false,
          ).hasMatch(f.name),
        )
        .toList();
    final candidates = videoFiles.isNotEmpty ? videoFiles : files;
    final file =
        candidates.where((f) => f.index == source.fileIdx).firstOrNull ??
        (candidates..sort((a, b) => b.size.compareTo(a.size))).first;
    await session.selectFile(file.index);
    return StreamSource(
      name: source.name,
      url: session.streamUrl,
      description: source.description,
      headers: source.headers,
      subtitles: source.subtitles,
      providerName: source.providerName,
    );
  }

  /// Controls hide only while playback is running and the viewer is not
  /// scrubbing, using a sheet, or looking at an error.
  bool get _canAutoHide {
    final c = _controller;
    return c != null &&
        _ready &&
        !_error &&
        c.value.isPlaying &&
        !_scrubbing &&
        _sheetsOpen == 0;
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && _canAutoHide) _controlsVisible.value = false;
    });
  }

  void _show() {
    _controlsVisible.value = true;
    _scheduleHide();
  }

  void _toggleControls() {
    if (_controlsVisible.value) {
      _hide?.cancel();
      _controlsVisible.value = false;
    } else {
      _show();
    }
  }

  /// Keeps controls up while a sheet is open; playback continues behind it.
  Future<T> _withSheet<T>(Future<T> Function() open) async {
    _sheetsOpen++;
    _hide?.cancel();
    _controlsVisible.value = true;
    try {
      return await open();
    } finally {
      _sheetsOpen--;
      if (mounted) _scheduleHide();
    }
  }

  void _onScrubChanged(bool scrubbing) {
    _scrubbing = scrubbing;
    if (scrubbing) {
      _hide?.cancel();
    } else {
      _scheduleHide();
    }
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !_ready) return;
    final value = c.value;
    if (value.isCompleted && !value.isPlaying) {
      unawaited(c.seekTo(Duration.zero).then((_) => c.play()));
    } else if (value.isPlaying) {
      unawaited(c.pause());
    } else {
      unawaited(c.play());
    }
    _show();
  }

  /// Back to 1x from the speed pill. Also updates the session speed, so a
  /// source switch or reconnect does not restore the old speed.
  void _resetSpeed() {
    final c = _controller;
    if (c == null) return;
    setState(() => _speed = 1);
    unawaited(c.setPlaybackSpeed(1).catchError((Object _) {}));
    _show();
  }

  void _seekTo(Duration target) {
    final c = _controller;
    if (c == null || !_ready) return;
    final max = c.value.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (max > Duration.zero && target > max ? max : target);
    unawaited(c.seekTo(clamped));
  }

  void _seekBy(Duration delta) {
    final c = _controller;
    if (c == null) return;
    _seekTo(c.value.position + delta);
    _show();
  }

  /// Double-tap seek with feedback; quick repeated taps on one side add up.
  void _doubleTapSeek(bool forward) {
    final c = _controller;
    if (c == null || !_ready) return;
    final now = DateTime.now();
    final last = _seekFlash.value;
    final continuing =
        last != null &&
        last.forward == forward &&
        now.difference(_lastSeekFlashAt) < const Duration(milliseconds: 900);
    _lastSeekFlashAt = now;
    _seekFlash.value = SeekFlash(
      forward: forward,
      seconds: continuing ? last.seconds + 10 : 10,
      id: ++_seekFlashId,
    );
    _seekTo(c.value.position + Duration(seconds: forward ? 10 : -10));
  }

  /// Wide video starts in landscape once per session. The rotate control
  /// changes this; it is a layout change and never reopens the stream.
  void _decideOrientation(VideoPlayerController c) {
    if (_orientationDecided) return;
    _orientationDecided = true;
    final ratio = c.value.aspectRatio;
    if (ratio > 1.05 && !_landscapeLocked) _toggleLandscape();
  }

  void _toggleLandscape() {
    final lock = !_landscapeLocked;
    setState(() => _landscapeLocked = lock);
    unawaited(
      SystemChrome.setPreferredOrientations(
        lock
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [],
      ),
    );
  }

  Future<void> _pickAudio() async {
    final controller = _controller;
    if (controller == null || _audioTracks.length < 2) return;
    final id = await _withSheet(() => AudioTrackSheet.show(context, _audioTracks));
    if (id == null || !mounted || !identical(controller, _controller)) return;
    await _selectAudioTrack(controller, id);
  }

  Future<void> _selectAudioTrack(
    VideoPlayerController controller,
    String id,
  ) async {
    try {
      await controller.selectAudioTrack(id);
    } catch (_) {
      return; // Keep the engine's current track if the backend refuses.
    }
    if (!mounted) return;
    setState(() {
      _audioTracks = [
        for (final track in _audioTracks)
          VideoAudioTrack(
            id: track.id,
            label: track.label,
            language: track.language,
            isSelected: track.id == id,
            bitrate: track.bitrate,
            sampleRate: track.sampleRate,
            channelCount: track.channelCount,
            codec: track.codec,
          ),
      ];
    });
    if (_playback.useForcedSubtitles) unawaited(_applyPreferredSubtitle(automatic: false));
  }

  Future<void> _resolveEpisodes() async {
    final pending = widget.episodeContext;
    if (pending == null) return;
    EpisodeContext? resolved;
    try {
      resolved = await pending;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _episodes = resolved;
      _episodesResolved = true;
    });
    // At the finale (or before the next episode airs) there is nothing to
    // offer; withdraw an offer made before this was known.
    if (resolved != null && resolved.next == null && _nextEpisodePromptVisible) {
      _dismissNextEpisode();
    }
  }

  /// False only when the episode list says there is no playable next one.
  bool get _hasNextEpisode =>
      !(_episodesResolved && _episodes != null && _episodes!.next == null);

  /// Shows the next-episode card; with auto-play on, an 8 second countdown
  /// the viewer can cancel starts the existing next-episode flow.
  void _offerNextEpisode() {
    _nextEpisodeTimer?.cancel();
    setState(() {
      _nextEpisodePromptVisible = true;
      _nextEpisodeCountdown = _playback.autoPlayNextEpisode ? 8 : null;
    });
    if (!_playback.autoPlayNextEpisode) return;
    _nextEpisodeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      final remaining = (_nextEpisodeCountdown ?? 1) - 1;
      if (remaining <= 0) {
        timer.cancel();
        unawaited(_startNextEpisode());
      } else {
        setState(() => _nextEpisodeCountdown = remaining);
      }
    });
  }

  void _dismissNextEpisode() {
    _nextEpisodeTimer?.cancel();
    setState(() {
      _nextEpisodePromptVisible = false;
      _nextEpisodeCountdown = null;
    });
  }

  Future<void> _saveProgress() {
    final c = _controller;
    // While a failed source is being replaced there is no controller; keep
    // the last position the viewer reached.
    final position = c != null && c.value.isInitialized && _ready
        ? c.value.position
        : _lastPosition;
    if (position == null) return Future.value();
    return widget.storage.saveProgress(widget.item, position.inMilliseconds);
  }

  Future<void> _pickStream() async {
    final streams = _sources.where(_isSourceAllowed).toList();
    if (streams.length < 2 || _source == null) return;
    final picked = await _withSheet(
      () => StreamSelectorSheet.show(context, streams, _source!),
    );
    if (picked == null || !mounted) return;
    final current = _source!;
    if (picked.url == current.url &&
        picked.providerName == current.providerName &&
        _ready) {
      return; // Already playing this source.
    }
    _source = picked;
    _error = false;
    _nextStatus = 'Switching source…';
    await _initialize(picked);
  }

  Future<void> _settings() async {
    final controller = _controller;
    final result = await _withSheet(
      () => PlayerSettingsSheet.show(
        context,
        PlayerSettings(
          speed: _speed,
          fit: _fit,
          ratio: _ratio,
          subtitle: _subtitle,
          subtitleDelay: _subtitleDelay,
          videoTrack: _selectedVideoTrack,
        ),
        _availableSubtitles,
        _videoTracks,
        _audioTracks,
      ),
    );
    if (result == null || !mounted) return;
    // Apply only what changed: re-selecting the same quality can make the
    // engine switch renditions, and reloading subtitles blanks them.
    final speedChanged = result.speed != _speed;
    final trackChanged = result.videoTrack != _selectedVideoTrack;
    final subtitleChanged = result.subtitle?.key != _subtitle?.key;
    final delayChanged = result.subtitleDelay != _subtitleDelay;
    setState(() {
      _speed = result.speed;
      _fit = result.fit;
      _ratio = result.ratio;
      _subtitleDelay = result.subtitleDelay;
      _selectedVideoTrack = result.videoTrack;
    });
    final active = identical(controller, _controller) ? controller : null;
    try {
      if (speedChanged) await active?.setPlaybackSpeed(_speed);
      if (trackChanged && _videoTracks.isNotEmpty) {
        await active?.selectVideoTrack(_selectedVideoTrack);
      }
    } catch (_) {
      // The engine keeps its current speed or quality if it refuses.
    }
    final audioTrackId = result.audioTrackId;
    if (active != null &&
        audioTrackId != null &&
        !_audioTracks.any(
          (track) => track.id == audioTrackId && track.isSelected,
        )) {
      await _selectAudioTrack(active, audioTrackId);
    }
    final mpvId = _mpvPlayerId;
    if (delayChanged && mpvId != null) {
      unawaited(
        MediaKitVideoPlayer.shared?.setSubtitleDelay(mpvId, _subtitleDelay),
      );
    }
    if (subtitleChanged) {
      _userChoseSubtitle = true;
      final chosen = result.subtitle;
      _rememberSubtitleChoice(chosen);
      chosen == null ? _clearSubtitle() : await _selectSubtitle(chosen);
    }
  }

  /// Downloadable subtitles: from the provider and from subtitle addons, with
  /// the viewer's filters applied (as Nuvio's filterAddonSubtitlesForSettings
  /// applies "show only preferred languages" to addon results).
  List<SubtitleTrack> get _availableSubtitles => _filterSubtitles([
    ..._providerSubtitles,
    ..._addonSubtitleResults,
  ]);

  List<SubtitleTrack> get _providerSubtitles {
    final unique = <String, SubtitleTrack>{};
    for (final track in [...widget.subtitles, ...?_source?.subtitles]) {
      if (track.url.isNotEmpty) {
        unique.putIfAbsent(
          track.url,
          () => track.hearingImpaired || !_isSdh(track)
              ? track
              : SubtitleTrack(
                  url: track.url,
                  lang: track.lang,
                  id: track.id,
                  format: track.format,
                  headers: track.headers,
                  detail: track.detail,
                  hearingImpaired: true,
                ),
        );
      }
    }
    return unique.values.toList();
  }

  List<String> get _preferredSubtitleLanguages => [
    _playback.preferredSubtitleLanguage,
    _playback.secondarySubtitleLanguage,
    if (_playback.useForcedSubtitles) _selectedAudioLanguage,
  ].where((language) => language.isNotEmpty).toList();

  List<SubtitleTrack> _filterSubtitles(List<SubtitleTrack> tracks) {
    var filtered = tracks;
    if (_playback.stripSdhSubtitles) {
      filtered = filtered
          .where((track) => !track.hearingImpaired && !_isSdh(track))
          .toList();
    }
    if (_playback.showOnlyPreferredLanguages) {
      final preferred = _preferredSubtitleLanguages;
      filtered = preferred.isEmpty
          ? []
          : filtered
                .where(
                  (track) => preferred.any(
                    (language) => _languageMatches(track.lang, language),
                  ),
                )
                .toList();
    }
    return filtered;
  }

  /// Publishes the current subtitle choices to the menu.
  void _refreshSubtitleMenu() {
    final subtitle = _subtitle;
    _subtitleMenu.value = _subtitleMenu.value.copyWith(
      embedded: _embeddedSubtitles,
      provider: _filterSubtitles(_providerSubtitles),
      addonSubtitles: _filterSubtitles(_addonSubtitleResults),
      selectedKey: subtitle?.key,
      clearSelection: subtitle == null,
      preferredLanguages: _preferredSubtitleLanguages,
    );
  }

  void _onPlaybackSettingsChanged() {
    final previous = _playback;
    _playback = widget.playbackSettings.value;
    if (!mounted) return;
    if (!setEquals(previous.allowedProviderIds, _playback.allowedProviderIds) ||
        previous.p2pStreaming != _playback.p2pStreaming) {
      final candidates = <String, StreamSource>{};
      for (final source in [
        ..._sources,
        ...?widget.discovery?.sources,
        widget.source,
        ?_source,
      ]) {
        candidates.putIfAbsent(
          _playbackCoordinator.sourceKey(source),
          () => source,
        );
      }
      _sources = candidates.values.where(_isSourceAllowed).toList();
      _playbackCoordinator.replaceCandidates(_sources);
    }
    if (previous.holdToSpeed && !_playback.holdToSpeed) {
      unawaited(_endHoldSpeed());
    }
    if (!previous.autoPlayNextEpisode &&
        _playback.autoPlayNextEpisode &&
        _nextEpisodePromptVisible &&
        _nextEpisodeCountdown == null) {
      unawaited(_startNextEpisode());
    }
    if (previous.pauseOverlay && !_playback.pauseOverlay) {
      _pauseOverlayTimer?.cancel();
      _pauseOverlayTimer = null;
      _pauseOverlayVisible = false;
    }
    setState(() {
      if (_subtitle != null &&
          _subtitle!.source != SubtitleSource.embedded &&
          !_availableSubtitles.any((track) => track.key == _subtitle!.key)) {
        _subtitle = null;
        _cues = [];
      }
    });
    _refreshSubtitleMenu();
    if (previous.preferredAudioLanguage != _playback.preferredAudioLanguage ||
        previous.secondaryAudioLanguage != _playback.secondaryAudioLanguage) {
      final controller = _controller;
      if (controller != null) unawaited(_applyPreferredAudio(controller));
    }
    if (previous.preferredSubtitleLanguage !=
            _playback.preferredSubtitleLanguage ||
        previous.secondarySubtitleLanguage !=
            _playback.secondarySubtitleLanguage ||
        previous.stripSdhSubtitles != _playback.stripSdhSubtitles ||
        previous.useForcedSubtitles != _playback.useForcedSubtitles) {
      unawaited(_applyPreferredSubtitle(automatic: false));
    }
  }

  bool _isSourceAllowed(StreamSource source) => isPlaybackSourceAllowed(
    source,
    allowedProviderIds: _playback.allowedProviderIds,
    allowTorrents:
        _playback.p2pStreaming &&
        defaultTargetPlatform == TargetPlatform.android,
  );

  Future<void> _applyPreferredAudio(VideoPlayerController controller) async {
    if (_audioTracks.isNotEmpty && controller.isAudioTrackSupportAvailable()) {
      final preferences = [
        _playback.preferredAudioLanguage == 'device'
            ? WidgetsBinding.instance.platformDispatcher.locale.languageCode
            : _playback.preferredAudioLanguage,
        _playback.secondaryAudioLanguage,
      ].where((language) => language.isNotEmpty).toList();
      for (final language in preferences) {
        final track = _audioTracks
            .where((entry) => entry.language?.isNotEmpty == true)
            .where((entry) => _languageMatches(entry.language!, language))
            .firstOrNull;
        if (track == null) continue;
        try {
          await controller.selectAudioTrack(track.id);
          if (mounted) {
            setState(() {
              _audioTracks = [
                for (final entry in _audioTracks)
                  VideoAudioTrack(
                    id: entry.id,
                    label: entry.label,
                    language: entry.language,
                    isSelected: entry.id == track.id,
                    bitrate: entry.bitrate,
                    sampleRate: entry.sampleRate,
                    channelCount: entry.channelCount,
                    codec: entry.codec,
                  ),
              ];
            });
          }
        } catch (_) {
          // Keep the engine's selected track if a backend rejects the request.
        }
        break;
      }
    }
    if (_playback.useForcedSubtitles) {
      // Subtitle download must not hold back the start of playback.
      unawaited(_applyPreferredSubtitle(automatic: false));
    }
  }

  Future<void> _applyPreferredVideoTrack(
    VideoPlayerController controller,
    int generation,
  ) async {
    final height = selectPreferredVideoHeight(
      _videoTracks.map(
        (track) => track.height ?? _heightFromLabel(track.label),
      ),
      _playback.preferredVideoHeight,
    );
    if (height == null ||
        generation != _initializationGeneration ||
        !controller.isVideoTrackSupportAvailable()) {
      return;
    }
    final track = _videoTracks
        .where(
          (candidate) =>
              (candidate.height ?? _heightFromLabel(candidate.label)) == height,
        )
        .firstOrNull;
    if (track == null) return;
    try {
      await controller.selectVideoTrack(track);
      if (!mounted || generation != _initializationGeneration) return;
      _selectedVideoTrack = track;
      setState(() {});
    } catch (_) {
      // Quality selection is optional; leave the backend's automatic choice.
    }
  }

  int? _heightFromLabel(String? label) {
    if (label == null) return null;
    final match = RegExp(
      r'(?<!\d)(\d{3,4})\s*p?',
      caseSensitive: false,
    ).firstMatch(label);
    return int.tryParse(match?.group(1) ?? '');
  }

  String get _titleKey => '${widget.item.type}:${widget.item.id}';

  /// The best available subtitle for a remembered choice: same language,
  /// then the same source, addon and SDH variant where possible.
  SubtitleTrack? _rememberedMatch(RememberedSubtitle remembered) {
    SubtitleTrack? best;
    var bestScore = -1;
    for (final track in _autoSelectCandidates) {
      if (!_languageMatches(track.lang, remembered.language)) continue;
      final score =
          (track.source == remembered.source ? 4 : 0) +
          (track.addonName == remembered.addonName ? 2 : 0) +
          (track.hearingImpaired == remembered.hearingImpaired ? 1 : 0);
      if (score > bestScore) {
        best = track;
        bestScore = score;
      }
    }
    return best;
  }

  /// Remembers an explicit choice ([track] null for Off) for this title.
  void _rememberSubtitleChoice(SubtitleTrack? track) {
    unawaited(
      widget.storage.rememberSubtitle(
        _titleKey,
        track == null
            ? const RememberedSubtitle.off()
            : RememberedSubtitle.of(track),
      ),
    );
  }

  /// Subtitles automatic selection may pick, in Nuvio's order: tracks in
  /// the video first, then provider subtitles, then OpenSubtitles.
  List<SubtitleTrack> get _autoSelectCandidates => [
    ..._filterSubtitles(_embeddedSubtitles),
    ..._availableSubtitles,
  ];

  /// Selects a subtitle in the preferred language, if one is set. Does
  /// nothing without a preferred language, so subtitles are never forced on.
  ///
  /// [automatic] calls (startup, new tracks or addon results) first restore
  /// the viewer's remembered choice for this title, as Nuvio does per show:
  /// Off stays off, and a remembered language wins over the general
  /// preference. Calls after a settings change apply the settings directly.
  Future<void> _applyPreferredSubtitle({bool automatic = true}) async {
    if (automatic) {
      final remembered = await _remembered;
      if (!mounted || _subtitle != null || _userChoseSubtitle) return;
      if (remembered != null) {
        if (remembered.off) return;
        final match = _rememberedMatch(remembered);
        if (match != null) {
          await _selectSubtitle(match);
          return;
        }
        // The remembered language may still come from a subtitle addon.
        if (!_addonSearchFinished) return;
      }
    }
    if (_playback.useForcedSubtitles) {
      final audioLanguage = _selectedAudioLanguage;
      final forced = _autoSelectCandidates
          .where(_isForced)
          .where(
            (track) =>
                audioLanguage.isNotEmpty &&
                _languageMatches(track.lang, audioLanguage),
          )
          .firstOrNull;
      if (forced == null) {
        if (_subtitle != null && !_userChoseSubtitle) _clearSubtitle();
        return;
      }
      await _selectSubtitle(forced);
      return;
    }
    for (final language in [
      _playback.preferredSubtitleLanguage,
      _playback.secondarySubtitleLanguage,
    ].where((value) => value.isNotEmpty)) {
      final match = _autoSelectCandidates
          .where((track) => _languageMatches(track.lang, language))
          .firstOrNull;
      if (match != null) {
        await _selectSubtitle(match);
        return;
      }
    }
  }

  String get _selectedAudioLanguage {
    final selected = _audioTracks
        .where((track) => track.isSelected)
        .map((track) => track.language ?? '')
        .firstOrNull;
    if (selected?.isNotEmpty == true) return selected!;
    return _playback.preferredAudioLanguage == 'device'
        ? WidgetsBinding.instance.platformDispatcher.locale.languageCode
        : _playback.preferredAudioLanguage;
  }

  /// Turns [track] on. Embedded tracks switch libmpv's selection; others are
  /// downloaded and drawn by the player. Playback is never interrupted.
  Future<void> _selectSubtitle(SubtitleTrack track) async {
    if (_subtitle?.key == track.key || !mounted) return;
    setState(() {
      _subtitle = track;
      _cues = [];
    });
    _refreshSubtitleMenu();
    PlaybackLog.log(
      'Subtitle',
      'select source=${track.source.name} '
          'language=${SubtitleLanguage.normalize(track.lang)}',
    );
    final controller = _controller;
    final mpv = _engine.id == PlayerEngineId.mediaKit && controller != null
        ? MediaKitVideoPlayer.shared
        : null;
    if (track.source == SubtitleSource.embedded) {
      _embeddedLines.value = const [];
      final id = _mpvPlayerId;
      if (id != null) await mpv?.selectEmbeddedSubtitle(id, track.id);
      return;
    }
    // An external subtitle replaces any embedded one libmpv is showing.
    final id = _mpvPlayerId;
    if (id != null) await mpv?.selectEmbeddedSubtitle(id, null);
    await _loadSubtitle(track);
  }

  /// The libmpv player for the current controller, when libmpv is the engine.
  int? get _mpvPlayerId =>
      _engine.id == PlayerEngineId.mediaKit && _controller != null
      ? MediaKitVideoPlayer.shared?.activePlayerId
      : null;

  void _clearSubtitle() {
    if (!mounted) return;
    setState(() {
      _subtitle = null;
      _cues = [];
    });
    _embeddedLines.value = const [];
    final controller = _controller;
    if (_engine.id == PlayerEngineId.mediaKit && controller != null) {
      unawaited(
        MediaKitVideoPlayer.shared?.selectEmbeddedSubtitle(
          _mpvPlayerId ?? -1,
          null,
        ),
      );
    }
    _refreshSubtitleMenu();
  }

  bool _languageMatches(String trackLanguage, String preferred) =>
      SubtitleLanguage.matches(trackLanguage, preferred);

  bool _isForced(SubtitleTrack track) => RegExp(
    r'forced|foreign|signs.?only',
    caseSensitive: false,
  ).hasMatch('${track.id} ${track.format} ${track.url} ${track.detail}');

  bool _isSdh(SubtitleTrack track) =>
      track.hearingImpaired ||
      RegExp(
        r'\b(sdh|cc|hi)\b|hearing.?impaired|closed.?caption',
        caseSensitive: false,
      ).hasMatch(
        '${track.id} ${track.lang} ${track.format} ${track.url} ${track.detail}',
      );

  Future<void> _pickSubtitles() async {
    _refreshSubtitleMenu();
    final selected = await _withSheet(
      () => SubtitlePickerSheet.show(
        context,
        menu: _subtitleMenu,
        onRetry: () => unawaited(_searchSubtitleAddons(force: true)),
      ),
    );
    if (selected == null || !mounted) return;
    _userChoseSubtitle = true;
    final turnedOff =
        selected.url.isEmpty && selected.source != SubtitleSource.embedded;
    _rememberSubtitleChoice(turnedOff ? null : selected);
    if (turnedOff) {
      _clearSubtitle();
    } else {
      await _selectSubtitle(selected);
    }
    _show();
  }

  /// Looks up OpenSubtitles results for the playing title in the background,
  /// as Nuvio does when its player starts. Never blocks or fails playback.
  Future<void> _searchSubtitleAddons({bool force = false}) async {
    if (_addonSearchStarted && !force) return;
    _addonSearchStarted = true;
    final generation = ++_subtitleSearchGeneration;
    try {
      await _runSubtitleSearch(generation);
    } catch (error) {
      // Subtitle discovery must never affect playback.
      PlaybackLog.log('Subtitle', 'search failed: ${error.runtimeType}');
      if (mounted && generation == _subtitleSearchGeneration) {
        _subtitleMenu.value = _subtitleMenu.value.copyWith(
          status: ExternalSubtitleStatus.failed,
          message: 'Unable to load subtitles.',
        );
      }
    } finally {
      if (mounted && generation == _subtitleSearchGeneration) {
        _addonSearchFinished = true;
        // A remembered language that never arrived falls back to the
        // general preferred-language setting.
        if (_subtitle == null && !_userChoseSubtitle) {
          unawaited(_applyPreferredSubtitle());
        }
      }
    }
  }

  Future<void> _runSubtitleSearch(int generation) async {
    bool stale() => !mounted || generation != _subtitleSearchGeneration;

    _subtitleMenu.value = _subtitleMenu.value.copyWith(
      status: ExternalSubtitleStatus.loading,
      clearMessage: true,
    );
    var imdbId = [
      widget.item.externalId,
      widget.item.id,
    ].firstWhere((id) => id.startsWith('tt'), orElse: () => '');
    if (imdbId.isEmpty && widget.imdbId != null) {
      try {
        imdbId = await widget.imdbId!.timeout(const Duration(seconds: 15));
      } catch (_) {
        imdbId = '';
      }
    }
    if (stale()) return;
    final request = SubtitleRequest.create(
      type: widget.item.type,
      imdbId: imdbId,
      season: widget.season,
      episode: widget.episode,
    );
    if (request == null) {
      PlaybackLog.log('Subtitle', 'search skipped: no IMDb id or episode');
      _subtitleMenu.value = _subtitleMenu.value.copyWith(
        status: ExternalSubtitleStatus.idle,
        message: 'Not available for this title',
      );
      return;
    }
    final byAddon = <String, List<SubtitleTrack>>{};
    final errors = <SubtitleSearchException>[];
    final searched = await _subtitleAddons.search(
      request,
      onAddon: (addon, results, error) {
        if (stale()) return; // A newer search, or the player was closed.
        if (error != null) {
          errors.add(error);
          return;
        }
        // Progressive, like Nuvio: each addon's results appear as they come.
        byAddon[addon.manifestUrl] = results;
        _addonSubtitleResults = [
          for (final tracks in byAddon.values) ...tracks,
        ];
        _refreshSubtitleMenu();
        if (_subtitle == null && !_userChoseSubtitle) {
          unawaited(_applyPreferredSubtitle());
        }
      },
    );
    if (stale()) return;
    if (searched.isEmpty) {
      _subtitleMenu.value = _subtitleMenu.value.copyWith(
        status: ExternalSubtitleStatus.idle,
        message: 'No subtitle addon supports this title',
      );
    } else if (errors.length == searched.length) {
      _subtitleMenu.value = _subtitleMenu.value.copyWith(
        status: ExternalSubtitleStatus.failed,
        message: errors.first.message,
      );
    } else {
      _subtitleMenu.value = _subtitleMenu.value.copyWith(
        status: ExternalSubtitleStatus.ready,
        clearMessage: true,
      );
    }
  }

  /// Follows libmpv's embedded subtitle tracks for [controller] (libmpv only;
  /// Media3 does not expose text tracks through package:video_player).
  void _bindEmbeddedSubtitles(VideoPlayerController controller) {
    _unbindEmbeddedSubtitles();
    final mpv = MediaKitVideoPlayer.shared;
    if (_engine.id != PlayerEngineId.mediaKit || mpv == null) return;
    final id = _mpvPlayerId;
    if (id == null) return;
    void refresh() {
      if (!mounted || !identical(controller, _controller)) return;
      _embeddedSubtitles = [
        for (final track in mpv.embeddedSubtitles(id))
          SubtitleTrack(
            url: '',
            id: track.id,
            lang: SubtitleLanguage.normalize(
              track.language.isNotEmpty ? track.language : track.title,
            ),
            source: SubtitleSource.embedded,
            detail: track.title,
            hearingImpaired: RegExp(
              r'\b(sdh|cc|hi)\b|hearing',
              caseSensitive: false,
            ).hasMatch(track.title),
          ),
      ];
      // A track libmpv selected by itself (a default or forced track) is
      // shown as selected, unless the viewer chose something else.
      final active = mpv.selectedEmbeddedSubtitle(id);
      if (active != null && _subtitle == null && !_userChoseSubtitle) {
        final track = _embeddedSubtitles
            .where((track) => track.id == active)
            .firstOrNull;
        if (track != null) setState(() => _subtitle = track);
      }
      _refreshSubtitleMenu();
      if (_subtitle == null &&
          !_userChoseSubtitle &&
          _embeddedSubtitles.isNotEmpty) {
        unawaited(_applyPreferredSubtitle());
      }
    }

    _embeddedSubscriptions
      ..add(mpv.subtitleTracksChanged(id).listen((_) => refresh()))
      ..add(
        mpv.subtitleLines(id).listen((lines) {
          if (_subtitle?.source == SubtitleSource.embedded) {
            _embeddedLines.value = lines;
          }
        }),
      );
    refresh();
    if (_subtitleDelay != 0) {
      unawaited(mpv.setSubtitleDelay(id, _subtitleDelay));
    }
  }

  void _unbindEmbeddedSubtitles() {
    for (final subscription in _embeddedSubscriptions) {
      unawaited(subscription.cancel());
    }
    _embeddedSubscriptions.clear();
    _embeddedSubtitles = const [];
    _embeddedLines.value = const [];
  }

  Future<void> _loadSubtitle(SubtitleTrack track) async {
    try {
      final cues = await _subtitleLoader.load(track);
      // Ignore a download that finished after another subtitle was chosen.
      if (mounted && _subtitle?.key == track.key) {
        setState(() => _cues = cues);
      }
    } on SubtitleLoadException catch (error) {
      if (mounted && _subtitle?.key == track.key) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  void _hintFor(String text) {
    setState(() => _gestureHint = text);
    _hint?.cancel();
    _hint = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _gestureHint = null);
    });
  }

  @override
  void dispose() {
    _discoverySubscription?.cancel();
    // Stop starting further providers for a lookup this screen started.
    _rediscovery?.cancel();
    widget.playbackSettings.removeListener(_onPlaybackSettingsChanged);
    _initializationGeneration++;
    final openCancellation = _openCancellation;
    if (openCancellation != null && !openCancellation.isCompleted) {
      openCancellation.complete();
    }
    _saveProgress();
    _hide?.cancel();
    _save?.cancel();
    _hint?.cancel();
    _pauseOverlayTimer?.cancel();
    _nextEpisodeTimer?.cancel();
    _controlsVisible.dispose();
    _seekFlash.dispose();
    // Invalidate an in-flight subtitle search; its result is then ignored.
    _subtitleSearchGeneration++;
    _unbindEmbeddedSubtitles();
    _subtitleMenu.dispose();
    _embeddedLines.dispose();
    _controller?.removeListener(_tick);
    _controller?.dispose();
    _torrentSession?.stop();
    const MethodChannel('onfeed/player').invokeMethod<void>('resetBrightness');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Leave the rest of the app free to rotate again.
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  void _tick() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      _pauseOverlayTimer?.cancel();
      _pauseOverlayTimer = null;
      if (_pauseOverlayVisible && mounted) {
        setState(() => _pauseOverlayVisible = false);
      }
    } else if (_playback.pauseOverlay && _pauseOverlayTimer == null) {
      _pauseOverlayTimer = Timer(const Duration(seconds: 5), () {
        if (mounted && _controller?.value.isPlaying == false) {
          setState(() => _pauseOverlayVisible = true);
        }
      });
    }
    if (c.value.hasError) {
      unawaited(
        _handleFailure(
          _source ?? widget.source,
          c.value.errorDescription ?? 'The video source failed.',
          _initializationGeneration,
        ),
      );
      return;
    }
    if (_ready && c.value.isInitialized && c.value.position > Duration.zero) {
      _lastPosition = c.value.position;
    }
    final duration = c.value.duration;
    if (widget.item.type == 'series' &&
        widget.onNextEpisode != null &&
        !_nextEpisodeHandled &&
        _hasNextEpisode &&
        duration > Duration.zero &&
        c.value.position.inMilliseconds * 100 >=
            duration.inMilliseconds * _playback.nextEpisodeThresholdPercent) {
      _nextEpisodeHandled = true;
      if (mounted) _offerNextEpisode();
    }
    // Each save rewrites the whole history list, so save every 15 s while
    // playing, plus immediately when playback pauses (the app may then be
    // backgrounded and killed without disposing this screen).
    final playing = c.value.isPlaying;
    final paused = _wasPlaying && !playing && _ready;
    final resumed = !_wasPlaying && playing && _ready;
    _wasPlaying = playing;
    // Controls stay up while paused or ended, however the pause happened.
    if (paused) {
      _hide?.cancel();
      _controlsVisible.value = true;
    } else if (resumed) {
      _scheduleHide();
    }
    final progressBucket = c.value.position.inSeconds ~/ 15;
    if (paused || progressBucket != _lastProgressSaveBucket) {
      _lastProgressSaveBucket = progressBucket;
      _save?.cancel();
      _save = Timer(const Duration(milliseconds: 300), _saveProgress);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final current = _source;
    final currentUri = current == null ? null : Uri.tryParse(current.url);
    final sourceDetails = [
      if (current?.name.isNotEmpty == true) current!.name,
      if (current?.providerName.isNotEmpty == true) current!.providerName,
      if (currentUri?.hasAuthority == true) currentUri!.host,
    ].toSet().join(' · ');
    final playable = c != null && _ready;
    final alternatives = _sources.where(_isSourceAllowed).length;
    final quality = current == null
        ? ''
        : StreamSelectorSheet.qualityOf(current);
    final sourceLabel = [
      if (quality.isNotEmpty) quality,
      if (current?.providerName.isNotEmpty == true) current!.providerName,
    ].join(' · ');
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Video surface. Controls are separate layers above it, so
          // showing or updating them never rebuilds or recreates the video.
          if (playable)
            Center(
              child: AspectRatio(
                aspectRatio: _ratio > 0 ? _ratio : c.value.aspectRatio,
                child: FittedBox(
                  fit: _fit,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: c.value.size.width,
                    height: c.value.size.height,
                    child: VideoPlayer(c),
                  ),
                ),
              ),
            ),
          if (playable &&
              _brightness < 1 &&
              defaultTargetPlatform != TargetPlatform.android)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 1 - _brightness),
                ),
              ),
            ),
          // 2. Subtitles, raised above the bottom controls while they show.
          if (c != null && _subtitle != null)
            ValueListenableBuilder<bool>(
              valueListenable: _controlsVisible,
              builder: (context, controlsVisible, _) => AnimatedPositioned(
                duration: playerFade,
                curve: Curves.easeOutCubic,
                left: 24,
                right: 24,
                bottom:
                    (controlsVisible && playable ? 132 : 80) +
                    _playback.subtitleVerticalOffset,
                child: IgnorePointer(
                  // Embedded tracks: libmpv's current text. Others: cues
                  // from the downloaded file, shifted by the subtitle delay.
                  child: _subtitle!.source == SubtitleSource.embedded
                      ? ValueListenableBuilder<List<String>>(
                          valueListenable: _embeddedLines,
                          builder: (context, lines, _) => _subtitleBox(
                            lines
                                .map((line) => line.trim())
                                .where((line) => line.isNotEmpty)
                                .join('\n'),
                          ),
                        )
                      : ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: c,
                          builder: (context, v, _) {
                            final t =
                                v.position.inMilliseconds / 1000 -
                                _subtitleDelay;
                            final cue = _cues
                                .where((e) => t >= e.start && t <= e.end)
                                .firstOrNull;
                            return _subtitleBox(cue?.text ?? '');
                          },
                        ),
                ),
              ),
            ),
          // 3. Gestures. A single tap always toggles the controls; double
          // taps, swipes and hold-to-speed follow the viewer's settings.
          if (playable)
            GestureTouchLayer(
              onTap: _toggleControls,
              onDoubleTap: _playback.touchGestures ? _doubleTapSeek : null,
              onSwipe: !_playback.touchGestures
                  ? null
                  : (right, amount) {
                      if (right) {
                        _volume = (_volume + amount).clamp(0, 1);
                        c.setVolume(_volume);
                        _hintFor('Volume ${(_volume * 100).round()}%');
                      } else {
                        _brightness = (_brightness + amount).clamp(.15, 1);
                        if (defaultTargetPlatform == TargetPlatform.android) {
                          const MethodChannel(
                            'onfeed/player',
                          ).invokeMethod<void>('setBrightness', {
                            'value': _brightness,
                          });
                        }
                        _hintFor('Brightness ${(_brightness * 100).round()}%');
                      }
                    },
              onLongPressStart: _playback.holdToSpeed
                  ? () => unawaited(_beginHoldSpeed())
                  : null,
              onLongPressEnd: _playback.holdToSpeed
                  ? () => unawaited(_endHoldSpeed())
                  : null,
              child: const SizedBox.expand(),
            ),
          // 4. Temporary feedback.
          if (playable) PlayerSeekFeedback(flashes: _seekFlash),
          if (playable)
            PlayerBufferingIndicator(
              controller: c,
              controlsVisible: _controlsVisible,
            ),
          if (_gestureHint != null)
            Center(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xCC101015),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: Text(
                      _gestureHint!,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ),
          if (_pauseOverlayVisible && playable && !c.value.isPlaying)
            Positioned(
              left: 32,
              right: 32,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Align(
                  alignment: const Alignment(0, -.45),
                  child: Text(
                    widget.item.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      shadows: [Shadow(color: Colors.black87, blurRadius: 16)],
                    ),
                  ),
                ),
              ),
            ),
          // 5. Controls: always mounted while playable, faded in and out.
          if (playable)
            ValueListenableBuilder<bool>(
              valueListenable: _controlsVisible,
              builder: (context, visible, child) => IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: playerFade,
                  curve: Curves.easeOutCubic,
                  // Hidden controls run no animations (the title marquee,
                  // button transitions) while the fade-out still completes.
                  child: TickerMode(enabled: visible, child: child!),
                ),
              ),
              child: PlayerControlsOverlay(
                controller: c,
                title: widget.item.name,
                subtitle:
                    _episodes?.current.label ??
                    (widget.episodeLabel.isNotEmpty
                    ? widget.episodeLabel
                    : (current?.providerName ?? '')),
                sourceLabel: sourceLabel,
                subtitleEnabled: _subtitle != null,
                showAudio: _audioTracks.length > 1,
                showSources: alternatives > 1,
                landscapeLocked: _landscapeLocked,
                onBack: () {
                  _saveProgress();
                  Navigator.pop(context);
                },
                onTogglePlay: _togglePlay,
                onSeekBy: _seekBy,
                onSeekTo: (target) {
                  _seekTo(target);
                  _show();
                },
                onScrubChanged: _onScrubChanged,
                onSubtitles: _pickSubtitles,
                onAudio: _pickAudio,
                onSources: _pickStream,
                onSettings: _settings,
                onPip: () async {
                  _hide?.cancel();
                  _controlsVisible.value = false;
                  try {
                    await const MethodChannel(
                      'onfeed/player',
                    ).invokeMethod<bool>('enterPip', {
                      'ratio': c.value.aspectRatio,
                    });
                  } catch (_) {}
                },
                onRotate: _toggleLandscape,
                onNextEpisode:
                    _nextEpisodePromptVisible && !_startingNextEpisode
                    ? () => unawaited(_startNextEpisode())
                    : null,
                nextEpisodeCountdown: _nextEpisodeCountdown,
                onSpeedReset: _resetSpeed,
              ),
            ),
          // The floating card shows while controls are hidden; with controls
          // up, the same offer is a pill in the bottom row, so the card never
          // covers the center controls on short landscape screens.
          if (_nextEpisodePromptVisible && !_startingNextEpisode)
            ValueListenableBuilder<bool>(
              valueListenable: _controlsVisible,
              builder: (context, controlsVisible, card) => IgnorePointer(
                ignoring: controlsVisible && playable,
                child: AnimatedOpacity(
                  opacity: controlsVisible && playable ? 0 : 1,
                  duration: playerFade,
                  child: card,
                ),
              ),
              child: SafeArea(
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: NextEpisodeCard(
                        seriesName: widget.item.name,
                        nextLabel: _episodes?.next?.label,
                        countdown: _nextEpisodeCountdown,
                        onPlay: () => unawaited(_startNextEpisode()),
                        onDismiss: _dismissNextEpisode,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // 6. No frame yet: starting, switching, reconnecting, or an error.
          if (!playable)
            PlayerStatusView(
              onBack: () {
                _saveProgress();
                Navigator.pop(context);
              },
              status: _playback.showLoadingStatus ? _status : null,
              showSpinner: _playback.showLoadingOverlay,
              error: _error
                  ? PlayerErrorPanel(
                      canTryAnother: alternatives > 1,
                      message: _errorMessage ?? '',
                      sourceDetails: sourceDetails,
                      onRetry: _retryPlayback,
                      onTryAnother: _pickStream,
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}
