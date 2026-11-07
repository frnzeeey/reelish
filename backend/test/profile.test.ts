import { afterEach, describe, expect, it, vi } from 'vitest';
import { call, fakeUpstream, jsonResponse, signIn, testEnv } from './helpers';
import { cleanAvatarUrl } from '../src/trakt';
import { profileMaxAgeSeconds, profileRetrySeconds } from '../src/profile';

const avatar = 'https://walter-r2.trakt.tv/images/users/000/000/001/avatars/large/a1b2c3.jpg';
const newAvatar = 'https://walter-r2.trakt.tv/images/users/000/000/001/avatars/large/d4e5f6.jpg';

type Me = { user: { id: string; username: string; avatarUrl: string | null; profileCheckedAt: number | null } };

const me = async (token: string) => {
  const response = await call('/api/v1/me', { token });
  expect(response.status).toBe(200);
  return ((await response.json()) as Me).user;
};

const now = () => Math.floor(Date.now() / 1000);

/** Makes the stored profile a day and a bit old, so the next /me reads Trakt. */
const age = (userId: string) =>
  testEnv.DB.prepare('UPDATE users SET trakt_profile_checked_at = ? WHERE id = ?')
    .bind(now() - profileMaxAgeSeconds - 60, userId).run();

const stored = (userId: string) =>
  testEnv.DB.prepare('SELECT trakt_username, trakt_avatar_url, trakt_profile_checked_at FROM users WHERE id = ?')
    .bind(userId).first<{ trakt_username: string; trakt_avatar_url: string | null; trakt_profile_checked_at: number }>();

/** Trakt's settings for [uuid], as /users/settings answers. */
const settings = (uuid: string, username: string, picture?: string) => jsonResponse({
  user: { username, ids: { uuid }, ...(picture ? { images: { avatar: { full: picture } } } : {}) },
});

afterEach(() => vi.restoreAllMocks());

describe('The avatar URL Trakt gives', () => {
  it('is kept when it is an image on Trakt or Gravatar', () => {
    expect(cleanAvatarUrl(avatar)).toBe(avatar);
    expect(cleanAvatarUrl('https://secure.gravatar.com/avatar/abc?s=256')).toBe('https://secure.gravatar.com/avatar/abc?s=256&d=404');
  });

  it('a Gravatar link never falls back to the Trakt stand-in picture', () => {
    const placeholder = encodeURIComponent('https://walter-r2.trakt.tv/hotlink-ok/placeholders/medium/fry.png');
    const cleaned = new URL(cleanAvatarUrl(`https://secure.gravatar.com/avatar/abc?d=${placeholder}&r=pg`)!);
    expect(cleaned.searchParams.get('d')).toBe('404');
    expect(cleaned.searchParams.get('r')).toBe('pg');
  });

  it('is dropped when it is anything else', () => {
    for (const bad of [
      'http://walter-r2.trakt.tv/images/a.jpg',
      'https://evil.example/a.jpg',
      'https://trakt.tv.evil.example/a.jpg',
      'https://user:pass@walter-r2.trakt.tv/a.jpg',
      'https://walter-r2.trakt.tv:8443/a.jpg',
      'https://walter-r2.trakt.tv/hotlink-ok/placeholders/medium/fry.png',
      `https://walter-r2.trakt.tv/${'a'.repeat(600)}.jpg`,
      'javascript:alert(1)',
      '',
      42,
      null,
    ]) {
      expect(cleanAvatarUrl(bad)).toBeNull();
    }
  });
});

describe('Signing in reads the profile', () => {
  it('stores the username and avatar, and returns them', async () => {
    const account = await signIn({ username: 'sam', avatar });
    expect(account.user.avatarUrl).toBe(avatar);
    const user = await me(account.session.accessToken);
    expect(user).toMatchObject({ username: 'sam', avatarUrl: avatar });
    expect(user.profileCheckedAt).toBeGreaterThan(now() - 60);
  });

  it('an account without an avatar has none, not Trakt\'s stand-in', async () => {
    const account = await signIn({ avatar: 'https://walter-r2.trakt.tv/hotlink-ok/placeholders/medium/fry.png' });
    expect((await me(account.session.accessToken)).avatarUrl).toBeNull();
  });

  it('a new device sees a change another device brought in, without signing in again', async () => {
    const phone = await signIn({ uuid: 'uuid-shared-1', username: 'before', avatar });
    // The TV signs in later, after the person changed their Trakt profile.
    await signIn({ uuid: 'uuid-shared-1', username: 'after', avatar: newAvatar });
    expect(await me(phone.session.accessToken)).toMatchObject({ username: 'after', avatarUrl: newAvatar });
  });
});

