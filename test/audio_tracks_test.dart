import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/widgets/player/audio_switch_check.dart';
import 'package:onfeed/src/widgets/player/audio_track_sheet.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart'
    show MpvAudioTrackInfo;

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

  // The metadata below is libmpv's own `track-list` output for real files,
  // recorded on Windows during the 2026-11-20 audit
  // (docs/REELISH_PLAYBACK_AUDIT.md), trimmed to the keys Reelish reads.
  group('libmpv metadata', () {
    VideoAudioTrack track(
      String id, {
      String? label,
      String? language,
      String? codec,
      int? channels,
      int? sampleRate,
      bool selected = false,
    }) => VideoAudioTrack(
      id: id,
      label: label,
      language: language,
      codec: codec,
      channelCount: channels,
      sampleRate: sampleRate,
      isSelected: selected,
    );

    List<String> rows(
      List<VideoAudioTrack> tracks,
      Map<String, MpvAudioTrackInfo> info,
    ) => [
      for (final (i, t) in tracks.indexed)
        '${AudioTrackLabel.title(t, i, info)} / '
            '${AudioTrackLabel.detail(tracks, i, info)}',
    ];

    test('parses the audio tracks and nothing else', () {
      final info = MpvAudioTrackInfo.parseTrackList(
        '[{"id":1,"type":"video","codec":"h264"},'
        '{"id":1,"type":"audio","default":true,"forced":false,'
        '"visual-impaired":false,"demux-channels":"5.1(side)"},'
        '{"id":3,"type":"audio","forced":true,"hearing-impaired":true,'
        '"demux-channels":"unknown4","program-id":2,"hls-bitrate":577610},'
        '{"id":2,"type":"sub","forced":true}]',
      );
      expect(info.keys, ['1', '3']);
      expect(info['1']!.isDefault, isTrue);
      expect(info['1']!.channelLayout, '5.1(side)');
      expect(info['3']!.channelLayout, isNull, reason: 'unknownN is a count');
      expect(info['3']!.isForced, isTrue);
      expect(info['3']!.hearingImpaired, isTrue);
      expect(info['3']!.programId, 2);
      expect(info['3']!.hlsBitrate, 577610);
    });

    test('malformed or missing track lists give no metadata', () {
      for (final value in [
        '',
        'null',
        '{}',
        '[1,2]',
        'not json',
        '[{"id":"x"}]',
      ]) {
        expect(MpvAudioTrackInfo.parseTrackList(value), isEmpty);
      }
    });

    String audioList(List<String> entries) => '[${entries.join(',')}]';

    test('a Blu-ray file without languages names tracks by codec and '
        'layout, not "Audio track N"', () {
      // hitman_cut.m2ts: 7 tracks, container ids 4352-4358, no languages.
      final tracks = [
        track('1', codec: 'dts', channels: 6, selected: true),
        track('2', codec: 'dts', channels: 6),
        track('3', codec: 'dts', channels: 6),
        track('4', codec: 'dts', channels: 6),
        track('5', codec: 'ac3', channels: 6),
        track('6', codec: 'ac3', channels: 6),
        track('7', codec: 'ac3', channels: 2),
      ];
      final info = MpvAudioTrackInfo.parseTrackList(
        audioList([
          for (var i = 1; i <= 7; i++)
            '{"id":$i,"type":"audio","demux-channels":'
                '"${i == 7 ? 'stereo' : '5.1(side)'}"}',
        ]),
      );
      expect(rows(tracks, info), [
        'DTS · 5.1 / Track 1',
        'DTS · 5.1 / Track 2',
        'DTS · 5.1 / Track 3',
        'DTS · 5.1 / Track 4',
        'AC-3 · 5.1 / Track 5',
        'AC-3 · 5.1 / Track 6',
        'AC-3 · Stereo / ',
      ]);
      // Selection still goes by libmpv's id, never the row.
      expect(AudioTrackLabel.choices(tracks, info).map((t) => t.id), [
        for (var i = 1; i <= 7; i++) '$i',
      ]);
    });

    test('an MKV with an untagged main track and a commentary', () {
      // Matroska test file 5.
      final tracks = [
        track('1', codec: 'aac', channels: 2, selected: true),
        track(
          '2',
          label: 'Commentary',
          language: 'eng',
          codec: 'aac',
          channels: 1,
        ),
      ];
      final info = MpvAudioTrackInfo.parseTrackList(
        audioList([
          '{"id":1,"type":"audio","default":true,"demux-channels":"unknown2"}',
          '{"id":2,"type":"audio","default":false,"demux-channels":"unknown1"}',
        ]),
      );
      expect(rows(tracks, info), [
        'AAC · Stereo / Default',
        'English / Commentary · Mono · AAC',
      ]);
    });

    test('an audio description rendition says so, not "visual impaired"', () {
      // HLS master with CHARACTERISTICS="public.accessibility.describes-video".
      final tracks = [
        track('1', codec: 'aac', channels: 2, selected: true),
        track(
          '2',
          label: 'visual impaired',
          language: 'en',
          codec: 'aac',
          channels: 2,
        ),
      ];
      final info = MpvAudioTrackInfo.parseTrackList(
        audioList([
          '{"id":1,"type":"audio","default":true,"demux-channels":"stereo"}',
          '{"id":2,"type":"audio","visual-impaired":true,'
              '"demux-channels":"stereo"}',
        ]),
      );
      expect(rows(tracks, info), [
        'AAC · Stereo / Default',
        'English / Audio description · Stereo · AAC',
      ]);
    });

    test('a real layout wins over the count; a count alone stays a count', () {
      final tracks = [
        track('1', language: 'en', codec: 'dts', channels: 4),
        track('2', language: 'en', codec: 'eac3', channels: 6),
        track('3', language: 'en', codec: 'opus', channels: 3),
      ];
      final info = MpvAudioTrackInfo.parseTrackList(
        audioList([
          '{"id":1,"type":"audio","demux-channels":"unknown4"}',
          '{"id":2,"type":"audio","demux-channels":"5.1(side)"}',
          '{"id":3,"type":"audio","demux-channels":"2.1"}',
        ]),
      );
      expect(rows(tracks, info), [
        'English / 4 channels · DTS',
        'English / 5.1 · E-AC-3',
        'English / 2.1 · Opus',
      ]);
    });

    test('forced and hearing-impaired flags appear; "Default" only when it '
        'tells tracks apart', () {
      final tracks = [
        track('1', language: 'ja', codec: 'flac', channels: 2),
        track('2', language: 'ja', codec: 'flac', channels: 2),
      ];
      // Every track default (as HLS and DASH mark them): not shown.
      final info = MpvAudioTrackInfo.parseTrackList(
        audioList([
          '{"id":1,"type":"audio","default":true,"forced":true}',
          '{"id":2,"type":"audio","default":true,"hearing-impaired":true}',
        ]),
      );
      expect(rows(tracks, info), [
        'Japanese / Forced · Stereo · FLAC',
        'Japanese / Hearing impaired · Stereo · FLAC',
      ]);
    });

    test('codec names', () {
      for (final (codec, name) in const [
        ('aac', 'AAC'),
        ('mp4a.40.2', 'AAC'),
        ('ac3', 'AC-3'),
        ('ac-3', 'AC-3'),
        ('eac3', 'E-AC-3'),
        ('ec-3', 'E-AC-3'),
        ('dts', 'DTS'),
        ('dtsl', 'DTS-HD MA'),
        ('truehd', 'TrueHD'),
        ('opus', 'Opus'),
        ('pcm_s24le', 'PCM'),
        ('mp3', 'MP3'),
        ('someday-codec', 'SOMEDAY-CODEC'),
      ]) {
        expect(AudioTrackLabel.codecName(codec), name, reason: codec);
      }
    });

    test('nothing at all still reads "Audio track N"', () {
      final tracks = [track('9'), track('12')];
      expect(rows(tracks, const {}), ['Audio track 1 / ', 'Audio track 2 / ']);
    });

    group('HLS variant copies', () {
      // Apple's bipbop: row 1 is a separate rendition; rows 2-7 are the
      // audio inside each of six variants (program-id 0-5); row 6 plays.
      final tracks = [
        for (var i = 1; i <= 7; i++)
          track(
            '$i',
            language: 'eng',
            codec: 'aac',
            channels: 2,
            sampleRate: 22050,
            selected: i == 6,
          ),
      ];
      const bitrates = [null, 263851, 577610, 915905, 1030138, 1924009, 41457];
      const programs = [0, 0, 1, 2, 3, 4, 5];
      final info = MpvAudioTrackInfo.parseTrackList(
        audioList([
          for (var i = 0; i < 7; i++)
            '{"id":${i + 1},"type":"audio","program-id":${programs[i]}'
                '${bitrates[i] == null ? '' : ',"hls-bitrate":${bitrates[i]}'}'
                ',"demux-channels":"stereo"}',
        ]),
      );

      test('keeps the playing track and the separate rendition only', () {
        expect(AudioTrackLabel.choices(tracks, info).map((t) => t.id), [
          '1',
          '6',
        ]);
      });

      test('a different language in another variant is kept', () {
        final mixed = [
          ...tracks.take(6),
          track(
            '7',
            language: 'spa',
            codec: 'aac',
            channels: 2,
            sampleRate: 22050,
          ),
        ];
        expect(AudioTrackLabel.choices(mixed, info).map((t) => t.id), [
          '1',
          '6',
          '7',
        ]);
      });

      test('nothing is hidden without libmpv data or a playing track', () {
        expect(AudioTrackLabel.choices(tracks, const {}), tracks);
        final none = [
          for (final t in tracks)
            track(t.id, language: 'eng', codec: 'aac', channels: 2),
        ];
        expect(AudioTrackLabel.choices(none, info), none);
      });

      test('one-variant streams keep every track', () {
        // The local playlist: three tracks, all in program 0.
        final single = MpvAudioTrackInfo.parseTrackList(
          audioList([
            for (var i = 1; i <= 3; i++)
              '{"id":$i,"type":"audio","program-id":0,"hls-bitrate":263851}',
          ]),
        );
        final three = [
          track('1', codec: 'aac', channels: 2, selected: true),
          track('2', codec: 'aac', channels: 2),
          track('3', codec: 'aac', channels: 2),
        ];
        expect(AudioTrackLabel.choices(three, single), three);
      });
    });
  });
}
