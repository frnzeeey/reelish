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
      expect(settings.subtitleSize, 18);
      expect(settings.subtitleVerticalOffset, 20);
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
      },
    );

    test('clamps malformed numeric preferences to safe ranges', () {
      final settings = PlaybackSettings.fromJson({
        'holdSpeed': 99,
        'streamSelectionTimeoutSeconds': -20,
        'subtitleSize': 2,
        'subtitleVerticalOffset': 300,
        'lastLinkCacheHours': 0,
      });

      expect(settings.holdSpeed, 4);
      expect(settings.streamSelectionTimeoutSeconds, 1);
      expect(settings.subtitleSize, 12);
      expect(settings.subtitleVerticalOffset, 80);
      expect(settings.lastLinkCacheHours, 1);
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
  });

  test('playback settings controller persists and reloads changes', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = PlaybackSettingsController();
    await controller.load();
    await controller.update(
      controller.value.copyWith(autoStreamSelection: false, subtitleSize: 24),
    );
    controller.dispose();

    final restored = PlaybackSettingsController();
    await restored.load();

    expect(restored.value.autoStreamSelection, isFalse);
    expect(restored.value.subtitleSize, 24);
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
    controller.dispose();
  });
}

const _jsonSource =
    '{"name":"HD stream","url":"https://media.example/video.m3u8","providerName":"Example provider","quality":"1080p"}';
