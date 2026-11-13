import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { codeAlphabet, handleChangeIntervalMs, handleHoldMs } from '../src/social/profiles';
import { orderedPair, relationship } from '../src/social/relationship';
import { pruneSocial, recommendationRetentionMs, requestRetentionMs } from '../src/social/retention';

type Profile = {
  handle: string;
  friendCode: string;
  displayName: string | null;
  avatar: string | null;
  findByCode: boolean;
  findByHandle: boolean;
  allowRecommendations: boolean;
  shareActivity: boolean;
  handleChangeableAt: number;
  createdAt: number;
};

let handleCounter = 0;
const uniqueHandle = (prefix = 'viewer') => `${prefix}_${++handleCounter}_${Math.floor(Math.random() * 1e6)}`;

const put = (token: string, body: unknown) => call('/api/v1/social/profile', { method: 'PUT', token, body });

async function enable(token: string, extra: Record<string, unknown> = {}): Promise<Profile> {
  const response = await put(token, { handle: uniqueHandle(), ...extra });
  expect(response.status).toBe(201);
  return ((await response.json()) as { profile: Profile }).profile;
}

async function profile(token: string): Promise<Profile | null> {
  const response = await call('/api/v1/social/profile', { token });
  expect(response.status).toBe(200);
  return ((await response.json()) as { profile: Profile | null }).profile;
}

async function errorCode(response: Response): Promise<string> {
  return ((await response.json()) as { error: { code: string } }).error.code;
}

const count = async (sql: string, ...values: unknown[]) =>
  (await testEnv.DB.prepare(sql).bind(...values).first<{ n: number }>())!.n;

async function befriend(one: string, other: string) {
  const [a, b] = orderedPair(one, other);
  await testEnv.DB.prepare(`INSERT INTO friendships (user_a, user_b, created_at) VALUES (?, ?, ?)`)
    .bind(a, b, Date.now()).run();
}

const block = (blocker: string, blocked: string) =>
  testEnv.DB.prepare(`INSERT INTO blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)`)
    .bind(blocker, blocked, Date.now()).run();

const request = (sender: string, receiver: string, at = Date.now()) =>
  testEnv.DB.prepare(`INSERT INTO friend_requests (sender_id, receiver_id, created_at) VALUES (?, ?, ?)`)
    .bind(sender, receiver, at).run();

const recommend = (sender: string, recipient: string, at = Date.now()) =>
  testEnv.DB.prepare(
    `INSERT INTO recommendations (id, sender_id, recipient_id, media_key, title, client_id, created_at)
     VALUES (?, ?, ?, 'movie:438631', 'Dune', ?, ?)`,
  ).bind(crypto.randomUUID(), sender, recipient, crypto.randomUUID(), at).run();

const shareActivity = (user: string, expiresAt = Date.now() + 60_000) =>
  testEnv.DB.prepare(
    `INSERT INTO current_activity (user_id, media_key, title, started_at, updated_at, expires_at)
     VALUES (?, 'movie:438631', 'Dune', ?, ?, ?)`,
  ).bind(user, Date.now(), Date.now(), expiresAt).run();