describe('Reading Trakt again', () => {
  it('a fresh profile costs no Trakt call', async () => {
    const account = await signIn({ avatar });
    const calls = fakeUpstream(() => new Response('unexpected', { status: 500 }));
    await me(account.session.accessToken);
    expect(calls).toHaveLength(0);
  });

  it('after a day, a rename and a new avatar come through once', async () => {
    const account = await signIn({ username: 'old-name', avatar });
    await age(account.user.id);
    const calls = fakeUpstream((url) =>
      url.pathname === '/users/settings' ? settings(account.uuid, 'new-name', newAvatar) : new Response('', { status: 500 }));
    expect(await me(account.session.accessToken)).toMatchObject({ username: 'new-name', avatarUrl: newAvatar });
    await me(account.session.accessToken);
    expect(calls.filter((c) => c.url.pathname === '/users/settings')).toHaveLength(1);
  });

  it('two devices asking at once cost one Trakt call', async () => {
    const account = await signIn({ avatar });
    await age(account.user.id);
    const calls = fakeUpstream((url) =>
      url.pathname === '/users/settings' ? settings(account.uuid, 'same', avatar) : new Response('', { status: 500 }));
    const token = account.session.accessToken;
    const [a, b] = await Promise.all([call('/api/v1/me', { token }), call('/api/v1/me', { token })]);
    expect([a.status, b.status]).toEqual([200, 200]);
    expect(calls.filter((c) => c.url.pathname === '/users/settings')).toHaveLength(1);
  });

  it('a removed avatar is removed; the username stays', async () => {
    const account = await signIn({ username: 'sam', avatar });
    await age(account.user.id);
    fakeUpstream(() => settings(account.uuid, 'sam'));
    expect(await me(account.session.accessToken)).toMatchObject({ username: 'sam', avatarUrl: null });
  });

  it('Trakt failing keeps the profile, and waits an hour before trying again', async () => {
    const account = await signIn({ username: 'sam', avatar });
    await age(account.user.id);
    const calls = fakeUpstream(() => new Response('down', { status: 503 }));
    expect(await me(account.session.accessToken)).toMatchObject({ username: 'sam', avatarUrl: avatar });
    const row = await stored(account.user.id);
    const retryAt = row!.trakt_profile_checked_at + profileMaxAgeSeconds;
    expect(retryAt - now()).toBeGreaterThan(profileRetrySeconds - 60);
    expect(retryAt - now()).toBeLessThanOrEqual(profileRetrySeconds);
    const before = calls.length;
    await me(account.session.accessToken);
    expect(calls.length).toBe(before);
  });

  it('an empty or broken answer never blanks the profile', async () => {
    const account = await signIn({ username: 'sam', avatar });
    for (const answer of [jsonResponse({}), jsonResponse({ user: { ids: { uuid: 'x' } } }), new Response('{not json')]) {
      await age(account.user.id);
      fakeUpstream(() => answer.clone());
      expect(await me(account.session.accessToken)).toMatchObject({ username: 'sam', avatarUrl: avatar });
      vi.restoreAllMocks();
    }
  });

  it('another Trakt account\'s answer cannot change this one', async () => {
    const account = await signIn({ username: 'sam', avatar });
    await age(account.user.id);
    fakeUpstream(() => settings('someone-else-uuid', 'intruder', newAvatar));
    expect(await me(account.session.accessToken)).toMatchObject({ username: 'sam', avatarUrl: avatar });
  });

  it('a lost Trakt grant keeps the stored profile', async () => {
    const account = await signIn({ username: 'sam', avatar });
    await testEnv.DB.prepare('DELETE FROM trakt_credentials WHERE user_id = ?').bind(account.user.id).run();
    await age(account.user.id);
    expect(await me(account.session.accessToken)).toMatchObject({ username: 'sam', avatarUrl: avatar });
  });
});

describe('Each account sees only its own', () => {
  it('two accounts never see each other\'s profile', async () => {
    const first = await signIn({ username: 'first', avatar });
    const second = await signIn({ username: 'second' });
    expect(await me(second.session.accessToken)).toMatchObject({ username: 'second', avatarUrl: null });
    expect(await me(first.session.accessToken)).toMatchObject({ username: 'first', avatarUrl: avatar });
  });

  it('a deleted account leaves nothing to come back', async () => {
    const first = await signIn({ uuid: 'uuid-deleted-1', avatar });
    await call('/api/v1/me', { method: 'DELETE', token: first.session.accessToken });
    const again = await signIn({ uuid: 'uuid-deleted-1' });
    expect((await me(again.session.accessToken)).avatarUrl).toBeNull();
  });
});
