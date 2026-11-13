import { env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { call, signIn } from './helpers';
import { maxGenres, parsePreferences } from '../src/discovery-preferences';

type Stored = {
  preferences: { onboarding: string | null; genres: number[]; personalization: boolean };
  device: string;
  at: number;
} | null;
type Answer = { stored: Stored; accepted?: boolean; serverTime: number };

const deviceA = 'device-aaaaaaaa';
const deviceB = 'device-bbbbbbbb';

const prefs = (overrides: Record<string, unknown> = {}) => ({
  onboarding: 'completed',
  genres: [878, 9648],
  personalization: true,
  ...overrides,
});

const put = (token: string, device: string, seq: number, at: number, preferences: unknown) =>
  call('/api/v1/discovery/preferences', { method: 'PUT', token, body: { device, seq, at, preferences } });

async function get(token: string): Promise<Answer> {
  const response = await call('/api/v1/discovery/preferences', { token });
  expect(response.status).toBe(200);
  return (await response.json()) as Answer;
}

describe('Discovery preferences sync', () => {
  it('a new account has none', async () => {
    const { session } = await signIn();
    expect((await get(session.accessToken)).stored).toBeNull();
  });

  it('preferences saved on one device are read on another', async () => {
    const phone = await signIn({ uuid: 'discovery-two-devices' });
    const tv = await signIn({ uuid: 'discovery-two-devices' });
    const response = await put(phone.session.accessToken, deviceA, 1, 1_000, prefs());
    expect(response.status).toBe(200);
    expect(((await response.json()) as Answer).accepted).toBe(true);
    const seen = (await get(tv.session.accessToken)).stored;
    expect(seen?.preferences).toEqual({ onboarding: 'completed', genres: [878, 9648], personalization: true });
    expect(seen?.device).toBe(deviceA);
  });

  it('a later change from another device wins and an older one does not', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await put(token, deviceA, 1, 2_000, prefs({ genres: [28] }));
    await put(token, deviceB, 1, 3_000, prefs({ genres: [35] }));
    const late = await put(token, deviceA, 2, 2_500, prefs({ genres: [27] }));
    const answer = (await late.json()) as Answer;
    // The device that lost is told what won.
    expect(answer.accepted).toBe(false);
    expect(answer.stored?.preferences.genres).toEqual([35]);
    expect((await get(token)).stored?.preferences.genres).toEqual([35]);
  });

  it('the same device is ordered by its counter, whatever its clock says', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await put(token, deviceA, 5, 9_000, prefs({ personalization: true }));
    await put(token, deviceA, 6, 8_000, prefs({ personalization: false }));
    expect((await get(token)).stored?.preferences.personalization).toBe(false);
    const replay = await put(token, deviceA, 5, 9_500, prefs({ personalization: true }));
    expect(((await replay.json()) as Answer).accepted).toBe(false);
  });

  it('a clock far ahead cannot win forever', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    await put(token, deviceA, 1, Date.now() + 365 * 24 * 3600_000, prefs({ genres: [28] }));
    const stored = (await get(token)).stored;
    expect(stored!.at).toBeLessThanOrEqual(Date.now());
    await put(token, deviceB, 1, Date.now() + 1_000, prefs({ genres: [35] }));
    expect((await get(token)).stored?.preferences.genres).toEqual([35]);
  });

  it('accounts never see each other\'s preferences', async () => {
    const one = await signIn({ uuid: 'discovery-owner' });
    const other = await signIn({ uuid: 'discovery-other' });
    await put(one.session.accessToken, deviceA, 1, 1_000, prefs({ genres: [99] }));
    expect((await get(other.session.accessToken)).stored).toBeNull();
  });

  it('refuses malformed preferences and requests', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    const refused = async (body: unknown) => {
      const response = await call('/api/v1/discovery/preferences', { method: 'PUT', token, body });
      expect(response.status, JSON.stringify(body)).toBe(400);
    };
    await refused({ device: 'x', seq: 1, at: 1, preferences: prefs() });
    await refused({ device: deviceA, seq: -1, at: 1, preferences: prefs() });
    await refused({ device: deviceA, seq: 1, at: 1.5, preferences: prefs() });
    await refused({ device: deviceA, seq: 1, at: 1, preferences: prefs({ onboarding: 'yes' }) });
    await refused({ device: deviceA, seq: 1, at: 1, preferences: prefs({ genres: ['878'] }) });
    await refused({ device: deviceA, seq: 1, at: 1, preferences: prefs({ genres: [0] }) });
    await refused({ device: deviceA, seq: 1, at: 1, preferences: prefs({ genres: Array.from({ length: maxGenres + 1 }, (_, i) => i + 1) }) });
    await refused({ device: deviceA, seq: 1, at: 1, preferences: prefs({ personalization: 'no' }) });
    await refused({ device: deviceA, seq: 1, at: 1, preferences: [] });
    expect((await get(token)).stored).toBeNull();
  });

  it('stores only the checked fields', () => {
    expect(parsePreferences({ genres: [18, 18, 35], extra: 'ignored', personalization: false })).toEqual({
      onboarding: null,
      genres: [18, 35],
      personalization: false,
    });
  });

  it('needs a session', async () => {
    const response = await call('/api/v1/discovery/preferences');
    expect(response.status).toBe(401);
  });

  it('goes with the account', async () => {
    const { session } = await signIn({ uuid: 'discovery-deleted' });
    await put(session.accessToken, deviceA, 1, 1_000, prefs());
    const userId = (await env.DB.prepare(`SELECT user_id FROM discovery_preferences`).all<{ user_id: string }>())
      .results.map((row) => row.user_id);
    expect(userId.length).toBeGreaterThan(0);
    const deleted = await call('/api/v1/me', { method: 'DELETE', token: session.accessToken });
    expect(deleted.status).toBeLessThan(300);
    const left = await env.DB.prepare(
      `SELECT COUNT(*) AS count FROM discovery_preferences p JOIN users u ON u.id = p.user_id
        WHERE u.trakt_uuid = 'discovery-deleted'`,
    ).first<{ count: number }>();
    expect(left?.count).toBe(0);
    const orphans = await env.DB.prepare(
      `SELECT COUNT(*) AS count FROM discovery_preferences WHERE user_id NOT IN (SELECT id FROM users)`,
    ).first<{ count: number }>();
    expect(orphans?.count).toBe(0);
  });
});
