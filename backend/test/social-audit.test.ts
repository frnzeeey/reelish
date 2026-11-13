// Phase 7 audit: every Friends route refuses a missing or ended session and a
// body that is not JSON, nothing names a person in the request log, and an
// ex-friend no longer sees what the other changes.
import { describe, expect, it, vi } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { maskPath } from '../src/index';

const id24 = 'a'.repeat(24);
const uuid = '00000000-0000-4000-8000-000000000000';

/** Every Friends route, with a body where it takes one. */
const routes: [string, string, unknown?][] = [
  ['GET', '/social/profile'],
  ['PUT', '/social/profile', { handle: 'someone_here' }],
  ['DELETE', '/social/profile'],
  ['POST', '/social/profile/code', {}],
  ['POST', '/social/requests', { code: 'ABCD2345' }],
  ['POST', '/social/requests/someone_here/accept', {}],
  ['POST', '/social/requests/someone_here/decline', {}],
  ['DELETE', '/social/requests/someone_here'],
  ['GET', '/social/friends'],
  ['GET', '/social/friends/someone_here'],
  ['DELETE', '/social/friends/someone_here'],
  ['GET', `/social/friends/someone_here/collections/${id24}`],
  ['GET', '/social/blocks'],
  ['POST', '/social/blocks', { handle: 'someone_here' }],
  ['DELETE', '/social/blocks/someone_here'],
  ['POST', '/social/reports', { handle: 'someone_here', reason: 'spam' }],
  ['GET', '/social/recommendations'],
  ['POST', '/social/recommendations', { recipients: ['someone_here'], media: { type: 'movie', id: '1', title: 'X' }, clientId: uuid }],
  ['GET', '/social/recommendations/sent'],
  ['POST', '/social/recommendations/read', {}],
  ['DELETE', `/social/recommendations/${uuid}`],
  ['GET', '/social/activity'],
  ['PUT', '/social/activity', { media: { type: 'movie', id: '1', title: 'X' } }],
  ['DELETE', '/social/activity'],
];

let counter = 0;
async function member(settings: Record<string, unknown> = {}) {
  const account = await signIn();
  const handle = `aud_${++counter}_${Math.floor(Math.random() * 1e6)}`;
  const response = await call('/api/v1/social/profile', {
    method: 'PUT', token: account.session.accessToken, body: { handle, ...settings },
  });
  const { profile } = (await response.json()) as { profile: { friendCode: string } };
  return { token: account.session.accessToken, handle, code: profile.friendCode };
}

describe('Every Friends route', () => {
  it('refuses a request without a session', async () => {
    for (const [method, path, body] of routes) {
      const response = await call(`/api/v1${path}`, { method, body });
      expect(response.status, `${method} ${path}`).toBe(401);
    }
  });

  it('refuses a session that has ended', async () => {
    const { session } = await signIn();
    await call('/api/v1/auth/logout', { method: 'POST', token: session.accessToken });
    for (const [method, path, body] of routes) {
      const response = await call(`/api/v1${path}`, { method, token: session.accessToken, body });
      expect(response.status, `${method} ${path}`).toBe(401);
    }
  });

  it('takes only JSON bodies where it reads one', async () => {
    const { session } = await signIn();
    // Accept, decline and a new code take no body: whatever is sent is
    // never read.
    const ignored = /\/(accept|decline|code)$/;
    for (const [method, path, body] of routes) {
      if (body === undefined || ignored.test(path)) continue;
      const response = await call(`/api/v1${path}`, {
        method,
        token: session.accessToken,
        headers: { 'Content-Type': 'text/plain' },
        body: undefined,
      });
      // No JSON content type: refused before anything is read (415), or,
      // for routes that need Friends on, the same refusal as any other.
      expect([409, 415], `${method} ${path}`).toContain(response.status);
    }
  });
});

describe('Request log', () => {
  it('never names a person, a party or a record', () => {
    expect(maskPath('/api/v1/social/friends/ben_handle')).toBe('/api/v1/social/friends/:handle');
    expect(maskPath(`/api/v1/social/friends/ben_handle/collections/${id24}`))
      .toBe('/api/v1/social/friends/:handle/collections/:id');
    expect(maskPath('/api/v1/social/requests/ben_handle/accept')).toBe('/api/v1/social/requests/:handle/accept');
    expect(maskPath('/api/v1/social/blocks/ben_handle')).toBe('/api/v1/social/blocks/:handle');
    expect(maskPath(`/api/v1/social/recommendations/${uuid}`)).toBe('/api/v1/social/recommendations/:id');
    expect(maskPath('/api/v1/social/recommendations/sent')).toBe('/api/v1/social/recommendations/sent');
    expect(maskPath('/api/v1/party/12345678/socket')).toBe('/api/v1/party/:code/socket');
    expect(maskPath('/api/v1/social/friends')).toBe('/api/v1/social/friends');
  });

  it('the logged line for a friend page has no handle', async () => {
    const ana = await member();
    const lines: string[] = [];
    vi.spyOn(console, 'log').mockImplementation((line: string) => lines.push(line));
    await call(`/api/v1/social/friends/${ana.handle}`, { token: ana.token });
    vi.restoreAllMocks();
    const requestLine = lines.find((line) => line.includes('"event":"request"'))!;
    expect(requestLine).toContain('/api/v1/social/friends/:handle');
    expect(requestLine).not.toContain(ana.handle);
  });
});

