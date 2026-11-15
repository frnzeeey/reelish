import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/notifications/episode_alerts.dart';
import 'package:onfeed/src/notifications/episode_check.dart';
import 'package:onfeed/src/notifications/smart_alerts.dart';
import 'package:onfeed/src/screens/notification_settings_screen.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/follow_alert_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 11, 10, 12);

String _day(DateTime d, [int plusDays = 0]) {
  final t = d.add(Duration(days: plusDays));
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

AlertEvent _event(String key, {DateTime? at, String name = 'A'}) => AlertEvent(
  key: key,
  category: AlertCategory.watchlist,
  title: 'Title $key',
  body: 'Body',
  target: 'series:1',
  name: name,
  at: (at ?? _now).millisecondsSinceEpoch,
);

class _Notifier implements EpisodeNotifier {
  final shown = <List<NewEpisode>>[];
  final updates = <(AlertCategory, List<AlertEvent>)>[];
  final digests = <List<AlertEvent>>[];
  final messages = <int>[];

  @override
  Future<void> showNew(List<NewEpisode> episodes) async => shown.add(episodes);
  @override
  Future<void> showPopular(List<NewEpisode> episodes) async {}
  @override
  Future<void> showMessages(int count, List<String> from) async =>
      messages.add(count);
  @override
  Future<void> showUpdates(AlertCategory c, List<AlertEvent> events) async =>
      updates.add((c, events));
  @override
  Future<void> showDigest(List<AlertEvent> events) async => digests.add(events);
}

/// The API's answers, set per test; records what was asked.
class _Api {
  final series = <Map<String, Object?>>[];
  final movies = <Map<String, Object?>>[];
  final people = <Map<String, Object?>>[];
  int messages = 0;
  final asked = <Map<String, dynamic>>[];

  Future<http.Response> handle(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    asked.add(body);
    return http.Response(
      jsonEncode({
        'series': series,
        'popular': [],
        if (messages > 0) 'messages': {'count': messages, 'from': []},
        if (body.containsKey('movies')) 'movies': movies,
        if (body.containsKey('people')) 'people': people,
        if (body.containsKey('collections')) 'collections': [],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  group('AlertPlanner', () {
    test('never shows what was already shown, nor the same news twice', () {
      final plan = AlertPlanner.plan(
        found: [_event('a'), _event('b'), _event('b')],
        pending: [_event('a')],
        delivered: {'b'},
        frequency: AlertFrequency.instant,
        quiet: null,
        now: _now,
      );
      expect(plan.now.map((e) => e.key), ['a']);
    });

    test('quiet hours hold everything, then let it through', () {
      const quiet = QuietHours(22, 7);
      final night = DateTime(2026, 11, 10, 23);
      final held = AlertPlanner.plan(
        found: [_event('a', at: night)],
        pending: const [],
        delivered: const {},
        frequency: AlertFrequency.instant,
        quiet: quiet,
        now: night,
      );
      expect(held.now, isEmpty);
      expect(held.pending, hasLength(1));
      final morning = DateTime(2026, 11, 11, 8);
      final later = AlertPlanner.plan(
        found: const [],
        pending: held.pending,
        delivered: const {},
        frequency: AlertFrequency.instant,
        quiet: quiet,
        now: morning,
      );
      expect(later.now.map((e) => e.key), ['a']);
    });

    test('quiet hours over midnight, and within a day', () {
      expect(const QuietHours(22, 7).contains(DateTime(2026, 1, 1, 3)), isTrue);
      expect(
        const QuietHours(22, 7).contains(DateTime(2026, 1, 1, 7)),
        isFalse,
      );
      expect(const QuietHours(1, 5).contains(DateTime(2026, 1, 1, 0)), isFalse);
      expect(const QuietHours(1, 5).contains(DateTime(2026, 1, 1, 4)), isTrue);
    });

    test('a daily summary waits for its day; news too old is dropped', () {
      final plan = AlertPlanner.plan(
        found: [_event('new')],
        pending: [_event('stale', at: _now.subtract(const Duration(days: 9)))],
        delivered: const {},
        frequency: AlertFrequency.daily,
        quiet: null,
        now: _now,
        lastDigest: _now.subtract(const Duration(hours: 5)),
      );
      expect(plan.now, isEmpty);
      expect(plan.pending.map((e) => e.key), ['new']);
      final due = AlertPlanner.plan(
        found: const [],
        pending: plan.pending,
        delivered: const {},
        frequency: AlertFrequency.daily,
        quiet: null,
        now: _now.add(const Duration(hours: 18)),
        lastDigest: _now.subtract(const Duration(hours: 5)),
      );
      expect(due.digest, isTrue);
      expect(due.now.map((e) => e.key), ['new']);
    });
  });

  group('WatchlistUpdates', () {
    Map<String, Object?> series(
      int seasons, {
      String? premiere,
      int next = 0,
    }) => {
      'tmdbId': 1,
      'name': 'Show',
      'seasons': seasons,
      'lastEpisode': {'season': seasons - 1 < 1 ? 1 : seasons - 1},
      if (premiere != null)
        'nextEpisode': {'season': next, 'episode': 1, 'airDate': premiere},
    };

    Detected run(
      List<Map<String, Object?>> s,
      Map<String, Object?> state, {
      List<Map<String, Object?>> movies = const [],
    }) => WatchlistUpdates.detect(
      series: [for (final x in s) Map<String, dynamic>.from(x)],
      movies: [for (final x in movies) Map<String, dynamic>.from(x)],
      seriesOnList: {1},
      state: state,
      now: _now,
    );

    test('a first sight is only noted', () {
      final first = run([series(2)], {});
      expect(first.events, isEmpty);
      expect(first.state['s:1'], {'n': 2});
    });

    test('a season announced, then dated, each once', () {
      var state = run([series(2)], {}).state;
      final announced = run([series(3)], state);
      expect(announced.events.single.title, 'Show: season 3 announced');
      state = announced.state;
      expect(run([series(3)], state).events, isEmpty);
      final dated = run([series(3, premiere: _day(_now, 30), next: 3)], state);
      expect(dated.events.single.title, startsWith('Show: season 3 premieres'));
      expect(
        run([series(3, premiere: _day(_now, 30), next: 3)], dated.state).events,
        isEmpty,
      );
    });

    test('a movie dated, then released; old releases are not news', () {
      Map<String, Object?> movie(String status, String date) => {
        'tmdbId': 9,
        'title': 'Film',
        'status': status,
        'releaseDate': date,
      };
      var state = run([], {}, movies: [movie('Planned', '')]).state;
      final dated = run([], state, movies: [movie('Planned', _day(_now, 40))]);
      expect(dated.events.single.title, 'Film has a release date');
      state = dated.state;
      // The date moving again is a minor change: no alert.
      final moved = run([], state, movies: [movie('Planned', _day(_now, 50))]);
      expect(moved.events, isEmpty);
      final released = run(
        [],
        moved.state,
        movies: [movie('Released', _day(_now, -1))],
      );
      expect(released.events.single.title, 'Film is released');
      expect(released.events.single.body, contains('depends on your sources'));
      // Corrected by TMDB to a release from long ago: noted, not news.
      final old = run([], state, movies: [movie('Released', '2001-01-01')]);
      expect(old.events, isEmpty);
    });
  });

  group('FollowedWork', () {
    Detected run(List<Map<String, Object?>> credits, Map<String, Object?> s) =>
        FollowedWork.detect(
          people: [
            {'tmdbId': 5, 'name': 'Ada', 'credits': credits},
          ],
          collections: const [],
          state: s,
          now: _now,
        );

    test('announced once, released once, never for what was known', () {
      final known = {
        'type': 'movie',
        'tmdbId': 1,
        'title': 'Known',
        'date': '',
        'role': 'cast',
      };
      var state = run([known], {}).state;
      expect(run([known], state).events, isEmpty);
      final fresh = {
        'type': 'movie',
        'tmdbId': 2,
        'title': 'Fresh',
        'date': '',
        'role': 'director',
      };
      final announced = run([known, fresh], state);
      expect(announced.events.single.title, 'New project: Ada directs Fresh');
      state = announced.state;
      expect(run([known, fresh], state).events, isEmpty);
      final out = {...fresh, 'date': _day(_now, -2)};
      final released = run([known, out], state);
      expect(released.events.single.title, 'Fresh is out, directed by Ada');
      expect(run([known, out], released.state).events, isEmpty);
    });
  });

  group('UnfinishedReminders', () {
    SeriesProgress progress(DateTime at, {bool watched = false}) =>
        SeriesProgress(
          episodes: {
            '1:3': EpisodeProgress(
              positionMs: watched ? 3000000 : 600000,
              durationMs: 3000000,
              at: at.millisecondsSinceEpoch,
            ),
          },
          last: (season: 1, episode: 3),
        );

    List<AlertEvent> run(
      int days,
      SeriesProgress p, {
      DateTime? last,
      Map<String, String> names = const {'7': 'Show'},
    }) => UnfinishedReminders.detect(
      days: days,
      progress: {'series:7': p},
      names: names,
      now: _now,
      lastReminder: last,
    );

    test('off, too recent, finished, let go or removed: no reminder', () {
      final ago = _now.subtract(const Duration(days: 8));
      expect(run(0, progress(ago)), isEmpty);
      expect(run(14, progress(ago)), isEmpty);
      expect(run(7, progress(ago, watched: true)), isEmpty);
      expect(
        run(7, progress(_now.subtract(const Duration(days: 60)))),
        isEmpty,
      );
      expect(run(7, progress(ago), names: const {}), isEmpty);
    });

    test('one reminder a stretch, and at most one a day', () {
      final ago = _now.subtract(const Duration(days: 8));
      final first = run(7, progress(ago));
      expect(first.single.title, 'Pick up Show');
      expect(first.single.body, 'S1 E3 is waiting where you left it.');
      // The same stretch has the same key, so the planner drops it.
      expect(run(7, progress(ago)).single.key, first.single.key);
      expect(
        run(7, progress(ago), last: _now.subtract(const Duration(hours: 3))),
        isEmpty,
      );
    });
  });

  group('Saved data', () {
    test('settings from before smart alerts read their defaults', () {
      final s = EpisodeAlertStore.settingsOf({
        'settings': {'enabled': true, 'myList': false},
      });
      expect(s.enabled, isTrue);
      expect(s.myList, isFalse);
      expect(s.watchlist, isTrue);
      expect(s.reminderDays, 0);
      expect(s.frequency, AlertFrequency.instant);
      expect(s.quiet, isNull);
      final round = EpisodeAlertStore.settingsOf({
        'settings': EpisodeAlertStore.settingsJson(
          s.copyWith(
            reminderDays: 7,
            frequency: AlertFrequency.weekly,
            quiet: const QuietHours(23, 8),
          ),
        ),
      });
      expect(round.reminderDays, 7);
      expect(round.frequency, AlertFrequency.weekly);
      expect(round.quiet, const QuietHours(23, 8));
      expect(round.copyWith(quiet: null).quiet, isNull);
    });

    test('a tap target is parsed strictly', () {
      expect(
        AlertTarget.parse(AlertTarget.payloadOf('person:12', 'Ada'))?.kind,
        'person',
      );
      expect(AlertTarget.parse('recent'), AlertTarget.recent);
      for (final bad in [
        null,
        '',
        'series:1',
        '{"to":"series:0"}',
        '{"to":"https://evil/x"}',
        '{"to":"series:1; rm"}',
        '[1]',
      ]) {
        expect(AlertTarget.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('AlertRoutes', () {
    setUp(AlertRoutes.debugReset);
    tearDown(AlertRoutes.debugReset);

    test('the tap that launched the app waits for Home, then opens once', () {
      AlertRoutes.handle(AlertTarget.payloadOf('movie:7', 'Heat'));
      final opened = <AlertTarget>[];
      AlertRoutes.open = opened.add;
      expect(opened.map((t) => '${t.kind}:${t.id}:${t.name}'), [
        'movie:7:Heat',
      ]);
      // Home rebuilt or came back: the old tap is not opened again.
      AlertRoutes.open = null;
      AlertRoutes.open = opened.add;
      expect(opened, hasLength(1));
    });

    test('while Home is up, a tap opens at once; a bad one opens nothing', () {
      final opened = <AlertTarget>[];
      AlertRoutes.open = opened.add;
      AlertRoutes.handle('recent');
      AlertRoutes.handle('{"to":"https://evil/x"}');
      AlertRoutes.handle(null);
      expect(opened, [AlertTarget.recent]);
    });

    test('only the latest tap before Home waits', () {
      AlertRoutes.handle(AlertTarget.payloadOf('series:1', 'A'));
      AlertRoutes.handle(AlertTarget.payloadOf('person:2', 'B'));
      final opened = <AlertTarget>[];
      AlertRoutes.open = opened.add;
      expect(opened.single.kind, 'person');
    });
  });

  group('EpisodeCheck with smart alerts', () {
    late _Api fake;
    late StorageService storage;
    late _Notifier notifier;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      StorageService.debugResetWrites();
      fake = _Api();
      storage = StorageService();
      notifier = _Notifier();
    });

    Future<void> settings(EpisodeAlertSettings s) => EpisodeAlertStore.update(
      'u',
      (e) => e['settings'] = EpisodeAlertStore.settingsJson(s),
    );

    Future<EpisodeCheckResult> check(DateTime at) => EpisodeCheck.run(
      userId: 'u',
      alertToken: 'rnt_${'a' * 43}',
      api: AccountApi(
        baseUrl: Uri.parse('https://api.reelish.app'),
        client: MockClient(fake.handle),
      ),
      storage: storage,
      notifier: notifier,
      now: at,
    );

    Map<String, Object?> show(int episode) => {
      'tmdbId': 3,
      'name': 'Show',
      'seasons': 1,
      'lastEpisode': {
        'season': 1,
        'episode': episode,
        'name': '',
        'airDate': _day(_now),
      },
    };

    test('an episode already watched on another device is not news', () async {
      await settings(const EpisodeAlertSettings(enabled: true));
      await storage.saveProgress(
        const MediaItem(id: '3', type: 'series', name: 'Show'),
        60000,
      );
      fake.series.add(show(1));
      await check(_now);
      await storage.saveEpisodeProgress(
        const MediaItem(id: '3', type: 'series', name: 'Show'),
        season: 1,
        episode: 2,
        positionMs: 2900000,
        durationMs: 3000000,
      );
      fake.series
        ..clear()
        ..add(show(2));
      await check(_now.add(const Duration(hours: 6)));
      expect(notifier.shown, isEmpty);
    });

    test('quiet hours hold episodes and messages until after', () async {
      await settings(
        const EpisodeAlertSettings(enabled: true, quiet: QuietHours(22, 7)),
      );
      await storage.saveProgress(
        const MediaItem(id: '3', type: 'series', name: 'Show'),
        60000,
      );
      fake.series.add(show(1));
      await check(_now);
      fake.series
        ..clear()
        ..add(show(2));
      fake.messages = 2;
      final night = DateTime(2026, 11, 10, 23);
      await check(night);
      expect(notifier.shown, isEmpty);
      expect(notifier.messages, isEmpty);
      final morning = DateTime(2026, 11, 11, 7, 30);
      await check(morning);
      expect(notifier.shown.single.single.episode, 2);
      expect(notifier.messages, [2]);
      // Never again.
      await check(morning.add(const Duration(hours: 6)));
      expect(notifier.shown, hasLength(1));
      final recent = EpisodeAlertStore.recentOf(
        await EpisodeAlertStore.entry('u'),
      );
      expect(recent.single.event.target, 'series:3');
      expect(recent.single.read, isFalse);
    });

    test('a weekly summary gathers news into one', () async {
      await settings(
        const EpisodeAlertSettings(
          enabled: true,
          frequency: AlertFrequency.weekly,
        ),
      );
      await storage.saveProgress(
        const MediaItem(id: '3', type: 'series', name: 'Show'),
        60000,
      );
      fake.series.add(show(1));
      await check(_now);
      expect(notifier.digests, isEmpty);
      fake.series
        ..clear()
        ..add(show(2));
      await check(_now.add(const Duration(hours: 6)));
      // The first summary goes out at once; the next waits a week.
      expect(notifier.digests.single.single.episode, 2);
      fake.series
        ..clear()
        ..add(show(3));
      await check(_now.add(const Duration(days: 1)));
      expect(notifier.digests, hasLength(1));
      expect(notifier.shown, isEmpty);
    });

    test('people are asked about only while that category is on', () async {
      await EpisodeAlertStore.update('u', (e) {
        e['follows'] = EpisodeAlertStore.followsJson((
          people: {5: 'Ada'},
          collections: <int, String>{},
        ));
      });
      await settings(const EpisodeAlertSettings(enabled: true));
      await check(_now);
      expect(fake.asked.last['people'], [5]);
      expect(fake.asked.last.containsKey('collections'), isFalse);
      await settings(const EpisodeAlertSettings(enabled: true, people: false));
      await check(_now.add(const Duration(hours: 6)));
      expect(fake.asked.last.containsKey('people'), isFalse);
    });
  });

  group('Following', () {
    Future<EpisodeAlerts> signedIn() async {
      SharedPreferences.setMockInitialValues({});
      final account = AccountController(
        store: MemorySessionStore(
          StoredSession(
            sessionId: 's',
            accessToken: 'a',
            accessExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
            refreshToken: 'r',
            refreshExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
            userId: 'u',
            username: 'viewer',
          ),
        ),
      );
      await account.restore();
      final alerts = EpisodeAlerts(
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.app'),
          client: MockClient((_) async => http.Response('{}', 500)),
        ),
        storage: StorageService(),
        notifier: _Notifier(),
        background: false,
      )..attach(account);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return alerts;
    }

    test(
      'follows are saved per account, once each, within the limit',
      () async {
        final alerts = await signedIn();
        expect(await alerts.setFollowPerson(5, 'Ada', follow: true), isTrue);
        expect(await alerts.setFollowPerson(5, 'Ada', follow: true), isTrue);
        expect(alerts.follows.people, {5: 'Ada'});
        for (var i = 100; i < 114; i++) {
          await alerts.setFollowCollection(i, 'C$i', follow: true);
        }
        expect(
          await alerts.setFollowCollection(200, 'X', follow: true),
          isTrue,
        );
        expect(
          await alerts.setFollowCollection(201, 'Y', follow: true),
          isFalse,
        );
        final saved = EpisodeAlertStore.followsOf(
          await EpisodeAlertStore.entry('u'),
        );
        expect(saved.people, {5: 'Ada'});
        expect(saved.collections, hasLength(EpisodeAlertStore.maxFollows));
        await alerts.setFollowPerson(5, 'Ada', follow: false);
        expect(alerts.followsPerson(5), isFalse);
      },
    );

    testWidgets('the Follow button follows and unfollows', (tester) async {
      late EpisodeAlerts alerts;
      await tester.runAsync(() async => alerts = await signedIn());
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: FollowAlertButton.person(id: 5, name: 'Ada', alerts: alerts),
          ),
        ),
      );
      expect(find.text('Follow'), findsOneWidget);
      await tester.tap(find.text('Follow'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.text('Following'), findsOneWidget);
      expect(alerts.followsPerson(5), isTrue);
      // Alerts are off, so it says how to hear about them.
      expect(find.textContaining('Turn on notifications'), findsOneWidget);
      await tester.tap(find.text('Following'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(alerts.followsPerson(5), isFalse);
    });

    testWidgets('the settings page lists follows and recent alerts', (
      tester,
    ) async {
      late EpisodeAlerts alerts;
      await tester.runAsync(() async {
        alerts = await signedIn();
        await alerts.setFollowCollection(10, 'The Saga', follow: true);
      });
      tester.view.physicalSize = const Size(412, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: NotificationSettingsScreen(alerts: alerts, onBack: () {}),
          ),
        ),
      );
      await tester.pump();
      for (final text in [
        'My list updates',
        'People you follow',
        'Collections you follow',
        'Unfinished series',
        'How alerts arrive',
        'Quiet hours',
        'The Saga',
        'Alerts you get will be listed here.',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      await tester.tap(find.text('Unfollow'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.text('The Saga'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
