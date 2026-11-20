// Names audio tracks from what libmpv reports about real media, and checks
// that choosing each named row really changes what libmpv decodes (needs
// internet):
//
//   flutter test integration_test/audio_track_metadata_test.dart -d windows
//
// Media: FFmpeg's public samples (a Blu-ray .m2ts with seven untagged DTS
// and AC-3 tracks whose container ids are 4352-4358), the Matroska
// project's test file 5 (an untagged main track and an English
// commentary), Apple's bipbop HLS (its audio repeated in each of six
// variants) and a local HLS master over bipbop's segments with an
// unlabelled rendition and an audio description rendition. Each switch is
// confirmed through libmpv's own observed `aid`, `audio-codec-name` (the
// active decoder) and `audio-params/channel-count`, never through
// media_kit's requested state. Media3 (Android) is not covered here.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/playable_source.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:onfeed/src/widgets/player/audio_track_sheet.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

const _bluRay = 'https://samples.ffmpeg.org/A-codecs/DTS/hitman_cut.m2ts';
const _mkv =
    'https://raw.githubusercontent.com/ietf-wg-cellar/matroska-test-files/'
    'master/test_files/test5.mkv';
const _bip =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
    'bipbop_16x9';
const _master =
    '#EXTM3U\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Japanese Dub",'
    'AUTOSELECT=YES,DEFAULT=YES,'
    'URI="$_bip/alternate_audio_aac/prog_index.m3u8"\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",LANGUAGE="en",NAME="English AD",'
    'CHARACTERISTICS="public.accessibility.describes-video",'
    'AUTOSELECT=NO,DEFAULT=NO,'
    'URI="$_bip/alternate_audio_aac/prog_index.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=263851,CODECS="mp4a.40.2, avc1.4d400d",'
    'RESOLUTION=416x234,AUDIO="a"\n'
    '$_bip/gear1/prog_index.m3u8\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Blu-ray tracks without languages: named by codec and layout, and each '
    'row plays its own stream',
    (tester) async {
      final session = await _Session.open(
        tester,
        _bluRay,
        StreamType.progressive,
      );
      final rows = session.rows();
      expect(rows, hasLength(7));
      for (final row in rows) {
        expect(row.title, isNot(startsWith('Audio track')), reason: '$row');
      }
      expect(rows.map((row) => row.title), [
        'DTS · 5.1',
        'DTS · 5.1',
        'DTS · 5.1',
        'DTS · 5.1',
        'AC-3 · 5.1',
        'AC-3 · 5.1',
        'AC-3 · Stereo',
      ]);
      // Identical rows are told apart by position, never left identical.
      expect(
        rows.map((row) => '${row.title}|${row.detail}').toSet(),
        hasLength(7),
      );

      // Every row, in an order that changes codec and layout both ways.
      for (final id in ['5', '7', '2', '6', '1', '3', '4']) {
        await session.choose(id);
      }
      await session.close();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  testWidgets(
    'MKV: an untagged default track and an English commentary',
    (tester) async {
      final session = await _Session.open(tester, _mkv, StreamType.progressive);
      final rows = session.rows();
      expect(rows.map((row) => '${row.title} / ${row.detail}'), [
        'AAC · Stereo / Default',
        'English / Commentary · Mono · AAC',
      ]);
      await session.choose('2');
      await session.choose('1');
      await session.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'HLS: an audio description rendition says so; an unlabelled one is '
    'named by codec',
    (tester) async {
      final server = await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );
      server!.listen((request) {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response
          ..write(_master)
          ..close();
      });
      final session = await _Session.open(
        tester,
        'http://127.0.0.1:${server.port}/master.m3u8',
        StreamType.hls,
      );
      final rows = session.rows();
      expect(rows.map((row) => '${row.title} / ${row.detail}'), [
        'AAC · Stereo / Default',
        'English / Audio description · Stereo · AAC',
        'AAC · Stereo / ',
      ]);
      await session.choose('2');
      await session.close();
      await tester.runAsync(server.close);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'HLS with audio in every variant offers the playing track, not one copy '
    'per variant',
    (tester) async {
      final session = await _Session.open(
        tester,
        '$_bip/bipbop_16x9_variant.m3u8',
        StreamType.hls,
      );
      final all = await session.controller.getAudioTracks();
      final choices = AudioTrackLabel.choices(all, session.info);
      // ignore: avoid_print
      print(
        'VARIANT_COPIES all=${all.map((t) => t.id).toList()} '
        'offered=${choices.map((t) => t.id).toList()}',
      );
      expect(all.length, greaterThan(2));
      expect(choices.where((track) => track.isSelected), hasLength(1));
      expect(choices.length, lessThan(all.length));
      // The separate rendition (no variant bitrate) is still offered.
      expect(
        choices.where((track) => session.info[track.id]?.hlsBitrate == null),
        isNotEmpty,
      );
      await session.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

typedef _Row = ({String id, String title, String detail});

class _Session {
  _Session(this.tester, this.controller, this.playerId);

  final WidgetTester tester;
  final VideoPlayerController controller;
  final int playerId;

  /// libmpv's own values, as observed.
  String aid = '';
  String decoder = '';
  String channels = '';

  Map<String, MpvAudioTrackInfo> get info =>
      MediaKitVideoPlayer.shared!.audioTrackInfo(playerId);

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
        source: StreamSource(name: 'Audio metadata test', url: url),
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
    await mpv.debugObserveMpv(
      session.playerId,
      'audio-codec-name',
      (value) => session.decoder = value,
    );
    await mpv.debugObserveMpv(
      session.playerId,
      'audio-params/channel-count',
      (value) => session.channels = value,
    );
    await tester.pumpWidget(MaterialApp(home: VideoPlayer(controller)));
    await controller.play();
    await _until(
      tester,
      () => session.position > const Duration(seconds: 1),
      'playback did not start',
      60,
    );
    await _until(
      tester,
      () => session.info.isNotEmpty,
      'libmpv track-list never observed',
      10,
    );
    session._tracks = await controller.getAudioTracks();
    return session;
  }

  List<VideoAudioTrack> _tracks = const [];

  /// The rows the player shows, built as the player builds them.
  List<_Row> rows() {
    final info = this.info;
    final rows = [
      for (final (i, track) in _tracks.indexed)
        (
          id: track.id,
          title: AudioTrackLabel.title(track, i, info),
          detail: AudioTrackLabel.detail(_tracks, i, info),
        ),
    ];
    for (final row in rows) {
      // ignore: avoid_print
      print('AUDIO_ROW ${row.id}: ${row.title} / ${row.detail}');
    }
    return rows;
  }

  /// Chooses track [id] as the player does and waits until libmpv plays it:
  /// its `aid`, its decoder's codec and channel count, and the position
  /// moving on.
  Future<void> choose(String id) async {
    final track = _tracks.firstWhere((track) => track.id == id);
    final expectedChannels = '${track.channelCount}';
    await controller.selectAudioTrack(id);
    await _until(tester, () => aid == id, 'libmpv kept aid=$aid', 20);
    await _until(
      tester,
      () => decoder == track.codec && channels == expectedChannels,
      'track $id: decoder=$decoder channels=$channels, expected '
      '${track.codec} / $expectedChannels',
      20,
    );
    final from = position;
    await _until(
      tester,
      () => position > from + const Duration(seconds: 1),
      'playback stopped after choosing track $id',
      30,
    );
    expect(controller.value.hasError, isFalse);
    // ignore: avoid_print
    print(
      'AUDIO_PLAYS requested=$id aid=$aid decoder=$decoder '
      'channels=$channels at $position',
    );
  }

  Future<void> close() async {
    await controller.dispose();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String failure,
  int seconds,
) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(failure);
    await tester.pump(const Duration(milliseconds: 100));
  }
}
