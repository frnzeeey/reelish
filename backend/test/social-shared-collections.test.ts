import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { titlesPageSize } from '../src/social/shared-collections';

let counter = 0;
const uniqueHandle = () => `col_${++counter}_${Math.floor(Math.random() * 1e6)}`;
const device = 'device-aaaaaaaa';
const scifi = 'a'.repeat(24);
const secret = 'b'.repeat(24);
const poster = (n: number) => `https://image.tmdb.org/t/p/w500/p${n}.jpg`;

async function member() {
  const account = await signIn();
  const handle = uniqueHandle();
  const response = await call('/api/v1/social/profile', {
    method: 'PUT', token: account.session.accessToken, body: { handle },
  });
  const { profile } = (await response.json()) as { profile: { friendCode: string } };
  return { token: account.session.accessToken, id: account.user.id, handle, code: profile.friendCode };
}

type Member = Awaited<ReturnType<typeof member>>;

async function befriend(one: Member, other: Member) {
  await call('/api/v1/social/requests', { method: 'POST', token: one.token, body: { code: other.code } });
  await call(`/api/v1/social/requests/${one.handle}/accept`, { method: 'POST', token: other.token, body: {} });
}

let seq = 0;
const collection = (key: string, extra: Record<string, unknown> = {}) => ({
  kind: 'collection', key, name: key === scifi ? 'Sci-fi' : 'Secret', order: 1, createdAt: 1, seq: ++seq, at: 1_000 + seq, ...extra,
});
const entry = (collectionId: string, tmdb: number, extra: Record<string, unknown> = {}) => ({
  kind: 'entry', key: `${collectionId}|movie:${tmdb}`, name: `Film ${tmdb}`, year: '2021',
  poster: poster(tmdb), addedAt: tmdb, seq: ++seq, at: 1_000 + seq, ...extra,
});

const push = async (token: string, changes: unknown[]) => {
  const response = await call('/api/v1/collections', { method: 'POST', token, body: { device, changes } });
  expect(response.status).toBe(200);
};

type Shared = { id: string; name: string; description: string | null; count: number; posters: string[] };

async function friendPage(token: string, handle: string) {
  const response = await call(`/api/v1/social/friends/${handle}`, { token });
  return { status: response.status, body: response.status === 200 ? ((await response.json()) as { collections: Shared[] }) : null };
}

const titles = (token: string, handle: string, id: string, cursor = '') =>
  call(`/api/v1/social/friends/${handle}/collections/${id}${cursor ? `?cursor=${cursor}` : ''}`, { token });

/** Ana shares Sci-fi (three titles, the second chosen as cover) and keeps Secret private. */
async function setUp() {
  const ana = await member();
  const ben = await member();
  await befriend(ana, ben);
  await push(ana.token, [
    collection(scifi, { visibility: 'friends', cover: 'movie:2', description: 'Space' }),
    collection(secret),
    entry(scifi, 1), entry(scifi, 2), entry(scifi, 3),
    entry(secret, 9),
  ]);
  return { ana, ben };
}

