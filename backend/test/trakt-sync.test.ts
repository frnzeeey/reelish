import { describe, expect, it } from 'vitest';
import { traktAccessToken } from '../src/trakt';
import { call, fakeUpstream, jsonResponse, signIn, testEnv } from './helpers';

type ErrorBody = { error: { code: string } };
const codeOf = async (response: Response) => ((await response.json()) as ErrorBody).error.code;

const expire = (userId: string) =>
  testEnv.DB.prepare(`UPDATE trakt_credentials SET expires_at = 1 WHERE user_id = ?`).bind(userId).run();

const refreshed = (n: number) => jsonResponse({
  access_token: `access-${n}`, refresh_token: `refresh-${n}`, expires_in: 86400,
  created_at: Math.floor(Date.now() / 1000),
});

describe('Trakt refresh redirect URIs', () => {
  it('device grants are recorded as out-of-band and refreshed with it', async () => {
    const { user } = await signIn();
    const row = await testEnv.DB.prepare(`SELECT redirect_uri FROM trakt_credentials WHERE user_id = ?`)
      .bind(user.id).first<{ redirect_uri: string }>();
    expect(row!.redirect_uri).toBe('urn:ietf:wg:oauth:2.0:oob');
    await expire(user.id);
    const calls = fakeUpstream(() => refreshed(1));
    expect(await traktAccessToken(testEnv, user.id)).toBe('access-1');
    expect(calls).toHaveLength(1);
    expect(JSON.parse(String(calls[0].init.body)).redirect_uri).toBe('urn:ietf:wg:oauth:2.0:oob');
  });

  it('an older grant tries the callback, then out-of-band, and keeps the one that works', async () => {
    const { user } = await signIn();
    await testEnv.DB.prepare(`UPDATE trakt_credentials SET redirect_uri = '', expires_at = 1 WHERE user_id = ?`)
      .bind(user.id).run();
    const tried: string[] = [];
    fakeUpstream((_, init) => {
      const redirect = JSON.parse(String(init.body)).redirect_uri as string;
      tried.push(redirect);
      return redirect === 'urn:ietf:wg:oauth:2.0:oob'
        ? refreshed(2)
        : new Response('{"error":"invalid_grant"}', { status: 400 });
    });
    expect(await traktAccessToken(testEnv, user.id)).toBe('access-2');
    expect(tried).toEqual([
      'https://api.reelish.test/api/v1/auth/web/callback',
      'urn:ietf:wg:oauth:2.0:oob',
    ]);
    const row = await testEnv.DB.prepare(`SELECT redirect_uri FROM trakt_credentials WHERE user_id = ?`)
      .bind(user.id).first<{ redirect_uri: string }>();
    expect(row!.redirect_uri).toBe('urn:ietf:wg:oauth:2.0:oob');
  });
});

describe('Trakt watchlist', () => {
  it('reads movies and shows as TMDB ids, skipping titles without one', async () => {
    const { session } = await signIn();
    const calls = fakeUpstream((url) => {
      if (url.pathname === '/sync/watchlist/movies') {
        return jsonResponse([
          { listed_at: '2026-10-01T00:00:00.000Z', type: 'movie', movie: { ids: { trakt: 1, tmdb: 550 } } },
          { listed_at: '2026-10-02T00:00:00.000Z', type: 'movie', movie: { ids: { trakt: 2, tmdb: null } } },
        ]);
      }
      if (url.pathname === '/sync/watchlist/shows') {
        return jsonResponse([{ listed_at: '2026-10-03T00:00:00.000Z', type: 'show', show: { ids: { tmdb: 1399 } } }]);
      }
      return new Response('unexpected', { status: 500 });
    });
    const response = await call('/api/v1/trakt/watchlist', { token: session.accessToken });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { items: { type: string; tmdbId: number }[] };
    expect(body.items.map((i) => `${i.type}:${i.tmdbId}`)).toEqual(['movie:550', 'series:1399']);
    // Sent as the user, with their (server-held) Trakt token.
    expect(new Headers(calls[0].init.headers).get('Authorization')).toMatch(/^Bearer trakt-access-/);
    expect(JSON.stringify(body)).not.toContain('trakt-access');
  });

  it('adds and removes titles by TMDB id and reports what Trakt could not find', async () => {
    const { session } = await signIn();
    const bodies: Record<string, unknown> = {};
    fakeUpstream((url, init) => {
      bodies[url.pathname] = JSON.parse(String(init.body));
      if (url.pathname === '/sync/watchlist') {
        return jsonResponse({
          added: { movies: 1, shows: 0 },
          not_found: { movies: [], shows: [{ ids: { tmdb: 999999 } }] },
        }, 201);
      }
      return jsonResponse({ deleted: { movies: 0, shows: 1 }, not_found: { movies: [], shows: [] } });
    });
    const response = await call('/api/v1/trakt/watchlist', {
      token: session.accessToken,
      body: {
        add: [{ type: 'movie', tmdbId: 550 }, { type: 'series', tmdbId: 999999 }],
        remove: [{ type: 'series', tmdbId: 1399 }],
      },
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      added: 1, removed: 1, notFound: [{ type: 'series', tmdbId: 999999 }],
    });
    expect(bodies['/sync/watchlist']).toEqual({
      movies: [{ ids: { tmdb: 550 } }], shows: [{ ids: { tmdb: 999999 } }],
    });
    expect(bodies['/sync/watchlist/remove']).toEqual({ movies: [], shows: [{ ids: { tmdb: 1399 } }] });
  });

  it('rejects malformed or oversized changes without calling Trakt', async () => {
    const { session } = await signIn();
    const calls = fakeUpstream(() => new Response('unexpected', { status: 500 }));
    for (const body of [
      { add: [{ type: 'person', tmdbId: 1 }] },
      { add: [{ type: 'movie', tmdbId: -5 }] },
      { add: [{ type: 'movie', tmdbId: '550' }] },
      { remove: 'all' },
      { add: Array.from({ length: 101 }, (_, i) => ({ type: 'movie', tmdbId: i + 1 })) },
    ]) {
      const response = await call('/api/v1/trakt/watchlist', { token: session.accessToken, body });
      expect(response.status).toBe(400);
      expect(await codeOf(response)).toBe('invalid_watchlist_change');
    }
    expect(calls).toHaveLength(0);
  });

  it('a full Trakt watchlist answers trakt_limit', async () => {
    const { session } = await signIn();
    fakeUpstream(() => new Response('', { status: 420 }));
    const response = await call('/api/v1/trakt/watchlist', {
      token: session.accessToken,
      body: { add: [{ type: 'movie', tmdbId: 550 }] },
    });
    expect(response.status).toBe(409);
    expect(await codeOf(response)).toBe('trakt_limit');
  });

  it('a lost Trakt grant answers 409, never 401 (which would sign the app out)', async () => {
    const { session, user } = await signIn();
    await expire(user.id);
    fakeUpstream(() => new Response('{"error":"invalid_grant"}', { status: 401 }));
    const response = await call('/api/v1/trakt/watchlist', { token: session.accessToken });
    expect(response.status).toBe(409);
    expect(await codeOf(response)).toBe('trakt_reauth_required');
  });

  it('needs a Reelish session', async () => {
    expect((await call('/api/v1/trakt/watchlist')).status).toBe(401);
  });
});
