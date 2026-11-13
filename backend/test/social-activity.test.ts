import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { defaultExpiryMs, maxExpiryMs, minExpiryMs } from '../src/social/activity';

let counter = 0;
const uniqueHandle = () => `act_${++counter}_${Math.floor(Math.random() * 1e6)}`;
const poster = 'https://image.tmdb.org/t/p/w500/dune.jpg';
const dune = { type: 'movie', id: '438631', title: 'Dune', poster };
const dark = { type: 'series', id: '70523', title: 'Dark' };

async function member(settings: Record<string, unknown> = {}) {
  const account = await signIn();
  const handle = uniqueHandle();
  const response = await call('/api/v1/social/profile', {
    method: 'PUT', token: account.session.accessToken, body: { handle, ...settings },
  });
  const { profile } = (await response.json()) as { profile: { friendCode: string } };
  return { token: account.session.accessToken, id: account.user.id, handle, code: profile.friendCode };
}

type Member = Awaited<ReturnType<typeof member>>;

async function befriend(one: Member, other: Member) {
  await call('/api/v1/social/requests', { method: 'POST', token: one.token, body: { code: other.code } });
  await call(`/api/v1/social/requests/${one.handle}/accept`, { method: 'POST', token: other.token, body: {} });
}

const publish = (token: string, body: Record<string, unknown>) =>
  call('/api/v1/social/activity', { method: 'PUT', token, body });

type Watching = {
  person: { handle: string };
  media: Record<string, unknown>;
  season: number | null;
  episode: number | null;
  startedAt: number;
};

async function watching(token: string): Promise<Watching[]> {
  const response = await call('/api/v1/social/activity', { token });
  expect(response.status).toBe(200);
  return ((await response.json()) as { watching: Watching[] }).watching;
}

const row = (userId: string) =>
  testEnv.DB.prepare(`SELECT * FROM current_activity WHERE user_id = ?`).bind(userId)
    .first<{ started_at: number; updated_at: number; expires_at: number }>();

describe('Watching now', () => {
  it('nothing is published unless its owner shares activity', async () => {
    const ana = await member();
    const response = await publish(ana.token, { media: dune });
    expect(response.status).toBe(409);
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe('sharing_off');
    expect(await row(ana.id)).toBeNull();
    const off = await signIn();
    expect((await publish(off.session.accessToken, { media: dune })).status).toBe(409);
    expect((await call('/api/v1/social/activity', { token: off.session.accessToken })).status).toBe(409);
  });

  it('friends see it; strangers do not; clearing ends it', async () => {
    const ana = await member({ shareActivity: true });
    const ben = await member();
    const eve = await member();
    await befriend(ana, ben);
    expect((await publish(ana.token, { media: dark, season: 1, episode: 3, remainingMs: 40 * 60 * 1000 })).status).toBe(200);

    const seen = await watching(ben.token);
    expect(seen).toEqual([{
      person: { handle: ana.handle, displayName: null, avatar: null },
      media: { type: 'series', id: '70523', title: 'Dark', poster: null },
      season: 1,
      episode: 3,
      startedAt: expect.any(Number),
    }]);
    expect(JSON.stringify(seen)).not.toContain(ana.id);
    expect(await watching(eve.token)).toEqual([]);
    // Not shown to the owner as a friend's.
    expect(await watching(ana.token)).toEqual([]);

    expect((await call('/api/v1/social/activity', { method: 'DELETE', token: ana.token })).status).toBe(200);
    expect(await watching(ben.token)).toEqual([]);
  });

  it('the server sets the expiry, within bounds', async () => {
    const ana = await member({ shareActivity: true });
    const before = Date.now();
    await publish(ana.token, { media: dune });
    let saved = (await row(ana.id))!;
    expect(saved.expires_at - saved.updated_at).toBe(defaultExpiryMs);
    await publish(ana.token, { media: dune, remainingMs: 0 });
    saved = (await row(ana.id))!;
    expect(saved.expires_at - saved.updated_at).toBe(minExpiryMs);
    await publish(ana.token, { media: dune, remainingMs: 99 * 60 * 60 * 1000 });
    saved = (await row(ana.id))!;
    expect(saved.expires_at - saved.updated_at).toBe(maxExpiryMs);
    expect(saved.updated_at).toBeGreaterThanOrEqual(before);
  });

  it('an expired activity is never shown', async () => {
    const ana = await member({ shareActivity: true });
    const ben = await member();
    await befriend(ana, ben);
    await publish(ana.token, { media: dune });
    await testEnv.DB.prepare(`UPDATE current_activity SET expires_at = ? WHERE user_id = ?`)
      .bind(Date.now() - 1, ana.id).run();
    expect(await watching(ben.token)).toEqual([]);
  });

  it('the same episode keeps its start; another starts again', async () => {
    const ana = await member({ shareActivity: true });
    await publish(ana.token, { media: dark, season: 1, episode: 1 });
    await testEnv.DB.prepare(`UPDATE current_activity SET started_at = 5 WHERE user_id = ?`).bind(ana.id).run();
    await publish(ana.token, { media: dark, season: 1, episode: 1 });
    expect((await row(ana.id))!.started_at).toBe(5);
    await publish(ana.token, { media: dark, season: 1, episode: 2 });
    expect((await row(ana.id))!.started_at).toBeGreaterThan(5);
  });

  it('turning sharing off hides it at once, and a stale row with sharing off never shows', async () => {
    const ana = await member({ shareActivity: true });
    const ben = await member();
    await befriend(ana, ben);
    await publish(ana.token, { media: dune });
    await call('/api/v1/social/profile', { method: 'PUT', token: ana.token, body: { shareActivity: false } });
    expect(await watching(ben.token)).toEqual([]);
    expect(await row(ana.id)).toBeNull();
    // A row left behind (it cannot be, but if it were) stays hidden.
    await testEnv.DB.prepare(
      `INSERT INTO current_activity (user_id, media_key, title, started_at, updated_at, expires_at)
       VALUES (?, 'movie:1', 'X', 1, 1, ?)`,
    ).bind(ana.id, Date.now() + 60_000).run();
    expect(await watching(ben.token)).toEqual([]);
  });

  it('removing or blocking a friend hides it', async () => {
    const ana = await member({ shareActivity: true });
    const ben = await member();
    const cara = await member();
    await befriend(ana, ben);
    await befriend(ana, cara);
    await publish(ana.token, { media: dune });
    await call(`/api/v1/social/friends/${ana.handle}`, { method: 'DELETE', token: ben.token });
    expect(await watching(ben.token)).toEqual([]);
    await call('/api/v1/social/blocks', { method: 'POST', token: ana.token, body: { handle: cara.handle } });
    expect(await watching(cara.token)).toEqual([]);
  });

  it('checks what is sent', async () => {
    const ana = await member({ shareActivity: true });
    for (const body of [
      {},
      { media: { ...dune, type: 'person' } },
      { media: { ...dune, poster: 'https://evil.example/x.jpg' } },
      { media: dark, season: -1 },
      { media: dark, episode: 1.5 },
      { media: dune, remainingMs: -5 },
    ]) {
      expect((await publish(ana.token, body)).status, JSON.stringify(body)).toBe(400);
    }
    expect(await row(ana.id)).toBeNull();
  });
});
