import { describe, expect, it } from 'vitest';
import { call, fakeUpstream, jsonResponse, signIn, testEnv } from './helpers';

type ErrorBody = { error: { code: string } };
const codeOf = async (response: Response) => ((await response.json()) as ErrorBody).error.code;

let nextId = 70000;
/** Fresh TMDB ids per test: the gateway's edge cache outlives a test. */
const ids = (n: number) => Array.from({ length: n }, () => ++nextId);

async function alertToken(accessToken: string): Promise<string> {
  const response = await call('/api/v1/notifications/token', { token: accessToken, body: {} });
  expect(response.status).toBe(200);
  return ((await response.json()) as { token: string }).token;
}

const check = (token: string, body: unknown) =>
  call('/api/v1/notifications/episodes', { body, headers: { Authorization: `Bearer ${token}` } });

function fakeTmdb(popular: number[] = []) {
  return fakeUpstream((url) => {
    if (url.pathname === '/3/tv/popular') {
      return jsonResponse({ page: 1, results: popular.map((id) => ({ id })) });
    }
    const match = /^\/3\/tv\/(\d+)$/.exec(url.pathname);
    if (match) {
      const id = Number(match[1]);
      return jsonResponse({
        id,
        name: `Show ${id}`,
        poster_path: `/p${id}.jpg`,
        last_episode_to_air: { season_number: 2, episode_number: 5, name: 'Finale', air_date: '2026-10-29' },
        next_episode_to_air: { season_number: 3, episode_number: 1, name: '', air_date: '2027-02-01' },
        seasons: [{ season_number: 0 }, { season_number: 1 }, { season_number: 2 }, { season_number: 3 }],
        status: 'Returning Series',
        secret_field: 'not passed on',
      });
    }
    const movie = /^\/3\/movie\/(\d+)$/.exec(url.pathname);
    if (movie) {
      expect(url.searchParams.get('append_to_response')).toBe('credits,external_ids');
      const id = Number(movie[1]);
      return jsonResponse({ id, title: `Film ${id}`, status: 'Post Production', release_date: '2027-05-01', budget: 1 });
    }
    const person = /^\/3\/person\/(\d+)$/.exec(url.pathname);
    if (person) {
      expect(url.searchParams.get('append_to_response')).toBe('combined_credits');
      return jsonResponse({
        id: Number(person[1]),
        name: 'Ada Actor',
        combined_credits: {
          cast: [
            { id: 1, media_type: 'movie', title: 'Lead role', release_date: '2027-03-01', order: 0, character: 'Kate' },
            { id: 2, media_type: 'movie', title: 'Cameo', release_date: '2027-03-01', order: 30, character: 'Barista' },
            { id: 3, media_type: 'movie', title: 'Old film', release_date: '2001-01-01', order: 0, character: 'Kate' },
            { id: 4, media_type: 'tv', name: 'Talk show', first_air_date: '', episode_count: 40, character: 'Self', genre_ids: [10767] },
            { id: 5, media_type: 'tv', name: 'New series', first_air_date: '', episode_count: 8, character: 'Mara' },
            { id: 6, media_type: 'tv', name: 'Guest spot', first_air_date: '', episode_count: 1, character: 'Doctor' },
          ],
          crew: [
            { id: 7, media_type: 'movie', title: 'Her debut', release_date: '', job: 'Director' },
            { id: 8, media_type: 'movie', title: 'Produced', release_date: '', job: 'Producer' },
          ],
        },
      });
    }
    const collection = /^\/3\/collection\/(\d+)$/.exec(url.pathname);
    if (collection) {
      return jsonResponse({
        id: Number(collection[1]),
        name: 'The Saga',
        parts: [
          { id: 11, title: 'Part One', release_date: '2020-01-01', overview: 'not passed on' },
          { id: 12, title: 'Part Two', release_date: '' },
        ],
      });
    }
    return new Response('unexpected', { status: 500 });
  });
}

describe('Episode alert tokens', () => {
  it('are issued per session, stored hashed, and open only the episode check', async () => {
    const { session } = await signIn();
    const token = await alertToken(session.accessToken);
    expect(token).toMatch(/^rnt_[A-Za-z0-9_-]{43}$/);
    const row = await testEnv.DB.prepare(`SELECT notify_hash FROM sessions WHERE id = ?`)
      .bind(session.sessionId).first<{ notify_hash: string }>();
    expect(row!.notify_hash).not.toContain(token);

    // Not a session: account and catalog routes refuse it.
    const headers = { Authorization: `Bearer ${token}` };
    expect((await call('/api/v1/me', { headers })).status).toBe(401);
    expect((await call('/api/v1/tmdb/movie/popular', { headers })).status).toBe(401);
    expect((await call('/api/v1/trakt/watchlist', { headers })).status).toBe(401);
  });

  it('a new token replaces the old one', async () => {
    const { session } = await signIn();
    const first = await alertToken(session.accessToken);
    const second = await alertToken(session.accessToken);
    fakeTmdb();
    expect((await check(first, { series: [] })).status).toBe(401);
    expect((await check(second, { series: [] })).status).toBe(200);
  });

  it('stops working when its session is signed out', async () => {
    const { session } = await signIn();
    const token = await alertToken(session.accessToken);
    await call('/api/v1/auth/logout', { token: session.accessToken, body: {} });
    fakeTmdb();
    const response = await check(token, { series: [] });
    expect(response.status).toBe(401);
    expect(await codeOf(response)).toBe('invalid_token');
  });
});

