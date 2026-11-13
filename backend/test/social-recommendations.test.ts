import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { dailyRecommendationLimit, inboxPageSize, maxRecipients } from '../src/social/recommendations';

type Item = {
  id: string;
  from: { handle: string; displayName: string | null; avatar: string | null } | null;
  media: { type: string; id: string; title: string; year: string | null; poster: string | null };
  message: string | null;
  createdAt: number;
  read: boolean;
};

let counter = 0;
const uniqueHandle = () => `rec_${++counter}_${Math.floor(Math.random() * 1e6)}`;
const poster = 'https://image.tmdb.org/t/p/w500/abc_DEF-1.jpg';
const dune = { type: 'movie', id: '438631', title: 'Dune', year: '2021', poster };

async function member(settings: Record<string, unknown> = {}) {
  const account = await signIn();
  const handle = uniqueHandle();
  const response = await call('/api/v1/social/profile', {
    method: 'PUT', token: account.session.accessToken, body: { handle, ...settings },
  });
  expect(response.status).toBe(201);
  const { profile } = (await response.json()) as { profile: { friendCode: string } };
  return { token: account.session.accessToken, id: account.user.id, handle, code: profile.friendCode };
}

type Member = Awaited<ReturnType<typeof member>>;

async function befriend(one: Member, other: Member) {
  await call('/api/v1/social/requests', { method: 'POST', token: one.token, body: { code: other.code } });
  const accepted = await call(`/api/v1/social/requests/${one.handle}/accept`, { method: 'POST', token: other.token, body: {} });
  expect(accepted.status).toBe(200);
}

const send = (token: string, body: Record<string, unknown>) =>
  call('/api/v1/social/recommendations', {
    method: 'POST', token, body: { media: dune, clientId: crypto.randomUUID(), ...body },
  });

async function inbox(token: string, cursor = '') {
  const response = await call(`/api/v1/social/recommendations${cursor ? `?cursor=${cursor}` : ''}`, { token });
  expect(response.status).toBe(200);
  return (await response.json()) as { items: Item[]; cursor: string | null; unread?: number };
}

