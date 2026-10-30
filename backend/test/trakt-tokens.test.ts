import { describe, expect, it } from 'vitest';
import { traktAccessToken } from '../src/trakt';
import { fakeUpstream, jsonResponse, signIn, testEnv } from './helpers';

const expire = (userId: string) =>
  testEnv.DB.prepare(`UPDATE trakt_credentials SET expires_at = 1 WHERE user_id = ?`).bind(userId).run();

describe('Trakt token custody', () => {
  it('returns the stored token while it is fresh', async () => {
    const { user } = await signIn();
    const calls = fakeUpstream(() => jsonResponse({}));
    expect(await traktAccessToken(testEnv, user.id)).toMatch(/^trakt-access-/);
    expect(calls).toHaveLength(0);
  });

  it('refreshes near expiry and stores the rotated refresh token', async () => {
    const { user } = await signIn();
    await expire(user.id);
    const calls = fakeUpstream(() => jsonResponse({
      access_token: 'new-access', refresh_token: 'new-refresh', expires_in: 86400,
      created_at: Math.floor(Date.now() / 1000),
    }));
    expect(await traktAccessToken(testEnv, user.id)).toBe('new-access');
    const sent = JSON.parse(String(calls[0].init.body));
    expect(sent.grant_type).toBe('refresh_token');
    expect(sent.refresh_token).toMatch(/^trakt-refresh-/);

    // The next refresh must use the rotated token.
    await expire(user.id);
    const again = fakeUpstream(() => jsonResponse({
      access_token: 'third-access', refresh_token: 'third-refresh', expires_in: 86400,
      created_at: Math.floor(Date.now() / 1000),
    }));
    expect(await traktAccessToken(testEnv, user.id)).toBe('third-access');
    expect(JSON.parse(String(again[0].init.body)).refresh_token).toBe('new-refresh');
  });

  it('settles concurrent refreshes on one token', async () => {
    const { user } = await signIn();
    await expire(user.id);
    let refreshes = 0;
    fakeUpstream(async () => {
      refreshes += 1;
      await new Promise((resolve) => setTimeout(resolve, 10));
      return jsonResponse({
        access_token: `access-${refreshes}`, refresh_token: `refresh-${refreshes}`,
        expires_in: 86400, created_at: Math.floor(Date.now() / 1000),
      });
    });
    const tokens = await Promise.all([traktAccessToken(testEnv, user.id), traktAccessToken(testEnv, user.id)]);
    const stored = await traktAccessToken(testEnv, user.id);
    // Whoever lost the race ends up with the winner's token.
    expect(tokens.every((token) => token.startsWith('access-'))).toBe(true);
    expect(tokens).toContain(stored);
  });

  it('asks the user to sign in again when Trakt rejects the refresh', async () => {
    const { user } = await signIn();
    await expire(user.id);
    fakeUpstream(() => new Response('{"error":"invalid_grant"}', { status: 401 }));
    await expect(traktAccessToken(testEnv, user.id)).rejects.toMatchObject({ code: 'trakt_reauth_required' });
    const row = await testEnv.DB.prepare(`SELECT 1 FROM trakt_credentials WHERE user_id = ?`).bind(user.id).first();
    expect(row).toBeNull();
  });
});
