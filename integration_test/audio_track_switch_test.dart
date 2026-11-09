// Switches the audio of real multi-audio media on libmpv the way the player
// does, and checks through libmpv's own `current-tracks/audio` and
// `audio-params` that the decoded audio changed while the position carried
// on (needs internet):
//
//   flutter test integration_test/audio_track_switch_test.dart -d windows
//
// Media: the Matroska project's test file 5 (two audio tracks in one file);
// Shaka Player's public "Angel One" demo, whose DASH version has one audio
// adaptation set per language and whose HLS version carries its languages
// as alternative fMP4 renditions; and Apple's bipbop example, whose
// alternative HLS audio is in TS segments. media_kit's own track state
// records a request rather than libmpv's result, so the test reads libmpv
// directly. Media3 (Android) is not covered here.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/playable_source.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/models/subtitle_language.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:onfeed/src/widgets/player/audio_switch_check.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

const _mkv =
    'https://raw.githubusercontent.com/ietf-wg-cellar/matroska-test-files/'
    'master/test_files/test5.mkv';
const _dash =
    'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd';
const _fmp4Hls =
    'https://storage.googleapis.com/shaka-demo-assets/angel-one-hls/hls.m3u8';
const _tsHls =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
    'bipbop_16x9/bipbop_16x9_variant.m3u8';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'embedded tracks switch in place: playing, paused and rapidly',
    (tester) async {
      final session = await _Session.open(tester, _mkv, StreamType.progressive);
      var tracks = await session.tracks();
      expect(tracks.length, greaterThanOrEqualTo(2));
      await session.expectSelectionIsTruthful(tracks);

      final before = session.position;
      await session.switchTo(_other(tracks), newOutput: true);
      expect(
        session.position,
        greaterThanOrEqualTo(before - const Duration(seconds: 1)),
        reason: 'switching audio restarted playback',
      );
      expect(await session.check(), isTrue);
      await session.expectAdvancing();

      await session.controller.pause();
      await tester.pump(const Duration(milliseconds: 500));
      final paused = session.position;
      tracks = await session.tracks();
      await session.switchTo(_other(tracks));
      expect(
        (session.position - paused).abs(),
        lessThan(const Duration(seconds: 1)),
        reason: 'switching while paused moved the position',
      );
      await session.controller.play();
      await session.expectAdvancing();

      tracks = await session.tracks();
      final last = _other(tracks);
      for (final track in tracks) {
        // Not awaited on purpose: the last request must win.
        session.controller.selectAudioTrack(track.id).ignore();
      }
      await session.switchTo(last);
      await session.expectAdvancing();
      await session.expectSelectionIsTruthful(await session.tracks());
      await session.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'DASH audio adaptation sets switch language in place',
    (tester) async {
      final session = await _Session.open(tester, _dash, StreamType.dash);
      final tracks = await session.tracks();
      _expectLanguages(tracks);
      await session.expectSelectionIsTruthful(tracks);
      final before = session.position;
      await session.switchTo(_other(tracks, newLanguage: true));
      expect(
        session.position,
        greaterThanOrEqualTo(before - const Duration(seconds: 1)),
      );
      expect(await session.check(), isTrue);
      await session.expectAdvancing();
      await session.expectSelectionIsTruthful(await session.tracks());
      await session.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'HLS alternative audio in TS segments switches in place',
    (tester) async {
      final session = await _Session.open(tester, _tsHls, StreamType.hls);
      final tracks = await session.tracks();
      await session.expectSelectionIsTruthful(tracks);
      await session.switchTo(_other(tracks));
      expect(await session.check(), isTrue, reason: 'check failed a switch');
      await session.expectAdvancing();
      // A seek after the switch still plays.
      await session.controller.seekTo(const Duration(seconds: 40));
      await session.expectAdvancing();
      await session.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'HLS alternative fMP4 rendition libmpv cannot start: the switch fails '
    'the source, and reopening it on the previous track plays',
    (tester) async {
      final session = await _Session.open(tester, _fmp4Hls, StreamType.hls);
      // Past the first segments, which FFmpeg read for every rendition
      // when it opened the stream: switching inside them can still work.
      await session.playUntil(const Duration(seconds: 9));
      final tracks = await session.tracks();
      _expectLanguages(tracks);
      await session.expectSelectionIsTruthful(tracks);
      final previous = tracks.firstWhere((track) => track.isSelected);
      await session.controller.selectAudioTrack(
        _other(tracks, newLanguage: true).id,
      );
      // libmpv either freezes (the check fails it; the player restores the
      // previous track) or ends the source as a lost connection at once
      // (the player's reopen restores the previous language). Either way
      // the switch never plays on.
      final plays = await session.check();
      // ignore: avoid_print
      print(
        'FMP4_SWITCH plays=$plays error=${session.controller.value.hasError}',
      );
      expect(plays && !session.controller.value.hasError, isFalse);
      await session.close();

      // The reopen: the same source on the language from before.
      final reopened = await _Session.open(tester, _fmp4Hls, StreamType.hls);
      final again = await reopened.tracks();
      expect(again.firstWhere((track) => track.isSelected).id, previous.id);
      await reopened.expectAdvancing();
      await reopened.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

void _expectLanguages(List<VideoAudioTrack> tracks) {
  final languages = {
    for (final track in tracks) SubtitleLanguage.normalize(track.language),
  }..remove(SubtitleLanguage.unknown);
  expect(
    languages.length,
    greaterThanOrEqualTo(2),
    reason: 'libmpv exposed fewer than two audio languages',
  );
}

/// A track other than the selected one; with [newLanguage], in another
/// language.
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
  _Session(this.tester, this.controller, this.playerId);

  final WidgetTester tester;
  final VideoPlayerController controller;
  final int playerId;

  /// libmpv's `current-tracks/audio/id`, as observed.
  String aid = '';

  /// Audio output (re)starts seen, as media_kit observes `audio-params`.
  int audioStarts = 0;
  StreamSubscription<String?>? _formats;

  Duration get position => controller.value.position;

  static Future<_Session> open(
    WidgetTester tester,
    String url,
    StreamType type,
  ) async {
    PlayerEngineBootstrap.initialize();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    const engine = MpvPlayerEngine();
    await PlayerEngineGate.activate(engine);
    final controller = engine.createController(
      PlayableSource(
        source: StreamSource(name: 'Audio test', url: url),
        uri: Uri.parse(url),
        headers: const {},
        streamType: type,
      ),
    );
    var ready = false;
    controller.initialize().then((_) => ready = true);
    await _until(tester, () => ready, 'libmpv did not initialize', 120);
    final mpv = MediaKitVideoPlayer.shared!;
    final session = _Session(tester, controller, mpv.activePlayerId!);
    // Observed, never read on request: a libmpv property read blocks the
    // UI thread and can deadlock with the video output.
    await mpv.debugObserveMpv(
      session.playerId,
      'current-tracks/audio/id',
      (value) => session.aid = value,
    );
    session._formats = mpv.debugAudioFormats(session.playerId).listen((format) {
      if (format?.isNotEmpty == true) session.audioStarts++;
    });
    await tester.pumpWidget(MaterialApp(home: VideoPlayer(controller)));
    await controller.play();
    await _until(
      tester,
      () => session.position > const Duration(seconds: 2),
      'playback did not start',
      60,
    );
    return session;
  }

  /// The player's check of a switch, sampling the controller as the player
  /// does. The check waits in real time, so frames keep pumping alongside.
  Future<bool> check() async {
    bool? result;
    AudioSwitchCheck(
      sample: () => AudioSwitchSample(
        playing: controller.value.isPlaying,
        position: controller.value.position,
      ),
    ).run().then((value) => result = value);
    await _until(tester, () => result != null, 'the check never ended', 70);
    // ignore: avoid_print
    print('AUDIO_CHECK plays=$result at $position');
    return result!;
  }

  Future<List<VideoAudioTrack>> tracks() async {
    final tracks = await controller.getAudioTracks();
    for (final track in tracks) {
      // ignore: avoid_print
      print(
        'AUDIO_TRACK id=${track.id} label=${track.label} '
        'lang=${track.language} codec=${track.codec} '
        'channels=${track.channelCount} selected=${track.isSelected}',
      );
    }
    return tracks;
  }

  /// Exactly one track is reported selected, and it is libmpv's.
  Future<void> expectSelectionIsTruthful(List<VideoAudioTrack> tracks) async {
    final selected = tracks.where((track) => track.isSelected).toList();
    expect(selected, hasLength(1), reason: 'no single selected track');
    await _until(tester, () => aid.isNotEmpty, 'aid never observed', 10);
    expect(selected.single.id, aid);
  }

  /// Selects [track] as the player does and waits for libmpv to take it
  /// and start its audio output.
  /// With [newOutput], also waits for libmpv to restart its audio output,
  /// which media_kit reports only when the audio format changes.
  Future<void> switchTo(VideoAudioTrack track, {bool newOutput = false}) async {
    final starts = audioStarts;
    await controller.selectAudioTrack(track.id);
    await expectDecoding(track, startsBefore: newOutput ? starts : null);
  }

  Future<void> expectDecoding(
    VideoAudioTrack track, {
    int? startsBefore,
  }) async {
    await _until(tester, () => aid == track.id, 'libmpv kept aid=$aid', 20);
    if (startsBefore != null) {
      await _until(
        tester,
        () => audioStarts > startsBefore,
        'no audio output started after the switch',
        20,
      );
    }
    // ignore: avoid_print
    print(
      'AUDIO_SWITCH requested=${track.id} lang=${track.language} aid=$aid '
      'audioStarts=$audioStarts at $position',
    );
  }

  Future<void> playUntil(Duration target) => _until(
    tester,
    () => position >= target,
    'playback did not reach $target',
    60,
  );

  /// The position moves on, within [within] seconds, with no error.
  Future<void> expectAdvancing({int within = 30}) async {
    final from = position;
    await _until(
      tester,
      () => position > from + const Duration(seconds: 2),
      'playback stopped after switching audio',
      within,
    );
    expect(controller.value.hasError, isFalse);
  }

  Future<void> close() async {
    await _formats?.cancel();
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  }

  static Future<void> _until(
    WidgetTester tester,
    bool Function() done,
    String what,
    int seconds,
  ) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(done(), isTrue, reason: what);
  }
}
