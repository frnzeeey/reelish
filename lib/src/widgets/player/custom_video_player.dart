import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import '../../models/episode_context.dart';
import '../../models/episode_progress.dart';
import '../../models/media_details.dart';
import '../../models/media_item.dart';
import '../../models/playback_settings.dart';
import '../../models/stream_source.dart';
import '../../models/subtitle_language.dart';
import '../../platform/device_capabilities.dart';
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
import '../../services/torrent_source_preparer.dart';
import 'audio_track_sheet.dart';
import 'episode_panel.dart';
import 'external_cue_clock.dart';
import 'gesture_touch_layer.dart';
import 'paused_overlay.dart';
import 'player_controls.dart';
import 'player_lock_overlay.dart';
import 'subtitle_position_panel.dart';
import 'player_settings_sheet.dart';
import 'stream_selector_sheet.dart';
import 'subtitle_picker_sheet.dart';

/// Starts [episode] in a new player that replaces the current one.
typedef EpisodeSwitch =
    Future<void> Function(EpisodeRef episode, EpisodeHandOff handOff);

/// What the playing player offers the episode it hands over to.
class EpisodeHandOff {
  const EpisodeHandOff({required this.context, required this.release});

  /// The playing player, which hosts the stream search and its errors.
  final BuildContext context;

