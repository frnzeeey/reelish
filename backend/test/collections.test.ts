import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { maxChanges, pageSize, pruneCollections, tombstoneRetentionMs } from '../src/collections';

type Item = Record<string, unknown> & {
  kind: string;
  key: string;
  deleted: boolean;
  device: string;
  at: number;
};
type Pull = { items: Item[]; cursor: number; more: boolean; serverTime: number };

const deviceA = 'device-aaaaaaaa';
const deviceB = 'device-bbbbbbbb';
const scifi = 'a'.repeat(24);
const movies = 'b'.repeat(24);
const dune = `${scifi}|movie:438631`;
const poster = 'https://image.tmdb.org/t/p/w500/abc_DEF-1.jpg';

const collection = (overrides: Record<string, unknown> = {}) => ({
  kind: 'collection',
  key: scifi,
  name: 'Sci-fi',
  order: 1,
  createdAt: 500,
  seq: 1,
  at: 1_000,
  ...overrides,
});

const entry = (overrides: Record<string, unknown> = {}) => ({
  kind: 'entry',
  key: dune,
  name: 'Dune',
  poster,
  year: '2021',
  addedAt: 1_000,
  seq: 2,
  at: 1_000,
  ...overrides,
});

const push = (token: string, device: string, changes: unknown[]) =>
  call('/api/v1/collections', { method: 'POST', token, body: { device, changes } });

async function pull(token: string, since = 0): Promise<Pull> {
  const response = await call(`/api/v1/collections?since=${since}`, { token });
  expect(response.status).toBe(200);
  return (await response.json()) as Pull;
}

async function record(token: string, kind: string, key: string): Promise<Item | undefined> {
  return (await pull(token)).items.find((item) => item.kind === kind && item.key === key);
}

