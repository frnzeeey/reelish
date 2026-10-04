import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';
import '../../models/media_item.dart';
import '../../models/playback_settings.dart';
import '../../models/stream_source.dart';
import '../../services/storage_service.dart';
import '../../services/playback_settings_controller.dart';
import '../../services/stream_discovery.dart';
import '../../services/perf_timeline.dart';
import '../../services/playback_coordinator.dart';
import '../../services/player_engine.dart';
import '../../services/playback_source_policy.dart';
import '../../services/video_quality_selector.dart';
import '../../services/network_target_policy.dart';
import '../../services/open_subtitles_service.dart';
import '../../theme/glass_theme.dart';
import 'glass_controls_overlay.dart';
import 'gesture_touch_layer.dart';
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
  @override
  State<CustomVideoPlayer> createState() => _CustomVideoPlayerState();
}

class _CustomVideoPlayerState extends State<CustomVideoPlayer> {
  VideoPlayerController? _controller;
  StreamSource? _source;
  bool _ready = false, _error = false, _visible = true;
  double _volume = 1, _brightness = 1;
  BoxFit _fit = BoxFit.contain;
  double _ratio = 0;
  late double _speed;
  SubtitleTrack? _subtitle;
  List<_Cue> _cues = [];
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
  final _openSubtitles = OpenSubtitlesService();
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
      _visible = true;
      _pauseOverlayVisible = false;
    });
    _pauseOverlayTimer?.cancel();
    _pauseOverlayTimer = null;
    _source = source;
    _videoTracks = [];
    _audioTracks = [];
    _selectedVideoTrack = null;
    if (_subtitle != null &&
        ![
          ...widget.subtitles,
          ...source.subtitles,
        ].any((track) => track.url == _subtitle!.url)) {
      _subtitle = null;
      _cues = [];
    }
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
      setState(() => _ready = false);
      await Future<void>.delayed(delay);
      if (!mounted || generation != _initializationGeneration) return;
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
    if (mounted) setState(() => _nextEpisodePromptVisible = false);
    await callback();
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

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _show() {
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    if (_visible) {
      _hide?.cancel();
      setState(() => _visible = false);
    } else {
      _show();
    }
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
    if (streams.length < 2) return;
    final picked = await StreamSelectorSheet.show(context, streams, _source!);
    if (picked != null) {
      _source = picked;
      _error = false;
      await _initialize(picked);
    }
  }

  Future<void> _settings() async {
    final result = await PlayerSettingsSheet.show(
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
    );
    if (result == null) return;
    setState(() {
      _speed = result.speed;
      _fit = result.fit;
      _ratio = result.ratio;
      _subtitle = result.subtitle;
      _subtitleDelay = result.subtitleDelay;
      _selectedVideoTrack = result.videoTrack;
      _cues = [];
    });
    await _controller?.setPlaybackSpeed(_speed);
    if (_videoTracks.isNotEmpty) {
      await _controller?.selectVideoTrack(_selectedVideoTrack);
    }
    if (result.audioTrackId != null) {
      await _controller?.selectAudioTrack(result.audioTrackId!);
      if (mounted) {
        setState(() {
          _audioTracks = [
            for (final track in _audioTracks)
              VideoAudioTrack(
                id: track.id,
                label: track.label,
                language: track.language,
                isSelected: track.id == result.audioTrackId,
                bitrate: track.bitrate,
                sampleRate: track.sampleRate,
                channelCount: track.channelCount,
                codec: track.codec,
              ),
          ];
        });
      }
      if (_playback.useForcedSubtitles) {
        await _applyPreferredSubtitle();
      }
    }
    if (_subtitle != null) await _loadSubtitle(_subtitle!);
    _show();
  }

  List<SubtitleTrack> get _availableSubtitles {
    final unique = <String, SubtitleTrack>{};
    for (final track in [...widget.subtitles, ...?_source?.subtitles]) {
      if (track.url.isNotEmpty) unique.putIfAbsent(track.url, () => track);
    }
    var tracks = unique.values.toList();
    if (_playback.stripSdhSubtitles) {
      tracks = tracks.where((track) => !_isSdh(track)).toList();
    }
    if (_playback.showOnlyPreferredLanguages) {
      final preferred = {
        _normalizedLanguage(_playback.preferredSubtitleLanguage),
        _normalizedLanguage(_playback.secondarySubtitleLanguage),
        if (_playback.useForcedSubtitles)
          _normalizedLanguage(_selectedAudioLanguage),
      }..remove('');
      if (preferred.isNotEmpty) {
        tracks = tracks
            .where(
              (track) => preferred.any(
                (language) => _languageMatches(track.lang, language),
              ),
            )
            .toList();
      } else {
        tracks = [];
      }
    }
    return tracks;
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
        _nextEpisodePromptVisible) {
      unawaited(_startNextEpisode());
    }
    if (previous.pauseOverlay && !_playback.pauseOverlay) {
      _pauseOverlayTimer?.cancel();
      _pauseOverlayTimer = null;
      _pauseOverlayVisible = false;
    }
    setState(() {
      if (_subtitle != null &&
          !_availableSubtitles.any((track) => track.url == _subtitle!.url)) {
        _subtitle = null;
        _cues = [];
      }
    });
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
      unawaited(_applyPreferredSubtitle());
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
      unawaited(_applyPreferredSubtitle());
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

  Future<void> _applyPreferredSubtitle() async {
    if (_playback.useForcedSubtitles) {
      final audioLanguage = _selectedAudioLanguage;
      final forced = _availableSubtitles
          .where(_isForced)
          .where(
            (track) =>
                audioLanguage.isNotEmpty &&
                _languageMatches(track.lang, audioLanguage),
          )
          .firstOrNull;
      if (forced == null) {
        if (_subtitle != null) {
          setState(() {
            _subtitle = null;
            _cues = [];
          });
        }
        return;
      }
      await _selectSubtitle(forced);
      return;
    }
    for (final language in [
      _playback.preferredSubtitleLanguage,
      _playback.secondarySubtitleLanguage,
    ].where((value) => value.isNotEmpty)) {
      final match = _availableSubtitles
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

  Future<void> _selectSubtitle(SubtitleTrack track) async {
    if (_subtitle?.url == track.url) return;
    if (!mounted) return;
    setState(() {
      _subtitle = track;
      _cues = [];
    });
    await _loadSubtitle(track);
  }

  String _normalizedLanguage(String language) {
    final code = language.trim().toLowerCase().split(RegExp(r'[-_ ]')).first;
    return const {
          'eng': 'en',
          'english': 'en',
          'spa': 'es',
          'spanish': 'es',
          'fre': 'fr',
          'fra': 'fr',
          'french': 'fr',
          'ger': 'de',
          'deu': 'de',
          'german': 'de',
          'ita': 'it',
          'italian': 'it',
          'por': 'pt',
          'portuguese': 'pt',
          'jpn': 'ja',
          'japanese': 'ja',
          'kor': 'ko',
          'korean': 'ko',
          'chi': 'zh',
          'zho': 'zh',
          'chinese': 'zh',
          'ara': 'ar',
          'arabic': 'ar',
          'rus': 'ru',
          'russian': 'ru',
        }[code] ??
        code;
  }

  bool _languageMatches(String trackLanguage, String preferred) {
    final track = _normalizedLanguage(trackLanguage);
    final target = _normalizedLanguage(preferred);
    return track.isNotEmpty && target.isNotEmpty && track == target;
  }

  bool _isForced(SubtitleTrack track) => RegExp(
    r'forced|foreign|signs.?only',
    caseSensitive: false,
  ).hasMatch('${track.id} ${track.format} ${track.url}');

  bool _isSdh(SubtitleTrack track) => RegExp(
    r'\b(sdh|cc|hi)\b|hearing.?impaired|closed.?caption',
    caseSensitive: false,
  ).hasMatch('${track.id} ${track.lang} ${track.format} ${track.url}');

  Future<void> _pickSubtitles() async {
    final selected = await SubtitlePickerSheet.show(
      context,
      _availableSubtitles,
      _subtitle,
      onOpenSubtitles: true,
    );
    if (selected == null || !mounted) return;
    if (selected.url == 'opensubtitles://search') {
      await _searchOpenSubtitles();
      return;
    }
    if (selected.url.isEmpty) {
      setState(() {
        _subtitle = null;
        _cues = [];
      });
      _show();
      return;
    }
    setState(() {
      _subtitle = selected;
      _cues = [];
    });
    await _loadSubtitle(selected);
    _show();
  }

  Future<void> _searchOpenSubtitles() async {
    try {
      final results = await _openSubtitles.search(
        type: widget.item.type,
        imdbId: widget.item.externalId,
        fallbackId: widget.item.id,
        subtitleQuery: widget.item.subtitleQuery,
      );
      if (!mounted) return;
      if (results.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No OpenSubtitles v3 results found.')),
        );
        return;
      }
      final result = await showModalBottomSheet<OpenSubtitleResult>(
        context: context,
        backgroundColor: Colors.transparent,
        useSafeArea: true,
        builder: (context) => Padding(
          padding: const EdgeInsets.all(14),
          child: Material(
            color: GlassTheme.surface,
            borderRadius: BorderRadius.circular(24),
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  leading: Icon(Icons.search_rounded),
                  title: Text('OpenSubtitles v3 results'),
                ),
                for (final subtitle in results)
                  ListTile(
                    leading: const Icon(Icons.subtitles_rounded),
                    title: Text(
                      subtitle.name.isEmpty ? subtitle.language : subtitle.name,
                    ),
                    subtitle: Text(
                      '${subtitle.language}${subtitle.format.isNotEmpty ? ' · ${subtitle.format}' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, subtitle),
                  ),
              ],
            ),
          ),
        ),
      );
      if (result == null || !mounted) return;
      final track = SubtitleTrack(
        url: result.url,
        lang: result.language,
        id: result.id,
        format: result.format,
        headers: result.headers,
      );
      setState(() {
        _subtitle = track;
        _cues = [];
      });
      await _loadSubtitle(track);
      _show();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'OpenSubtitles v3: ${error.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    }
  }

  Future<void> _loadSubtitle(SubtitleTrack track) async {
    try {
      final raw = (await _fetchSubtitle(track)).replaceAll('\r', '');
      final cues = <_Cue>[];
      final reg = RegExp(
        r'((?:\d{2}:)?\d{2}:\d{2}[,.]\d{3})\s*-->\s*((?:\d{2}:)?\d{2}:\d{2}[,.]\d{3})',
      );
      for (final block in raw.split(RegExp(r'\n\s*\n'))) {
        final lines = block.split('\n');
        final i = lines.indexWhere((l) => reg.hasMatch(l));
        if (i < 0) continue;
        final m = reg.firstMatch(lines[i])!;
        double sec(String s) {
          final parts = s.replaceAll(',', '.').split(':');
          final hours = parts.length == 3 ? int.parse(parts[0]) : 0;
          final minutePart = parts.length == 3 ? parts[1] : parts[0];
          final secondPart = parts.length == 3 ? parts[2] : parts[1];
          final secondParts = secondPart.split('.');
          final seconds = int.parse(secondParts[0]);
          final milliseconds = int.parse(secondParts[1].padRight(3, '0'));
          return hours * 3600 +
              int.parse(minutePart) * 60 +
              seconds +
              milliseconds / 1000;
        }

        final text = lines
            .skip(i + 1)
            .join('\n')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&nbsp;', ' ')
            .trim();
        if (text.isNotEmpty) {
          cues.add(_Cue(sec(m.group(1)!), sec(m.group(2)!), text));
        }
      }
      if (mounted) setState(() => _cues = cues);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load subtitles.')),
        );
      }
    }
  }

  Future<String> _fetchSubtitle(SubtitleTrack track) async {
    var current = Uri.parse(track.url);
    final headers = Map<String, String>.of(track.headers);
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      final response = await _networkDestinations.sendForBytes(
        request,
        allowedSchemes: const {'https'},
        maxResponseBytes: 4 * 1024 * 1024,
        timeout: const Duration(seconds: 12),
      );
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw const FormatException('Subtitle request failed.');
        }
        return utf8.decode(response.bodyBytes, allowMalformed: true);
      }
      final location = response.headers['location'];
      if (location == null || redirects == 5) {
        throw const FormatException('Invalid subtitle redirect.');
      }
      final next = await _networkDestinations.validateRedirect(
        current,
        location,
        allowedSchemes: const {'https'},
      );
      final sameOrigin =
          current.scheme == next.scheme &&
          current.host.toLowerCase() == next.host.toLowerCase() &&
          current.port == next.port;
      if (!sameOrigin) {
        headers.removeWhere(
          (name, _) =>
              !const {'accept', 'user-agent'}.contains(name.toLowerCase()),
        );
      }
      current = next;
    }
    throw const FormatException('Too many subtitle redirects.');
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
    _controller?.removeListener(_tick);
    _controller?.dispose();
    _torrentSession?.stop();
    const MethodChannel('onfeed/player').invokeMethod<void>('resetBrightness');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
        duration > Duration.zero &&
        c.value.position.inMilliseconds * 100 >=
            duration.inMilliseconds * _playback.nextEpisodeThresholdPercent) {
      _nextEpisodeHandled = true;
      if (_playback.autoPlayNextEpisode) {
        unawaited(_startNextEpisode());
      } else if (mounted) {
        setState(() => _nextEpisodePromptVisible = true);
      }
    }
    // Each save rewrites the whole history list, so save every 15 s while
    // playing, plus immediately when playback pauses (the app may then be
    // backgrounded and killed without disposing this screen).
    final playing = c.value.isPlaying;
    final paused = _wasPlaying && !playing && _ready;
    _wasPlaying = playing;
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
    final failedSource = _source;
    final failedUri = failedSource == null
        ? null
        : Uri.tryParse(failedSource.url);
    final sourceDetails = [
      if (failedSource?.name.isNotEmpty == true) failedSource!.name,
      if (failedSource?.providerName.isNotEmpty == true)
        failedSource!.providerName,
      if (failedUri?.hasAuthority == true) failedUri!.host,
    ].toSet().join(' · ');
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (c != null && _ready)
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
            )
          else
            Center(
              child: _error
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: Colors.orangeAccent,
                            size: 42,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'This stream could not be played.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                          if (sourceDetails.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              sourceDetails,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          if (_errorMessage?.isNotEmpty == true) ...[
                            const SizedBox(height: 8),
                            Text(
                              _errorMessage!,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          const SizedBox(height: 18),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _retryPlayback,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Retry'),
                              ),
                              if (_sources.length > 1)
                                FilledButton.icon(
                                  onPressed: _pickStream,
                                  icon: const Icon(Icons.playlist_play_rounded),
                                  label: const Text('Choose another'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : (_playback.showLoadingOverlay
                        ? CircularProgressIndicator(
                            color: GlassTheme.primary,
                          )
                        : const SizedBox.shrink()),
            ),
          if (c != null &&
              _ready &&
              _brightness < 1 &&
              defaultTargetPlatform != TargetPlatform.android)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 1 - _brightness),
                ),
              ),
            ),
          if (c != null && _subtitle != null)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (context, v, _) {
                final t = v.position.inMilliseconds / 1000 - _subtitleDelay;
                final cue = _cues
                    .where((e) => t >= e.start && t <= e.end)
                    .firstOrNull;
                return cue == null
                    ? const SizedBox.shrink()
                    : Positioned(
                        bottom: 80 + _playback.subtitleVerticalOffset,
                        left: 24,
                        right: 24,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(_playback.subtitleBackgroundColor),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                                vertical: 1,
                              ),
                              child: _subtitleText(cue.text),
                            ),
                          ),
                        ),
                      );
              },
            ),
          if (c != null &&
              _ready &&
              (_playback.touchGestures || _playback.holdToSpeed))
            GestureTouchLayer(
              child: const SizedBox.expand(),
              onTap: _playback.touchGestures ? _toggleControls : () {},
              onDoubleTap: (right) {
                if (!_playback.touchGestures) return;
                c.seekTo(
                  c.value.position + Duration(seconds: right ? 10 : -10),
                );
              },
              onSwipe: (right, amount) {
                if (!_playback.touchGestures) return;
                if (right) {
                  _volume = (_volume + amount).clamp(0, 1);
                  c.setVolume(_volume);
                  _hintFor('Volume ${(_volume * 100).round()}%');
                } else {
                  _brightness = (_brightness + amount).clamp(.15, 1);
                  if (defaultTargetPlatform == TargetPlatform.android) {
                    const MethodChannel('onfeed/player').invokeMethod<void>(
                      'setBrightness',
                      {'value': _brightness},
                    );
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
            ),
          if (_gestureHint != null)
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _gestureHint!,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          if (_visible && c != null && _ready)
            GlassControlsOverlay(
              controller: c,
              title: widget.item.name,
              sourceLabel: [
                if (_source?.providerName.isNotEmpty == true)
                  _source!.providerName,
                if (_source?.name.isNotEmpty == true) _source!.name,
              ].toSet().join(' · '),
              subtitleEnabled: _subtitle != null,
              onBack: () {
                _saveProgress();
                Navigator.pop(context);
              },
              onToggle: () {
                c.value.isPlaying ? c.pause() : c.play();
                _show();
              },
              onSeek: (d) {
                final max = c.value.duration;
                final target = d < Duration.zero
                    ? Duration.zero
                    : (d > max ? max : d);
                c.seekTo(target);
                _show();
              },
              onStreams: _pickStream,
              onSettings: _settings,
              onSubtitles: _pickSubtitles,
              onPip: () async {
                _hide?.cancel();
                setState(() => _visible = false);
                try {
                  await const MethodChannel('onfeed/player').invokeMethod<bool>(
                    'enterPip',
                    {'ratio': c.value.aspectRatio},
                  );
                } catch (_) {}
              },
            ),
          if (_pauseOverlayVisible && c != null && _ready && !c.value.isPlaying)
            Center(
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .72),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    widget.item.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          if (_nextEpisodePromptVisible && !_startingNextEpisode)
            Positioned(
              left: 20,
              right: 20,
              bottom: 108,
              child: Material(
                color: const Color(0xEE19191F),
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Play the next episode?',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => _nextEpisodePromptVisible = false),
                        child: const Text('Not now'),
                      ),
                      FilledButton(
                        onPressed: () => unawaited(_startNextEpisode()),
                        child: const Text('Play'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!_ready && !_error && _playback.showLoadingStatus)
            const Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.all(30),
                child: Text(
                  'Connecting to stream…',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Cue {
  const _Cue(this.start, this.end, this.text);
  final double start, end;
  final String text;
}
