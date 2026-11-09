import { beforeEach, describe, expect, it } from 'vitest';
import { call, freshIp, signIn, testEnv } from './helpers';
import worker from '../src/index';
import { hasFounderPerks, hasSupporterPerks, type Entitlement } from '../src/entitlements';

const founderUuid = 'founder-uuid';
const movie = { tmdbId: 603, type: 'movie', title: 'The Matrix' };

const makeSupporter = (userId: string) =>
  testEnv.DB.prepare(
    `INSERT INTO supporter_profiles (user_id, support_code, supporter_since, created_at, updated_at)
     VALUES (?, ?, 1000, 1000, 1000)
     ON CONFLICT (user_id) DO UPDATE SET supporter_since = 1000`,
  )
    .bind(userId, `RS-${crypto.randomUUID().slice(0, 8)}`)
    .run();

const status = async (token: string) => {
  const response = await call('/api/v1/supporters/me', { token });
  expect(response.status).toBe(200);
  return (await response.json()) as { status: string; entitlement: Entitlement };
};

const host = (token: string) =>
  call('/api/v1/party', { token, body: { content: movie, profile: { name: 'Host' } } });

const badges = async (token: string) =>
  ((await (await call('/api/v1/me', { token })).json()) as { badges: string[] }).badges;

beforeEach(async () => {
  await testEnv.DB.prepare('DELETE FROM users WHERE trakt_uuid = ?').bind(founderUuid).run();
});

describe('Entitlements', () => {
  it('free accounts have none of the supporter perks', async () => {
    const { session } = await signIn();
    expect((await status(session.accessToken)).entitlement).toBe('free');
    const response = await host(session.accessToken);
    expect(response.status).toBe(403);
  });

  it('supporters have them through their donation', async () => {
    const { session, user } = await signIn();
    await makeSupporter(user.id);
    expect(await status(session.accessToken)).toMatchObject({ status: 'verified', entitlement: 'supporter' });
    expect((await host(session.accessToken)).status).toBe(201);
  });

  it('the Founder has every supporter perk without donating', async () => {
    const { session } = await signIn({ uuid: founderUuid });
    // No donation, and the donation status says so honestly.
    expect(await status(session.accessToken)).toMatchObject({ status: 'none', entitlement: 'founder' });
    expect((await host(session.accessToken)).status).toBe(201);
  });

  it('the Founder shows the Founder badge, not a Supporter badge they did not earn', async () => {
    const { session } = await signIn({ uuid: founderUuid });
    expect(await badges(session.accessToken)).toEqual(['founder']);
  });

  it('a Founder who donates is still the Founder, with both badges', async () => {
    const { session, user } = await signIn({ uuid: founderUuid });
    await makeSupporter(user.id);
    expect((await status(session.accessToken)).entitlement).toBe('founder');
    expect(await badges(session.accessToken)).toEqual(['founder', 'supporter']);
  });

  it('the Founder keeps it after signing out and in, and after a refund', async () => {
    const first = await signIn({ uuid: founderUuid });
    await makeSupporter(first.user.id);
    await call('/api/v1/auth/logout', { method: 'POST', token: first.session.accessToken, body: {} });
    const again = await signIn({ uuid: founderUuid });
    await testEnv.DB.prepare('UPDATE supporter_profiles SET supporter_since = NULL WHERE user_id = ?')
      .bind(again.user.id).run();
    expect((await status(again.session.accessToken)).entitlement).toBe('founder');
    expect((await host(again.session.accessToken)).status).toBe(201);
  });

  it('a refunded supporter goes back to free', async () => {
    const { session, user } = await signIn();
    await makeSupporter(user.id);
    await testEnv.DB.prepare('UPDATE supporter_profiles SET supporter_since = NULL WHERE user_id = ?')
      .bind(user.id).run();
    expect((await status(session.accessToken)).entitlement).toBe('free');
    expect((await host(session.accessToken)).status).toBe(403);
  });

  it('without the secret, nobody is Founder', async () => {
    const { session } = await signIn({ uuid: founderUuid });
    const unset = { ...testEnv, FOUNDER_TRAKT_UUID: undefined };
    const ask = (path: string, init: RequestInit = {}) => worker.fetch(
      new Request(`https://api.reelish.test${path}`, {
        ...init,
        headers: {
          Authorization: `Bearer ${session.accessToken}`,
          'CF-Connecting-IP': freshIp(),
          'Content-Type': 'application/json',
        },
      }),
      unset,
    );
    const body = (await (await ask('/api/v1/supporters/me')).json()) as { entitlement: string };
    expect(body.entitlement).toBe('free');
    const response = await ask('/api/v1/party', { method: 'POST', body: JSON.stringify({ content: movie }) });
    expect(response.status).toBe(403);
  });

  it('nothing a client sends makes an account Founder or a supporter', async () => {
    const { session } = await signIn({ username: 'founder' });
    await call('/api/v1/supporters/recognition', {
      method: 'PUT',
      token: session.accessToken,
      body: { listed: true, name: 'Founder', entitlement: 'founder', founder: true },
    });
    const response = await call('/api/v1/party', {
      token: session.accessToken,
      headers: { 'X-Party-Founder': '1', 'X-Entitlement': 'founder' },
      body: { content: movie, entitlement: 'founder', founder: true },
    });
    expect(response.status).toBe(403);
    expect((await status(session.accessToken)).entitlement).toBe('free');
  });

  it('the Founder inherits the Supporter entitlement as a whole', () => {
    // Every perk is one rule, so a new perk cannot leave the Founder out.
    expect(hasSupporterPerks('founder')).toBe(true);
    expect(hasSupporterPerks('supporter')).toBe(true);
    expect(hasSupporterPerks('free')).toBe(false);
  });

  it('the Founder perks are the Founder\'s alone: no donation unlocks them', () => {
    expect(hasFounderPerks('founder')).toBe(true);
    expect(hasFounderPerks('supporter')).toBe(false);
    expect(hasFounderPerks('free')).toBe(false);
  });
});