describe('Collection sync', () => {
  it('a collection made on one device, a title added on another: both kept', async () => {
    const phone = await signIn({ uuid: 'collections-two-devices' });
    const pc = await signIn({ uuid: 'collections-two-devices' });
    expect((await push(phone.session.accessToken, deviceA, [collection()])).status).toBe(200);
    await push(pc.session.accessToken, deviceB, [entry({ seq: 1 })]);
    const { items } = await pull(phone.session.accessToken);
    expect(items.map((item) => `${item.kind}:${item.key}`).sort()).toEqual([`collection:${scifi}`, `entry:${dune}`]);
    const title = items.find((item) => item.kind === 'entry')!;
    expect(title).toMatchObject({ name: 'Dune', poster, year: '2021', addedAt: 1_000, deleted: false, device: deviceB });
    const made = items.find((item) => item.kind === 'collection')!;
    expect(made).toMatchObject({ name: 'Sci-fi', order: 1, createdAt: 500, device: deviceA });
  });

  it('the same title added on two devices is one record', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceA, [entry({ at: 2_000 })]);
    await push(token, deviceB, [entry({ at: 2_100, seq: 1 })]);
    const entries = (await pull(token)).items.filter((item) => item.kind === 'entry');
    expect(entries).toHaveLength(1);
    expect(entries[0].device).toBe(deviceB);
  });

  it('the later change wins; an older offline copy does not undo a deletion', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceA, [collection({ name: 'Old name', at: 2_000 })]);
    await push(token, deviceB, [collection({ name: 'New name', at: 3_000, seq: 1 })]);
    expect((await record(token, 'collection', scifi))?.name).toBe('New name');
    await push(token, deviceB, [collection({ deleted: true, at: 4_000, seq: 2 })]);
    // Device A comes back online with an edit made before the deletion.
    const late = await push(token, deviceA, [collection({ name: 'Offline edit', at: 3_500, seq: 2 })]);
    expect(((await late.json()) as { accepted: number }).accepted).toBe(0);
    const stored = await record(token, 'collection', scifi);
    expect(stored?.deleted).toBe(true);
    // A deletion carries no content.
    expect(stored?.name).toBeUndefined();
  });

  it('the same device is ordered by its counter; future clocks are clamped', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceA, [collection({ name: 'First', seq: 5, at: 9_000 })]);
    await push(token, deviceA, [collection({ name: 'Second', seq: 6, at: 8_000 })]);
    expect((await record(token, 'collection', scifi))?.name).toBe('Second');
    await push(token, deviceA, [collection({ name: 'Replayed', seq: 6, at: 10_000 })]);
    expect((await record(token, 'collection', scifi))?.name).toBe('Second');

    const before = Date.now();
    await push(token, deviceB, [collection({ name: 'Future', at: Date.now() + 86_400_000, seq: 1 })]);
    expect((await record(token, 'collection', scifi))!.at).toBeLessThanOrEqual(Date.now());
    expect((await record(token, 'collection', scifi))!.at).toBeGreaterThanOrEqual(before);
    // A later honest change from A still wins over the clamped one.
    await new Promise((resolve) => setTimeout(resolve, 5));
    await push(token, deviceA, [collection({ name: 'Later', at: Date.now(), seq: 7 })]);
    expect((await record(token, 'collection', scifi))?.name).toBe('Later');
  });

  it('folders, moves and removals travel', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceA, [
      { kind: 'folder', key: movies, name: 'Movies', order: 1, createdAt: 1, seq: 1, at: 1_000 },
      collection({ folderId: movies, cover: 'movie:438631', description: 'Big ideas', seq: 2 }),
      entry({ seq: 3 }),
    ]);
    expect(await record(token, 'folder', movies)).toMatchObject({ name: 'Movies' });
    expect(await record(token, 'collection', scifi)).toMatchObject({
      folderId: movies,
      cover: 'movie:438631',
      description: 'Big ideas',
    });
    await push(token, deviceB, [entry({ deleted: true, at: 2_000, seq: 1 })]);
    expect((await record(token, 'entry', dune))?.deleted).toBe(true);
  });

  it('accounts never see each other’s records', async () => {
    const mine = await signIn();
    const theirs = await signIn();
    await push(mine.session.accessToken, deviceA, [collection({ name: 'Private' })]);
    // The same record key and device id under another account is its own row.
    await push(theirs.session.accessToken, deviceA, [collection({ name: 'Theirs' })]);
    expect((await record(mine.session.accessToken, 'collection', scifi))?.name).toBe('Private');
    expect((await record(theirs.session.accessToken, 'collection', scifi))?.name).toBe('Theirs');
  });

  it('pulls from a cursor, in pages', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    const keys = Array.from({ length: pageSize + 10 }, (_, i) => `${scifi}|movie:${i + 1}`);
    for (let i = 0; i < keys.length; i += maxChanges) {
      await push(token, deviceA, keys.slice(i, i + maxChanges).map((key, j) => entry({ key, seq: i + j + 1 })));
    }
    const first = await pull(token);
    expect(first.items).toHaveLength(pageSize);
    expect(first.more).toBe(true);
    const seen = new Set(first.items.map((item) => item.key));
    let cursor = first.cursor;
    for (let page = 0; page < 5; page++) {
      const next = await pull(token, cursor);
      next.items.forEach((item) => seen.add(item.key));
      cursor = next.cursor;
      if (!next.more) break;
    }
    expect(seen.size).toBe(keys.length);
    const after = await pull(token, (await pull(token)).serverTime + 1);
    expect(after.items).toHaveLength(0);
  });

  it('rejects malformed records without storing any', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    const bad: unknown[] = [
      'text',
      { ...collection(), kind: 'person' },
      collection({ key: 'not-hex' }),
      entry({ key: `${scifi}|person:1` }),
      collection({ name: '' }),
      collection({ name: 'x'.repeat(81) }),
      collection({ description: 'x'.repeat(301) }),
      collection({ folderId: 'nope' }),
      collection({ cover: 'episode:1:1:1' }),
      collection({ order: 'first' }),
      entry({ poster: 'https://evil.example/a.jpg' }),
      entry({ year: '21' }),
      entry({ addedAt: -1 }),
      collection({ seq: -1 }),
      collection({ at: 1.5 }),
    ];
    for (const change of bad) {
      const response = await push(token, deviceA, [entry(), change]);
      expect(response.status).toBe(400);
    }
    expect((await push(token, 'x', [])).status).toBe(400);
    expect((await push(token, deviceA, Array(maxChanges + 1).fill(entry()))).status).toBe(400);
    expect((await pull(token)).items).toHaveLength(0);
    expect((await call('/api/v1/collections?since=-1', { token })).status).toBe(400);
  });

  it('needs a signed-in session', async () => {
    expect((await call('/api/v1/collections')).status).toBe(401);
    expect((await call('/api/v1/collections', { method: 'POST', body: { device: deviceA, changes: [] } })).status)
      .toBe(401);
  });

  it('is deleted with the account; only old deletion marks are pruned', async () => {
    const { session, user } = await signIn();
    await push(session.accessToken, deviceA, [collection(), entry({ deleted: true })]);
    const count = async (id: string) => (await testEnv.DB.prepare(
      `SELECT COUNT(*) AS n FROM collection_records WHERE user_id = ?`,
    ).bind(id).first<{ n: number }>())!.n;
    expect(await count(user.id)).toBe(2);
    expect(await pruneCollections(testEnv, Date.now() + tombstoneRetentionMs - 60_000)).toBe(0);
    expect(await pruneCollections(testEnv, Date.now() + tombstoneRetentionMs + 60_000)).toBeGreaterThanOrEqual(1);
    // The live collection is never pruned, however old.
    expect(await count(user.id)).toBe(1);
    await call('/api/v1/me', { method: 'DELETE', token: session.accessToken });
    expect(await count(user.id)).toBe(0);
  });
});
