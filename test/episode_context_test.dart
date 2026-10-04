import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_context.dart';

Map<String, dynamic> _episode(
  int season,
  int episode, {
  String name = '',
  String? airDate = '2024-01-01',
}) => {
  'season_number': season,
  'episode_number': episode,
  'name': name,
  'air_date': ?airDate,
};

void main() {
  final today = DateTime(2026, 10, 4);

  test('titles the current and next episode', () {
    final context = EpisodeContext.fromTmdb(
      [
        _episode(2, 4, name: 'The Crossing'),
        _episode(2, 3, name: 'The Path'),
        _episode(1, 9, name: 'Finale One'),
      ],
      season: 2,
      episode: 3,
      today: today,
    )!;
    expect(context.current.label, 'S2 · E3 · The Path');
    expect(context.next?.label, 'S2 · E4 · The Crossing');
  });

  test('rolls over to the next season', () {
    final context = EpisodeContext.fromTmdb(
      [_episode(1, 9), _episode(2, 1, name: 'Return')],
      season: 1,
      episode: 9,
      today: today,
    )!;
    expect(context.next?.label, 'S2 · E1 · Return');
    expect(context.current.label, 'S1 · E9');
  });

  test('offers nothing at the finale', () {
    final context = EpisodeContext.fromTmdb(
      [_episode(1, 1), _episode(1, 2)],
      season: 1,
      episode: 2,
      today: today,
    )!;
    expect(context.next, isNull);
  });

  test('does not offer an episode that has not aired', () {
    final context = EpisodeContext.fromTmdb(
      [_episode(3, 5), _episode(3, 6, airDate: '2026-10-11')],
      season: 3,
      episode: 5,
      today: today,
    )!;
    expect(context.next, isNull);
  });

  test('an unknown air date does not hide the next episode', () {
    final context = EpisodeContext.fromTmdb(
      [_episode(1, 1), _episode(1, 2, airDate: null)],
      season: 1,
      episode: 1,
      today: today,
    )!;
    expect(context.next?.code, 'S1 · E2');
  });

  test('returns null when the current episode is not listed', () {
    expect(
      EpisodeContext.fromTmdb(
        [_episode(1, 1)],
        season: 4,
        episode: 2,
        today: today,
      ),
      isNull,
    );
  });
}
