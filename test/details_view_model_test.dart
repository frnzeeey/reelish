import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_details.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/tv_season.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/viewmodels/details_view_model.dart';

const _series = MediaItem(id: '1', type: 'series', name: 'Show');
const _movie = MediaItem(id: '2', type: 'movie', name: 'Film');

/// TMDB answers on demand: each call waits on a completer the test resolves.
class _FakeTmdb extends TmdbService {
  final details_ = <Completer<MediaDetails>>[];
  final seasons_ = <Completer<List<Map<String, dynamic>>>>[];
  final episodes_ = <int, Completer<List<Map<String, dynamic>>>>{};
  final related_ = <Completer<List<MediaItem>>>[];

  @override
  Future<MediaDetails> details(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(MediaDetails)? onRevalidated,
  }) => (details_..add(Completer())).last.future;

  @override
  Future<List<Map<String, dynamic>>> seasons(
    MediaItem item, {
    bool forceRefresh = false,
  }) => (seasons_..add(Completer())).last.future;

  @override
  Future<List<Map<String, dynamic>>> episodes(
    MediaItem item,
    int season, {
    bool forceRefresh = false,
  }) => (episodes_[season] = Completer()).future;

  @override
  Future<List<MediaItem>> recommendations(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
  }) => (related_..add(Completer())).last.future;
}

Map<String, dynamic> _season(int n) => {'season_number': n, 'name': 'S$n'};
Map<String, dynamic> _episode(int? n) => {
  'episode_number': ?n,
  'name': 'E$n',
  'air_date': '2020-01-0${n ?? 1}',
};

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeTmdb tmdb;
  setUp(() => tmdb = _FakeTmdb());

  test('a series: details, seasons, then the first season sorted', () async {
    final model = DetailsViewModel(item: _series, tmdb: tmdb);
    var notified = 0;
    model.addListener(() => notified++);
    model.start();
    expect(model.loadingDetails, isTrue);
    expect(model.loadingEpisodes, isTrue);
    expect(tmdb.related_, isEmpty, reason: 'related titles only on request');

    tmdb.details_.single.complete(const MediaDetails(overview: 'Plot'));
    tmdb.seasons_.single.complete([_season(1), _season(2)]);
    await _settle();
    expect(model.details?.overview, 'Plot');
    expect(model.loadingDetails, isFalse);
    expect(model.seasons.map((s) => s.number), [1, 2]);
    expect(model.selectedSeason, 1);

    tmdb.episodes_[1]!.complete([_episode(3), _episode(1), _episode(null)]);
    await _settle();
    expect(model.episodes.map((e) => e.number), [null, 1, 3]);
    expect(model.loadingEpisodes, isFalse);
    expect(model.episodeError, isNull);
    expect(notified, greaterThan(3));
    model.dispose();
  });

  test('a movie loads no seasons', () async {
    final model = DetailsViewModel(item: _movie, tmdb: tmdb)..start();
    await _settle();
    expect(tmdb.seasons_, isEmpty);
    expect(model.isSeries, isFalse);
    model.dispose();
  });

  test('a late answer for a season no longer selected is dropped', () async {
    final model = DetailsViewModel(item: _series, tmdb: tmdb)..start();
    tmdb.seasons_.single.complete([_season(1), _season(2)]);
    await _settle();
    final second = model.selectSeason(2);
    tmdb.episodes_[2]!.complete([_episode(7)]);
    await second;
    // Season 1 answers last; season 2 stays on screen.
    tmdb.episodes_[1]!.complete([_episode(1)]);
    await _settle();
    expect(model.selectedSeason, 2);
    expect(model.episodes.single.number, 7);
    model.dispose();
  });

  for (final keeps in [false, true]) {
    test(
      'a failed season ${keeps ? 'keeps' : 'clears'} the episodes',
      () async {
        final model = DetailsViewModel(
          item: _series,
          tmdb: tmdb,
          keepsEpisodesOnError: keeps,
        )..start();
        tmdb.seasons_.single.complete([_season(1), _season(2)]);
        await _settle();
        tmdb.episodes_[1]!.complete([_episode(1)]);
        await _settle();

        final load = model.selectSeason(2);
        tmdb.episodes_[2]!.completeError(Exception('offline'));
        await load;
        expect(model.episodeError, EpisodeLoadError.season);
        expect(model.episodes, keeps ? hasLength(1) : isEmpty);
        model.dispose();
      },
    );
  }

  test('failures are reported and can be retried', () async {
    final model = DetailsViewModel(item: _series, tmdb: tmdb)..start();
    tmdb.details_.single.completeError(Exception('down'));
    // A season without a number is a broken response, as before.
    tmdb.seasons_.single.complete([
      {'name': 'Specials'},
    ]);
    await _settle();
    expect(model.detailsFailed, isTrue);
    expect(model.loadingDetails, isFalse);
    expect(model.episodeError, EpisodeLoadError.seasons);

    final retry = model.loadDetails();
    expect(model.loadingDetails, isTrue);
    expect(model.detailsFailed, isFalse);
    tmdb.details_.last.complete(const MediaDetails());
    await retry;
    expect(model.detailsFailed, isFalse);
    model.dispose();
  });

  test('related titles load when asked for', () async {
    final model = DetailsViewModel(item: _movie, tmdb: tmdb, loadsRelated: true)
      ..start();
    tmdb.related_.single.complete([_series]);
    await _settle();
    expect(model.related.single.id, '1');
    model.dispose();
  });

  test('answers after dispose change nothing and notify no one', () async {
    final model = DetailsViewModel(item: _series, tmdb: tmdb)..start();
    var notified = 0;
    model.addListener(() => notified++);
    model.dispose();
    tmdb.details_.single.complete(const MediaDetails(overview: 'late'));
    tmdb.seasons_.single.complete([_season(1)]);
    await _settle();
    expect(notified, 0);
    expect(model.details, isNull);
  });

  test('TvEpisode reads TMDB fields with the screens’ defaults', () {
    final episode = TvEpisode.fromJson({
      'episode_number': 4.0,
      'vote_average': 8.25,
      'runtime': 52,
      'still_path': '/s.jpg',
    });
    expect(episode.number, 4);
    expect(episode.name, isNull);
    expect(episode.overview, '');
    expect(episode.rating, 8.25);
    expect(episode.stillPath, '/s.jpg');
    expect(episode.runtime, 52);
    // Unknown and past dates count as aired; a future one does not.
    final now = DateTime(2026, 10, 18);
    expect(episode.airedBy(now), isTrue);
    expect(TvEpisode.fromJson({'air_date': '2026-10-17'}).airedBy(now), isTrue);
    expect(
      TvEpisode.fromJson({'air_date': '2026-12-01'}).airedBy(now),
      isFalse,
    );
    expect(() => TvSeason.fromJson({'name': 'x'}), throwsA(isA<TypeError>()));
  });
}
