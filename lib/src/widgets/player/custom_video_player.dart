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
    this.onRefreshSources,
  });
  final MediaItem item;
  final StreamSource source;
  final List<StreamSource> sources;
  final List<SubtitleTrack> subtitles;
  final StorageService storage;
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
  @override
  void initState() {
    super.initState();
    _sources = List.of(widget.sources);
    _source = widget.source;
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
      if (source.isTorrent) source = await _prepareTorrent(source);
      if (!mounted || generation != _initializationGeneration) return;
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
      try {
        if (c.isVideoTrackSupportAvailable()) {
          _videoTracks = await c.getVideoTracks();
          _videoTracks.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
        } else {
          _videoTracks = [];
        }
      } catch (_) {
        // Track selection is optional; playback should continue without it.
        _videoTracks = [];
      }
      try {
        _audioTracks = c.isAudioTrackSupportAvailable()
            ? await c.getAudioTracks()
            : [];
      } catch (_) {
        _audioTracks = [];
      }
      c.addListener(_tick);
      await c.setPlaybackSpeed(_speed);
      if (widget.item.resumeMs > 0) {
        final resume = Duration(milliseconds: widget.item.resumeMs);
        final duration = c.value.duration;
        final safeResume =
            duration > const Duration(seconds: 1) && resume >= duration
            ? duration - const Duration(seconds: 1)
            : resume;
        if (safeResume > Duration.zero) {
          try {
            await c.seekTo(safeResume);
          } catch (_) {
            // Some live streams do not support seeking; playback can continue.
          }
        }
      }
      if (!mounted || generation != _initializationGeneration) return;
      await c.play();
      if (mounted && generation == _initializationGeneration) {
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
        final alternative = _sources
            .where(
              (candidate) =>
                  !_attemptedSourceKeys.contains(_sourceKey(candidate)),
            )
            .firstOrNull;
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
        ? _sources
              .where(
                (candidate) =>
                    !_attemptedSourceKeys.contains(_sourceKey(candidate)),
              )
              .firstOrNull
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
    var magnet = source.url;
    if (!magnet.startsWith('magnet:')) {
      final hash = source.infoHash.trim();
      if (hash.isEmpty) throw Exception('Torrent source has no info hash.');
      magnet = 'magnet:?xt=urn:btih:$hash';
      if (source.name.isNotEmpty)
        magnet += '&dn=${Uri.encodeComponent(source.name)}';
      for (final tracker in source.torrentSources) {
        if (tracker.startsWith('tracker:'))
          magnet += '&tr=${Uri.encodeComponent(tracker.substring(8))}';
      }
    }
    final dir = await getApplicationDocumentsDirectory();
    final session = await FlutterTorrentStreamer().startStream(
      magnet,
      dir.path,
    );
    _torrentSession = session;
    List<TorrentFile> files = [];
    for (var i = 0; i < 60 && files.isEmpty; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      files = await session.getFiles();
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
    if (_videoTracks.isNotEmpty)
      await _controller?.selectVideoTrack(_selectedVideoTrack);
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
            color: const Color(0xFF171D29),
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
      final response = await http
          .get(Uri.parse(track.url), headers: track.headers)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw Exception();
      final raw = response.body.replaceAll('\r', '');
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
        if (text.isNotEmpty)
          cues.add(_Cue(sec(m.group(1)!), sec(m.group(2)!), text));
      }
      if (mounted) setState(() => _cues = cues);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load subtitles.')),
        );
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
                  : const CircularProgressIndicator(color: GlassTheme.cyan),
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