describe('Social profile', () => {
  it('Friends is off until the owner turns it on', async () => {
    const { session, user } = await signIn();
    expect(await profile(session.accessToken)).toBeNull();
    expect(await count(`SELECT COUNT(*) AS n FROM social_profiles WHERE user_id = ?`, user.id)).toBe(0);
  });

  it('turning Friends on needs a handle and starts with private defaults', async () => {
    const { session } = await signIn();
    const missing = await put(session.accessToken, { findByHandle: true });
    expect(missing.status).toBe(400);
    expect(await errorCode(missing)).toBe('handle_required');

    const made = await enable(session.accessToken);
    expect(made).toMatchObject({
      displayName: null,
      avatar: null,
      findByCode: true,
      findByHandle: false,
      allowRecommendations: true,
      shareActivity: false,
    });
    expect(made.friendCode).toMatch(new RegExp(`^[${codeAlphabet}]{8}$`));
    expect(await profile(session.accessToken)).toEqual(made);
  });

  it('never returns the Trakt username or any account id', async () => {
    const { session, user } = await signIn({ username: 'secret_trakt_name' });
    await enable(session.accessToken);
    const text = await (await call('/api/v1/social/profile', { token: session.accessToken })).text();
    expect(text).not.toContain('secret_trakt_name');
    expect(text).not.toContain(user.id);
  });

  it('refuses malformed, reserved and look-alike handles', async () => {
    const { session } = await signIn();
    for (const handle of ['ab', '1abc', 'has space', 'émile', 'a'.repeat(21), 'semi;colon', 42]) {
      const response = await put(session.accessToken, { handle });
      expect(response.status, String(handle)).toBe(400);
      expect(await errorCode(response)).toBe('invalid_handle');
    }
    // Another account: handle claims are limited to 10 a minute each.
    const other = await signIn();
    for (const handle of ['Admin', 'support', 'ReelishTeam', 'the_reelish']) {
      const response = await put(other.session.accessToken, { handle });
      expect(response.status, handle).toBe(400);
      expect(await errorCode(response)).toBe('handle_reserved');
    }
  });

  it('a handle belongs to one account, whatever its case', async () => {
    const ana = await signIn();
    const ben = await signIn();
    const handle = uniqueHandle('Ana');
    expect((await put(ana.session.accessToken, { handle })).status).toBe(201);
    const taken = await put(ben.session.accessToken, { handle: handle.toUpperCase() });
    expect(taken.status).toBe(409);
    expect(await errorCode(taken)).toBe('handle_taken');
  });

  it('the first handle change is free, the next waits a week; an old handle is held for others', async () => {
    const ana = await signIn();
    const ben = await signIn();
    const first = uniqueHandle('first');
    await put(ana.session.accessToken, { handle: first });
    const second = uniqueHandle('second');
    expect((await put(ana.session.accessToken, { handle: second })).status).toBe(200);

    const tooSoon = await put(ana.session.accessToken, { handle: uniqueHandle('third') });
    expect(tooSoon.status).toBe(429);
    expect(await errorCode(tooSoon)).toBe('handle_change_too_soon');
    // Only the letter case: the same handle, allowed at any time.
    expect((await put(ana.session.accessToken, { handle: second.toUpperCase() })).status).toBe(200);

    expect(await errorCode(await put(ben.session.accessToken, { handle: first }))).toBe('handle_taken');

    // A week later Ana may take her old handle back.
    await testEnv.DB.prepare(`UPDATE social_profiles SET handle_changed_at = handle_changed_at - ? WHERE user_id = ?`)
      .bind(handleChangeIntervalMs, ana.user.id).run();
    const back = await put(ana.session.accessToken, { handle: first });
    expect(back.status).toBe(200);
    expect(((await back.json()) as { profile: Profile }).profile.handle).toBe(first);
  });

  it('checks the display name and avatar', async () => {
    const { session } = await signIn();
    await enable(session.accessToken);
    for (const displayName of ['x'.repeat(41), 'see https://spam', 'visit www.spam', 'spam.com', 7]) {
      const response = await put(session.accessToken, { displayName });
      expect(response.status, String(displayName)).toBe(400);
    }
    const named = await put(session.accessToken, { displayName: '  Ana\u0007 ‮M ', avatar: 'avatar3' });
    expect(((await named.json()) as { profile: Profile }).profile).toMatchObject({ displayName: 'Ana M', avatar: 'avatar3' });
    expect((await put(session.accessToken, { avatar: 'avatar9' })).status).toBe(400);
    expect((await put(session.accessToken, { avatar: '../etc' })).status).toBe(400);
    const cleared = await put(session.accessToken, { displayName: null, avatar: null });
    expect(((await cleared.json()) as { profile: Profile }).profile).toMatchObject({ displayName: null, avatar: null });
  });

  it('settings are true or false and change only what is sent', async () => {
    const { session } = await signIn();
    await enable(session.accessToken);
    expect((await put(session.accessToken, { findByHandle: 'yes' })).status).toBe(400);
    expect((await put(session.accessToken, { shareActivity: 1 })).status).toBe(400);
    const changed = await put(session.accessToken, { findByHandle: true, allowRecommendations: false });
    expect(((await changed.json()) as { profile: Profile }).profile).toMatchObject({
      findByCode: true,
      findByHandle: true,
      allowRecommendations: false,
      shareActivity: false,
    });
  });

  it('acts only on the caller, whatever ids the body names', async () => {
    const ana = await signIn();
    const ben = await signIn();
    const before = await enable(ana.session.accessToken);
    await enable(ben.session.accessToken);
    await put(ben.session.accessToken, { userId: ana.user.id, user_id: ana.user.id, findByHandle: true, displayName: 'Ben' });
    expect(await profile(ana.session.accessToken)).toEqual(before);
    expect((await profile(ben.session.accessToken))!.displayName).toBe('Ben');
  });

  it('turning activity sharing off removes the current activity at once', async () => {
    const { session, user } = await signIn();
    await enable(session.accessToken, { shareActivity: true });
    await shareActivity(user.id);
    await put(session.accessToken, { shareActivity: false });
    expect(await count(`SELECT COUNT(*) AS n FROM current_activity WHERE user_id = ?`, user.id)).toBe(0);
  });

  it('a new friend code replaces the old one; it needs Friends on', async () => {
    const { session } = await signIn();
    const off = await call('/api/v1/social/profile/code', { method: 'POST', token: session.accessToken });
    expect(off.status).toBe(409);
    expect(await errorCode(off)).toBe('friends_off');
    const before = await enable(session.accessToken);
    const reset = await call('/api/v1/social/profile/code', { method: 'POST', token: session.accessToken });
    expect(reset.status).toBe(200);
    const after = ((await reset.json()) as { profile: Profile }).profile;
    expect(after.friendCode).not.toBe(before.friendCode);
    expect(after.friendCode).toMatch(new RegExp(`^[${codeAlphabet}]{8}$`));
  });

  it('limits handle claims to 10 a minute per account', async () => {
    const { session } = await signIn();
    const statuses: number[] = [];
    for (let attempt = 0; attempt < 11; attempt++) {
      statuses.push((await put(session.accessToken, { handle: 'x' })).status);
    }
    expect(statuses.slice(0, 10).every((status) => status === 400)).toBe(true);
    expect(statuses[10]).toBe(429);
  });

  it('needs a signed-in, live session', async () => {
    expect((await call('/api/v1/social/profile')).status).toBe(401);
    const { session } = await signIn();
    await call('/api/v1/auth/logout', { method: 'POST', token: session.accessToken });
    expect((await call('/api/v1/social/profile', { token: session.accessToken })).status).toBe(401);
    expect((await put(session.accessToken, { handle: uniqueHandle() })).status).toBe(401);
  });
});

