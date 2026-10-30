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
        secret_field: 'not passed on',
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
    });
    expect(body.popular).toEqual([]);
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