describe('Shared collections', () => {
  it('a friend sees only shared collections, with counts and the cover first', async () => {
    const { ana, ben } = await setUp();
    const { status, body } = await friendPage(ben.token, ana.handle);
    expect(status).toBe(200);
    expect(body!.collections).toEqual([
      { id: scifi, name: 'Sci-fi', description: 'Space', count: 3, posters: [poster(2), poster(3), poster(1)] },
    ]);

    const response = await titles(ben.token, ana.handle, scifi);
    expect(response.status).toBe(200);
    const page = (await response.json()) as { collection: Shared; items: Record<string, unknown>[]; cursor: string | null };
    expect(page.collection).toMatchObject({ id: scifi, name: 'Sci-fi', count: 3 });
    expect(page.items.map((item) => item.id)).toEqual(['1', '2', '3']);
    expect(page.items[0]).toEqual({ type: 'movie', id: '1', title: 'Film 1', year: '2021', poster: poster(1), addedAt: 1 });
    expect(page.cursor).toBeNull();
    const text = JSON.stringify(page);
    expect(text).not.toContain(ana.id);
    expect(text).not.toContain(device);
  });

  it("a private collection's titles cannot be read, even by id", async () => {
    const { ana, ben } = await setUp();
    expect((await titles(ben.token, ana.handle, secret)).status).toBe(404);
    expect((await titles(ben.token, ana.handle, 'c'.repeat(24))).status).toBe(404);
    expect((await titles(ben.token, ana.handle, 'not-an-id')).status).toBe(404);
    expect((await titles(ben.token, ana.handle, scifi, "x' OR 1")).status).toBe(400);
  });

  it('strangers, blocked people and removed friends see nothing', async () => {
    const { ana, ben } = await setUp();
    const eve = await member();
    expect((await friendPage(eve.token, ana.handle)).status).toBe(404);
    expect((await titles(eve.token, ana.handle, scifi)).status).toBe(404);

    await call(`/api/v1/social/friends/${ana.handle}`, { method: 'DELETE', token: ben.token });
    expect((await titles(ben.token, ana.handle, scifi)).status).toBe(404);

    const cara = await member();
    await befriend(ana, cara);
    expect((await titles(cara.token, ana.handle, scifi)).status).toBe(200);
    await call('/api/v1/social/blocks', { method: 'POST', token: ana.token, body: { handle: cara.handle } });
    expect((await titles(cara.token, ana.handle, scifi)).status).toBe(404);
  });

  it('making it private again, or deleting it, hides it at once', async () => {
    const { ana, ben } = await setUp();
    // An older app's edit says nothing about visibility: it stays shared,
    // and the owner's devices still pull it as shared.
    await push(ana.token, [collection(scifi, { name: 'Renamed' })]);
    expect((await friendPage(ben.token, ana.handle)).body!.collections.map((c) => c.name)).toEqual(['Renamed']);
    const pulled = (await (await call('/api/v1/collections?since=0', { token: ana.token })).json()) as {
      items: Record<string, unknown>[];
    };
    expect(pulled.items.find((item) => item.key === scifi)?.visibility).toBe('friends');
    // This app says "private" outright.
    await push(ana.token, [collection(scifi, { visibility: 'private' })]);
    expect((await friendPage(ben.token, ana.handle)).body!.collections).toEqual([]);
    expect((await titles(ben.token, ana.handle, scifi)).status).toBe(404);

    await push(ana.token, [collection(scifi, { visibility: 'friends' })]);
    expect((await friendPage(ben.token, ana.handle)).body!.collections).toHaveLength(1);
    await push(ana.token, [{ kind: 'collection', key: scifi, deleted: true, visibility: 'friends', seq: ++seq, at: 9_000 }]);
    expect((await friendPage(ben.token, ana.handle)).body!.collections).toEqual([]);
  });

  it('only a collection can be shared', async () => {
    const ana = await member();
    await push(ana.token, [
      { kind: 'folder', key: 'f'.repeat(24), name: 'F', order: 1, visibility: 'friends', seq: ++seq, at: 5 },
      entry(scifi, 4, { visibility: 'friends' }),
      collection(scifi, { visibility: 'everyone' }),
    ]);
    const { results } = await testEnv.DB.prepare(`SELECT kind, visibility FROM collection_records WHERE user_id = ?`)
      .bind(ana.id).all<{ kind: string; visibility: string }>();
    expect(results.every((row) => row.visibility === 'private')).toBe(true);
  });

  it("the owner's own pull carries the visibility", async () => {
    const { ana } = await setUp();
    const response = await call('/api/v1/collections?since=0', { token: ana.token });
    const { items } = (await response.json()) as { items: Record<string, unknown>[] };
    expect(items.find((item) => item.key === scifi)?.visibility).toBe('friends');
    expect(items.find((item) => item.key === secret)).not.toHaveProperty('visibility');
  });

  it("turning Friends off makes them private as a newer change the owner's devices pull", async () => {
    const { ana, ben } = await setUp();
    const before = Date.now();
    await call('/api/v1/social/profile', { method: 'DELETE', token: ana.token });
    const response = await call(`/api/v1/collections?since=${before - 1}`, { token: ana.token });
    const { items } = (await response.json()) as { items: Record<string, unknown>[] };
    const pulled = items.find((item) => item.key === scifi)!;
    expect(pulled).not.toHaveProperty('visibility');
    expect(pulled.name).toBe('Sci-fi');
    expect(pulled.at as number).toBeGreaterThanOrEqual(before);
    expect(pulled.device).not.toBe(device);
    expect((await friendPage(ben.token, ana.handle)).status).toBe(404);
  });

  it('titles come 200 a page', async () => {
    const { ana, ben } = await setUp();
    const many = Array.from({ length: titlesPageSize + 2 }, (_, index) => entry(scifi, 100 + index));
    for (let start = 0; start < many.length; start += 50) {
      await push(ana.token, many.slice(start, start + 50));
    }
    const first = (await (await titles(ben.token, ana.handle, scifi)).json()) as { items: unknown[]; cursor: string; collection: Shared };
    expect(first.items).toHaveLength(titlesPageSize);
    expect(first.collection.count).toBe(titlesPageSize + 5);
    const second = (await (await titles(ben.token, ana.handle, scifi, first.cursor)).json()) as { items: unknown[]; cursor: string | null; collection?: unknown };
    expect(second.items).toHaveLength(5);
    expect(second.cursor).toBeNull();
    expect(second.collection).toBeUndefined();
  });
});
