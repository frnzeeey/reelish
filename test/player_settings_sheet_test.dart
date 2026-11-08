import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/theme/supporter_themes.dart';
import 'package:onfeed/src/theme/theme_tokens.dart';
import 'package:onfeed/src/widgets/player/player_settings_sheet.dart';
import 'package:video_player/video_player.dart';

const _english = SubtitleTrack(
  url: 'https://subs.test/en.srt',
  lang: 'English',
);
const _spanish = SubtitleTrack(
  url: 'https://subs.test/es.vtt',
  lang: 'Spanish',
  format: 'vtt',
);

void main() {
  /// Opens the sheet and returns what it is closed with.
  Future<Future<PlayerSettings?>> openSheet(
    WidgetTester tester, {
    String? alternateEngine,
    PlayerSettings value = const PlayerSettings(),
    List<SubtitleTrack> subtitles = const [],
    List<VideoTrack> videoTracks = const [],
    List<VideoAudioTrack> audioTracks = const [],
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    Future<PlayerSettings?>? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => result = PlayerSettingsSheet.show(
                context,
                value,
                subtitles,
                videoTracks,
                audioTracks,
                alternateEngine,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result!;
  }

  testWidgets('offers the other engine and reports the choice', (tester) async {
    final closed = await openSheet(
      tester,
      alternateEngine: 'the Android player',
    );
    await tester.tap(find.text('Switch to the Android player'));
    await tester.pumpAndSettle();
    expect((await closed)?.switchEngine, isTrue);
  });

  testWidgets('hides the switch when no other engine can play', (tester) async {
    await openSheet(tester);
    expect(find.textContaining('Switch to'), findsNothing);
  });

  testWidgets('shows each category with its current value', (tester) async {
    await openSheet(
      tester,
      value: const PlayerSettings(
        speed: 1.5,
        subtitle: _english,
        subtitleDelay: .5,
      ),
      subtitles: const [_english],
    );
    expect(find.text('Playback settings'), findsOneWidget);
    expect(find.text('1.5×'), findsOneWidget);
    expect(find.text('English · +0.50 s'), findsOneWidget);
    expect(find.text('Auto · Fit'), findsOneWidget);
  });

  testWidgets('only offers what the stream has', (tester) async {
    await openSheet(
      tester,
      audioTracks: const [VideoAudioTrack(id: 'a', isSelected: true)],
    );
    // No video tracks: no quality. One audio track: nothing to choose.
    expect(find.text('Quality'), findsNothing);
    expect(find.text('Audio'), findsNothing);
  });

  testWidgets('a speed applies with one tap', (tester) async {
    final closed = await openSheet(tester);
    await tester.tap(find.text('Speed'));
    await tester.pumpAndSettle();
    expect(find.text('Normal'), findsOneWidget);
    await tester.tap(find.text('1.25×'));
    await tester.pumpAndSettle();
    expect((await closed)?.speed, 1.25);
  });

  testWidgets('quality lists the stream\'s own tracks, and Auto', (
    tester,
  ) async {
    const hd = VideoTrack(
      id: 'hd',
      isSelected: false,
      width: 1920,
      height: 1080,
      bitrate: 5200000,
    );
    final closed = await openSheet(tester, videoTracks: const [hd]);
    await tester.tap(find.text('Quality'));
    await tester.pumpAndSettle();
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('1920×1080 · 5.2 Mbps'), findsOneWidget);
    await tester.tap(find.text('1080p'));
    await tester.pumpAndSettle();
    expect((await closed)?.videoTrack, hd);
  });

  testWidgets('subtitles mark the current track, and Off', (tester) async {
    final closed = await openSheet(
      tester,
      value: const PlayerSettings(subtitle: _english),
      subtitles: const [_english, _spanish],
    );
    await tester.tap(find.text('Subtitles'));
    await tester.pumpAndSettle();
    // Only the current track carries the mark.
    expect(find.text('Showing'), findsOneWidget);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    final result = await closed;
    expect(result?.subtitle, isNull);
  });

  testWidgets('Back on a category returns to the categories', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('Picture'));
    await tester.pumpAndSettle();
    expect(find.text('Fill the screen'.toUpperCase()), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Playback settings'), findsOneWidget);
  });

  testWidgets('timing steps without closing, then applies once', (
    tester,
  ) async {
    final closed = await openSheet(tester);
    await tester.tap(find.text('Subtitles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Timing'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Later by a quarter second'));
      await tester.pump();
    }
    expect(find.text('+0.75 s'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect((await closed)?.subtitleDelay, .75);
  });

  testWidgets('stays dark under a light app theme', (tester) async {
    final ivory = SupporterTheme.ivoryStudio;
    GlassTheme.setAccent(ivory.accent);
    GlassTheme.setSurfaces(ivory.surfaces);
    addTearDown(() {
      GlassTheme.setAccent(GlassTheme.coral);
      GlassTheme.setSurfaces(ThemeSurfaces.classic);
    });
    await openSheet(tester, theme: GlassTheme.player(tv: false));
    final theme = Theme.of(tester.element(find.text('Playback settings')));
    expect(theme.brightness, Brightness.dark);
    expect(GlassTheme.playerSurfaces.brightness, Brightness.dark);
    // Light text on the player's dark sheets.
    expect(
      GlassTheme.playerSurfaces.textPrimary.computeLuminance(),
      greaterThan(.8),
    );
  });
}
