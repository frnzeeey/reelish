import { describe, expect, it } from 'vitest';
import { call, fakeUpstream, jsonResponse, testEnv } from './helpers';
import { sha256 } from '../src/crypto';

type ErrorBody = { error: { code: string } };
const codeOf = async (response: Response) => ((await response.json()) as ErrorBody).error.code;

type Started = { pollToken: string; authorizeUrl: string; expiresIn: number; interval: number };

async function start(platform = 'android'): Promise<Started & { state: string; url: URL }> {
  const response = await call('/api/v1/auth/web/start', { body: { platform, deviceName: 'Pixel' } });
  expect(response.status).toBe(200);
  const body = (await response.json()) as Started;
  const url = new URL(body.authorizeUrl);
  return { ...body, url, state: url.searchParams.get('state')! };
}

const callback = (query: Record<string, string>) =>
  call(`/api/v1/auth/web/callback?${new URLSearchParams(query)}`);

const poll = (pollToken: string) => call('/api/v1/auth/web/poll', { body: { pollToken } });

/** Fakes Trakt's token exchange and account lookup; records exchanges. */
function fakeTrakt(options: { tokenStatus?: number; uuid?: string; rateLimited?: number; retryAfter?: string } = {}) {
  const exchanges: Record<string, string>[] = [];
  let limited = options.rateLimited ?? 0;
  const calls = fakeUpstream((url, init) => {
    if (url.pathname === '/oauth/token') {
      exchanges.push(JSON.parse(String(init.body)));
      if (limited > 0) {
        limited--;
        return new Response('', { status: 429, headers: { 'Retry-After': options.retryAfter ?? '1' } });
      }
      if ((options.tokenStatus ?? 200) !== 200) return new Response('', { status: options.tokenStatus });
      return jsonResponse({
        access_token: 'trakt-web-access',
        refresh_token: 'trakt-web-refresh',
        expires_in: 86400,
        created_at: Math.floor(Date.now() / 1000),
        scope: 'public',
      });
    }
    if (url.pathname === '/users/settings') {
      return jsonResponse({ user: { username: 'webviewer', ids: { uuid: options.uuid ?? crypto.randomUUID() } } });
    }
    return new Response('unexpected', { status: 500 });
  });
  return { exchanges, calls };
}