describe('Turning Friends off', () => {
  it('removes every social row of the account and makes its collections private', async () => {
    const ana = await signIn();
    const ben = await signIn();
    const cara = await signIn();
    const handle = uniqueHandle('leaving');
    await put(ana.session.accessToken, { handle });
    await enable(ben.session.accessToken);
    await enable(cara.session.accessToken);
    const [a, b, c] = [ana.user.id, ben.user.id, cara.user.id];
    await befriend(a, b);
    await befriend(b, c);
    await request(a, c);
    await request(c, a);
    await block(a, c);
    await block(c, a);
    await shareActivity(a);
    await recommend(b, a); // received: removed
    await recommend(a, b); // sent: stays with Ben
    await testEnv.DB.prepare(`INSERT INTO social_counters (user_id, day, requests) VALUES (?, 1, 3)`).bind(a).run();
    await testEnv.DB.prepare(
      `INSERT INTO collection_records (user_id, kind, record_key, body, device_id, seq, client_at, changed_at, visibility)
       VALUES (?, 'collection', ?, '{}', 'device-aaaaaaaa', 1, 1, 1, 'friends')`,
    ).bind(a, 'c'.repeat(24)).run();

    const off = await call('/api/v1/social/profile', { method: 'DELETE', token: ana.session.accessToken });
    expect(off.status).toBe(200);
    expect(await profile(ana.session.accessToken)).toBeNull();

    expect(await count(`SELECT COUNT(*) AS n FROM friendships WHERE user_a = ?1 OR user_b = ?1`, a)).toBe(0);
    expect(await count(`SELECT COUNT(*) AS n FROM friend_requests WHERE sender_id = ?1 OR receiver_id = ?1`, a)).toBe(0);
    expect(await count(`SELECT COUNT(*) AS n FROM blocks WHERE blocker_id = ?`, a)).toBe(0);
    expect(await count(`SELECT COUNT(*) AS n FROM current_activity WHERE user_id = ?`, a)).toBe(0);
    expect(await count(`SELECT COUNT(*) AS n FROM recommendations WHERE recipient_id = ?`, a)).toBe(0);
    expect(await count(
      `SELECT COUNT(*) AS n FROM collection_records WHERE user_id = ? AND visibility <> 'private'`, a,
    )).toBe(0);
    // Other people's data stays: Cara's block of Ana, Ben's friendship with
    // Cara, Ben's copy of Ana's recommendation; and Ana's limits.
    expect(await count(`SELECT COUNT(*) AS n FROM blocks WHERE blocker_id = ? AND blocked_id = ?`, c, a)).toBe(1);
    expect(await relationship(testEnv, b, c)).toBe('friend');
    expect(await count(`SELECT COUNT(*) AS n FROM recommendations WHERE recipient_id = ?`, b)).toBe(1);
    expect(await count(`SELECT COUNT(*) AS n FROM social_counters WHERE user_id = ?`, a)).toBe(1);

    // The handle is held from everyone else, but Ana may take it back.
    const other = await signIn();
    expect(await errorCode(await put(other.session.accessToken, { handle }))).toBe('handle_taken');
    expect((await put(ana.session.accessToken, { handle })).status).toBe(201);
  });

  it('is harmless when Friends is already off', async () => {
    const { session } = await signIn();
    expect((await call('/api/v1/social/profile', { method: 'DELETE', token: session.accessToken })).status).toBe(200);
  });
});

