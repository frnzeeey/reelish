import { beforeEach, describe, expect, it } from 'vitest';
import { call, freshIp, signIn, testEnv } from './helpers';
import worker from '../src/index';

const founderUuid = 'founder-uuid';

const badges = async (token: string) => {
  const response = await call('/api/v1/me', { token });
  expect(response.status).toBe(200);
  return ((await response.json()) as { badges: string[] }).badges;
};

const makeSupporter = (userId: string) =>
  testEnv.DB.prepare(
    `INSERT INTO supporter_profiles (user_id, support_code, supporter_since, created_at, updated_at)
     VALUES (?, ?, 1000, 1000, 1000)
     ON CONFLICT (user_id) DO UPDATE SET supporter_since = 1000`,
  )
    .bind(userId, `RS-TEST-${crypto.randomUUID().slice(0, 4)}`)
    .run();

beforeEach(async () => {
  await testEnv.DB.prepare('DELETE FROM supporter_profiles').run();
  await testEnv.DB.prepare('DELETE FROM users WHERE trakt_uuid = ?').bind(founderUuid).run();
});

describe('The Founder badge', () => {
  it('belongs to the account with the Founder uuid', async () => {
    const { session } = await signIn({ uuid: founderUuid, username: 'someone' });
    expect(await badges(session.accessToken)).toEqual(['founder']);
  });

  it('an ordinary account has none', async () => {
    const { session } = await signIn();
    expect(await badges(session.accessToken)).toEqual([]);
  });

  it('a matching username earns nothing', async () => {
    await signIn({ uuid: founderUuid, username: 'franze' });
    const copycat = await signIn({ username: 'franze' });
    expect(await badges(copycat.session.accessToken)).toEqual([]);
  });

  it('follows the uuid when the username changes', async () => {
    await signIn({ uuid: founderUuid, username: 'before' });
    const renamed = await signIn({ uuid: founderUuid, username: 'after' });
    expect(await badges(renamed.session.accessToken)).toEqual(['founder']);
  });

  it('stays after signing out and in again', async () => {
    const first = await signIn({ uuid: founderUuid });
    await call('/api/v1/auth/logout', { method: 'POST', token: first.session.accessToken, body: {} });
    const second = await signIn({ uuid: founderUuid });
    expect(await badges(second.session.accessToken)).toEqual(['founder']);
  });

  it('comes back if the account is deleted and made again', async () => {
    const first = await signIn({ uuid: founderUuid });
    await call('/api/v1/me', { method: 'DELETE', token: first.session.accessToken });
    const second = await signIn({ uuid: founderUuid });
    expect(second.user.id).not.toBe(first.user.id);
    expect(await badges(second.session.accessToken)).toEqual(['founder']);
  });

  it('no request can change it', async () => {
    const { session } = await signIn();
    const token = session.accessToken;
    const attempts = [
      { method: 'POST', body: { badges: ['founder'], founder: true } },
      { method: 'PUT', body: { badges: ['founder'] } },
      { method: 'PATCH', body: { badges: ['founder'], trakt_uuid: founderUuid } },
    ];
    for (const attempt of attempts) {
      const response = await call('/api/v1/me', { ...attempt, token });
      expect(response.status).toBeGreaterThanOrEqual(400);
    }
    await call('/api/v1/supporters/recognition', {
      method: 'PUT',
      token,
      body: { listed: true, name: 'Founder', founder: true, badges: ['founder'] },
    });
    expect(await badges(token)).toEqual([]);
  });

  it('nobody has it when no owner is configured', async () => {
    const { session } = await signIn({ uuid: founderUuid });
    const response = await worker.fetch(
      new Request('https://api.reelish.test/api/v1/me', {
        headers: {
          Authorization: `Bearer ${session.accessToken}`,
          'CF-Connecting-IP': freshIp(),
        },
      }),
      { ...testEnv, FOUNDER_TRAKT_UUID: undefined },
    );
    expect(((await response.json()) as { badges: string[] }).badges).toEqual([]);
  });

  it('gives no access to anything', async () => {
    const founder = await signIn({ uuid: founderUuid });
    const other = await signIn();
    // Another account's device stays out of reach.
    const sessions = await call(`/api/v1/sessions/${other.session.sessionId}`, {
      method: 'DELETE',
      token: founder.session.accessToken,
    });
    expect(sessions.status).toBe(404);
  });
});

describe('Badges stay independent', () => {
  it('a supporter keeps theirs, and does not become Founder', async () => {
    const { session, user } = await signIn();
    await makeSupporter(user.id);
    expect(await badges(session.accessToken)).toEqual(['supporter']);
  });

  it('one account can hold both', async () => {
    const { session, user } = await signIn({ uuid: founderUuid });
    await makeSupporter(user.id);
    expect(await badges(session.accessToken)).toEqual(['founder', 'supporter']);
  });

  it('losing supporter status leaves Founder alone', async () => {
    const { session, user } = await signIn({ uuid: founderUuid });
    await makeSupporter(user.id);
    await testEnv.DB.prepare('UPDATE supporter_profiles SET supporter_since = NULL WHERE user_id = ?')
      .bind(user.id)
      .run();
    expect(await badges(session.accessToken)).toEqual(['founder']);
  });
});
