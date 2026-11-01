import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/analytics/analytics_events.dart';
import 'package:onfeed/src/analytics/analytics_service.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/services/playback_metrics.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/analytics_consent_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('onfeed/analytics-test');

/// Records what the native side would receive.
List<MethodCall> _fakeNative({bool configured = true}) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isConfigured' => configured,
          'configure' => configured,
          _ => null,
        };
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
  return calls;
}

AnalyticsService _service({bool android = true}) =>
    AnalyticsService(channel: _channel, supportedPlatform: android);

Iterable<String> _events(List<MethodCall> calls) => calls
    .where((c) => c.method == 'logEvent')
    .map((c) => (c.arguments as Map)['name'] as String);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AnalyticsService', () {
    test('sends nothing before the viewer agrees', () async {
      final calls = _fakeNative();
      final analytics = _service();
      await analytics.load();
      expect(analytics.available.value, isTrue);
      expect(analytics.consent.value, AnalyticsConsent.unknown);
      analytics.log(AnalyticsEvent.featureUsed(AnalyticsFeature.myListAdd));
      analytics.logScreen('home');
      await pumpEventQueue();
      expect(calls.map((c) => c.method), ['isConfigured']);
    });

    test('after yes, events flow; after no, collection stops and the '
        'device data is cleared', () async {
      final calls = _fakeNative();
      final analytics = _service();
      await analytics.load();
      await analytics.setConsent(true);
      analytics.log(AnalyticsEvent.featureUsed(AnalyticsFeature.myListAdd));
      await pumpEventQueue();
      expect(calls[1].method, 'configure');
      expect(calls[1].arguments, {'enabled': true, 'reset': false});
      expect(_events(calls), ['analytics_enabled', 'feature_used']);
      expect(
        (await SharedPreferences.getInstance()).getString(
          AnalyticsService.consentKey,
        ),
        'granted',
      );

      calls.clear();
      await analytics.setConsent(false);
      analytics.log(AnalyticsEvent.featureUsed(AnalyticsFeature.myListAdd));
      await pumpEventQueue();
      expect(calls.single.arguments, {'enabled': false, 'reset': true});
    });

    test('a saved yes resumes collection on the next launch', () async {
      SharedPreferences.setMockInitialValues({
        AnalyticsService.consentKey: 'granted',
      });
      final calls = _fakeNative();
      await _service().load();
      expect(calls.map((c) => c.method), ['isConfigured', 'configure']);
    });

    test('a build without a Firebase configuration sends nothing, even '
        'after yes', () async {
      final calls = _fakeNative(configured: false);
      final analytics = _service();
      await analytics.load();
      await analytics.setConsent(true);
      analytics.logScreen('home');
      await pumpEventQueue();
      expect(analytics.available.value, isFalse);
      expect(calls.map((c) => c.method), ['isConfigured']);
    });

    test('Windows and other platforms never touch the channel', () async {
      final calls = _fakeNative();
      final analytics = _service(android: false);
      await analytics.load();
      await analytics.setConsent(true);
      analytics.logScreen('home');
      await pumpEventQueue();
      expect(calls, isEmpty);
      expect(analytics.available.value, isFalse);
    });

    test('the same page twice in a row is counted once', () async {
      final calls = _fakeNative();
      final analytics = _service();
      await analytics.load();
      await analytics.setConsent(true);
      analytics
        ..logScreen('home')
        ..logScreen('home')
        ..logScreen('library')
        ..logScreen('home');
      await pumpEventQueue();
      final screens = calls
          .where((c) => c.method == 'logEvent')
          .map((c) => (c.arguments as Map)['parameters'] as Map)
          .where((p) => p.containsKey('screen_name'))
          .map((p) => p['screen_name']);
      expect(screens, ['home', 'library', 'home']);
    });

    test('a native failure never reaches the app', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _channel,
            (call) async => throw PlatformException(code: 'boom'),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, null),
      );
      final analytics = _service();
      await analytics.load();
      await analytics.setConsent(true);
      expect(analytics.available.value, isFalse);
    });
  });

  group('Events', () {
    final all = [
      AnalyticsEvent.screenView('home'),
      AnalyticsEvent.selectContent(contentType: 'series', itemId: '1399'),
      AnalyticsEvent.search(SearchOutcome.noResults),
      AnalyticsEvent.playbackSession(
        contentType: 'movie',
        itemId: '550',
        outcome: PlaybackOutcome.played,
      ),
      for (final feature in AnalyticsFeature.values)
        AnalyticsEvent.featureUsed(feature),
      AnalyticsEvent.analyticsEnabled(),
    ];

    test('names and parameters meet Firebase limits', () {
      final name = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$');
      for (final event in all) {
        expect(name.hasMatch(event.name), isTrue, reason: event.name);
        expect(event.name.startsWith('firebase_'), isFalse);
        expect(event.parameters.length, lessThanOrEqualTo(25));
        for (final MapEntry(:key, :value) in event.parameters.entries) {
          expect(name.hasMatch(key), isTrue, reason: key);
          expect(value is String || value is num, isTrue, reason: key);
          if (value is String) expect(value.length, lessThanOrEqualTo(100));
        }
      }
    });

    test('no event can carry account, search or source details', () {
      const forbidden = [
        'user',
        'account',
        'token',
        'email',
        'query',
        'term',
        'url',
        'provider',
        'plugin',
        'title',
        'name_',
      ];
      for (final event in all) {
        for (final key in event.parameters.keys) {
          for (final word in forbidden) {
            expect(key.contains(word), isFalse, reason: '${event.name}.$key');
          }
        }
      }
      expect(
        AnalyticsEvent.featureUsed(
          AnalyticsFeature.watchPartyCreate,
        ).parameters,
        {'feature': 'watch_party_create'},
      );
    });

    test('search sends a count, capped, and never text', () {
      expect(
        AnalyticsEvent.search(SearchOutcome.results, results: 57).parameters,
        {'outcome': 'results', 'results': 21},
      );
    });
  });

  group('Playback session', () {
    test('a played session reports startup, buffering and watched share', () {
      var now = DateTime(2026);
      final metrics = PlaybackMetrics(clock: () => now);
      now = now.add(const Duration(milliseconds: 1840));
      metrics.firstFrame('media3');
      metrics.buffering(true);
      now = now.add(const Duration(milliseconds: 500));
      metrics.buffering(false);
      final event = metrics.event(
        contentType: 'series',
        itemId: '1399',
        watched: .87,
      );
      expect(event.name, 'playback_session');
      expect(event.parameters, {
        'content_type': 'series',
        'item_id': '1399',
        'outcome': 'played',
        'engine': 'media3',
        'first_frame_ms': 1840,
        'rebuffers': 1,
        'rebuffer_ms': 500,
        'stalls': 0,
        'watched_pct': 90,
        'watch_party': 0,
      });
    });

    test('no first frame: failed with the first failure, or abandoned', () {
      final failed = PlaybackMetrics()
        ..failure(PlaybackFailureKind.http)
        ..failure(PlaybackFailureKind.timeout);
      expect(
        failed.event(contentType: 'movie', itemId: '1').parameters,
        containsPair('failure', 'http'),
      );
      expect(
        failed.event(contentType: 'movie', itemId: '1').parameters['outcome'],
        'failed',
      );
      expect(
        PlaybackMetrics()
            .event(contentType: 'movie', itemId: '1')
            .parameters['outcome'],
        'abandoned',
      );
    });

    test('a session is reported once', () async {
      final calls = _fakeNative();
      final analytics = _service();
      await analytics.load();
      await analytics.setConsent(true);
      calls.clear();
      final metrics = PlaybackMetrics(analytics: analytics);
      metrics.report(contentType: 'movie', itemId: '550');
      metrics.report(contentType: 'movie', itemId: '550');
      await pumpEventQueue();
      expect(_events(calls), ['playback_session']);
    });
  });

  group('Consent dialog', () {
    Future<AnalyticsService> pump(WidgetTester tester) async {
      _fakeNative();
      final analytics = _service();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => AnalyticsConsentDialog.maybeAsk(
                  context,
                  service: analytics,
                ),
                child: const Text('start'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      return analytics;
    }

    testWidgets('asks once; OK on a remote answers no', (tester) async {
      final analytics = await pump(tester);
      expect(find.text('Share usage statistics?'), findsOneWidget);
      // "No thanks" has focus: select does not opt in.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(analytics.consent.value, AnalyticsConsent.denied);

      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      expect(find.text('Share usage statistics?'), findsNothing);
    });

    testWidgets('Share turns it on', (tester) async {
      final analytics = await pump(tester);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(analytics.consent.value, AnalyticsConsent.granted);
    });

    testWidgets('Back counts as no', (tester) async {
      final analytics = await pump(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Share usage statistics?'), findsNothing);
      expect(analytics.consent.value, AnalyticsConsent.denied);
    });
  });
}