describe('Deleting the account', () => {
  it('removes every social row and holds the handle', async () => {
    const ana = await signIn();
    const ben = await signIn();
    const handle = uniqueHandle('gone');
    await put(ana.session.accessToken, { handle });
    await enable(ben.session.accessToken);
    const [a, b] = [ana.user.id, ben.user.id];
    await befriend(a, b);
    await request(b, a);
    await block(b, a);
    await shareActivity(a);
    await recommend(a, b);
    await recommend(b, a);

    expect((await call('/api/v1/me', { method: 'DELETE', token: ana.session.accessToken })).status).toBe(200);
    for (const [table, column] of [
      ['social_profiles', 'user_id'], ['friendships', 'user_a'], ['friendships', 'user_b'],
      ['friend_requests', 'sender_id'], ['friend_requests', 'receiver_id'], ['blocks', 'blocked_id'],
      ['current_activity', 'user_id'], ['recommendations', 'sender_id'], ['recommendations', 'recipient_id'],
    ]) {
      expect(await count(`SELECT COUNT(*) AS n FROM ${table} WHERE ${column} = ?`, a), `${table}.${column}`).toBe(0);
    }
    expect(await errorCode(await put((await signIn()).session.accessToken, { handle }))).toBe('handle_taken');
  });
});

describe('Relationship check', () => {
  it('tells self, stranger, friend and blocked apart; a block wins', async () => {
    const ana = await signIn();
    const ben = await signIn();
    const cara = await signIn();
    const [a, b, c] = [ana.user.id, ben.user.id, cara.user.id];
    expect(await relationship(testEnv, a, a)).toBe('self');
    expect(await relationship(testEnv, a, b)).toBe('none');
    await befriend(a, b);
    expect(await relationship(testEnv, a, b)).toBe('friend');
    expect(await relationship(testEnv, b, a)).toBe('friend');
    await block(b, a);
    expect(await relationship(testEnv, a, b)).toBe('blocked');
    expect(await relationship(testEnv, b, a)).toBe('blocked');
    // A pending request is not a friendship.
    await request(a, c);
    expect(await relationship(testEnv, a, c)).toBe('none');
  });

  it('stores a friendship once, smaller id first', async () => {
    const ana = await signIn();
    const ben = await signIn();
    const [low, high] = orderedPair(ana.user.id, ben.user.id);
    await expect(
      testEnv.DB.prepare(`INSERT INTO friendships (user_a, user_b, created_at) VALUES (?, ?, 1)`).bind(high, low).run(),
    ).rejects.toThrow();
    await befriend(low, high);
    await expect(
      testEnv.DB.prepare(`INSERT INTO friendships (user_a, user_b, created_at) VALUES (?, ?, 1)`).bind(low, high).run(),
    ).rejects.toThrow();
  });
});

describe('Social retention', () => {
  it('prunes held handles, old requests and recommendations, expired activity and old counters', async () => {
    const ana = await signIn();
    const ben = await signIn();
    const [a, b] = [ana.user.id, ben.user.id];
    const now = Date.now();
    const day = 24 * 60 * 60 * 1000;
    await testEnv.DB.prepare(`INSERT INTO released_handles (handle_key, user_id, released_at) VALUES (?, NULL, ?), (?, NULL, ?)`)
      .bind(`old_${a}`, now - handleHoldMs - 1, `new_${a}`, now).run();
    await request(a, b, now - requestRetentionMs - 1);
    await request(b, a, now);
    await recommend(a, b, now - recommendationRetentionMs - 1);
    await recommend(b, a, now);
    await shareActivity(a, now - 1);
    await shareActivity(b, now + 60_000);
    const today = Math.floor(now / day);
    await testEnv.DB.prepare(`INSERT INTO social_counters (user_id, day) VALUES (?, ?), (?, ?)`)
      .bind(a, today - 3, a, today).run();

    await pruneSocial(testEnv, now);

    expect(await count(`SELECT COUNT(*) AS n FROM released_handles WHERE handle_key IN (?, ?)`, `old_${a}`, `new_${a}`)).toBe(1);
    expect(await count(`SELECT COUNT(*) AS n FROM friend_requests WHERE sender_id IN (?1, ?2) AND receiver_id IN (?1, ?2)`, a, b)).toBe(1);
    expect(await count(`SELECT COUNT(*) AS n FROM recommendations WHERE sender_id IN (?1, ?2)`, a, b)).toBe(1);
    expect(await count(`SELECT COUNT(*) AS n FROM current_activity WHERE user_id IN (?1, ?2)`, a, b)).toBe(1);
    expect(await count(`SELECT COUNT(*) AS n FROM social_counters WHERE user_id = ?`, a)).toBe(1);
  });
});