describe('Trakt browser sign-in', () => {
  it('builds a Trakt authorize URL with state, PKCE and the API callback', async () => {
    const started = await start();
    expect(started.url.origin + started.url.pathname).toBe('https://trakt.tv/oauth/authorize');
    const query = started.url.searchParams;
    expect(query.get('response_type')).toBe('code');
    expect(query.get('client_id')).toBe('test-trakt-client-id');
    expect(query.get('redirect_uri')).toBe('https://api.reelish.test/api/v1/auth/web/callback');
    expect(query.get('code_challenge_method')).toBe('S256');
    expect(query.get('code_challenge')).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(started.state).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(started.state).not.toBe(started.pollToken);
    expect(started.authorizeUrl).not.toContain('client_secret');
    expect(started.authorizeUrl).not.toContain(started.pollToken);
  });

  it('stores only hashes and an encrypted verifier', async () => {
    const started = await start();
    const row = await testEnv.DB.prepare(`SELECT * FROM web_authorizations WHERE state_hash = ?`)
      .bind(await sha256(started.state)).first<Record<string, string>>();
    expect(row).not.toBeNull();
    const stored = JSON.stringify(row);
    expect(stored).not.toContain(started.state);
    expect(stored).not.toContain(started.pollToken);
    expect(row!.verifier_enc.startsWith('v1.')).toBe(true);
  });

  it('signs in: callback exchanges the code with the verifier, the poll gets the session', async () => {
    const started = await start('windows');
    expect((await poll(started.pollToken)).status).toBe(202);

    const { exchanges } = fakeTrakt({ uuid: 'web-uuid-1' });
    const page = await callback({ code: 'trakt-code', state: started.state });
    expect(page.status).toBe(200);
    expect(page.headers.get('Content-Type')).toContain('text/html');
    expect(page.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
    expect(page.headers.get('Referrer-Policy')).toBe('no-referrer');
    const html = await page.text();
    expect(html).toContain('signed in');
    expect(html).not.toContain('<script');

    expect(exchanges).toHaveLength(1);
    const exchange = exchanges[0];
    expect(exchange.grant_type).toBe('authorization_code');
    expect(exchange.code).toBe('trakt-code');
    expect(exchange.client_secret).toBe('test-trakt-client-secret');
    expect(exchange.redirect_uri).toBe('https://api.reelish.test/api/v1/auth/web/callback');
    // The verifier hashes to the challenge sent to Trakt.
    expect(await sha256(exchange.code_verifier)).toBe(started.url.searchParams.get('code_challenge'));

    const done = await poll(started.pollToken);
    expect(done.status).toBe(200);
    const body = (await done.json()) as { status: string; session: { accessToken: string }; user: { username: string } };
    expect(body.status).toBe('authorized');
    expect(body.user.username).toBe('webviewer');
    expect(JSON.stringify(body)).not.toContain('trakt-web-access');

    const me = await call('/api/v1/me', { token: body.session.accessToken });
    expect(me.status).toBe(200);
    // Collected once: the poll token is spent.
    expect((await poll(started.pollToken)).status).toBe(404);
  });

  it('claims each state once: a replayed callback does not exchange again', async () => {
    const started = await start();
    const { exchanges } = fakeTrakt();
    expect((await callback({ code: 'c1', state: started.state })).status).toBe(200);
    const replay = await callback({ code: 'c2', state: started.state });
    expect(replay.status).toBe(400);
    expect(await replay.text()).toContain('expired');
    expect(exchanges).toHaveLength(1);
  });

  it('a declined sign-in reaches the app as sign_in_denied', async () => {
    const started = await start();
    const calls = fakeUpstream(() => new Response('unexpected', { status: 500 }));
    const page = await callback({ error: 'access_denied', state: started.state });
    expect(page.status).toBe(400);
    expect(await page.text()).toContain('cancelled');
    expect(calls).toHaveLength(0);
    const answer = await poll(started.pollToken);
    expect(answer.status).toBe(403);
    expect(await codeOf(answer)).toBe('sign_in_denied');
  });

  it('waits out a short Trakt rate limit and finishes the sign-in', async () => {
    const started = await start();
    const { exchanges } = fakeTrakt({ rateLimited: 1 });
    expect((await callback({ code: 'trakt-code', state: started.state })).status).toBe(200);
    // The same unused code, sent again after Retry-After.
    expect(exchanges.map((e) => e.code)).toEqual(['trakt-code', 'trakt-code']);
    expect((await poll(started.pollToken)).status).toBe(200);
  });

  it('does not wait out a long Trakt rate limit', async () => {
    const started = await start();
    const { exchanges } = fakeTrakt({ rateLimited: 1, retryAfter: '60' });
    expect((await callback({ code: 'trakt-code', state: started.state })).status).toBe(400);
    expect(exchanges).toHaveLength(1);
    expect(await codeOf(await poll(started.pollToken))).toBe('sign_in_failed');
  });

  it('a rejected code fails the sign-in without a session', async () => {
    const started = await start();
    fakeTrakt({ tokenStatus: 401 });
    expect((await callback({ code: 'bad', state: started.state })).status).toBe(400);
    const answer = await poll(started.pollToken);
    expect(await codeOf(answer)).toBe('sign_in_failed');
  });

  it('unknown or malformed states show the expired page and never reflect input', async () => {
    const calls = fakeUpstream(() => new Response('unexpected', { status: 500 }));
    const unknown = await callback({ code: 'x', state: 'A'.repeat(43) });
    expect(unknown.status).toBe(400);
    const hostile = await callback({ code: '<script>alert(1)</script>', state: '<img src=x>' });
    const html = await hostile.text();
    expect(html).not.toContain('<script>alert');
    expect(html).not.toContain('<img');
    expect(calls).toHaveLength(0);
  });

  it('an expired sign-in cannot be completed', async () => {
    const started = await start();
    await testEnv.DB.prepare(`UPDATE web_authorizations SET expires_at = 0 WHERE state_hash = ?`)
      .bind(await sha256(started.state)).run();
    const calls = fakeUpstream(() => new Response('unexpected', { status: 500 }));
    expect((await callback({ code: 'c', state: started.state })).status).toBe(400);
    expect(calls).toHaveLength(0);
    expect(await codeOf(await poll(started.pollToken))).toBe('sign_in_expired');
  });

  it('is unavailable, not broken, when PUBLIC_URL is unset', async () => {
    const saved = testEnv.PUBLIC_URL;
    testEnv.PUBLIC_URL = undefined;
    try {
      const response = await call('/api/v1/auth/web/start', { body: { platform: 'android' } });
      expect(response.status).toBe(503);
      expect(await codeOf(response)).toBe('web_sign_in_unavailable');
    } finally {
      testEnv.PUBLIC_URL = saved;
    }
  });
});