const rowsBetween = async (sender: string, recipient: string) =>
  (await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM recommendations WHERE sender_id = ? AND recipient_id = ?`)
    .bind(sender, recipient).first<{ n: number }>())!.n;

describe('Sending recommendations', () => {
  it('a friend gets the card and message; the counts show it unread', async () => {
    const ana = await member({ displayName: 'Ana' });
    const ben = await member();
    await befriend(ana, ben);
    const response = await send(ana.token, { recipients: [ben.handle], message: '  You will love this\u0007 ' });
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ sent: [ben.handle], notSent: [] });

    const box = await inbox(ben.token);
    expect(box.unread).toBe(1);
    expect(box.items).toHaveLength(1);
    expect(box.items[0]).toMatchObject({
      from: { handle: ana.handle, displayName: 'Ana', avatar: null },
      media: dune,
      message: 'You will love this',
      read: false,
    });
    const profile = await call('/api/v1/social/profile', { token: ben.token });
    expect(((await profile.json()) as { counts: { unread: number } }).counts.unread).toBe(1);
    // Nothing lands in the sender's own inbox.
    expect((await inbox(ana.token)).items).toEqual([]);
  });

  it('strangers, blocked people, unknown handles and friends who do not accept are all just not sent', async () => {
    const ana = await member();
    const friend = await member();
    const closed = await member({ allowRecommendations: false });
    const blocked = await member();
    const stranger = await member();
    await befriend(ana, friend);
    await befriend(ana, closed);
    await befriend(ana, blocked);
    await call('/api/v1/social/blocks', { method: 'POST', token: blocked.token, body: { handle: ana.handle } });

    const response = await send(ana.token, {
      recipients: [friend.handle, closed.handle, blocked.handle, stranger.handle, 'nobody_at_all'],
    });
    const body = (await response.json()) as { sent: string[]; notSent: string[] };
    expect(body.sent).toEqual([friend.handle]);
    expect(body.notSent.sort()).toEqual(
      [closed.handle, blocked.handle, stranger.handle, 'nobody_at_all'].map((h) => h.toLowerCase()).sort(),
    );
    for (const other of [closed, blocked, stranger]) {
      expect(await rowsBetween(ana.id, other.id), other.handle).toBe(0);
    }
  });

  it('a retry with the same clientId sends once and counts once', async () => {
    const ana = await member();
    const ben = await member();
    await befriend(ana, ben);
    const clientId = crypto.randomUUID();
    expect((await send(ana.token, { recipients: [ben.handle], clientId })).status).toBe(201);
    const again = await send(ana.token, { recipients: [ben.handle], clientId });
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ sent: [ben.handle], notSent: [] });
    expect(await rowsBetween(ana.id, ben.id)).toBe(1);
    const today = Math.floor(Date.now() / (24 * 60 * 60 * 1000));
    const used = await testEnv.DB.prepare(`SELECT recommendations FROM social_counters WHERE user_id = ? AND day = ?`)
      .bind(ana.id, today).first<{ recommendations: number }>();
    expect(used?.recommendations).toBe(1);
  });

  it('the same title again refreshes the one card: new message, unread again', async () => {
    const ana = await member();
    const ben = await member();
    await befriend(ana, ben);
    await send(ana.token, { recipients: [ben.handle], message: 'first' });
    await call('/api/v1/social/recommendations/read', { method: 'POST', token: ben.token, body: {} });
    await send(ana.token, { recipients: [ben.handle], message: 'second' });
    const box = await inbox(ben.token);
    expect(box.items).toHaveLength(1);
    expect(box.items[0]).toMatchObject({ message: 'second', read: false });
  });

  it('checks every field', async () => {
    const ana = await member();
    const ben = await member();
    await befriend(ana, ben);
    const bad: Record<string, unknown>[] = [
      { recipients: [] },
      { recipients: Array.from({ length: maxRecipients + 1 }, (_, i) => `someone_${i}`) },
      { recipients: ["x'; drop"] },
      { recipients: [ben.handle], media: { ...dune, type: 'person' } },
      { recipients: [ben.handle], media: { ...dune, id: '0' } },
      { recipients: [ben.handle], media: { ...dune, title: '' } },
      { recipients: [ben.handle], media: { ...dune, year: '21' } },
      { recipients: [ben.handle], media: { ...dune, poster: 'https://evil.example/x.jpg' } },
      { recipients: [ben.handle], message: 'x'.repeat(201) },
      { recipients: [ben.handle], message: 'watch at https://spam' },
      { recipients: [ben.handle], message: 'see spam.com' },
      { recipients: [ben.handle], clientId: 'short' },
    ];
    for (const body of bad) {
      const response = await send(ana.token, body);
      expect(response.status, JSON.stringify(body).slice(0, 80)).toBe(400);
    }
    expect(await rowsBetween(ana.id, ben.id)).toBe(0);
  });

  it('a daily limit on recipients', async () => {
    const ana = await member();
    const ben = await member();
    await befriend(ana, ben);
    const today = Math.floor(Date.now() / (24 * 60 * 60 * 1000));
    // Sending the friend request already made today's row.
    await testEnv.DB.prepare(
      `INSERT INTO social_counters (user_id, day, recommendations) VALUES (?1, ?2, ?3)
       ON CONFLICT (user_id, day) DO UPDATE SET recommendations = ?3`,
    ).bind(ana.id, today, dailyRecommendationLimit).run();
    const response = await send(ana.token, { recipients: [ben.handle] });
    expect(response.status).toBe(429);
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe('recommendation_limit');
  });

  it('needs Friends on', async () => {
    const off = await signIn();
    const response = await send(off.session.accessToken, { recipients: ['someone_here'] });
    expect(response.status).toBe(409);
    expect((await call('/api/v1/social/recommendations', { token: off.session.accessToken })).status).toBe(409);
  });
});

describe('The inbox', () => {
  it('mark read and remove act only on my own', async () => {
    const ana = await member();
    const ben = await member();
    await befriend(ana, ben);
    await send(ana.token, { recipients: [ben.handle] });
    await send(ana.token, { recipients: [ben.handle], media: { ...dune, id: '693134', title: 'Dune: Part Two', year: '2024' } });
    const [first, second] = (await inbox(ben.token)).items;

    // Ana, the sender, can neither mark nor remove Ben's copies.
    const marked = await call('/api/v1/social/recommendations/read', { method: 'POST', token: ana.token, body: { ids: [first.id] } });
    expect(((await marked.json()) as { marked: number }).marked).toBe(0);
    expect((await call(`/api/v1/social/recommendations/${first.id}`, { method: 'DELETE', token: ana.token })).status).toBe(404);

    await call('/api/v1/social/recommendations/read', { method: 'POST', token: ben.token, body: { ids: [first.id] } });
    let box = await inbox(ben.token);
    expect(box.unread).toBe(1);
    expect(box.items.find((item) => item.id === first.id)?.read).toBe(true);
    await call('/api/v1/social/recommendations/read', { method: 'POST', token: ben.token, body: {} });
    expect((await inbox(ben.token)).unread).toBe(0);

    expect((await call(`/api/v1/social/recommendations/${second.id}`, { method: 'DELETE', token: ben.token })).status).toBe(200);
    box = await inbox(ben.token);
    expect(box.items.map((item) => item.id)).toEqual([first.id]);
    expect((await call('/api/v1/social/recommendations/read', { method: 'POST', token: ben.token, body: { ids: ['nope'] } })).status).toBe(400);
    expect((await call('/api/v1/social/recommendations/not-an-id', { method: 'DELETE', token: ben.token })).status).toBe(404);
  });

  it('kept after unfriending; the sender shows as gone after they leave Friends', async () => {
    const ana = await member();
    const ben = await member();
    await befriend(ana, ben);
    await send(ana.token, { recipients: [ben.handle] });
    await call(`/api/v1/social/friends/${ana.handle}`, { method: 'DELETE', token: ben.token });
    expect((await inbox(ben.token)).items).toHaveLength(1);
    await call('/api/v1/social/profile', { method: 'DELETE', token: ana.token });
    const [item] = (await inbox(ben.token)).items;
    expect(item.from).toBeNull();
    expect(item.media.title).toBe('Dune');
  });

  it('pages of 30, newest first', async () => {
    const ana = await member();
    const ben = await member();
    await befriend(ana, ben);
    const statements = Array.from({ length: inboxPageSize + 2 }, (_, index) =>
      testEnv.DB.prepare(
        `INSERT INTO recommendations (id, sender_id, recipient_id, media_key, title, client_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ).bind(crypto.randomUUID(), ana.id, ben.id, `movie:${index + 1}`, `Title ${index}`, crypto.randomUUID(), 1_000 + Math.floor(index / 2)));
    await testEnv.DB.batch(statements);
    const first = await inbox(ben.token);
    expect(first.items).toHaveLength(inboxPageSize);
    const second = await inbox(ben.token, first.cursor!);
    expect(second.items).toHaveLength(2);
    expect(second.cursor).toBeNull();
    expect(second.unread).toBeUndefined();
    const ids = [...first.items, ...second.items].map((item) => item.id);
    expect(new Set(ids).size).toBe(inboxPageSize + 2);
    const times = [...first.items, ...second.items].map((item) => item.createdAt);
    expect(times).toEqual([...times].sort((x, y) => y - x));
    expect((await call('/api/v1/social/recommendations?cursor=1%20OR%201', { token: ben.token })).status).toBe(400);
  });

  it('the sent list names the friend and never says whether it was read', async () => {
    const ana = await member();
    const ben = await member({ displayName: 'Ben' });
    await befriend(ana, ben);
    await send(ana.token, { recipients: [ben.handle], message: 'hi' });
    const response = await call('/api/v1/social/recommendations/sent', { token: ana.token });
    const { items } = (await response.json()) as { items: Record<string, unknown>[] };
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ to: { handle: ben.handle, displayName: 'Ben' }, media: dune, message: 'hi' });
    expect(items[0]).not.toHaveProperty('read');
    const text = JSON.stringify(items);
    expect(text).not.toContain(ben.id);
    expect(text).not.toContain(ana.id);
  });
});
