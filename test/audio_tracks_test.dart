import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/widgets/player/audio_switch_check.dart';
import 'package:onfeed/src/widgets/player/audio_track_sheet.dart';
import 'package:video_player/video_player.dart';

void main() {
  testWidgets('a TV remote opens the sheet on the playing track and picks '
      'another with the D-pad', (tester) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    addTearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<String?>? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => picked = AudioTrackSheet.show(context, const [
                VideoAudioTrack(id: 'ja', language: 'jpn', isSelected: true),
                VideoAudioTrack(id: 'en', language: 'eng', isSelected: false),
              ]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Audio & language'), findsOneWidget);
    // The sheet opens with focus on the playing track.
    final playing = find.ancestor(
      of: find.text('Japanese'),
      matching: find.byType(InkWell),
    );
    expect(
      Focus.of(tester.element(find.text('Japanese'))).hasPrimaryFocus,
      isTrue,
    );
    expect(tester.widget<InkWell>(playing).autofocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(await picked, 'en');
  });

  group('AudioTrackLabel', () {
    String title(VideoAudioTrack track) => AudioTrackLabel.title(track, 0);

    test('names a track by its language code', () {
      expect(
        title(
          const VideoAudioTrack(isSelected: false, id: '1', language: 'ja'),
        ),
        'Japanese',
      );
      expect(
        title(
          const VideoAudioTrack(isSelected: false, id: '1', language: 'jpn'),
        ),
        'Japanese',
      );
      expect(
        title(
          const VideoAudioTrack(isSelected: false, id: '1', language: 'fil'),
        ),
        'Filipino',
      );
      expect(
        title(
          const VideoAudioTrack(isSelected: false, id: '1', language: 'kor'),
        ),
        'Korean',
      );
      expect(
        title(
          const VideoAudioTrack(isSelected: false, id: '1', language: 'pt-BR'),
        ),
        'Portuguese (Brazil)',
      );
    });

    test('a bare code or name as the title still reads as the name', () {
      expect(
        title(
          const VideoAudioTrack(
            isSelected: false,
            id: '1',
            label: 'eng',
            language: 'eng',
          ),
        ),
        'English',
      );
      expect(
        title(
          const VideoAudioTrack(
            isSelected: false,
            id: '1',
            label: 'English',
            language: 'en',
          ),
        ),
        'English',
      );
    });

    test('keeps a title that says more than the language', () {
      const commentary = VideoAudioTrack(
        isSelected: false,
        id: '2',
        label: 'English Commentary',
        language: 'en',
      );
      expect(title(commentary), 'English Commentary');
      expect(AudioTrackLabel.detail(const [commentary], 0), isEmpty);
    });

    test('a title about something else moves to the detail', () {
      const tracks = [
        VideoAudioTrack(
          isSelected: false,
          id: '1',
          label: 'Commentary',
          language: 'eng',
          channelCount: 1,
          codec: 'aac',
        ),
        VideoAudioTrack(
          isSelected: false,
          id: '2',
          label: 'stream_5',
          language: 'en',
        ),
      ];
      expect(title(tracks[0]), 'English');
      expect(AudioTrackLabel.detail(tracks, 0), 'Commentary · Mono · AAC');
      expect(AudioTrackLabel.detail(tracks, 1), 'stream_5');
    });

    test('a language only in the title is used', () {
      const track = VideoAudioTrack(
        isSelected: false,
        id: '1',
        label: 'Japanese',
      );
      expect(title(track), 'Japanese');
      expect(AudioTrackLabel.language(track), 'ja');
    });

    test('never invents a language', () {
      for (final track in const [
        VideoAudioTrack(isSelected: false, id: '1'),
        VideoAudioTrack(isSelected: false, id: '1', language: 'und'),
        VideoAudioTrack(isSelected: false, id: '1', language: ''),
      ]) {
        expect(AudioTrackLabel.title(track, 2), 'Audio track 3');
        expect(AudioTrackLabel.language(track), isNull);
      }
      const surround = VideoAudioTrack(
        isSelected: false,
        id: '1',
        label: 'Surround',
      );
      expect(title(surround), 'Surround');
      expect(AudioTrackLabel.language(surround), isNull);
    });

    test('rows that would read the same get their position', () {
      // One language per quality variant, as some HLS streams list it.
      const tracks = [
        VideoAudioTrack(
          isSelected: false,
          id: '1',
          language: 'eng',
          channelCount: 2,
        ),
        VideoAudioTrack(
          isSelected: false,
          id: '2',
          language: 'eng',
          channelCount: 2,
        ),
        VideoAudioTrack(
          isSelected: false,
          id: '3',
          language: 'eng',
          channelCount: 6,
        ),
      ];
      expect(AudioTrackLabel.detail(tracks, 0), 'Stereo · Track 1');
      expect(AudioTrackLabel.detail(tracks, 1), 'Stereo · Track 2');
      expect(AudioTrackLabel.detail(tracks, 2), '5.1');
    });
  });

  group('AudioSwitchCheck', () {
    const step = Duration(milliseconds: 1);

    Future<bool> run(List<AudioSwitchSample?> samples) {
      var index = 0;
      return AudioSwitchCheck(
        sample: () =>
            samples[index < samples.length ? index++ : samples.length - 1],
        interval: step,
        stalledLimit: step * 3,
        progress: const Duration(seconds: 2),
        maxWait: step * 40,
      ).run();
    }

    AudioSwitchSample at(int seconds, {bool playing = true}) =>
        AudioSwitchSample(
          playing: playing,
          position: Duration(milliseconds: seconds * 1000),
        );

    test('passes once playback has moved on', () async {
      expect(await run([at(0), at(1), at(2)]), isTrue);
    });

    test('fails when playback freezes', () async {
      // The fMP4 HLS rendition libmpv cannot start.
      expect(await run([at(4), at(4), at(4), at(4), at(4)]), isFalse);
    });

    test('a short pause in progress is not a failure', () async {
      // TS HLS renditions take a moment while the video carries on.
      expect(await run([at(0), at(0), at(0), at(1), at(2)]), isTrue);
    });

    test('time spent paused does not count', () async {
      expect(
        await run([
          for (var i = 0; i < 10; i++) at(4, playing: false),
          at(4),
          at(5),
          at(6),
        ]),
        isTrue,
      );
    });

    test('stops when the player is gone or another switch starts', () async {
      expect(await run([at(0), null]), isTrue);
    });

    test('gives up waiting without blaming the track', () async {
      expect(await run([at(0, playing: false)]), isTrue);
    });
  });
}
