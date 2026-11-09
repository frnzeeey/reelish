// Switches the audio of real multi-audio media on Media3 (Android) the way
// the player does, and checks that ExoPlayer's own track selection moved to
// the chosen track while the position carried on (needs internet):
//
//   flutter test integration_test/media3_audio_track_test.dart -d <android>
//
// Media: the Matroska project's test file 5 (two audio tracks in one file);
// Shaka Player's public "Angel One" demo (DASH: one audio adaptation set per
// language; HLS: alternative fMP4 renditions); Apple's bipbop example (HLS
// alternative audio in TS segments). "Selected" is ExoPlayer's
// `Tracks.Group.isTrackSelected`, which follows the renderers; Media3 offers
// no decoder probe like libmpv's, so audible output is not measured.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/playable_source.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/models/subtitle_language.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:video_player/video_player.dart';

const _media = [
  (
    'embedded tracks in one MKV',
    'https://raw.githubusercontent.com/ietf-wg-cellar/matroska-test-files/'
        'master/test_files/test5.mkv',
    StreamType.progressive,
    false,
  ),
  (
    'DASH audio adaptation sets',
    'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
    StreamType.dash,
    true,
  ),
  (
    'HLS alternative fMP4 renditions',
    'https://storage.googleapis.com/shaka-demo-assets/angel-one-hls/hls.m3u8',
    StreamType.hls,
    true,
  ),
  (
    'HLS alternative audio in TS segments',
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
        'bipbop_16x9/bipbop_16x9_variant.m3u8',
    StreamType.hls,
    false,
  ),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, url, type, languages) in _media) {
    testWidgets('Media3 switches audio: $name', (tester) async {
      if (defaultTargetPlatform != TargetPlatform.android) {
        markTestSkipped('Media3 runs on Android only.');
        return;
      }
      final session = await _Session.open(tester, url, type);
      var tracks = await session.tracks();
      expect(tracks.length, greaterThanOrEqualTo(2));
      if (languages) {
        final codes = {
          for (final track in tracks)
            SubtitleLanguage.normalize(track.language),
        }..remove(SubtitleLanguage.unknown);
        expect(codes.length, greaterThanOrEqualTo(2));
      }
      _expectOneSelected(tracks);

      // While playing.
      final before = session.position;
      await session.switchTo(_other(tracks, newLanguage: languages));
      expect(
        session.position,
        greaterThanOrEqualTo(before - const Duration(seconds: 1)),
        reason: 'switching audio restarted playback',
      );
      await session.expectAdvancing();

      // While paused.
      await session.controller.pause();
      await tester.pump(const Duration(milliseconds: 500));
      final paused = session.position;
      tracks = await session.tracks();
      await session.switchTo(_other(tracks, newLanguage: languages));
      expect(
        (session.position - paused).abs(),
        lessThan(const Duration(seconds: 1)),
        reason: 'switching while paused moved the position',
      );
      await session.controller.play();
      await session.expectAdvancing();

      // Rapidly: the last request wins.
      tracks = await session.tracks();
      final last = tracks.firstWhere((track) => !track.isSelected);
      for (final track in tracks.take(3)) {
        session.controller.selectAudioTrack(track.id).ignore();
      }
      await session.switchTo(last);
      await session.expectAdvancing();
      _expectOneSelected(await session.tracks());
      await session.close();
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}

void _expectOneSelected(List<VideoAudioTrack> tracks) {
  expect(
    tracks.where((track) => track.isSelected),
    hasLength(1),
    reason: 'no single selected track',
  );
}

VideoAudioTrack _other(
  List<VideoAudioTrack> tracks, {
  bool newLanguage = false,
}) {
  final current = tracks.firstWhere(
    (track) => track.isSelected,
    orElse: () => tracks.first,
  );
  String code(VideoAudioTrack track) =>
      SubtitleLanguage.normalize(track.language);
  return tracks.firstWhere(
    (track) =>
        track.id != current.id &&
        (!newLanguage ||
            (code(track) != code(current) &&
                code(track) != SubtitleLanguage.unknown)),
  );
}

class _Session {
  _Session(this.tester, this.controller);

  final WidgetTester tester;
  final VideoPlayerController controller;

  Duration get position => controller.value.position;

  static Future<_Session> open(
    WidgetTester tester,
    String url,
    StreamType type,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    const engine = Media3PlayerEngine();
    await PlayerEngineGate.activate(engine);
    final controller = engine.createController(
      PlayableSource(
        source: StreamSource(name: 'Audio test', url: url),
        uri: Uri.parse(url),
        headers: const {},
        streamType: type,
      ),
    );
    final session = _Session(tester, controller);
    var ready = false;
    Object? failure;
    controller.initialize().then(
      (_) => ready = true,
      onError: (Object error) => failure = error,
    );
    await session._until(
      () => ready || failure != null,
      'Media3 did not initialize',
      90,
    );
    expect(failure, isNull, reason: 'Media3 failed to open: $failure');
    await tester.pumpWidget(MaterialApp(home: VideoPlayer(controller)));
    await controller.play();
    await session._until(
      () => session.position > const Duration(seconds: 2),
      'playback did not start',
      60,
    );
    return session;
  }

  Future<List<VideoAudioTrack>> tracks() async {
    final tracks = await controller.getAudioTracks();
    for (final track in tracks) {
      // ignore: avoid_print
      print(
        'MEDIA3_TRACK id=${track.id} label=${track.label} '
        'lang=${track.language} codec=${track.codec} '
        'channels=${track.channelCount} selected=${track.isSelected}',
      );
    }
    return tracks;
  }

  /// Selects [track] as the player does and waits for ExoPlayer to report
  /// it selected.
  Future<void> switchTo(VideoAudioTrack track) async {
    await controller.selectAudioTrack(track.id);
    var selected = false;
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!selected && DateTime.now().isBefore(end)) {
      final now = await controller.getAudioTracks();
      selected = now.any((entry) => entry.id == track.id && entry.isSelected);
      if (!selected) await tester.pump(const Duration(milliseconds: 250));
    }
    // ignore: avoid_print
    print(
      'MEDIA3_SWITCH requested=${track.id} lang=${track.language} '
      'selected=$selected at $position',
    );
    expect(selected, isTrue, reason: 'ExoPlayer did not select the track');
  }

  /// The position moves on with no error.
  Future<void> expectAdvancing() async {
    final from = position;
    await _until(
      () => position > from + const Duration(seconds: 2),
      'playback stopped after switching audio',
      30,
    );
    expect(controller.value.hasError, isFalse);
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  }

  Future<void> _until(bool Function() done, String what, int seconds) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(done(), isTrue, reason: what);
  }
}