describe('Episode check', () => {
  it('answers each series’ latest aired episode, and only the fields the app needs', async () => {
    const { session } = await signIn();
    const token = await alertToken(session.accessToken);
    const [a, b] = ids(2);
    fakeTmdb();
    const response = await check(token, { series: [a, b, a] });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { series: Record<string, unknown>[]; popular: unknown[] };
    expect(body.series).toHaveLength(2);
    expect(body.series[0]).toEqual({
      tmdbId: a,
      name: `Show ${a}`,
      poster: `/p${a}.jpg`,
      lastEpisode: { season: 2, episode: 5, name: 'Finale', airDate: '2026-10-29' },
      // Specials are not a season.
      seasons: 3,
      status: 'Returning Series',
      nextEpisode: { season: 3, episode: 1, name: '', airDate: '2027-02-01' },
    });
    expect(body.popular).toEqual([]);
    // Not asked: an older app's answer has nothing new in it.
    expect(body).not.toHaveProperty('movies');
    expect(body).not.toHaveProperty('people');
    expect(body).not.toHaveProperty('collections');
  });

  it('answers movies’ release status, people’s significant new work and collections’ films', async () => {
    const { session } = await signIn();
    const token = await alertToken(session.accessToken);
    const [m, p, c] = ids(3);
    fakeTmdb();
    const response = await check(token, { series: [], movies: [m], people: [p], collections: [c] });
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      movies: unknown[];
      people: { tmdbId: number; name: string; credits: { tmdbId: number; role: string }[] }[];
      collections: unknown[];
    };
    expect(body.movies).toEqual([{ tmdbId: m, title: `Film ${m}`, status: 'Post Production', releaseDate: '2027-05-01' }]);
    expect(body.people[0].name).toBe('Ada Actor');
    // A lead role, a series part and directing; never a cameo, a guest
    // spot, a talk show, producing or old work.
    expect(body.people[0].credits.map((c) => c.tmdbId).sort()).toEqual([1, 5, 7]);
    expect(body.people[0].credits.find((c) => c.tmdbId === 7)!.role).toBe('director');
    expect(body.collections).toEqual([
      {
        tmdbId: c,
        name: 'The Saga',
        parts: [
          { tmdbId: 11, title: 'Part One', releaseDate: '2020-01-01' },
          { tmdbId: 12, title: 'Part Two', releaseDate: '' },
        ],
      },
    ]);
  });

  it('rejects oversized or malformed lists of movies, people and collections', async () => {
    const { session } = await signIn();
    const token = await alertToken(session.accessToken);
    const calls = fakeTmdb();
    const many = (n: number) => Array.from({ length: n }, (_, i) => i + 1);
    for (const [name, value] of [
      ['movies', many(31)],
      ['people', many(16)],
      ['collections', many(16)],
      ['people', ['1']],
    ] as const) {
      const response = await check(token, { series: [], [name]: value });
      expect(response.status).toBe(400);
      expect(await codeOf(response)).toBe(`invalid_${name}`);
    }
    expect(calls).toHaveLength(0);
  });

  it('adds TMDB’s popular series when asked', async () => {
    const { session } = await signIn();
    const token = await alertToken(session.accessToken);
    const popular = ids(3);
    fakeTmdb(popular);
    const body = (await (await check(token, { series: [], popular: true })).json()) as { popular: { tmdbId: number }[] };
    expect(body.popular.map((s) => s.tmdbId)).toEqual(popular);
  });

  it('rejects malformed or oversized lists', async () => {
    const { session } = await signIn();
    const token = await alertToken(session.accessToken);
    const calls = fakeTmdb();
    for (const series of ['all', [0], [-1], ['5'], Array.from({ length: 151 }, (_, i) => i + 1)]) {
      const response = await check(token, { series });
      expect(response.status).toBe(400);
      expect(await codeOf(response)).toBe('invalid_series');
    }
    expect(calls).toHaveLength(0);
  });

  it('refuses requests without a valid alert token', async () => {
    fakeTmdb();
    expect((await check('rnt_' + 'x'.repeat(43), { series: [] })).status).toBe(401);
    const { session } = await signIn();
    // A session access token is not an alert token.
    expect((await check(session.accessToken, { series: [] })).status).toBe(401);
  });
});