describe('After a friendship ends', () => {
  it("an ex-friend's name and avatar are no longer shown on old cards", async () => {
    const ana = await member({ displayName: 'Ana', avatar: 'avatar2' });
    const ben = await member({ displayName: 'Ben', avatar: 'avatar3' });
    await call('/api/v1/social/requests', { method: 'POST', token: ana.token, body: { code: ben.code } });
    await call(`/api/v1/social/requests/${ana.handle}/accept`, { method: 'POST', token: ben.token, body: {} });
    await call('/api/v1/social/recommendations', {
      method: 'POST',
      token: ana.token,
      body: { recipients: [ben.handle], media: { type: 'movie', id: '1', title: 'X' }, clientId: uuid },
    });
    type Card = { from?: Record<string, unknown>; to?: Record<string, unknown> };
    const inbox = async () =>
      ((await (await call('/api/v1/social/recommendations', { token: ben.token })).json()) as { items: Card[] }).items[0];
    const sent = async () =>
      ((await (await call('/api/v1/social/recommendations/sent', { token: ana.token })).json()) as { items: Card[] }).items[0];

    expect((await inbox()).from).toEqual({ handle: ana.handle, displayName: 'Ana', avatar: 'avatar2' });
    expect((await sent()).to).toEqual({ handle: ben.handle, displayName: 'Ben', avatar: 'avatar3' });

    await call(`/api/v1/social/friends/${ana.handle}`, { method: 'DELETE', token: ben.token });
    await call('/api/v1/social/profile', { method: 'PUT', token: ana.token, body: { displayName: 'Ana New' } });
    expect((await inbox()).from).toEqual({ handle: ana.handle, displayName: null, avatar: null });
    expect((await sent()).to).toEqual({ handle: ben.handle, displayName: null, avatar: null });
  });
});

describe('Names', () => {
  it('a display name cannot pass as Reelish', async () => {
    const ana = await member();
    for (const displayName of ['Reelish Support', 'the reelish team', 'Ｒｅｅｌｉｓｈ']) {
      const response = await call('/api/v1/social/profile', { method: 'PUT', token: ana.token, body: { displayName } });
      expect(response.status, displayName).toBe(400);
    }
  });
});

describe('Follow-up fixes', () => {
  it('handle claims answered "taken" are limited to 10 an hour per account', async () => {
    const owner = await member();
    const { session, user } = await signIn();
    const now = Math.floor(Date.now() / 1000);
    // Nine earlier "taken" answers this hour, one from two hours ago.
    await testEnv.DB.batch([
      ...Array.from({ length: 9 }, () =>
        testEnv.DB.prepare(`INSERT INTO audit_events (user_id, event, created_at) VALUES (?, 'social.handle_taken', ?)`)
          .bind(user.id, now - 60)),
      testEnv.DB.prepare(`INSERT INTO audit_events (user_id, event, created_at) VALUES (?, 'social.handle_taken', ?)`)
        .bind(user.id, now - 2 * 60 * 60),
    ]);
    const tenth = await call('/api/v1/social/profile', { method: 'PUT', token: session.accessToken, body: { handle: owner.handle } });
    expect(tenth.status).toBe(409);
    const eleventh = await call('/api/v1/social/profile', { method: 'PUT', token: session.accessToken, body: { handle: owner.handle } });
    expect(eleventh.status).toBe(429);
    expect(((await eleventh.json()) as { error: { code: string } }).error.code).toBe('too_many_attempts');
    // A free handle is refused too until the hour passes; other changes are not.
    const free = await call('/api/v1/social/profile', { method: 'PUT', token: session.accessToken, body: { handle: `free_${now}` } });
    expect(free.status).toBe(429);
    expect((await call('/api/v1/social/profile', { token: owner.token })).status).toBe(200);
  });

  it('reports about a deleted account keep only the reason and date', async () => {
    const ana = await member();
    const ben = await signIn();
    const benHandle = `gone_${Date.now() % 1e6}`;
    await call('/api/v1/social/profile', { method: 'PUT', token: ben.session.accessToken, body: { handle: benHandle, displayName: 'Ben' } });
    const benCode = ((await (await call('/api/v1/social/profile', { token: ben.session.accessToken })).json()) as { profile: { friendCode: string } }).profile.friendCode;
    await call('/api/v1/social/requests', { method: 'POST', token: ana.token, body: { code: benCode } });
    const report = await call('/api/v1/social/reports', {
      method: 'POST', token: ana.token, body: { handle: benHandle, reason: 'spam', note: 'Ben spams me' },
    });
    const { id } = (await report.json()) as { id: string };
    await call('/api/v1/me', { method: 'DELETE', token: ben.session.accessToken });
    const row = await testEnv.DB.prepare(`SELECT * FROM support_reports WHERE id = ?`).bind(id).first<Record<string, unknown>>();
    expect(row).toMatchObject({ kind: 'person', category: 'spam', title: '@(deleted account)', description: '(account deleted)', diagnostics: '{}' });
    expect(JSON.stringify(row)).not.toContain(ben.user.id);
    expect(JSON.stringify(row)).not.toContain(benHandle);
  });
});
