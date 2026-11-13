import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { maxChanges, pageSize, progressRetentionMs, pruneProgress } from '../src/progress';

type Item = {
  key: string;
  positionMs: number;
  durationMs: number;
  next: [number, number] | null;
  removed: boolean;
  title: string | null;
  poster: string | null;
  device: string;
  at: number;
};
type Pull = { items: Item[]; cursor: number; more: boolean; serverTime: number };

const deviceA = 'device-aaaaaaaa';
const deviceB = 'device-bbbbbbbb';

function change(key: string, overrides: Record<string, unknown> = {}) {
  return { key, positionMs: 60_000, durationMs: 7_200_000, seq: 1, at: 1_000, ...overrides };
}

const push = (token: string, device: string, changes: unknown[]) =>
  call('/api/v1/progress', { method: 'POST', token, body: { device, changes } });

async function pull(token: string, since = 0): Promise<Pull> {
  const response = await call(`/api/v1/progress?since=${since}`, { token });
  expect(response.status).toBe(200);
  return (await response.json()) as Pull;
}

async function item(token: string, key: string): Promise<Item | undefined> {
  return (await pull(token)).items.find((entry) => entry.key === key);
}

describe('Playback progress sync', () => {
  it('a position saved on one device is read on another', async () => {
    const phone = await signIn({ uuid: 'progress-two-devices' });
    const tv = await signIn({ uuid: 'progress-two-devices' });
    const response = await push(phone.session.accessToken, deviceA, [
      change('movie:27205', {
        positionMs: 2_555_000,
        title: 'Inception',
        year: '2010',
        poster: 'https://image.tmdb.org/t/p/w500/abc_DEF-1.jpg',
      }),
    ]);
    expect(response.status).toBe(200);
    expect(((await response.json()) as { accepted: number }).accepted).toBe(1);
    const seen = await item(tv.session.accessToken, 'movie:27205');
    expect(seen?.positionMs).toBe(2_555_000);
    expect(seen?.title).toBe('Inception');
    expect(seen?.device).toBe(deviceA);
  });

  it('a later change from another device wins, an older one does not', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceA, [change('movie:1', { positionMs: 25 * 60_000, at: 2_000 })]);
    await push(token, deviceB, [change('movie:1', { positionMs: 31 * 60_000, at: 3_000 })]);
    expect((await item(token, 'movie:1'))?.positionMs).toBe(31 * 60_000);
    // Android's older upload arrives late: it does not overwrite Windows.
    const late = await push(token, deviceA, [change('movie:1', { positionMs: 26 * 60_000, at: 2_500, seq: 2 })]);
    expect(((await late.json()) as { accepted: number }).accepted).toBe(0);
    expect((await item(token, 'movie:1'))?.positionMs).toBe(31 * 60_000);
    // A rewind on the newest session is respected: not the largest position.
    await push(token, deviceA, [change('movie:1', { positionMs: 5 * 60_000, at: 4_000, seq: 3 })]);
    expect((await item(token, 'movie:1'))?.positionMs).toBe(5 * 60_000);
  });

  it('the same device is ordered by its counter, whatever its clock says', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceA, [change('movie:2', { positionMs: 1_000, seq: 5, at: 9_000 })]);
    // The clock went back, the counter on: still newer.
    await push(token, deviceA, [change('movie:2', { positionMs: 2_000, seq: 6, at: 8_000 })]);
    expect((await item(token, 'movie:2'))?.positionMs).toBe(2_000);
    // A repeated or reordered request (lower counter) is dropped.
    await push(token, deviceA, [change('movie:2', { positionMs: 3_000, seq: 4, at: 99_000 })]);
    expect((await item(token, 'movie:2'))?.positionMs).toBe(2_000);
  });

  it('a device clock in the future is clamped to the server time', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    const future = Date.now() + 365 * 24 * 60 * 60 * 1000;
    await push(token, deviceA, [change('movie:3', { positionMs: 1_000, at: future })]);
    const stored = await item(token, 'movie:3');
    expect(stored!.at).toBeLessThanOrEqual(Date.now());
    // A real later change from another device still wins.
    await push(token, deviceB, [change('movie:3', { positionMs: 2_000, at: Date.now() + 5 })]);
    expect((await item(token, 'movie:3'))?.positionMs).toBe(2_000);
  });

  it('ties between devices are settled the same way every time', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceB, [change('movie:4', { positionMs: 2_000, at: 5_000 })]);
    await push(token, deviceA, [change('movie:4', { positionMs: 1_000, at: 5_000 })]);
    expect((await item(token, 'movie:4'))?.device).toBe(deviceB);
  });

  it('episodes keep their own rows and the next episode', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceA, [
      change('episode:1396:1:3', { positionMs: 47 * 60_000, durationMs: 48 * 60_000, next: [1, 4] }),
      change('episode:1396:1:4', { positionMs: 5 * 60_000, durationMs: 48 * 60_000 }),
      change('series:1396', { positionMs: 0, durationMs: 0, title: 'Breaking Bad' }),
    ]);
    const { items } = await pull(token);
    expect(items.find((e) => e.key === 'episode:1396:1:3')?.next).toEqual([1, 4]);
    expect(items.find((e) => e.key === 'episode:1396:1:4')?.positionMs).toBe(5 * 60_000);
    expect(items.find((e) => e.key === 'series:1396')?.title).toBe('Breaking Bad');
  });

  it('a removal reaches other devices, and a newer play brings the title back', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await push(token, deviceA, [change('movie:5', { at: 1_000 })]);
    await push(token, deviceB, [change('movie:5', { removed: true, at: 2_000 })]);
    expect((await item(token, 'movie:5'))?.removed).toBe(true);
    await push(token, deviceA, [change('movie:5', { at: 3_000, seq: 2 })]);
    expect((await item(token, 'movie:5'))?.removed).toBe(false);
  });

  it('accounts never see each other’s progress', async () => {
    const a = await signIn();
    const b = await signIn();
    await push(a.session.accessToken, deviceA, [change('movie:6')]);
    expect((await pull(b.session.accessToken)).items).toEqual([]);
    // The same device id cannot touch another account's row either.
    await push(b.session.accessToken, deviceA, [change('movie:6', { positionMs: 1, seq: 9, at: 9_000 })]);
    expect((await item(a.session.accessToken, 'movie:6'))?.positionMs).toBe(60_000);
  });

  it('pulls from a cursor, in pages', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    const first = await pull(token);
    expect(first.items).toEqual([]);
    await push(token, deviceA, [change('movie:7')]);
    const next = await pull(token, first.cursor);
    expect(next.items.map((e) => e.key)).toEqual(['movie:7']);
    expect(next.more).toBe(false);
    // Rows are stamped with server time; the cursor never skips one.
    const after = await pull(token, next.cursor);
    expect(after.items.map((e) => e.key)).toEqual(['movie:7']);
    expect(pageSize).toBeGreaterThan(maxChanges);
  });

  it('rejects malformed changes without storing any', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    const bad: unknown[] = [
      change('movie:abc'),
      change('show:1'),
      change('movie:1', { positionMs: -1 }),
      change('movie:1', { durationMs: 2 * 24 * 60 * 60 * 1000 }),
      change('movie:1', { seq: 1.5 }),
      change('movie:1', { next: [1, 2] }),
      change('movie:1', { poster: 'https://evil.example/x.jpg' }),
      change('movie:1', { poster: 'javascript:alert(1)' }),
      change('movie:1', { year: '20100' }),
      change('movie:1', { title: 'x'.repeat(301) }),
    ];
    for (const entry of bad) {
      const response = await push(token, deviceA, [change('movie:99'), entry]);
      expect(response.status).toBe(400);
    }
    expect((await push(token, 'bad device', [change('movie:1')])).status).toBe(400);
    const tooMany = Array.from({ length: maxChanges + 1 }, (_, i) => change(`movie:${i + 1}`));
    expect((await push(token, deviceA, tooMany)).status).toBe(400);
    expect((await call('/api/v1/progress?since=abc', { token })).status).toBe(400);
    expect((await pull(token)).items).toEqual([]);
  });

  it('needs a signed-in session', async () => {
    expect((await call('/api/v1/progress')).status).toBe(401);
    expect((await call('/api/v1/progress', { method: 'POST', body: { device: deviceA, changes: [] } })).status)
      .toBe(401);
  });

  it('is deleted with the account and pruned when stale', async () => {
    const { session, user } = await signIn();
    await push(session.accessToken, deviceA, [change('movie:8')]);
    const count = async () => (await testEnv.DB.prepare(
      `SELECT COUNT(*) AS n FROM playback_progress WHERE user_id = ?`,
    ).bind(user.id).first<{ n: number }>())!.n;
    expect(await count()).toBe(1);
    expect(await pruneProgress(testEnv, Date.now() + progressRetentionMs - 60_000)).toBe(0);
    expect(await count()).toBe(1);
    await call('/api/v1/me', { method: 'DELETE', token: session.accessToken });
    expect(await count()).toBe(0);

    const other = await signIn();
    await push(other.session.accessToken, deviceA, [change('movie:9')]);
    expect(await pruneProgress(testEnv, Date.now() + progressRetentionMs + 60_000)).toBeGreaterThanOrEqual(1);
  });
});
