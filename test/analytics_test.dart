import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/analytics/analytics_events.dart';
import 'package:onfeed/src/analytics/analytics_service.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/services/playback_metrics.dart';
import 'package:onfeed/src/services/stream_discovery.dart';
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

/// A session with every stage measured, from a lookup whose source carries
/// everything that must never be sent.
AnalyticsEvent _fullSession() {
  var now = DateTime(2026);
  void wait(int ms) => now = now.add(Duration(milliseconds: ms));
  final lookup = StreamDiscovery()
    ..add(
      const StreamSource(
        name: 'Clip Title 1080p',
        url: 'https://cdn.example/clip.m3u8?token=abc',
        providerName: 'Secret Provider',
        providerId: 'https://repo.example/manifest.json|secret',
        headers: {
          'Authorization': 'Bearer abc',
          'Referer': 'https://cdn.example',
        },
      ),
    )
    ..providerRan(failed: false, stalled: false)
    ..providerRan(failed: true, stalled: true);
  final metrics = PlaybackMetrics(clock: () => now)
    ..resolution = SourceResolution(
      origin: SourceOrigin.auto,
      resolved: const Duration(milliseconds: 2300),
      lookup: lookup.stats,
    )
    ..attempted()
    ..opened(
      const Duration(milliseconds: 900),
      prepared: const Duration(milliseconds: 120),
    )
    ..playRequested();
  wait(300);
  metrics
    ..firstFrame('media3')
    ..playing(true)
    ..recovering();
  wait(1500);
  metrics
    ..attempted()
    ..firstFrame('media3');
  return metrics.event(
    contentType: 'movie',
    itemId: '550',
    watched: .5,
    watchParty: true,
  );
}

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

    test('a page opened before agreeing can still be counted after', () async {
      final calls = _fakeNative();
      final analytics = _service();
      await analytics.load();
      analytics.logScreen('home');
      await analytics.setConsent(true);
      analytics.logScreen('home');
      await pumpEventQueue();
      expect(
        _events(calls).where((name) => name == 'screen_view'),
        hasLength(1),
      );
    });

    test('a user property set before agreeing is sent on agreeing', () async {
      final calls = _fakeNative();
      final analytics = _service();
      await analytics.load();
      analytics.setUserProperty('interface', 'tv');
      await analytics.setConsent(true);
      await pumpEventQueue();
      expect(
        calls.singleWhere((c) => c.method == 'setUserProperty').arguments,
        {'name': 'interface', 'value': 'tv'},
      );
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
      _fullSession(),
      for (final outcome in LookupOutcome.values)
        AnalyticsEvent.sourceLookup(
          contentType: 'series',
          outcome: outcome,
          lookupMs: 61000,
          runs: 12,
          failed: 3,
          stalled: 2,
        ),
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

    test('watch party events hold fixed values only', () {
      expect(
        AnalyticsEvent.watchPartySession(
          host: false,
          endReason: 'notFound',
          minutes: 12,
          reconnects: 2,
        ).parameters,
        {
          'role': 'guest',
          'end_reason': 'not_found',
          'minutes': 12,
          'reconnects': 2,
        },
      );
      expect(
        AnalyticsEvent.watchPartyFailed(
          step: 'join',
          reason: 'notFound',
        ).parameters,
        {'step': 'join', 'reason': 'not_found'},
      );
    });

    test('a title from Continue watching says so', () {
      expect(
        AnalyticsEvent.selectContent(
          contentType: 'movie',
          itemId: '1',
          from: 'continue_watching',
        ).parameters['origin'],
        'continue_watching',
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
        'rebuffer_pct': 100,
        'recoveries': 0,
        'recovered': 0,
        'watched_pct': 90,
        'watch_party': 0,
        'opens': 0,
        'recovery_ms': 0,
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

    test('playback that fails for good after starting is interrupted, unless '
        'a later source plays', () {
      final metrics = PlaybackMetrics()
        ..firstFrame('mediaKit')
        ..recovering()
        ..gaveUp();
      Map<String, Object> parameters() =>
          metrics.event(contentType: 'movie', itemId: '1').parameters;
      expect(parameters()['outcome'], 'interrupted');
      expect(parameters()['recoveries'], 1);
      expect(parameters()['recovered'], 0);

      metrics.firstFrame('mediaKit');
      expect(parameters()['outcome'], 'played');
    });

    test('a session found by a lookup reports where its start-up time '
        'went', () {
      final parameters = _fullSession().parameters;
      expect(parameters, containsPair('source_origin', 'auto'));
      expect(parameters, containsPair('resolve_ms', 2300));
      expect(parameters['first_source_ms'], isA<int>());
      expect(parameters, containsPair('lookup_stalled', 1));
      expect(parameters, containsPair('prepare_ms', 120));
      expect(parameters, containsPair('open_ms', 900));
      expect(parameters, containsPair('opens', 2));
      expect(parameters, containsPair('recovery_ms', 1500));
      // Every parameter fits: Firebase drops those past 25 silently.
      expect(parameters, hasLength(lessThanOrEqualTo(25)));
    });

    test('stages that did not run are left out, not sent as zero', () {
      // A saved link: no lookup ran.
      final cached = PlaybackMetrics()
        ..resolution = const SourceResolution(
          origin: SourceOrigin.cache,
          resolved: Duration(milliseconds: 40),
        );
      final fromCache = cached
          .event(contentType: 'movie', itemId: '1')
          .parameters;
      expect(fromCache, containsPair('source_origin', 'cache'));
      expect(fromCache, containsPair('resolve_ms', 40));
      expect(fromCache.keys, isNot(contains('first_source_ms')));
      expect(fromCache.keys, isNot(contains('lookup_stalled')));
      // Nothing opened: no preparation or open time.
      expect(fromCache.keys, isNot(contains('prepare_ms')));
      expect(fromCache.keys, isNot(contains('open_ms')));

      // A source the viewer picked: their time with the list is not
      // start-up time.
      final picked = PlaybackMetrics()
        ..resolution = SourceResolution(
          origin: SourceOrigin.manual,
          lookup: StreamDiscovery().stats,
        );
      final manual = picked.event(contentType: 'movie', itemId: '1').parameters;
      expect(manual, containsPair('source_origin', 'manual'));
      expect(manual.keys, isNot(contains('resolve_ms')));
      // The lookup never found a source before it was picked from.
      expect(manual.keys, isNot(contains('first_source_ms')));

      // A player opened without Home's measurements.
      final bare = PlaybackMetrics()
          .event(contentType: 'movie', itemId: '1')
          .parameters;
      expect(bare.keys, isNot(contains('source_origin')));
      expect(bare.keys, isNot(contains('resolve_ms')));
    });

    test('a session that closes while recovering counts the time so far', () {
      var now = DateTime(2026);
      final metrics = PlaybackMetrics(clock: () => now)
        ..firstFrame('media3')
        ..recovering();
      now = now.add(const Duration(seconds: 4));
      expect(
        metrics.event(contentType: 'movie', itemId: '1').parameters,
        containsPair('recovery_ms', 4000),
      );
    });

    test('stage parameters never carry the stream, its host, headers, the '
        'provider or the title', () {
      final values = _fullSession().parameters.values.map((v) => '$v');
      for (final secret in [
        'cdn.example',
        'token=',
        'Bearer',
        'Secret Provider',
        'repo.example',
        'Clip Title',
      ]) {
        expect(values.any((v) => v.contains(secret)), isFalse, reason: secret);
      }
      // Every value is a number or a fixed word.
      for (final value in _fullSession().parameters.values) {
        expect(
          value is num || RegExp(r'^[a-z0-9_]+$').hasMatch('$value'),
          isTrue,
          reason: '$value',
        );
      }
    });

    test('a Play that never opens the player is one lookup event, only '
        'after yes', () async {
      final calls = _fakeNative();
      final analytics = _service();
      await analytics.load();
      AnalyticsEvent lookup() => AnalyticsEvent.sourceLookup(
        contentType: 'movie',
        outcome: LookupOutcome.noSource,
        lookupMs: 60400,
        runs: 7,
        failed: 2,
        stalled: 3,
      );
      analytics.log(lookup());
      await pumpEventQueue();
      expect(_events(calls), isEmpty);

      await analytics.setConsent(true);
      calls.clear();
      analytics.log(lookup());
      await pumpEventQueue();
      expect(_events(calls), ['source_lookup']);
      expect((calls.single.arguments as Map)['parameters'], {
        'content_type': 'movie',
        'outcome': 'no_source',
        'lookup_ms': 60400,
        'lookup_runs': 7,
        'lookup_failed': 2,
        'lookup_stalled': 3,
      });
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
