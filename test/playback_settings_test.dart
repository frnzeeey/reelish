import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/playback_settings.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/screens/playback_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PlaybackSettings', () {
    test('defaults preserve the existing automatic stream behavior', () {
      const settings = PlaybackSettings();

      expect(settings.autoStreamSelection, isTrue);
      expect(settings.streamSelectionTimeoutSeconds, 3);
      expect(settings.holdSpeed, 2);
      expect(settings.defaultPlaybackSpeed, 1);
      expect(settings.preferredVideoHeight, 0);
      expect(settings.subtitleSize, 18);
      expect(settings.subtitlePosition, 0);
      expect(settings.allowedProviderIds, isNull);
    });

    test(
      'round trips settings without losing selected providers or colors',
      () {
        const settings = PlaybackSettings(
          autoStreamSelection: false,
          allowedProviderIds: {'repo-a|provider-a', 'repo-b|provider-b'},
          subtitleTextColor: 0xFFABCDEF,
          subtitleBackgroundColor: 0x66000000,
          holdSpeed: 2.5,
          defaultPlaybackSpeed: 1.5,
          preferredVideoHeight: 1080,
        );

        final restored = PlaybackSettings.fromJson(settings.toJson());

        expect(restored.autoStreamSelection, isFalse);
        expect(restored.allowedProviderIds, settings.allowedProviderIds);
        expect(restored.subtitleTextColor, settings.subtitleTextColor);
        expect(
          restored.subtitleBackgroundColor,
          settings.subtitleBackgroundColor,
        );
        expect(restored.holdSpeed, 2.5);
        expect(restored.defaultPlaybackSpeed, 1.5);
        expect(restored.preferredVideoHeight, 1080);
      },
    );

    test('clamps malformed numeric preferences to safe ranges', () {
      final settings = PlaybackSettings.fromJson({
        'holdSpeed': 99,
        'streamSelectionTimeoutSeconds': -20,
        'subtitleSize': 2,
        'subtitlePosition': 3,
        'lastLinkCacheHours': 0,
        'defaultPlaybackSpeed': 10,
        'preferredVideoHeight': 1234,
      });

      expect(settings.holdSpeed, 4);
      expect(settings.streamSelectionTimeoutSeconds, 1);
      expect(settings.subtitleSize, 12);
      expect(settings.subtitlePosition, PlaybackSettings.subtitlePositionMax);
      expect(settings.lastLinkCacheHours, 1);
      expect(settings.defaultPlaybackSpeed, 2);
      expect(settings.preferredVideoHeight, 0);
    });

    test('subtitle position round trips and converts the old offset', () {
      final restored = PlaybackSettings.fromJson(
        const PlaybackSettings(subtitlePosition: .12).toJson(),
      );
      expect(restored.subtitlePosition, .12);

      // The old default pixel offset is the new default position.
      expect(
        PlaybackSettings.fromJson({
          'subtitleVerticalOffset': 20,
        }).subtitlePosition,
        0,
      );
      expect(
        PlaybackSettings.fromJson({
          'subtitleVerticalOffset': 60,
        }).subtitlePosition,
        closeTo(.1, 1e-9),
      );
      expect(
        PlaybackSettings.fromJson({'subtitlePosition': 'NaN'}).subtitlePosition,
        0,
      );
    });

    test('subtitle bottom keeps the original default and stays on screen', () {
      double bottom(
        double position, {
        double height = 400,
        bool controls = false,
        EdgeInsets padding = EdgeInsets.zero,
      }) => PlaybackSettings.subtitleBottom(
        height: height,
        padding: padding,
        controlsVisible: controls,
        position: position,
      );

      // Unchanged from before: 80 + 20, or 132 + 20 above the controls.
      expect(bottom(0), 100);
      expect(bottom(0, controls: true), 152);
      // Relative to the player height, so a tablet moves further.
      expect(bottom(.1), 140);
      expect(bottom(.1, height: 1000), 200);
      // Clamped inside the safe area and below the top bar.
      expect(
        bottom(
          PlaybackSettings.subtitlePositionMin,
          height: 1400,
          padding: const EdgeInsets.only(bottom: 24),
        ),
        32,
      );
      expect(
        bottom(
          PlaybackSettings.subtitlePositionMax,
          height: 300,
          padding: const EdgeInsets.only(top: 30),
          controls: true,
        ),
        150,
      );
    });

    test('subtitle position labels', () {
      expect(subtitlePositionLabel(0), 'Default');
      expect(subtitlePositionLabel(.06), 'Higher 6%');
      expect(subtitlePositionLabel(-.04), 'Lower 4%');
    });
  });

  group('last stream cache', () {
    const item = MediaItem(id: '42', type: 'movie', name: 'Example');
    const source = StreamSource(
      name: 'HD stream',
      url: 'https://media.example/video.m3u8',
      providerName: 'Example provider',
      quality: '1080p',
    );

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('stores and restores the source for the same title', () async {
      final storage = StorageService();
      await storage.saveLastStream(item, source);

      final restored = await storage.lastStream(
        item,
        maxAge: const Duration(days: 1),
        allowTorrents: true,
      );

      expect(restored?.url, source.url);
      expect(restored?.providerName, source.providerName);
    });

    test('does not reuse an expired source URL', () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'onfeed.playback.lastStreams.v1',
        '{"movie:42":{"savedAt":"2000-01-01T00:00:00.000Z","source":$_jsonSource}}',
      );

      final restored = await StorageService().lastStream(
        item,
        maxAge: const Duration(days: 1),
        allowTorrents: true,
      );

      expect(restored, isNull);
    });

    test('does not reuse a cached source from a disallowed provider', () async {
      final storage = StorageService();
      final providerSource = source.copyWithProviderId('repo-a|provider-a');
      await storage.saveLastStream(item, providerSource);

      final restored = await storage.lastStream(
        item,
        maxAge: const Duration(days: 1),
        allowTorrents: true,
        allowedProviderIds: {'repo-b|provider-b'},
      );

      expect(restored, isNull);
    });

    test('reuses a cached source when its provider is allowed', () async {
      final storage = StorageService();
      final providerSource = source.copyWithProviderId('repo-a|provider-a');
      await storage.saveLastStream(item, providerSource);

      final restored = await storage.lastStream(
        item,
        maxAge: const Duration(days: 1),
        allowTorrents: true,
        allowedProviderIds: {'repo-a|provider-a'},
      );

      expect(restored?.providerId, 'repo-a|provider-a');
    });
  });

  test('playback settings controller persists and reloads changes', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = PlaybackSettingsController();
    await controller.load();
    await controller.update(
      controller.value.copyWith(
        autoStreamSelection: false,
        subtitleSize: 24,
        defaultPlaybackSpeed: 1.5,
        preferredVideoHeight: 720,
      ),
    );
    controller.dispose();

    final restored = PlaybackSettingsController();
    await restored.load();

    expect(restored.value.autoStreamSelection, isFalse);
    expect(restored.value.subtitleSize, 24);
    expect(restored.value.defaultPlaybackSpeed, 1.5);
    expect(restored.value.preferredVideoHeight, 720);
    restored.dispose();
  });

  testWidgets('playback screen renders and persists a player switch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = PlaybackSettingsController();
    await controller.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSettingsScreen(
            controller: controller,
            plugins: const [],
            onBack: () {},
          ),
        ),
      ),
    );

    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('PLAYER'), findsOneWidget);
    await tester.ensureVisible(find.text('Touch gestures'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).at(3));
    await tester.pumpAndSettle();

    expect(controller.value.touchGestures, isFalse);

    await tester.ensureVisible(find.text('Default playback speed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default playback speed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×'));
    await tester.pumpAndSettle();
    expect(controller.value.defaultPlaybackSpeed, 1.5);

    await tester.ensureVisible(find.text('Preferred video quality'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preferred video quality'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p'));
    await tester.pumpAndSettle();
    expect(controller.value.preferredVideoHeight, 720);
    controller.dispose();
  });
}

const _jsonSource =
    '{"name":"HD stream","url":"https://media.example/video.m3u8","providerName":"Example provider","quality":"1080p"}';
