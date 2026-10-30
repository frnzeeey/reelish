import { describe, expect, it } from 'vitest';
import { call, fakeUpstream, jsonResponse, signIn, testEnv } from './helpers';

type ErrorBody = { error: { code: string } };
const codeOf = async (response: Response) => ((await response.json()) as ErrorBody).error.code;

describe('Trakt device sign-in', () => {
  it('issues a session keyed by the Trakt UUID, not the username', async () => {
    const first = await signIn({ uuid: 'stable-uuid-1', username: 'oldname' });
    expect(first.status).toBe('authorized');
    const renamed = await signIn({ uuid: 'stable-uuid-1', username: 'newname' });
    expect(renamed.user.id).toBe(first.user.id);
    expect(renamed.user.username).toBe('newname');
    const other = await signIn({ uuid: 'stable-uuid-2', username: 'oldname' });
    expect(other.user.id).not.toBe(first.user.id);
  });

  it('keeps Trakt tokens encrypted at rest', async () => {
    const { user } = await signIn();
    const row = await testEnv.DB.prepare(`SELECT * FROM trakt_credentials WHERE user_id = ?`)
      .bind(user.id).first<Record<string, string>>();
    expect(row).not.toBeNull();
    expect(JSON.stringify(row)).not.toContain('trakt-access-');
    expect(JSON.stringify(row)).not.toContain('trakt-refresh-');
    expect(row!.access_token_enc.startsWith('v1.')).toBe(true);
  });

  it('cannot be completed twice with the same poll token', async () => {
    const { pollToken } = await signIn();
    const replay = await call('/api/v1/auth/device/poll', { body: { pollToken } });
    expect(replay.status).toBe(404);
  });

  it('reports pending, honours the polling interval, and slows down on 429', async () => {
    let tokenStatus = 400;
    const calls = fakeUpstream((url) => {
      if (url.pathname === '/oauth/device/code') {
        return jsonResponse({ device_code: 'dc', user_code: 'U', verification_url: 'https://trakt.tv/activate', expires_in: 600, interval: 5 });
      }
      return new Response('', { status: tokenStatus });
    });
    const start = await call('/api/v1/auth/device/start', { body: { platform: 'android_tv' } });
    expect(start.status).toBe(200);
    const started = (await start.json()) as { pollToken: string; userCode: string; interval: number };
    expect(started.userCode).toBe('U');
    expect(JSON.stringify(started)).not.toContain('dc');

    // Too early: answered locally, Trakt is not asked.
    const early = await call('/api/v1/auth/device/poll', { body: { pollToken: started.pollToken } });
    expect(early.status).toBe(202);
    expect(calls.filter((c) => c.url.pathname === '/oauth/device/token')).toHaveLength(0);

    await testEnv.DB.prepare(`UPDATE device_authorizations SET next_poll_at = 0`).run();
    expect((await call('/api/v1/auth/device/poll', { body: { pollToken: started.pollToken } })).status).toBe(202);

    tokenStatus = 429;
    await testEnv.DB.prepare(`UPDATE device_authorizations SET next_poll_at = 0`).run();
    const slowed = await call('/api/v1/auth/device/poll', { body: { pollToken: started.pollToken } });
    expect(((await slowed.json()) as { interval: number }).interval).toBe(10);
  });

  it('ends the sign-in when Trakt says denied or expired', async () => {
    for (const [status, expected, code] of [[418, 403, 'sign_in_denied'], [410, 410, 'sign_in_expired']] as const) {
      fakeUpstream((url) => url.pathname === '/oauth/device/code'
        ? jsonResponse({ device_code: 'dc', user_code: 'U', verification_url: 'https://trakt.tv/activate', expires_in: 600, interval: 1 })
        : new Response('', { status }));
      const start = await call('/api/v1/auth/device/start', { body: { platform: 'windows' } });
      const { pollToken } = (await start.json()) as { pollToken: string };
      await testEnv.DB.prepare(`UPDATE device_authorizations SET next_poll_at = 0`).run();
      const poll = await call('/api/v1/auth/device/poll', { body: { pollToken } });
      expect(poll.status).toBe(expected);
      expect(await codeOf(poll)).toBe(code);
      expect((await call('/api/v1/auth/device/poll', { body: { pollToken } })).status).toBe(404);
    }
  });

  it('refuses an expired sign-in without asking Trakt', async () => {
    fakeUpstream(() => jsonResponse({ device_code: 'dc', user_code: 'U', verification_url: 'https://trakt.tv/activate', expires_in: 600, interval: 1 }));
    const start = await call('/api/v1/auth/device/start', { body: { platform: 'android' } });
    const { pollToken } = (await start.json()) as { pollToken: string };
    await testEnv.DB.prepare(`UPDATE device_authorizations SET expires_at = 1`).run();
    const poll = await call('/api/v1/auth/device/poll', { body: { pollToken } });
    expect(poll.status).toBe(410);
  });

  it('refuses an account Trakt returns without a stable id', async () => {
    fakeUpstream((url) => {
      if (url.pathname === '/oauth/device/code') {
        return jsonResponse({ device_code: 'dc', user_code: 'U', verification_url: 'https://trakt.tv/activate', expires_in: 600, interval: 1 });
      }
      if (url.pathname === '/oauth/device/token') {
        return jsonResponse({ access_token: 'a', refresh_token: 'r', expires_in: 86400, created_at: 1 });
      }
      return jsonResponse({ user: { username: 'noid', ids: { slug: 'noid' } } });
    });
    const start = await call('/api/v1/auth/device/start', { body: { platform: 'android' } });
    const { pollToken } = (await start.json()) as { pollToken: string };
    await testEnv.DB.prepare(`UPDATE device_authorizations SET next_poll_at = 0`).run();
    const poll = await call('/api/v1/auth/device/poll', { body: { pollToken } });
    expect(poll.status).toBe(502);
    expect(await codeOf(poll)).toBe('trakt_identity_unavailable');
  });

  it('refuses a verification URL that is not Trakt', async () => {
    fakeUpstream(() => jsonResponse({ device_code: 'dc', user_code: 'U', verification_url: 'https://evil.example/activate', expires_in: 600, interval: 1 }));
    const start = await call('/api/v1/auth/device/start', { body: { platform: 'android' } });
    expect(start.status).toBe(502);
  });

  it('validates the request body', async () => {
    expect((await call('/api/v1/auth/device/start', { body: { platform: 'ios' } })).status).toBe(400);
    expect((await call('/api/v1/auth/device/start', { method: 'POST', headers: { 'Content-Type': 'text/plain' } })).status).toBe(415);
    expect((await call('/api/v1/auth/device/poll', { body: { pollToken: 'short' } })).status).toBe(400);
    const big = await call('/api/v1/auth/device/start', { body: { platform: 'android', deviceName: 'x'.repeat(5000) } });
    expect(big.status).toBe(413);
  });

  it('rate-limits sign-in attempts per IP', async () => {
    fakeUpstream(() => jsonResponse({ device_code: 'dc', user_code: 'U', verification_url: 'https://trakt.tv/activate', expires_in: 600, interval: 1 }));
    const statuses: number[] = [];
    for (let i = 0; i < 25; i++) {
      statuses.push((await call('/api/v1/auth/device/start', { body: { platform: 'android' }, ip: '203.0.113.9' })).status);
    }
    expect(statuses.slice(0, 20).every((status) => status === 200)).toBe(true);
    expect(statuses).toContain(429);
  });
});

