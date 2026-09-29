import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/media_item.dart';
import '../../models/stream_source.dart';
import '../../services/storage_service.dart';
import '../../services/stream_discovery.dart';
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
    this.discovery,
    this.onRefreshSources,
  });
  final MediaItem item;
  final StreamSource source;
  final List<StreamSource> sources;
  final List<SubtitleTrack> subtitles;
  final StorageService storage;
  final StreamDiscovery? discovery;
  final Future<List<StreamSource>> Function()? onRefreshSources;
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
  double _speed = 1;
  SubtitleTrack? _subtitle;
  List<_Cue> _cues = [];
  List<VideoTrack> _videoTracks = [];
  List<VideoAudioTrack> _audioTracks = [];
  VideoTrack? _selectedVideoTrack;
  double _subtitleDelay = 0;
  TorrentStreamSession? _torrentSession;
  Timer? _hide, _save, _hint;
  String? _gestureHint;
  String? _errorMessage;
  int _initializationGeneration = 0;
  int _lastProgressSaveBucket = -1;
  final Set<String> _attemptedSourceKeys = {};
  late List<StreamSource> _sources;
  final _openSubtitles = OpenSubtitlesService();
  bool _handlingFailure = false;
  StreamSubscription<StreamSource>? _discoverySubscription;
  final DateTime _playerStartedAt = DateTime.now();
  final NetworkDestinationValidator _networkDestinations =
      NetworkDestinationValidator();
  @override
  void initState() {
    super.initState();
    _sources = List.of(widget.sources);
    _source = widget.source;
    _discoverySubscription = widget.discovery?.updates.listen((source) {
      if (!mounted || !source.isPlayable) return;
      final key = _sourceKey(source);
      if (_sources.any((entry) => _sourceKey(entry) == key)) return;
      setState(() => _sources.add(source));
      if (_error && _attemptedSourceKeys.length < 5) {
        final alternative = _nextAutomaticSource(
          _sourceKey(_source ?? widget.source),
        );
        if (alternative == null) return;
        setState(() {
          _error = false;
          _errorMessage = null;
        });
        unawaited(_initialize(alternative, resetAttempts: false));
      }
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initialize(widget.source);
  }

  Future<void> _initialize(
    StreamSource source, {
    bool resetAttempts = true,
  }) async {
    if (resetAttempts) _attemptedSourceKeys.clear();
    final requestedSourceKey = _sourceKey(source);
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
    });
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
      if (!isTorrent) {
        // media_kit/libmpv opens stream and playlist URLs in native code, so
        // it cannot use the pinned Dart HTTP client. Resolve and reject unsafe
        // destinations before handing them off. Dynamic provider hosts prevent
        // a safe static Android cleartext allowlist; Android cleartext stays
        // disabled globally while validated HTTP streams remain supported.
        await _networkDestinations.resolveDestination(
          Uri.parse(source.url),
          allowedSchemes: const {
            'https',
            'http',
            'rtmp',
            'rtmps',
            'rtsp',
            'rtsps',
            'rtp',
            'udp',
            'tcp',
            'srt',
            'mms',
            'mmsh',
          },
        );
      }
      if (!mounted || generation != _initializationGeneration) return;
      NetworkDestinationValidator.validateHeaders(source.headers);
      if (kDebugMode) {
        // ignore: avoid_print
        print(
          '[Stream] Player initialization started (TTP) in '
          '${DateTime.now().difference(_playerStartedAt).inMilliseconds}ms',
        );
      }
      final c = VideoPlayerController.networkUrl(
        Uri.parse(source.url),
        httpHeaders: source.headers,
      );
      _controller = c;
      await c.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || generation != _initializationGeneration) {
        await c.dispose();
        return;
      }
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
      c.addListener(_tick);
      try {
        await c.setPlaybackSpeed(_speed).timeout(const Duration(seconds: 2));
      } catch (_) {
        // Playback at normal speed can proceed if the backend is slow here.
      }
      if (widget.item.resumeMs > 0) {
        final resume = Duration(milliseconds: widget.item.resumeMs);
        final duration = c.value.duration;
        final safeResume =
            duration > const Duration(seconds: 1) && resume >= duration
            ? duration - const Duration(seconds: 1)
            : resume;
        if (safeResume > Duration.zero) {
          try {
            await c.seekTo(safeResume).timeout(const Duration(seconds: 2));
          } catch (_) {
            // Some live streams do not support seeking; playback can continue.
          }
        }
      }
      if (!mounted || generation != _initializationGeneration) return;
      await c.play();
      if (mounted && generation == _initializationGeneration) {
        if (kDebugMode) {
          // ignore: avoid_print
          print(
            '[Stream] Playback command accepted in '
            '${DateTime.now().difference(_playerStartedAt).inMilliseconds}ms',
          );
        }
        setState(() => _ready = true);
        _scheduleHide();
      }
    } catch (error) {
      if (mounted &&
          generation == _initializationGeneration &&
          !_handlingFailure) {
        _handlingFailure = true;
        final failedController = _controller;
        _controller = null;
        try {
          await failedController?.dispose();
          await _torrentSession?.stop();
        } catch (_) {}
        _torrentSession = null;
        final message = _safePlaybackError(error.toString());
        _attemptedSourceKeys.add(requestedSourceKey);
        final alternative = _nextAutomaticSource(requestedSourceKey);
        if (alternative != null && _attemptedSourceKeys.length < 5) {
          await _initialize(alternative, resetAttempts: false);
          return;
        }
        setState(() {
          _error = true;
          final details = _attemptedSourceKeys.length > 1
              ? 'Could not play ${_attemptedSourceKeys.length} sources. $message'
              : message;
          _errorMessage = details.length > 280
              ? '${details.substring(0, 277)}…'
              : details;
        });
      }
    }
  }

  String _sourceKey(StreamSource source) {
    final headers = source.headers.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return '${source.url}|${jsonEncode(headers.map((e) => [e.key.toLowerCase(), e.value]).toList())}';
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

  StreamSource? _nextAutomaticSource(String failedSourceKey) {
    final candidates = _sources
        .where((source) => !_attemptedSourceKeys.contains(_sourceKey(source)))
        .toList();
    if (candidates.isEmpty) return null;

    final failedSource =
        _sources
            .where((source) => _sourceKey(source) == failedSourceKey)
            .firstOrNull ??
        _source;
    final failedProvider = failedSource?.providerName ?? '';
    if (failedProvider.isEmpty) return candidates.first;

    final differentProvider = candidates
        .where((source) => source.providerName != failedProvider)
        .firstOrNull;
    if (differentProvider != null) return differentProvider;

    final triedFromProvider = _sources
        .where(
          (source) =>
              source.providerName == failedProvider &&
              _attemptedSourceKeys.contains(_sourceKey(source)),
        )
        .length;
    // Several links from one scraper often point to the same failing host.
    // Give it one alternate, then let other providers finish and take over.
    return triedFromProvider < 2 ? candidates.first : null;
  }

  Future<void> _retryPlayback() async {
    final refresh = widget.onRefreshSources;
    if (refresh == null) {
      await _initialize(_source!);
      return;
    }
    setState(() {
      _error = false;
      _errorMessage = null;
    });
    try {
      final freshSources = await refresh();
      if (!mounted) return;
      final playable = freshSources
          .where((source) => source.isPlayable)
          .toList();
      if (playable.isNotEmpty) {
        final previous = _source!;
        _sources = playable;
        final refreshed = playable
            .where(
              (source) =>
                  source.name == previous.name &&
                  source.providerName == previous.providerName &&
                  source.description == previous.description,
            )
            .firstOrNull;
        await _initialize(refreshed ?? playable.first);
        return;
      }
    } catch (_) {
      // If refresh fails, retry the last known URL.
    }
    if (mounted) await _initialize(_source!);
  }

  Future<void> _handleRuntimePlaybackFailure(
    String failedSourceKey,
    String error,
    int generation,
  ) async {
    if (!mounted ||
        generation != _initializationGeneration ||
        _handlingFailure) {
      return;
    }
    _handlingFailure = true;
    final failedController = _controller;
    _controller = null;
    failedController?.removeListener(_tick);
    try {
      await failedController?.dispose();
      await _torrentSession?.stop();
    } catch (_) {}
    _torrentSession = null;
    if (!mounted || generation != _initializationGeneration) return;

    _attemptedSourceKeys.add(failedSourceKey);
    // Keep automatic failover bounded; every remaining source is still
    // available from Choose another.
    const maxAutomaticSources = 5;
    final alternative = _attemptedSourceKeys.length < maxAutomaticSources
        ? _nextAutomaticSource(failedSourceKey)
        : null;
    if (alternative != null) {
      await _initialize(alternative, resetAttempts: false);
      return;
    }

    final message = _safePlaybackError(error);
    if (!mounted || generation != _initializationGeneration) return;
    setState(() {
      _error = true;
      _errorMessage = _attemptedSourceKeys.length > 1
          ? 'Could not play ${_attemptedSourceKeys.length} sources. $message'
          : message;
    });
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
    final dir = await getApplicationDocumentsDirectory();
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
    if (c == null || !c.value.isInitialized) return Future.value();
    return widget.storage.saveProgress(
      widget.item,
      c.value.position.inMilliseconds,
    );
  }

  Future<void> _pickStream() async {
    final streams = _sources;
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
    }
    if (_subtitle != null) await _loadSubtitle(_subtitle!);
    _show();
  }

  List<SubtitleTrack> get _availableSubtitles {
    final unique = <String, SubtitleTrack>{};
    for (final track in [...widget.subtitles, ...?_source?.subtitles]) {
      if (track.url.isNotEmpty) unique.putIfAbsent(track.url, () => track);
    }
    return unique.values.toList();
  }

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
    _initializationGeneration++;
    _saveProgress();
    _hide?.cancel();
    _save?.cancel();
    _hint?.cancel();
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
    if (c.value.hasError) {
      unawaited(
        _handleRuntimePlaybackFailure(
          _sourceKey(_source ?? widget.source),
          c.value.errorDescription ?? 'The video source failed.',
          _initializationGeneration,
        ),
      );
      return;
    }
    final progressBucket = c.value.position.inSeconds ~/ 5;
    if (progressBucket != _lastProgressSaveBucket) {
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
                  : const CircularProgressIndicator(color: GlassTheme.primary),
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
                        bottom: 88,
                        left: 24,
                        right: 24,
                        child: IgnorePointer(
                          child: Text(
                            cue.text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(blurRadius: 7, color: Colors.black),
                                Shadow(blurRadius: 12, color: Colors.black),
                              ],
                            ),
                          ),
                        ),
                      );
              },
            ),
          if (c != null && _ready)
            GestureTouchLayer(
              child: const SizedBox.expand(),
              onTap: _toggleControls,
              onDoubleTap: (right) => c.seekTo(
                c.value.position + Duration(seconds: right ? 10 : -10),
              ),
              onSwipe: (right, amount) {
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
          if (!_ready && !_error)
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