  /// Frees this player's video engine. Called once streams for the new
  /// episode are found, just before its player opens: the engine is chosen
  /// app-wide, so this player must let go of it first, or disposing it later
  /// would reach the new episode's engine and leave its own one running.
  final Future<void> Function() release;
}

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
    this.onPlayEpisode,
    this.episodeLabel = '',
    this.episodeContext,
    this.season,
    this.episode,
    this.imdbId,
    this.details,
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

  /// Plays another episode of this series through the app's play flow,
  /// which finds its streams while this player stays open and then replaces
  /// it. Completes early, with this player still open, when the switch fails
  /// or is cancelled. Null for movies.
  final EpisodeSwitch? onPlayEpisode;

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

  /// TMDB details (genres, runtime, synopsis) for the pause screen. Optional;
  /// the pause screen shows what the item itself carries until it resolves.
  final Future<MediaDetails?>? details;
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

  /// Controls lock against accidental touches. Session-only: every player
  /// (and so every episode) starts unlocked. It blocks touches, never
  /// playback.
  final ValueNotifier<bool> _locked = ValueNotifier(false);
  final ValueNotifier<bool> _unlockVisible = ValueNotifier(false);
  Timer? _unlockHide;

  /// Whether controls are really on screen: visible and not locked. The
  /// layers that make room for the controls follow this.
  final ValueNotifier<bool> _controlsShown = ValueNotifier(true);

  /// What Back depends on.
  late final Listenable _backState = Listenable.merge([
    _locked,
    _controlsShown,
  ]);

  /// Remote control, on TV. [_playerFocus] is the player itself: it holds
  /// focus whenever no control does, so every key reaches [_onRemoteKey].
  /// The play buttons are where focus lands when the controls appear.
  final FocusNode _playerFocus = FocusNode(debugLabel: 'Player');
  final FocusNode _playButtonFocus = FocusNode(debugLabel: 'Play');
  final FocusNode _pausePlayFocus = FocusNode(debugLabel: 'Resume');
  final FocusNode _errorActionFocus = FocusNode(debugLabel: 'Error action');
  final FocusNode _subtitlePositionFocus = FocusNode(
    debugLabel: 'Subtitle position',
  );
  ModalRoute<Object?>? _route;
  static bool get _tv => DeviceCapabilities.isTv;

  /// Live subtitle position, so moving subtitles rebuilds only their layer.
  late final ValueNotifier<double> _subtitlePosition;
  late final Listenable _subtitleLayout = Listenable.merge([
    _controlsShown,
    _subtitlePosition,
  ]);

  /// Whether the subtitle position panel is open.
  bool _adjustingSubtitles = false;

  /// Whether the viewer is dragging the progress bar.
  final ValueNotifier<bool> _scrubbing = ValueNotifier(false);
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

  /// The downloaded subtitle text to show, timed from the player clock.
  final _externalCue = ExternalCueClock();
  List<VideoTrack> _videoTracks = [];
  List<VideoAudioTrack> _audioTracks = [];
  VideoTrack? _selectedVideoTrack;
  double _subtitleDelay = 0;
  late PlaybackSettings _playback;
  Timer? _pauseOverlayTimer;

  /// Whether the pause screen is up. A notifier, so it animates in and out
  /// without rebuilding the player.
  final ValueNotifier<bool> _pauseOverlay = ValueNotifier(false);

  /// Title details for the pause screen, once [CustomVideoPlayer.details]
  /// resolves.
  MediaDetails? _details;

  /// Starts the one artwork download of the session, after startup.
  Timer? _artworkTimer;
  final Set<String> _precachedArtwork = {};
  int? _artworkWidth;
  bool _nextEpisodePromptVisible = false;
  bool _nextEpisodeHandled = false;

  /// True from choosing another episode until its player replaces this one
  /// (or the switch fails): ignores further choices and holds the offers.
  bool _switchingEpisode = false;

  /// Players currently alive. Switching episodes briefly overlaps the old
  /// player (closing) with the new one (opening).
  static int _livePlayers = 0;

  /// Whether the window is currently asked to keep the screen on. Neither
  /// engine holds a wakelock itself, so playback would otherwise let the
  /// screen time out.
  static bool _keepingScreenOn = false;

  static void _setKeepScreenOn(bool value) {
    if (_keepingScreenOn == value) return;
    _keepingScreenOn = value;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    unawaited(
      const MethodChannel(
        'onfeed/player',
      ).invokeMethod<void>('keepScreenOn', {'value': value}).catchError((_) {}),
    );
  }

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

  /// Length of the playing title, kept like [_lastPosition].
  Duration _lastDuration = Duration.zero;

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
    _subtitlePosition = ValueNotifier(_playback.subtitlePosition);
    _controlsVisible.addListener(_syncControlsShown);
    _locked.addListener(_syncControlsShown);
    widget.playbackSettings.addListener(_onPlaybackSettingsChanged);
    if (_tv) {
      FocusManager.instance.addListener(_keepRemoteFocus);
      _pauseOverlay.addListener(_followPauseScreen);
    }
    _sources = List.of(widget.sources);
    _playbackCoordinator.replaceCandidates(_sources);
    _source = widget.source;
    final discovery = widget.discovery;
    if (discovery != null) _listenForSources(discovery);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_resolveEpisodes());
    unawaited(_resolveDetails());
    _livePlayers++;
    unawaited(_startPosition); // Read alongside the stream opening.
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
    });
    _pauseOverlay.value = false;
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
    _syncExternalCue();
    _unbindEmbeddedSubtitles();
    try {
      final isTorrent = source.isTorrent;
      if (isTorrent) source = await _prepareTorrent(source, generation);
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
      // A newer source, episode or close during the track queries above has
      // already disposed [c]; it must not be listened to or played.
      if (!mounted || generation != _initializationGeneration) return;
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
      final resume = _lastPosition ?? await _startPosition;
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
      // A play request the engine never answers would leave the viewer on
      // the loading screen; it fails like any other start-up error.
      await c.play().timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw TimeoutException('The video engine did not start playing.'),
      );
      if (mounted && generation == _initializationGeneration) {
        PlaybackLog.log(
          'Player',
          'play accepted after ${attemptClock.elapsedMilliseconds}ms '
              '(${DateTime.now().difference(_playerStartedAt).inMilliseconds}ms '
              'since screen open)',
        );
        _awaitFirstFrame(c, generation, attemptClock);
        _watchForPicture(c, generation, attemptEngine, failedCandidate);
        if (engineFallback && attemptEngine.id != _preferredEngine.id) {
          // The other engine played what the preferred one could not; try it
          // first for the rest of this session.
          _preferredEngine = attemptEngine;
        }
        setState(() => _ready = true);
        // Pause artwork downloads once, after startup has had the network,
        // so the first pause shows it from memory.
        _artworkTimer ??= Timer(
          const Duration(seconds: 4),
          _precachePauseArtwork,
        );
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

  /// How long Media3 may play with no picture before the source counts as a
  /// rendering failure.
  static const _noPictureGrace = Duration(seconds: 4);

  /// Catches audio playing over a black screen on Media3.
  ///
  /// Media3 drops a video track it cannot decode (an unsupported codec or
  /// profile) and plays the audio alone without reporting an error; its video
  /// size then stays zero. After [_noPictureGrace] of such playback the
  /// source is handed to the failure policy as a rendering failure, which
  /// tries it on the other engine at the same position. libmpv reports its
  /// size differently, so it keeps the viewer's manual engine switch.
  void _watchForPicture(
    VideoPlayerController controller,
    int generation,
    PlayerEngine engine,
    StreamSource source,
  ) {
    if (engine.id != PlayerEngineId.media3 || !controller.value.size.isEmpty) {
      return;
    }
    final start = controller.value.position;
    late VoidCallback listener;
    listener = () {
      final value = controller.value;
      if (!mounted ||
          generation != _initializationGeneration ||
          value.hasError ||
          !value.size.isEmpty) {
        controller.removeListener(listener);
        return;
      }
      if (value.isPlaying && value.position - start >= _noPictureGrace) {
        controller.removeListener(listener);
        PlaybackLog.log('Failure', 'audio is playing but no picture appeared');
        unawaited(
          _handleFailure(source, PlaybackFailure.noPicture, generation),
        );
      }
    };
    controller.addListener(listener);
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

    // Reconnecting cannot help a picture that was never drawn.
    if (wasPlaying &&
        failure.kind != PlaybackFailureKind.rendering &&
        _allowReconnect(failedCandidate)) {
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
    // A picture that never appeared is also worth the other engine after
    // playback started: the audio was playing, the video was not.
    if ((!wasPlaying || failure.kind == PlaybackFailureKind.rendering) &&
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

  /// Plays the next episode (the offer, its countdown, and the panel's Next
  /// button all come here), as listed in [EpisodeContext].
  Future<void> _startNextEpisode() async {
    if (_switchingEpisode) return;
    _nextEpisodeTimer?.cancel();
    if (mounted) setState(() => _nextEpisodePromptVisible = false);
    final next = (await _episodeContext())?.next;
    if (!mounted) return;
    if (next == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('There is no next episode available.')),
      );
      return;
    }
    await _playEpisode(next);
  }

  /// The episode list, waiting for it if it is still loading.
  Future<EpisodeContext?> _episodeContext() async {
    if (_episodesResolved) return _episodes;
    try {
      return await widget.episodeContext;
    } catch (_) {
      return null;
    }
  }

  /// Whether this is a series episode another one can be chosen from.
  bool get _canSwitchEpisodes =>
      widget.item.type == 'series' &&
      widget.onPlayEpisode != null &&
      widget.season != null &&
      widget.episode != null;

  /// Set once this episode's position is saved and handed over to the
  /// player that replaces it, so disposing this one saves nothing stale.
  bool _progressHandedOff = false;

  /// The single way this player moves to another episode. The current
  /// position is saved first, so each episode keeps its own progress.
  /// Repeated taps while a switch is running are ignored.
  Future<void> _playEpisode(EpisodeRef target) async {
    final play = widget.onPlayEpisode;
    if (play == null || _switchingEpisode || !mounted) return;
    if (target.season == widget.season && target.episode == widget.episode) {
      return;
    }
    setState(() => _switchingEpisode = true);
    _nextEpisodeTimer?.cancel();
    final c = _controller;
    final wasPlaying = c?.value.isPlaying ?? false;
    if (wasPlaying) unawaited(c!.pause().catchError((Object _) {}));
    try {
      await _saveProgress();
    } catch (_) {
      // Progress is best effort; the switch still happens.
    }
    if (!mounted) return;
    _progressHandedOff = true;
    var released = false;
    try {
      await play(
        target,
        EpisodeHandOff(
          context: context,
          release: () {
            released = true;
            return _releaseEngine(target);
          },
        ),
      );
    } catch (_) {}
    // Still mounted: no stream was found, or the viewer cancelled. Continue
    // where they were.
    if (!mounted) return;
    _progressHandedOff = false;
    setState(() => _switchingEpisode = false);
    if (released) {
      // The new player did not open after all; reopen this episode at the
      // position it was left.
      unawaited(_initialize(_source ?? widget.source));
      return;
    }
    if (wasPlaying && identical(c, _controller)) {
      unawaited(c!.play().catchError((Object _) {}));
    }
  }

  /// Lets go of the video engine (and torrent session) before [target]'s
  /// player opens, showing a short status meanwhile. The last position is
  /// kept, so this episode can still be reopened.
  Future<void> _releaseEngine(EpisodeRef target) async {
    if (!mounted) return;
    _initializationGeneration++;
    final opening = _openCancellation;
    if (opening != null && !opening.isCompleted) opening.complete();
    _pauseOverlayTimer?.cancel();
    _pauseOverlay.value = false;
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_tick);
    _unbindEmbeddedSubtitles();
    final torrent = _torrentSession;
    _torrentSession = null;
    setState(() {
      _ready = false;
      _status = 'Opening ${target.code}…';
    });
    try {
      await controller?.dispose();
      await torrent?.stop();
    } catch (_) {
      // The new episode opens either way.
    }
  }

  /// Opens the episode panel over the playing video.
  Future<void> _openEpisodes() async {
    if (_switchingEpisode) return;
    final episodes = await _episodeContext();
    if (!mounted) return;
    if (episodes == null || episodes.episodes.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('The episode list is not available right now.'),
        ),
      );
      return;
    }
    var progress = SeriesProgress.empty;
    try {
      // Saved first, so this episode's card shows where the viewer is now.
      await _saveProgress();
      progress = await widget.storage.seriesProgress(widget.item);
    } catch (_) {}
    if (!mounted) return;
    final chosen = await _withSheet(
      () => EpisodePanel.show(
        context,
        seriesTitle: widget.item.name,
        episodes: episodes.episodes,
        progress: progress,
        current: episodes.current,
        previous: episodes.previous,
        next: episodes.next,
      ),
    );
    if (chosen == null || !mounted) return;
    await _playEpisode(chosen);
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

  /// The subtitle box, with sample text while the position panel is open
  /// and nothing is being said, so there is always something to place.
  Widget _positionedSubtitleBox(String text) => _subtitleBox(
    text.isEmpty && _adjustingSubtitles ? 'Subtitles appear here' : text,
  );

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
      final previous = _rediscovery;
      discovery = rediscover();
      // Lookups are shared per title, so the new one may be the same object.
      if (!identical(previous, discovery)) previous?.cancel();
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

  late final TorrentSourcePreparer _torrents = TorrentSourcePreparer(
    storage: widget.storage,
    destinations: _networkDestinations,
  );

  Future<StreamSource> _prepareTorrent(StreamSource source, int generation) {
    if (!Theme.of(context).platform.toString().contains('android')) {
      throw UnsupportedError('Torrent streaming is available on Android only.');
    }
    return _torrents.prepare(
      source,
      // The viewer may close the player or pick another source while the
      // session starts; dispose and the next attempt stop _torrentSession.
      superseded: () => !mounted || generation != _initializationGeneration,
      onSession: (session) => _torrentSession = session,
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
        !_scrubbing.value &&
        _sheetsOpen == 0;
  }

  void _scheduleHide() {
    _hide?.cancel();
    // Read from across the room with a remote, TV controls stay up longer.
    _hide = Timer(Duration(milliseconds: _tv ? 5000 : 3500), () {
      if (mounted && _canAutoHide) _controlsVisible.value = false;
    });
  }

  static final _arrowKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };
  static final _selectKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  /// The remote, on TV. Keys reach this while the player or one of its
  /// controls has focus; a sheet or dialog over the player takes its own.
  ///
  /// Media keys always act on playback. While the controls are hidden the
  /// D-pad drives playback itself: Left/Right seek 10 s (quick presses add
  /// up, as double-taps do) and Up, Down or Select bring the controls up
  /// with focus on play. With a control focused, the D-pad moves between
  /// controls as usual and every press keeps them on screen.
  KeyEventResult _onRemoteKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;
    final c = _controller;
    final playable = c != null && _ready;
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (!repeat) _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      final play = key == LogicalKeyboardKey.mediaPlay;
      if (!repeat && playable && c.value.isPlaying != play) _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaRewind) {
      if (playable) {
        _doubleTapSeek(key == LogicalKeyboardKey.mediaFastForward);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      if (!repeat &&
          widget.onPlayEpisode != null &&
          _hasNextEpisode &&
          !_switchingEpisode) {
        unawaited(_startNextEpisode());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.closedCaptionToggle) {
      if (!repeat && playable) unawaited(_pickSubtitles());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.info) {
      if (!repeat && playable) unawaited(_settings());
      return KeyEventResult.handled;
    }
    final arrow = _arrowKeys.contains(key);
    if (!arrow && !_selectKeys.contains(key)) return KeyEventResult.ignored;
    if (!node.hasPrimaryFocus) {
      // A control has focus.
      if (_controlsVisible.value) _scheduleHide();
      return KeyEventResult.ignored;
    }
    if (!playable || _adjustingSubtitles) {
      // The loading and error views, and the subtitle position panel, have
      // no playback to drive: the D-pad starts on their controls.
      _focusViewControl();
      return KeyEventResult.handled;
    }
    if (!_controlsShown.value &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _doubleTapSeek(key == LogicalKeyboardKey.arrowRight);
      return KeyEventResult.handled;
    }
    if (!repeat) _showControlsFromRemote();
    return KeyEventResult.handled;
  }

  /// Where the D-pad starts when there is no playback to drive: the subtitle
  /// position slider, the error view's first action, or else the one control
  /// the loading view has (Back).
  void _focusViewControl() {
    final target = _adjustingSubtitles
        ? _subtitlePositionFocus
        : _error
        ? _errorActionFocus
        : null;
    if (target != null && target.context != null && target.canRequestFocus) {
      target.requestFocus();
    } else {
      _playerFocus.traversalDescendants.firstOrNull?.requestFocus();
    }
  }

  /// The pause screen covers the center play button with its own, and
  /// takes it away again on resume; focus moves across instead of being
  /// dropped.
  void _followPauseScreen() {
    final paused = _pauseOverlay.value;
    final from = paused ? _playButtonFocus : _pausePlayFocus;
    if (!from.hasFocus) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pauseOverlay.value != paused) return;
      final to = paused ? _pausePlayFocus : _playButtonFocus;
      if (to.context != null && to.canRequestFocus) {
        to.requestFocus();
      } else {
        _playerFocus.requestFocus();
      }
    });
  }

  /// Brings the controls up with focus on the play button, or on the pause
  /// screen's own button while it shows. Hidden controls cannot take focus,
  /// so focus moves once they are built visible, after this frame.
  void _showControlsFromRemote() {
    _show();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_playerFocus.hasPrimaryFocus) return;
      final target = _pauseOverlay.value ? _pausePlayFocus : _playButtonFocus;
      if (target.context != null && target.canRequestFocus) {
        target.requestFocus();
      } else {
        _playerFocus.traversalDescendants.firstOrNull?.requestFocus();
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// While the player is the top screen on TV, focus stays inside it.
  /// Otherwise keys would land on the route itself and never reach
  /// [_onRemoteKey], such as when controls hide while one of them is
  /// focused, or a sheet closes over a control that has since hidden.
  void _keepRemoteFocus() {
    final route = _route;
    if (!mounted || route == null || !route.isCurrent) return;
    if (_playerFocus.hasFocus) return;
    // The route's focus scope encloses the player.
    final scope = Focus.maybeOf(
      context,
      scopeOk: true,
      createDependency: false,
    )?.nearestScope;
    if (scope == null) return;
    final primary = FocusManager.instance.primaryFocus;
    // Focus in another route, such as a sheet still closing, is left alone.
    if (primary != null &&
        primary != scope &&
        !primary.ancestors.contains(scope)) {
      return;
    }
    _playerFocus.requestFocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tv) _route = ModalRoute.of(context);
  }

  void _show() {
    _controlsVisible.value = true;
    _scheduleHide();
  }

  void _syncControlsShown() =>
      _controlsShown.value = _controlsVisible.value && !_locked.value;

  void _lockControls() {
    unawaited(_endHoldSpeed());
    _hide?.cancel();
    if (_adjustingSubtitles) setState(() => _adjustingSubtitles = false);
    _locked.value = true;
    // Shown once at first, so the viewer sees how to get back.
    _revealUnlock();
  }

  /// Shows the unlock button for a few seconds.
  void _revealUnlock() {
    _unlockVisible.value = true;
    _unlockHide?.cancel();
    _unlockHide = Timer(const Duration(seconds: 3), () {
      if (mounted) _unlockVisible.value = false;
    });
  }

  void _unlockControls() {
    _unlockHide?.cancel();
    _unlockVisible.value = false;
    _locked.value = false;
    _show();
  }

  void _openSubtitlePosition() {
    // Controls step aside so subtitles sit where they will while watching.
    _hide?.cancel();
    _controlsVisible.value = false;
    setState(() => _adjustingSubtitles = true);
    // A remote starts on the slider: Left/Right move the subtitles.
    if (_tv) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _adjustingSubtitles) _focusViewControl();
      });
    }
  }

  void _closeSubtitlePosition() {
    if (_adjustingSubtitles) setState(() => _adjustingSubtitles = false);
  }

  /// Saves a final subtitle position; dragging only updates the live value.
  void _commitSubtitlePosition(double value) {
    if (value == _playback.subtitlePosition) return;
    unawaited(
      widget.playbackSettings.update(
        _playback.copyWith(subtitlePosition: value),
      ),
    );
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
    _scrubbing.value = scrubbing;
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
    // A TV is always landscape and cannot rotate.
    if (_orientationDecided || _tv) return;
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
    final id = await _withSheet(
      () => AudioTrackSheet.show(context, _audioTracks),
    );
    if (id == null || !mounted || !identical(controller, _controller)) return;
    await _selectAudioTrack(controller, id);
  }

  Future<void> _selectAudioTrack(
    VideoPlayerController controller,
    String id,
  ) async {
    try {
      await controller.selectAudioTrack(id).timeout(const Duration(seconds: 4));
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
    if (_playback.useForcedSubtitles) {
      unawaited(_applyPreferredSubtitle(automatic: false));
    }
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
    if (resolved != null &&
        resolved.next == null &&
        _nextEpisodePromptVisible) {
      _dismissNextEpisode();
    }
    // The episode's own still replaces the series artwork; fetch it now if
    // the session's artwork download has already happened.
    if (_ready && _artworkTimer?.isActive == false) _precachePauseArtwork();
  }

  Future<void> _resolveDetails() async {
    final pending = widget.details;
    if (pending == null) return;
    MediaDetails? resolved;
    try {
      resolved = await pending;
    } catch (_) {}
    if (!mounted || resolved == null) return;
    setState(() => _details = resolved);
  }

  /// What the pause screen shows, from the item, the episode list and the
  /// title details as far as they have resolved.
  PauseCardContent _pauseContent() => PauseCardContent.resolve(
    item: widget.item,
    episode: _episodes?.current,
    season: widget.season,
    episodeNumber: widget.episode,
    details: _details,
    duration: _controller?.value.duration,
  );

  /// Artwork decode width: the screen's longest side, so one decoded image
  /// serves both orientations, capped at 1920 px.
  int get _pauseArtworkWidth => _artworkWidth ??= View.of(
    context,
  ).physicalSize.longestSide.clamp(640, 1920).round();

  /// Downloads and decodes the pause artwork ahead of the first pause. The
  /// image cache keeps it, so pausing again never downloads it again.
  void _precachePauseArtwork() {
    if (!mounted || !_playback.pauseOverlay) return;
    final url = _pauseContent().artwork.firstOrNull;
    if (url == null || !_precachedArtwork.add(url)) return;
    unawaited(
      precacheImage(
        pauseArtworkImage(url, _pauseArtworkWidth),
        context,
        // The overlay falls back to other artwork or the video frame.
        onError: (_, _) {},
      ),
    );
  }

  void _resumeFromPauseScreen() {
    final c = _controller;
    if (c == null || !_ready || c.value.isPlaying) return;
    _togglePlay();
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
    final duration =
        c != null && c.value.isInitialized && c.value.duration > Duration.zero
        ? c.value.duration
        : _lastDuration;
    final season = widget.season, episode = widget.episode;
    return Future.wait([
      widget.storage.saveProgress(
        widget.item,
        position.inMilliseconds,
        durationMs: duration.inMilliseconds,
      ),
      // Each episode keeps its own position, under its own key.
      if (widget.item.type == 'series' && season != null && episode != null)
        widget.storage.saveEpisodeProgress(
          widget.item,
          season: season,
          episode: episode,
          positionMs: position.inMilliseconds,
          durationMs: duration.inMilliseconds,
        ),
    ]);
  }

  /// Where this playback starts: a series episode resumes from its own
  /// saved position (from the beginning once watched), never from another
  /// episode's; a movie from its history entry.
  late final Future<Duration> _startPosition = () async {
    final season = widget.season, episode = widget.episode;
    if (widget.item.type != 'series' || season == null || episode == null) {
      return Duration(milliseconds: widget.item.resumeMs);
    }
    try {
      final progress = await widget.storage.seriesProgress(widget.item);
      return Duration(
        milliseconds: progress.of(season, episode)?.resumeMs ?? 0,
      );
    } catch (_) {
      return Duration.zero;
    }
  }();

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

  /// The other engine, when it can open the current source.
  PlayerEngine? get _alternateEngine {
    final source = _source;
    final alternate = PlayerEngineFactory.alternateFor(_engine);
    if (source == null ||
        alternate == null ||
        !PlayerEngineFactory.canOpen(alternate, source.url)) {
      return null;
    }
    return alternate;
  }

  static String _engineName(PlayerEngineId id) => switch (id) {
    PlayerEngineId.media3 => 'the Android player',
    PlayerEngineId.mediaKit => 'the compatibility player',
    PlayerEngineId.flutterPlatform => 'the system player',
  };

  /// Reopens the current source on [engine] where the viewer was, and uses
  /// that engine for the rest of the session. Rendering failures that leave
  /// audio over a black picture raise no error, so this is the viewer's way
  /// out of them.
  Future<void> _switchEngine(PlayerEngine engine) async {
    final source = _source;
    if (source == null) return;
    _preferredEngine = engine;
    _nextStatus = 'Switching player…';
    PlaybackLog.log(
      'Player',
      'viewer switched engine ${_engine.id.name} -> ${engine.id.name}',
    );
    await _initialize(source, resetAttempts: false, engine: engine);
  }

  Future<void> _settings() async {
    final controller = _controller;
    final alternate = _alternateEngine;
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
        alternate == null ? null : _engineName(alternate.id),
      ),
    );
    if (result == null || !mounted) return;
    if (result.switchEngine && alternate != null) {
      await _switchEngine(alternate);
      return;
    }
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
    if (delayChanged) _syncExternalCue();
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
    if (result.adjustSubtitlePosition && mounted) _openSubtitlePosition();
  }

  /// Downloadable subtitles: from the provider and from subtitle addons, with
  /// the viewer's filters applied ("show only preferred languages" also
  /// applies to addon results).
  List<SubtitleTrack> get _availableSubtitles =>
      _filterSubtitles([..._providerSubtitles, ..._addonSubtitleResults]);

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
    _subtitlePosition.value = _playback.subtitlePosition;
    // Moving subtitles only redraws their layer, not the whole player.
    if (jsonEncode(
          previous.copyWith(subtitlePosition: _playback.subtitlePosition),
        ) ==
        jsonEncode(_playback)) {
      return;
    }
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
      _pauseOverlay.value = false;
    }
    setState(() {
      if (_subtitle != null &&
          _subtitle!.source != SubtitleSource.embedded &&
          !_availableSubtitles.any((track) => track.key == _subtitle!.key)) {
        _subtitle = null;
        _cues = [];
      }
    });
    _syncExternalCue();
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
    allowTorrents: _playback.p2pStreaming && TorrentSupport.available,
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
          await controller
              .selectAudioTrack(track.id)
              .timeout(const Duration(seconds: 2));
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

  /// Subtitles automatic selection may pick, in order: tracks in
  /// the video first, then provider subtitles, then OpenSubtitles.
  List<SubtitleTrack> get _autoSelectCandidates => [
    ..._filterSubtitles(_embeddedSubtitles),
    ..._availableSubtitles,
  ];

  /// Selects a subtitle in the preferred language, if one is set. Does
  /// nothing without a preferred language, so subtitles are never forced on.
  ///
  /// [automatic] calls (startup, new tracks or addon results) first restore
  /// the viewer's remembered choice for this title (kept per show):
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
    _syncExternalCue();
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
    _syncExternalCue();
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
  /// starting with the player. Never blocks or fails playback.
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
        // Progressive: each addon's results appear as they come.
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
        _syncExternalCue();
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
    // Detach first: nothing below may be notified after it is disposed.
    _controller?.removeListener(_tick);
    _discoverySubscription?.cancel();
    // Stop starting further providers for a lookup this screen started.
    _rediscovery?.cancel();
    widget.playbackSettings.removeListener(_onPlaybackSettingsChanged);
    FocusManager.instance.removeListener(_keepRemoteFocus);
    _pauseOverlay.removeListener(_followPauseScreen);
    _initializationGeneration++;
    final openCancellation = _openCancellation;
    if (openCancellation != null && !openCancellation.isCompleted) {
      openCancellation.complete();
    }
    // After a hand-over this episode is already saved; saving it again here
    // would mark it as watched last, after the next episode started.
    if (!_progressHandedOff) _saveProgress();
    _hide?.cancel();
    _save?.cancel();
    _hint?.cancel();
    _pauseOverlayTimer?.cancel();
    _artworkTimer?.cancel();
    _nextEpisodeTimer?.cancel();
    _unlockHide?.cancel();
    _controlsVisible.dispose();
    _locked.dispose();
    _unlockVisible.dispose();
    _controlsShown.dispose();
    _subtitlePosition.dispose();
    _scrubbing.dispose();
    _pauseOverlay.dispose();
    _seekFlash.dispose();
    _playerFocus.dispose();
    _playButtonFocus.dispose();
    _pausePlayFocus.dispose();
    _errorActionFocus.dispose();
    _subtitlePositionFocus.dispose();
    // Invalidate an in-flight subtitle search; its result is then ignored.
    _subtitleSearchGeneration++;
    _unbindEmbeddedSubtitles();
    _subtitleMenu.dispose();
    _embeddedLines.dispose();
    _externalCue.dispose();
    _controller?.dispose();
    _torrentSession?.stop();
    // When another episode's player replaced this one, it is already
    // showing: restoring the app's system UI and rotation would undo its.
    if (--_livePlayers == 0) {
      _setKeepScreenOn(false);
      const MethodChannel(
        'onfeed/player',
      ).invokeMethod<void>('resetBrightness');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // Leave the rest of the app free to rotate again.
      SystemChrome.setPreferredOrientations(const []);
    }
    super.dispose();
  }

  /// Hands the downloaded subtitle and the player's clock to [_externalCue].
  /// Embedded tracks are timed by libmpv itself, so they never use it.
  void _syncExternalCue() {
    final subtitle = _subtitle;
    final external =
        subtitle != null && subtitle.source != SubtitleSource.embedded;
    _externalCue.setCues(
      external ? _cues : const <SubtitleCue>[],
      delay: _subtitleDelay,
    );
    final value = _controller?.value;
    if (value == null || !value.isInitialized) return;
    _externalCue.sync(
      position: value.position,
      playing: value.isPlaying && !value.isBuffering,
      speed: value.playbackSpeed,
    );
  }

  void _tick() {
    final c = _controller;
    if (c == null) return;
    _syncExternalCue();
    _setKeepScreenOn(c.value.isPlaying);
    // The pause screen follows a viewer pause, after a short hold so the
    // paused frame registers first and quick pause/play taps do not flash
    // it. Seeking while paused keeps it; playing or reaching the end (where
    // the next-episode offer takes over) clears it.
    if (!_canShowPauseScreen(c.value)) {
      _pauseOverlayTimer?.cancel();
      _pauseOverlayTimer = null;
      _pauseOverlay.value = false;
    } else if (!_pauseOverlay.value && _pauseOverlayTimer == null) {
      _pauseOverlayTimer = Timer(const Duration(milliseconds: 450), () {
        _pauseOverlayTimer = null;
        final value = _controller?.value;
        if (mounted && value != null && _canShowPauseScreen(value)) {
          _pauseOverlay.value = true;
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
      if (c.value.duration > Duration.zero) _lastDuration = c.value.duration;
    }
    final duration = c.value.duration;
    if (widget.item.type == 'series' &&
        widget.onPlayEpisode != null &&
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

  bool _canShowPauseScreen(VideoPlayerValue value) =>
      _playback.pauseOverlay &&
      _ready &&
      !_switchingEpisode &&
      !_error &&
      value.isInitialized &&
      !value.isPlaying &&
      !value.isCompleted &&
      !value.hasError;

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final current = _source;
    final currentUri = current == null ? null : Uri.tryParse(current.url);
    final sourceDetails = <String>{
      if (current?.name.isNotEmpty == true) current!.name,
      if (current?.providerName.isNotEmpty == true) current!.providerName,
      if (currentUri?.hasAuthority == true) currentUri!.host,
    }.join(' · ');
    final playable = c != null && _ready;
    final alternatives = _sources.where(_isSourceAllowed).length;
    final quality = current == null
        ? ''
        : StreamSelectorSheet.qualityOf(current);
    final sourceLabel = [
      if (quality.isNotEmpty) quality,
      if (current?.providerName.isNotEmpty == true) current!.providerName,
    ].join(' · ');
    // Back while locked shows the unlock button instead of leaving, and
    // closes the subtitle position panel first. On TV, Back while watching
    // brings the controls up, so a single press never ends playback; Back
    // with the controls up leaves. Never blocks back while the lock overlay
    // is not up (loading, errors), so the viewer cannot be trapped.
    final player = _buildPlayer(
      c,
      current: current,
      sourceDetails: sourceDetails,
      alternatives: alternatives,
      sourceLabel: sourceLabel,
    );
    return ListenableBuilder(
      listenable: _backState,
      builder: (context, player) {
        final locked = _locked.value;
        final revealControls = _tv && playable && !_controlsShown.value;
        return PopScope(
          canPop:
              !(locked && playable) && !_adjustingSubtitles && !revealControls,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (locked && playable) {
              _revealUnlock();
            } else if (_adjustingSubtitles) {
              _closeSubtitlePosition();
            } else if (revealControls) {
              _showControlsFromRemote();
            }
          },
          child: player!,
        );
      },
      child: _tv
          ? Focus(
              focusNode: _playerFocus,
              autofocus: true,
              onKeyEvent: _onRemoteKey,
              child: player,
            )
          : player,
    );
  }

  Widget _buildPlayer(
    VideoPlayerController? c, {
    required StreamSource? current,
    required String sourceDetails,
    required int alternatives,
    required String sourceLabel,
  }) {
    final playable = c != null && _ready;
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
          // 2. Subtitles, raised above the bottom controls while they show
          // and moved by the viewer's position preference. Moving them
          // rebuilds only this layer's position, not the text below.
          if (c != null && (_subtitle != null || _adjustingSubtitles))
            ListenableBuilder(
              listenable: _subtitleLayout,
              builder: (context, text) => AnimatedPositioned(
                duration: playerFade,
                curve: Curves.easeOutCubic,
                left: 24,
                right: 24,
                bottom: PlaybackSettings.subtitleBottom(
                  height: MediaQuery.sizeOf(context).height,
                  padding: MediaQuery.viewPaddingOf(context),
                  controlsVisible: _controlsShown.value && playable,
                  position: _subtitlePosition.value,
                ),
                child: text!,
              ),
              child: IgnorePointer(
                // Embedded tracks: libmpv's current text. Others: cues
                // from the downloaded file, shifted by the subtitle delay
                // and timed from the player clock (see ExternalCueClock).
                child: _subtitle == null
                    ? _positionedSubtitleBox('')
                    : _subtitle!.source == SubtitleSource.embedded
                    ? ValueListenableBuilder<List<String>>(
                        valueListenable: _embeddedLines,
                        builder: (context, lines, _) => _positionedSubtitleBox(
                          lines
                              .map((line) => line.trim())
                              .where((line) => line.isNotEmpty)
                              .join('\n'),
                        ),
                      )
                    : ValueListenableBuilder<String>(
                        valueListenable: _externalCue,
                        builder: (context, text, _) =>
                            _positionedSubtitleBox(text),
                      ),
              ),
            ),
          // 3. Gestures. A single tap always toggles the controls; double
          // taps, swipes and hold-to-speed follow the viewer's settings.
          if (playable)
            GestureTouchLayer(
              // With the position panel open, a tap on the video closes it.
              onTap: _adjustingSubtitles
                  ? _closeSubtitlePosition
                  : _toggleControls,
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
          // 4. Pause screen: artwork and details over the paused video,
          // under the controls. Only its play button takes touches; other
          // taps reach the gesture layer as usual.
          if (playable)
            ReelishPausedOverlay(
              visible: _pauseOverlay,
              scrubbing: _scrubbing,
              content: _pauseContent(),
              artworkWidth: _pauseArtworkWidth,
              onPlay: _resumeFromPauseScreen,
              playFocusNode: _pausePlayFocus,
            ),
          // 5. Temporary feedback.
          if (playable) PlayerSeekFeedback(flashes: _seekFlash),
          if (playable)
            PlayerBufferingIndicator(
              controller: c,
              controlsVisible: _controlsShown,
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
          // 6. Controls: always mounted while playable, faded in and out.
          // Locking hides them without unmounting.
          if (playable)
            ValueListenableBuilder<bool>(
              valueListenable: _controlsShown,
              builder: (context, visible, child) => IgnorePointer(
                ignoring: !visible,
                // Hidden controls cannot be reached by the remote either.
                child: ExcludeFocus(
                  excluding: !visible,
                  child: AnimatedOpacity(
                    opacity: visible ? 1 : 0,
                    duration: playerFade,
                    curve: Curves.easeOutCubic,
                    // Hidden controls run no animations (the title marquee,
                    // button transitions) while the fade-out still completes.
                    child: TickerMode(enabled: visible, child: child!),
                  ),
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
                onEpisodes: _canSwitchEpisodes
                    ? () => unawaited(_openEpisodes())
                    : null,
                onSettings: _settings,
                // TV: no rotation, no touch lock, and picture in picture
                // only where the TV supports it.
                onPip:
                    _tv && !DeviceCapabilities.current.supportsPictureInPicture
                    ? null
                    : () async {
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
                onRotate: _tv ? null : _toggleLandscape,
                onNextEpisode: _nextEpisodePromptVisible && !_switchingEpisode
                    ? () => unawaited(_startNextEpisode())
                    : null,
                nextEpisodeCountdown: _nextEpisodeCountdown,
                onSpeedReset: _resetSpeed,
                pauseScreen: _pauseOverlay,
                onLock: _tv ? null : _lockControls,
                playFocusNode: _playButtonFocus,
              ),
            ),
          // The floating card shows while controls are hidden; with controls
          // up, the same offer is a pill in the bottom row, so the card never
          // covers the center controls on short landscape screens.
          if (_nextEpisodePromptVisible && !_switchingEpisode)
            ValueListenableBuilder<bool>(
              valueListenable: _controlsShown,
              builder: (context, controlsVisible, card) => IgnorePointer(
                ignoring: controlsVisible && playable,
                child: ExcludeFocus(
                  excluding: controlsVisible && playable,
                  child: AnimatedOpacity(
                    opacity: controlsVisible && playable ? 0 : 1,
                    duration: playerFade,
                    child: card,
                  ),
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
          if (playable && _adjustingSubtitles)
            SubtitlePositionPanel(
              position: _subtitlePosition,
              onChanged: (value) => _subtitlePosition.value = value,
              onCommit: _commitSubtitlePosition,
              onDone: _closeSubtitlePosition,
              sliderFocusNode: _subtitlePositionFocus,
            ),
          // Lock: one layer over everything that takes touches, so no
          // gesture or control beneath it can react. Only while a frame
          // shows; the loading and error views stay usable.
          if (playable)
            ValueListenableBuilder<bool>(
              valueListenable: _locked,
              builder: (context, locked, _) => locked
                  ? PlayerLockOverlay(
                      unlockVisible: _unlockVisible,
                      onReveal: _revealUnlock,
                      onUnlock: _unlockControls,
                    )
                  : const SizedBox.shrink(),
            ),
          // 7. No frame yet: starting, switching, reconnecting, or an error.
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
                      primaryFocusNode: _errorActionFocus,
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}
