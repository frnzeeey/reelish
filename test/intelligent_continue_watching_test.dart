import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/resume_summary.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/viewmodels/library_view_model.dart';
import 'package:onfeed/src/widgets/player/custom_video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _minute = 60000;

MediaItem _movie(String id, {int resume = 0, int duration = 0}) => MediaItem(
  id: id,
  type: 'movie',
  name: 'Movie $id',
  resumeMs: resume,
  durationMs: duration,
);

const _series = MediaItem(
  id: '1396',
  type: 'series',
  name: 'Breaking Bad',
  resumeMs: 47 * _minute,
);

const _watched = EpisodeProgress(
  positionMs: 47 * _minute,
  durationMs: 48 * _minute,
);
const _halfway = EpisodeProgress(
  positionMs: 20 * _minute,
  durationMs: 48 * _minute,
);

void main() {
  group('the episode to continue', () {
    test('the last episode while it is unfinished', () {
      const progress = SeriesProgress(
        last: (season: 1, episode: 3),
        next: (season: 1, episode: 4),
        episodes: {'1:3': _halfway},
      );
      expect(progress.continueAt, (season: 1, episode: 3));
    });

    test('the next one once the last is watched', () {
      const progress = SeriesProgress(
        last: (season: 1, episode: 3),
        next: (season: 1, episode: 4),
        episodes: {'1:3': _watched},
      );
      expect(progress.continueAt, (season: 1, episode: 4));
    });

    test('nothing after the finale', () {
      const progress = SeriesProgress(
        last: (season: 5, episode: 16),
        episodes: {'5:16': _watched},
      );
      expect(progress.continueAt, isNull);
    });
  });

  group('cards', () {
    test('a finished episode offers the next one', () {
      final summary = ResumeSummary.of(
        _series,
        series: const SeriesProgress(
          last: (season: 1, episode: 3),
          next: (season: 1, episode: 4),
          episodes: {'1:3': _watched},
        ),
      );
      expect(summary.label, 'Up next · S1 E4');
      expect(summary.fraction, 0);
    });

    test('the next episode shows its own progress when it has some', () {
      final summary = ResumeSummary.of(
        _series,
        series: const SeriesProgress(
          last: (season: 1, episode: 3),
          next: (season: 1, episode: 4),
          episodes: {'1:3': _watched, '1:4': _halfway},
        ),
      );
      expect(summary.label, 'S1 E4 · 28 min left');
      expect(summary.fraction, closeTo(20 / 48, 1e-9));
    });
  });

  group('what stays in Continue watching', () {
    test('a movie stays until it is watched', () {
      expect(
        ResumeSummary.continues(
          _movie('1', resume: 30 * _minute, duration: 120 * _minute),
        ),
        isTrue,
      );
      expect(
        ResumeSummary.continues(
          _movie('1', resume: 115 * _minute, duration: 120 * _minute),
        ),
        isFalse,
      );
    });

    test('a movie saved without its length stays', () {
      expect(
        ResumeSummary.continues(_movie('1', resume: 30 * _minute)),
        isTrue,
      );
    });

    test('never started is not continued', () {
      expect(ResumeSummary.continues(_movie('1')), isFalse);
    });

    test('a finished series leaves; one with a next episode stays', () {
      const finale = SeriesProgress(
        last: (season: 5, episode: 16),
        episodes: {'5:16': _watched},
      );
      const withNext = SeriesProgress(
        last: (season: 1, episode: 3),
        next: (season: 1, episode: 4),
        episodes: {'1:3': _watched},
      );
      expect(ResumeSummary.continues(_series, series: finale), isFalse);
      expect(ResumeSummary.continues(_series, series: withNext), isTrue);
    });

    test('a series with no recorded episodes stays as before', () {
      expect(ResumeSummary.continues(_series), isTrue);
      expect(
        ResumeSummary.continues(_series, series: SeriesProgress.empty),
        isTrue,
      );
    });
  });

  group('resume position', () {
    test('a position in the watched end starts from the beginning', () {
      expect(
        CustomVideoPlayer.validResume(
          const Duration(minutes: 115),
          const Duration(minutes: 120),
        ),
        Duration.zero,
      );
    });

    test('a position past a shorter source starts from the beginning', () {
      expect(
        CustomVideoPlayer.validResume(
          const Duration(minutes: 100),
          const Duration(minutes: 90),
        ),
        Duration.zero,
      );
    });

    test('a position inside the title is kept', () {
      expect(
        CustomVideoPlayer.validResume(
          const Duration(minutes: 42),
          const Duration(minutes: 120),
        ),
        const Duration(minutes: 42),
      );
    });

    test('an unknown length keeps the position', () {
      expect(
        CustomVideoPlayer.validResume(
          const Duration(minutes: 42),
          Duration.zero,
        ),
        const Duration(minutes: 42),
      );
    });
  });

  group('storage', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      StorageService.debugResetWrites();
      StorageService.debugResetAccount();
    });
    tearDown(StorageService.debugResetAccount);

    test('the next episode is saved with a watched one, and dropped with '
        'an unfinished one', () async {
      final storage = StorageService();
      await storage.saveEpisodeProgress(
        _series,
        season: 1,
        episode: 3,
        positionMs: 47 * _minute,
        durationMs: 48 * _minute,
        next: (season: 1, episode: 4),
      );
      var progress = await storage.seriesProgress(_series);
      expect(progress.next, (season: 1, episode: 4));
      expect(progress.continueAt, (season: 1, episode: 4));

      await storage.saveEpisodeProgress(
        _series,
        season: 1,
        episode: 4,
        positionMs: 5 * _minute,
        durationMs: 48 * _minute,
      );
      progress = await storage.seriesProgress(_series);
      expect(progress.next, isNull);
      expect(progress.continueAt, (season: 1, episode: 4));
      // The finished episode keeps its own progress.
      expect(progress.of(1, 3)?.isWatched, isTrue);
    });

    test('progress saved before the next episode was recorded loads', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.history.episodes.v1':
            '{"series:1396":{"last":[1,3],"episodes":{"1:3":[1200000,2880000]}}}',
      });
      final progress = await StorageService().seriesProgress(_series);
      expect(progress.last, (season: 1, episode: 3));
      expect(progress.next, isNull);
      expect(progress.of(1, 3)?.positionMs, 1200000);
    });

    test('each account has its own history and progress', () async {
      final storage = StorageService();
      StorageService.useAccount('account-a');
      await storage.saveProgress(
        _movie('1'),
        30 * _minute,
        durationMs: 120 * _minute,
      );
      await storage.saveEpisodeProgress(
        _series,
        season: 1,
        episode: 3,
        positionMs: 20 * _minute,
        durationMs: 48 * _minute,
      );

      StorageService.useAccount('account-b');
      expect(await storage.history(), isEmpty);
      expect((await storage.seriesProgress(_series)).last, isNull);

      // Signed out: nothing of either account.
      StorageService.useAccount(null);
      expect(await storage.history(), isEmpty);

      StorageService.useAccount('account-a');
      expect((await storage.history()).single.resumeMs, 30 * _minute);
      expect((await storage.seriesProgress(_series)).last, (
        season: 1,
        episode: 3,
      ));
    });

    test('removing a title touches only the signed-in account', () async {
      final storage = StorageService();
      StorageService.useAccount('account-a');
      await storage.saveProgress(_movie('1'), 30 * _minute);
      StorageService.useAccount('account-b');
      await storage.saveProgress(_movie('1'), 10 * _minute);
      await storage.removeHistory(_movie('1'));
      expect(await storage.history(), isEmpty);
      StorageService.useAccount('account-a');
      expect((await storage.history()).single.resumeMs, 30 * _minute);
    });

    test('the device history moves into the account that owns it', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.history': [
          '{"id":"1","type":"movie","name":"Old","resumeMs":5}',
          '{"id":"2","type":"movie","name":"Both","resumeMs":7}',
        ],
        'onfeed.history.episodes.v1':
            '{"series:1396":{"last":[1,3],"episodes":{"1:3":[1200000,2880000]}}}',
        // The account already has an entry of its own for title 2.
        'onfeed.history.u.account-a': [
          '{"id":"2","type":"movie","name":"Both","resumeMs":99}',
        ],
      });
      StorageService.useAccount(
        'account-a',
        ownsDeviceHistory: Future.value(true),
      );
      final storage = StorageService();
      final history = await storage.history();
      expect(history.map((e) => e.id), ['2', '1']);
      // The account's own entry wins.
      expect(history.first.resumeMs, 99);
      expect((await storage.seriesProgress(_series)).last, (
        season: 1,
        episode: 3,
      ));
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('onfeed.history'), isFalse);
      expect(preferences.containsKey('onfeed.history.episodes.v1'), isFalse);
    });

    test('another account does not receive the device history', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.history': [
          '{"id":"1","type":"movie","name":"Old","resumeMs":5}',
        ],
      });
      StorageService.useAccount(
        'account-b',
        ownsDeviceHistory: Future.value(false),
      );
      expect(await StorageService().history(), isEmpty);
      final preferences = await SharedPreferences.getInstance();
      // Kept for the account that owns it.
      expect(preferences.containsKey('onfeed.history'), isTrue);
    });
  });

  group('library', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      StorageService.debugResetWrites();
      StorageService.debugResetAccount();
    });

    test(
      'finished titles leave Continue watching but stay in the history',
      () async {
        final storage = StorageService();
        await storage.saveProgress(
          _movie('finished'),
          118 * _minute,
          durationMs: 120 * _minute,
        );
        await storage.saveProgress(
          _movie('started'),
          30 * _minute,
          durationMs: 120 * _minute,
        );
        final model = LibraryViewModel(storage: storage);
        await model.load();
        expect(model.history.map((e) => e.id), ['started', 'finished']);
        expect(model.continueWatching.map((e) => e.id), ['started']);
        model.dispose();
      },
    );
  });
}
