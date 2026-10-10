import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';

import '../models/stream_source.dart';
import 'network_target_policy.dart';
import 'storage_service.dart';

/// Whether torrent playback can work in this app process.
///
/// It needs the torrent streamer's native library, which is built for
/// arm64-v8a and x86_64 only. A 32-bit Android process (armeabi-v7a) cannot
/// load it. That includes many Android TV and Google TV devices, such as
/// Chromecast with Google TV, which run 32-bit Android on 64-bit chips. There,
/// torrent sources are neither requested nor offered, instead of failing
/// each time one is played.
abstract final class TorrentSupport {
  static bool get available {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    // Only a real Android process has an ABI that decides this; widget tests
    // on a desktop host keep the Android behavior.
    if (!Platform.isAndroid) return true;
    final abi = Abi.current();
    return abi == Abi.androidArm64 || abi == Abi.androidX64;
  }
}

/// Turns a torrent source into a playable loopback stream: validates its info
/// hash and trackers, starts a streaming session, waits for the torrent's
/// metadata and selects the video file to play.
class TorrentSourcePreparer {
  TorrentSourcePreparer({
    required StorageService storage,
    NetworkDestinationValidator? destinations,
  }) : _storage = storage,
       _destinations = destinations ?? NetworkDestinationValidator();

  final StorageService _storage;
  final NetworkDestinationValidator _destinations;

  static final _topicPattern = RegExp(
    r'^urn:btih:(?:[0-9a-f]{40}|[a-z2-7]{32})$|^urn:btmh:1220[0-9a-f]{64}$',
    caseSensitive: false,
  );
  static final _videoFile = RegExp(
    r'\.(mkv|mp4|m4v|webm|mov|avi)$',
    caseSensitive: false,
  );

  /// The torrent's `xt` topic from its magnet link or info hash, or null
  /// when it has no valid one.
  static String? topicOf(StreamSource source) {
    final magnet = _magnetOf(source);
    final topic =
        magnet?.queryParametersAll['xt']
            ?.where((value) => _topicPattern.hasMatch(value))
            .firstOrNull ??
        (source.infoHash.isEmpty ? null : 'urn:btih:${source.infoHash.trim()}');
    return topic != null && _topicPattern.hasMatch(topic) ? topic : null;
  }

  static Uri? _magnetOf(StreamSource source) =>
      source.url.toLowerCase().startsWith('magnet:')
      ? Uri.tryParse(source.url)
      : null;

  /// Starts [source] and returns the loopback stream to play.
  ///
  /// [onSession] receives the session as soon as it exists, so the caller
  /// can stop it if it is closed while metadata loads. When [superseded]
  /// turns true (the player closed or moved on) the preparation stops; a
  /// session that finished starting after that point is stopped here, since
  /// nothing else holds it.
  Future<StreamSource> prepare(
    StreamSource source, {
    required bool Function() superseded,
    required void Function(TorrentStreamSession session) onSession,
  }) async {
    final topic = topicOf(source);
    if (topic == null) {
      throw Exception('Torrent source has no valid info hash.');
    }
    final trackers = await _publicTrackers(source);
    final magnet = Uri(
      scheme: 'magnet',
      queryParameters: <String, dynamic>{
        'xt': topic,
        if (source.name.isNotEmpty) 'dn': source.name,
        if (trackers.isNotEmpty) 'tr': trackers,
      },
    ).toString();
    final dir = await _storage.torrentCacheDirectory();
    if (superseded()) throw _cancelled();
    final session = await FlutterTorrentStreamer().startStream(
      magnet,
      dir.path,
    );
    if (superseded()) {
      unawaited(session.stop().catchError((Object _) {}));
      throw _cancelled();
    }
    onSession(session);
    final files = await _metadata(session, superseded);
    if (superseded()) throw _cancelled();
    if (files.isEmpty) throw Exception('Torrent metadata did not load.');
    final videoFiles = files.where((f) => _videoFile.hasMatch(f.name)).toList();
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

  /// Up to eight provider-supplied trackers that resolve to public
  /// addresses, checked four at a time.
  ///
  /// Invalid, private, or unresolvable trackers are omitted. The native
  /// torrent engine performs its own peer/DHT networking beyond this Dart
  /// preflight, so this narrows plugin-supplied tracker risk without claiming
  /// to pin native sockets.
  Future<List<String>> _publicTrackers(StreamSource source) async {
    final candidates = <String>{
      ...?_magnetOf(source)?.queryParametersAll['tr'],
      ...source.torrentSources
          .where((tracker) => tracker.startsWith('tracker:'))
          .map((tracker) => tracker.substring(8)),
    }.where(StreamSource.isSafeTorrentTracker).take(8).toList();
    final accepted = <String>[];
    var next = 0;
    Future<void> worker() async {
      while (next < candidates.length) {
        final tracker = candidates[next++];
        try {
          await _destinations.resolveDestination(
            Uri.parse(tracker),
            allowedSchemes: const {'http', 'https', 'udp'},
          );
          accepted.add(tracker);
        } catch (_) {}
      }
    }

    await Future.wait(
      List.generate(candidates.length < 4 ? candidates.length : 4, (_) {
        return worker();
      }),
    );
    return accepted;
  }

  /// Polls for the torrent's file list for up to 30 seconds.
  static Future<List<TorrentFile>> _metadata(
    TorrentStreamSession session,
    bool Function() superseded,
  ) async {
    var files = <TorrentFile>[];
    final elapsed = Stopwatch()..start();
    while (files.isEmpty &&
        !superseded() &&
        elapsed.elapsed < const Duration(seconds: 30)) {
      try {
        files = await session.getFiles().timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // Poll again until the bounded metadata deadline expires.
      }
      if (files.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return files;
  }

  static StateError _cancelled() =>
      StateError('Playback initialization was cancelled.');
}