describe('Reelish sessions', () => {
  it('rotates refresh tokens and revokes the session when an old one is reused', async () => {
    const { session } = await signIn();
    const first = await call('/api/v1/auth/refresh', { body: { refreshToken: session.refreshToken } });
    expect(first.status).toBe(200);
    const rotated = ((await first.json()) as { session: { refreshToken: string; accessToken: string } }).session;
    expect(rotated.refreshToken).not.toBe(session.refreshToken);

    // The spent token comes back: treated as stolen, the session ends.
    const reuse = await call('/api/v1/auth/refresh', { body: { refreshToken: session.refreshToken } });
    expect(reuse.status).toBe(401);
    expect((await call('/api/v1/auth/refresh', { body: { refreshToken: rotated.refreshToken } })).status).toBe(401);
    expect((await call('/api/v1/me', { token: rotated.accessToken })).status).toBe(401);
  });

  it('logs out this device only, or every device', async () => {
    const phone = await signIn({ uuid: 'multi-device', platform: 'android' });
    const tv = await signIn({ uuid: 'multi-device', platform: 'android_tv' });
    const pc = await signIn({ uuid: 'multi-device', platform: 'windows' });

    const list = await call('/api/v1/sessions', { token: phone.session.accessToken });
    const sessions = ((await list.json()) as { sessions: { platform: string; current: boolean }[] }).sessions;
    expect(sessions.map((s) => s.platform).sort()).toEqual(['android', 'android_tv', 'windows']);
    expect(sessions.filter((s) => s.current)).toHaveLength(1);

    expect((await call('/api/v1/auth/logout', { method: 'POST', token: phone.session.accessToken })).status).toBe(200);
    expect((await call('/api/v1/auth/refresh', { body: { refreshToken: phone.session.refreshToken } })).status).toBe(401);
    expect((await call('/api/v1/me', { token: tv.session.accessToken })).status).toBe(200);

    expect((await call('/api/v1/auth/logout-all', { method: 'POST', token: tv.session.accessToken })).status).toBe(200);
    expect((await call('/api/v1/auth/refresh', { body: { refreshToken: pc.session.refreshToken } })).status).toBe(401);
  });

  it("cannot revoke another account's session", async () => {
    const alice = await signIn();
    const bob = await signIn();
    const attempt = await call(`/api/v1/sessions/${bob.session.sessionId}`, { method: 'DELETE', token: alice.session.accessToken });
    expect(attempt.status).toBe(404);
    expect((await call('/api/v1/me', { token: bob.session.accessToken })).status).toBe(200);
  });

  it('deletes the account, its sessions and its Trakt tokens', async () => {
    const { session, user } = await signIn();
    const calls = fakeUpstream(() => new Response('', { status: 200 }));
    expect((await call('/api/v1/me', { method: 'DELETE', token: session.accessToken })).status).toBe(200);
    expect(calls.map((c) => c.url.pathname)).toEqual(['/oauth/revoke']);
    for (const table of ['users', 'trakt_credentials', 'sessions']) {
      const column = table === 'users' ? 'id' : 'user_id';
      const row = await testEnv.DB.prepare(`SELECT 1 FROM ${table} WHERE ${column} = ?`).bind(user.id).first();
      expect(row, table).toBeNull();
    }
    expect((await call('/api/v1/auth/refresh', { body: { refreshToken: session.refreshToken } })).status).toBe(401);
  });

  it('rejects an expired access token', async () => {
    const { session } = await signIn();
    const realNow = Date.now;
    Date.now = () => realNow() + 16 * 60 * 1000;
    try {
      const response = await call('/api/v1/me', { token: session.accessToken });
      expect(response.status).toBe(401);
      expect(await codeOf(response)).toBe('token_expired');
    } finally {
      Date.now = realNow;
    }
  });

  it('answers unknown routes and health checks safely', async () => {
    expect((await call('/health')).status).toBe(200);
    expect((await call('/api/v2/me')).status).toBe(404);
    const response = await call('/api/v1/nope');
    expect(response.status).toBe(401);
    expect(response.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(response.headers.get('X-Request-Id')).toBeTruthy();
  });
});
