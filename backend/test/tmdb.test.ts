import { describe, expect, it } from 'vitest';
import { call, fakeUpstream, jsonResponse, signIn } from './helpers';

describe('TMDB gateway', () => {
  it('requires a Reelish session', async () => {
    const calls = fakeUpstream(() => jsonResponse({}));
    const response = await call('/api/v1/tmdb/movie/popular');
    expect(response.status).toBe(401);
    expect(response.headers.get('WWW-Authenticate')).toBe('Bearer');
    expect(calls).toHaveLength(0);
  });

  it('rejects forged and tampered access tokens', async () => {
    const { session } = await signIn();
    const calls = fakeUpstream(() => jsonResponse({}));
    const parts = session.accessToken.split('.');
    const tampered = [parts[0], parts[1], parts[2].slice(0, -2) + 'AA', parts[3]].join('.');
    for (const token of ['ra1.abcdefgh.eyJ9.c2ln', tampered, `${session.accessToken}x`]) {
      expect((await call('/api/v1/tmdb/movie/popular', { token })).status).toBe(401);
    }
    expect(calls).toHaveLength(0);
  });

  it('attaches the credential server-side and never returns it', async () => {
    const { session } = await signIn();
    const calls = fakeUpstream(() => jsonResponse({ page: 1, results: [{ id: 1, title: 'Film' }] }));
    const response = await call('/api/v1/tmdb/movie/popular?page=7', { token: session.accessToken });
    expect(response.status).toBe(200);
    expect(response.headers.get('X-Cache')).toBe('MISS');
    const text = await response.text();
    expect(text).toContain('Film');
    expect(text).not.toContain('test-tmdb-read-token');
    expect(calls).toHaveLength(1);
    expect(calls[0].url.origin).toBe('https://api.themoviedb.org');
    expect(calls[0].url.pathname).toBe('/3/movie/popular');
    expect(calls[0].url.searchParams.has('api_key')).toBe(false);
    expect(new Headers(calls[0].init.headers).get('Authorization')).toBe('Bearer test-tmdb-read-token');
  });

  it('serves repeats from the edge cache, for any user', async () => {
    const first = await signIn();
    const second = await signIn();
    const calls = fakeUpstream(() => jsonResponse({ id: 4242, title: 'Cached' }));
    const path = '/api/v1/tmdb/movie/4242?append_to_response=credits,external_ids';
    expect((await call(path, { token: first.session.accessToken })).headers.get('X-Cache')).toBe('MISS');
    const repeat = await call(path, { token: second.session.accessToken });
    expect(repeat.headers.get('X-Cache')).toBe('HIT');
    expect(await repeat.json()).toEqual({ id: 4242, title: 'Cached' });
    expect(calls).toHaveLength(1);
  });

  it('shares one upstream request between concurrent identical requests', async () => {
    const { session } = await signIn();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const calls = fakeUpstream(async () => { await gate; return jsonResponse({ id: 777 }); });
    const path = '/api/v1/tmdb/tv/777?append_to_response=credits,external_ids';
    const pending = [1, 2, 3].map(() => call(path, { token: session.accessToken }));
    await new Promise((resolve) => setTimeout(resolve, 20));
    release();
    const responses = await Promise.all(pending);
    expect(responses.map((response) => response.status)).toEqual([200, 200, 200]);
    expect(calls).toHaveLength(1);
  });

  it('refuses unlisted routes and parameters before contacting TMDB', async () => {
    const { session } = await signIn();
    const calls = fakeUpstream(() => jsonResponse({}));
    expect((await call('/api/v1/tmdb/account', { token: session.accessToken })).status).toBe(404);
    const bad = await call('/api/v1/tmdb/movie/popular?api_key=x', { token: session.accessToken });
    expect(bad.status).toBe(400);
    expect(((await bad.json()) as { error: { code: string } }).error.code).toBe('invalid_parameter');
    expect((await call('/api/v1/tmdb/movie/popular', { method: 'POST', body: {}, token: session.accessToken })).status).toBe(405);
    expect(calls).toHaveLength(0);
  });

  it('translates upstream failures without leaking details', async () => {
    const { session } = await signIn();
    const cases: [number, number, string][] = [
      [404, 404, 'not_found'],
      [401, 502, 'upstream_unavailable'],
      [429, 503, 'upstream_busy'],
      [500, 502, 'upstream_unavailable'],
    ];
    for (const [upstream, expected, code] of cases) {
      fakeUpstream(() => new Response('{"status_message":"Invalid API key: secret"}', { status: upstream }));
      const response = await call(`/api/v1/tmdb/movie/${9000 + upstream}?append_to_response=credits,external_ids`,
        { token: session.accessToken });
      expect(response.status, `${upstream}`).toBe(expected);
      const body = await response.text();
      expect(body).toContain(code);
      expect(body).not.toContain('secret');
    }
  });

  it('retries a failed upstream once, then succeeds', async () => {
    const { session } = await signIn();
    let attempts = 0;
    const calls = fakeUpstream(() => (++attempts === 1 ? new Response('', { status: 503 }) : jsonResponse({ id: 31337 })));
    const response = await call('/api/v1/tmdb/movie/31337?append_to_response=credits,external_ids',
      { token: session.accessToken });
    expect(response.status).toBe(200);
    expect(calls).toHaveLength(2);
  });

  it('rejects an upstream body that is not JSON', async () => {
    const { session } = await signIn();
    fakeUpstream(() => new Response('<html>oops</html>', { status: 200 }));
    const response = await call('/api/v1/tmdb/movie/5150?append_to_response=credits,external_ids',
      { token: session.accessToken });
    expect(response.status).toBe(502);
  });
});
