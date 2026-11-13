import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { dailyRequestLimit, friendsPageSize, maxOutgoing } from '../src/social/friends';
import { orderedPair, relationship } from '../src/social/relationship';

type Person = { handle: string; displayName: string | null; avatar: string | null; since?: number };
type Friends = { friends: Person[]; cursor: string | null; incoming?: Person[]; outgoing?: Person[]; counts?: { friends: number; incoming: number } };

let counter = 0;
const uniqueHandle = (prefix = 'pal') => `${prefix}_${++counter}_${Math.floor(Math.random() * 1e6)}`;

/** A signed-in account with Friends on; returns its token, id, handle and code. */
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

/** People made straight in D1, for limits and pages that need many. */
async function quietMembers(count: number) {
  const now = Date.now();
  const made: { id: string; handle: string }[] = [];
  const statements: D1PreparedStatement[] = [];
  for (let index = 0; index < count; index++) {
    const id = crypto.randomUUID();
    const handle = uniqueHandle('q');
    made.push({ id, handle });
    statements.push(
      testEnv.DB.prepare(`INSERT INTO users (id, trakt_uuid, trakt_username, created_at, updated_at) VALUES (?, ?, 'x', 0, 0)`)
        .bind(id, `quiet-${id}`),
      testEnv.DB.prepare(
        `INSERT INTO social_profiles (user_id, handle, handle_key, handle_changed_at, friend_code, created_at, updated_at)
         VALUES (?, ?, ?, 0, ?, ?, ?)`,
      ).bind(id, handle, handle.toLowerCase(), id.replace(/-/g, '').slice(0, 12).toUpperCase(), now, now),
    );
  }
  await testEnv.DB.batch(statements);
  return made;
}

const send = (token: string, body: unknown) => call('/api/v1/social/requests', { method: 'POST', token, body });
const accept = (token: string, handle: string) =>
  call(`/api/v1/social/requests/${handle}/accept`, { method: 'POST', token, body: {} });
const decline = (token: string, handle: string) =>
  call(`/api/v1/social/requests/${handle}/decline`, { method: 'POST', token, body: {} });
const cancel = (token: string, handle: string) => call(`/api/v1/social/requests/${handle}`, { method: 'DELETE', token });

async function list(token: string, cursor = ''): Promise<Friends> {
  const response = await call(`/api/v1/social/friends${cursor ? `?cursor=${cursor}` : ''}`, { token });
  expect(response.status).toBe(200);
  return (await response.json()) as Friends;
}

const handles = (people: Person[] | undefined) => (people ?? []).map((person) => person.handle);

async function errorOf(response: Response) {
  return ((await response.json()) as { error: { code: string; message: string } }).error;
}

async function friends(one: { token: string; handle: string }, other: { token: string; handle: string; code: string }) {
  expect((await send(one.token, { code: other.code })).status).toBe(201);
  expect((await accept(other.token, one.handle)).status).toBe(200);
}

describe('Finding someone', () => {
  it('a friend code, typed any way, sends a request both sides can see', async () => {
    const ana = await member();
    const ben = await member({ displayName: 'Ben' });
    const typed = `${ben.code.slice(0, 4).toLowerCase()}-${ben.code.slice(4)} `;
    const response = await send(ana.token, { code: typed });
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ status: 'requested', person: { handle: ben.handle, displayName: 'Ben', avatar: null } });
    expect(handles((await list(ana.token)).outgoing)).toEqual([ben.handle]);
    const benView = await list(ben.token);
    expect(handles(benView.incoming)).toEqual([ana.handle]);
    expect(benView.counts).toEqual({ friends: 0, incoming: 1 });
    // Asking again changes nothing.
    expect(((await (await send(ana.token, { code: ben.code })).json()) as { status: string }).status).toBe('requested');
    expect(handles((await list(ben.token)).incoming)).toEqual([ana.handle]);
  });

  it('by handle only when its owner allows it', async () => {
    const ana = await member();
    const ben = await member();
    expect((await send(ana.token, { handle: ben.handle })).status).toBe(404);
    await call('/api/v1/social/profile', { method: 'PUT', token: ben.token, body: { findByHandle: true } });
    expect((await send(ana.token, { handle: `@${ben.handle.toUpperCase()}` })).status).toBe(201);
  });

  it('unknown, hidden and blocked people get the same answer', async () => {
    const ana = await member();
    const hidden = await member({ findByCode: false });
    const blocker = await member({ findByHandle: true });
    const blocked = await member({ findByHandle: true });
    await friends(ana, blocker);
    await friends(blocked, blocker);
    await call('/api/v1/social/blocks', { method: 'POST', token: blocker.token, body: { handle: blocked.handle } });

    const answers = [
      await send(ana.token, { code: 'ZZZZ-ZZZZ' }),
      await send(ana.token, { code: 'not a code' }),
      await send(ana.token, { handle: 'nobody_here_at_all' }),
      await send(ana.token, { code: hidden.code }),
      await send(blocked.token, { code: blocker.code }),
      await send(blocked.token, { handle: blocker.handle }),
    ];
    const blockerToo = await send(blocker.token, { handle: blocked.handle });
    for (const response of [...answers, blockerToo]) {
      expect(response.status).toBe(404);
      expect(await errorOf(response)).toEqual({ code: 'not_found', message: 'No one was found. Check it and try again.', requestId: expect.any(String) });
    }
  });

  it('refuses yourself, and needs Friends on', async () => {
    const ana = await member();
    expect((await errorOf(await send(ana.token, { code: ana.code }))).code).toBe('that_is_you');
    const off = await signIn();
    const response = await send(off.session.accessToken, { code: ana.code });
    expect(response.status).toBe(409);
    expect((await errorOf(response)).code).toBe('friends_off');
  });

  it('limits finding to 10 a minute', async () => {
    const ana = await member();
    const statuses: number[] = [];
    for (let attempt = 0; attempt < 11; attempt++) {
      statuses.push((await send(ana.token, { code: 'ZZZZZZZZ' })).status);
    }
    expect(statuses.slice(0, 10).every((status) => status === 404)).toBe(true);
    expect(statuses[10]).toBe(429);
  });

  it('a daily limit, and a limit on requests waiting', async () => {
    const ana = await member();
    const ben = await member();
    const today = Math.floor(Date.now() / (24 * 60 * 60 * 1000));
    await testEnv.DB.prepare(`INSERT INTO social_counters (user_id, day, requests) VALUES (?, ?, ?)`)
      .bind(ana.id, today, dailyRequestLimit).run();
    expect((await errorOf(await send(ana.token, { code: ben.code }))).code).toBe('request_limit');

    const cara = await member();
    const waiting = await quietMembers(maxOutgoing);
    await testEnv.DB.batch(waiting.map((person) =>
      testEnv.DB.prepare(`INSERT INTO friend_requests (sender_id, receiver_id, created_at) VALUES (?, ?, 1)`)
        .bind(cara.id, person.id)));
    expect((await errorOf(await send(cara.token, { code: ben.code }))).code).toBe('too_many_pending');
  });
});

describe('Answering requests', () => {
  it('only the receiver accepts or declines; only the sender cancels', async () => {
    const ana = await member();
    const ben = await member();
    const eve = await member();
    await send(ana.token, { code: ben.code });
    // Ana cannot accept her own request; Eve cannot touch it.
    expect((await accept(ana.token, ben.handle)).status).toBe(404);
    expect((await accept(eve.token, ana.handle)).status).toBe(404);
    expect((await decline(eve.token, ana.handle)).status).toBe(404);
    expect((await cancel(eve.token, ben.handle)).status).toBe(404);
    expect((await cancel(ben.token, ana.handle)).status).toBe(404);
    expect(await relationship(testEnv, ana.id, ben.id)).toBe('none');

    expect((await cancel(ana.token, ben.handle)).status).toBe(200);
    expect(handles((await list(ben.token)).incoming)).toEqual([]);

    await send(ana.token, { code: ben.code });
    expect((await decline(ben.token, ana.handle)).status).toBe(200);
    expect(handles((await list(ana.token)).outgoing)).toEqual([]);
    expect(await relationship(testEnv, ana.id, ben.id)).toBe('none');
  });

  it('accepting makes both friends, once', async () => {
    const ana = await member();
    const ben = await member({ displayName: 'Ben', avatar: 'avatar2' });
    await send(ana.token, { code: ben.code });
    const accepted = await accept(ben.token, ana.handle);
    expect(await accepted.json()).toMatchObject({ status: 'friends', person: { handle: ana.handle } });
    expect(handles((await list(ana.token)).friends)).toEqual([ben.handle]);
    expect(handles((await list(ben.token)).friends)).toEqual([ana.handle]);
    expect((await list(ana.token)).friends[0]).toMatchObject({ displayName: 'Ben', avatar: 'avatar2', since: expect.any(Number) });
    // The request is gone, and a second accept finds nothing.
    expect((await accept(ben.token, ana.handle)).status).toBe(404);
    const already = await send(ana.token, { code: ben.code });
    expect(((await already.json()) as { status: string }).status).toBe('friends');
  });

  it('two people asking each other become friends', async () => {
    const ana = await member();
    const ben = await member();
    await send(ana.token, { code: ben.code });
    const answer = await send(ben.token, { code: ana.code });
    expect(((await answer.json()) as { status: string }).status).toBe('friends');
    const [a, b] = orderedPair(ana.id, ben.id);
    expect((await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM friendships WHERE user_a = ? AND user_b = ?`).bind(a, b).first<{ n: number }>())!.n).toBe(1);
    expect((await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM friend_requests WHERE sender_id IN (?1, ?2) AND receiver_id IN (?1, ?2)`).bind(ana.id, ben.id).first<{ n: number }>())!.n).toBe(0);
  });

  it('two people asking each other at the same moment still end as one friendship', async () => {
    const ana = await member();
    const ben = await member();
    const [one, two] = await Promise.all([send(ana.token, { code: ben.code }), send(ben.token, { code: ana.code })]);
    expect([one.status, two.status].every((status) => status === 200 || status === 201)).toBe(true);
    const [a, b] = orderedPair(ana.id, ben.id);
    const friendshipCount = (await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM friendships WHERE user_a = ? AND user_b = ?`).bind(a, b).first<{ n: number }>())!.n;
    const pending = (await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM friend_requests WHERE sender_id IN (?1, ?2) AND receiver_id IN (?1, ?2)`).bind(ana.id, ben.id).first<{ n: number }>())!.n;
    // Either one friendship, or (if both ran before either saw the other) two
    // requests that the next send or accept turns into one.
    expect(friendshipCount + (pending === 2 ? 1 : 0)).toBe(1);
  });
});

describe('Friends', () => {
  it("a friend's profile is for friends only", async () => {
    const ana = await member();
    const ben = await member({ displayName: 'Ben' });
    const eve = await member();
    expect((await call(`/api/v1/social/friends/${ben.handle}`, { token: ana.token })).status).toBe(404);
    await friends(ana, ben);
    const response = await call(`/api/v1/social/friends/${ben.handle}`, { token: ana.token });
    expect(await response.json()).toEqual({ friend: { handle: ben.handle, displayName: 'Ben', avatar: null, since: expect.any(Number) }, collections: [] });
    expect((await call(`/api/v1/social/friends/${ben.handle}`, { token: eve.token })).status).toBe(404);
  });

  it('removing a friend ends it for both', async () => {
    const ana = await member();
    const ben = await member();
    await friends(ana, ben);
    expect((await call(`/api/v1/social/friends/${ana.handle}`, { method: 'DELETE', token: ben.token })).status).toBe(200);
    expect(handles((await list(ana.token)).friends)).toEqual([]);
    expect((await call(`/api/v1/social/friends/${ben.handle}`, { token: ana.token })).status).toBe(404);
    expect((await call(`/api/v1/social/friends/${ana.handle}`, { method: 'DELETE', token: ben.token })).status).toBe(404);
  });

  it('turning Friends off removes you from their list', async () => {
    const ana = await member();
    const ben = await member();
    await friends(ana, ben);
    await call('/api/v1/social/profile', { method: 'DELETE', token: ana.token });
    expect(handles((await list(ben.token)).friends)).toEqual([]);
  });

  it('lists friends in pages of 50, in handle order', async () => {
    const ana = await member();
    const people = await quietMembers(friendsPageSize + 3);
    await testEnv.DB.batch(people.map((person) => {
      const [a, b] = orderedPair(ana.id, person.id);
      return testEnv.DB.prepare(`INSERT INTO friendships (user_a, user_b, created_at) VALUES (?, ?, 1)`).bind(a, b);
    }));
    const first = await list(ana.token);
    expect(first.friends).toHaveLength(friendsPageSize);
    expect(first.counts?.friends).toBe(friendsPageSize + 3);
    const second = await list(ana.token, first.cursor!);
    expect(second.friends).toHaveLength(3);
    expect(second.cursor).toBeNull();
    expect(second.incoming).toBeUndefined();
    const all = [...handles(first.friends), ...handles(second.friends)];
    expect(all).toEqual(people.map((person) => person.handle).sort((x, y) => x.toLowerCase().localeCompare(y.toLowerCase())));
    expect((await call('/api/v1/social/friends?cursor=%27or1%3D1', { token: ana.token })).status).toBe(400);
  });

  it('the profile counts friends and waiting requests', async () => {
    const ana = await member();
    const ben = await member();
    const cara = await member();
    await friends(ana, ben);
    await send(cara.token, { code: ana.code });
    const response = await call('/api/v1/social/profile', { token: ana.token });
    expect(((await response.json()) as { counts: unknown }).counts).toEqual({ friends: 1, incoming: 1, unread: 0 });
  });

  it('never shows an account id or Trakt name', async () => {
    const account = await signIn({ username: 'trakt_secret_name' });
    const ana = await member();
    const handle = uniqueHandle('secret');
    await call('/api/v1/social/profile', { method: 'PUT', token: account.session.accessToken, body: { handle } });
    const code = ((await (await call('/api/v1/social/profile', { token: account.session.accessToken })).json()) as { profile: { friendCode: string } }).profile.friendCode;
    const texts = [
      await (await send(ana.token, { code })).text(),
      await (await call('/api/v1/social/friends', { token: ana.token })).text(),
      await (await call('/api/v1/social/friends', { token: account.session.accessToken })).text(),
    ];
    for (const text of texts) {
      expect(text).not.toContain('trakt_secret_name');
      expect(text).not.toContain(account.user.id);
      expect(text).not.toContain(ana.id);
    }
  });
});

describe('Blocking and reporting', () => {
  it('blocking ends everything both ways and refuses contact; unblocking restores nothing', async () => {
    const ana = await member({ findByHandle: true });
    const ben = await member({ findByHandle: true });
    await friends(ana, ben);
    await testEnv.DB.prepare(
      `INSERT INTO recommendations (id, sender_id, recipient_id, media_key, title, client_id, created_at)
       VALUES (?, ?, ?, 'movie:1', 'A', 'c1', 1), (?, ?, ?, 'movie:2', 'B', 'c2', 1)`,
    ).bind(crypto.randomUUID(), ben.id, ana.id, crypto.randomUUID(), ana.id, ben.id).run();

    expect((await call('/api/v1/social/blocks', { method: 'POST', token: ana.token, body: { handle: ben.handle } })).status).toBe(200);
    expect(await relationship(testEnv, ana.id, ben.id)).toBe('blocked');
    expect(handles((await list(ana.token)).friends)).toEqual([]);
    expect(handles((await list(ben.token)).friends)).toEqual([]);
    expect((await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM recommendations WHERE sender_id IN (?1, ?2) AND recipient_id IN (?1, ?2)`).bind(ana.id, ben.id).first<{ n: number }>())!.n).toBe(0);
    expect((await send(ben.token, { handle: ana.handle })).status).toBe(404);
    expect((await call(`/api/v1/social/friends/${ana.handle}`, { token: ben.token })).status).toBe(404);

    const blocked = (await (await call('/api/v1/social/blocks', { token: ana.token })).json()) as { blocked: Person[] };
    expect(handles(blocked.blocked)).toEqual([ben.handle]);
    // Ben cannot see or undo Ana's block.
    expect(handles(((await (await call('/api/v1/social/blocks', { token: ben.token })).json()) as { blocked: Person[] }).blocked)).toEqual([]);
    expect((await call(`/api/v1/social/blocks/${ana.handle}`, { method: 'DELETE', token: ben.token })).status).toBe(404);

    expect((await call(`/api/v1/social/blocks/${ben.handle}`, { method: 'DELETE', token: ana.token })).status).toBe(200);
    expect(await relationship(testEnv, ana.id, ben.id)).toBe('none');
    expect((await send(ben.token, { handle: ana.handle })).status).toBe(201);
  });

  it('a request can be blocked; a stranger cannot be blocked or reported', async () => {
    const ana = await member();
    const ben = await member();
    const stranger = await member({ findByHandle: true });
    await send(ben.token, { code: ana.code });
    expect((await call('/api/v1/social/blocks', { method: 'POST', token: ana.token, body: { handle: ben.handle } })).status).toBe(200);
    expect(handles((await list(ana.token)).incoming)).toEqual([]);
    expect((await call('/api/v1/social/blocks', { method: 'POST', token: ana.token, body: { handle: stranger.handle } })).status).toBe(404);
    expect((await call('/api/v1/social/reports', { method: 'POST', token: ana.token, body: { handle: stranger.handle, reason: 'spam' } })).status).toBe(404);
  });

  it('a report is kept for the developer with the reported account, the reporter only as a hash', async () => {
    const ana = await member();
    const ben = await member();
    await send(ben.token, { code: ana.code });
    expect((await call('/api/v1/social/reports', { method: 'POST', token: ana.token, body: { handle: ben.handle, reason: 'nope' } })).status).toBe(400);
    const response = await call('/api/v1/social/reports', {
      method: 'POST', token: ana.token, body: { handle: ben.handle, reason: 'harassment', note: 'Rude\u0007 name' },
    });
    expect(response.status).toBe(201);
    const { id } = (await response.json()) as { id: string };
    const row = await testEnv.DB.prepare(`SELECT * FROM support_reports WHERE id = ?`).bind(id).first<Record<string, string>>();
    expect(row).toMatchObject({ kind: 'person', category: 'harassment', title: `@${ben.handle}`, description: 'Rude name' });
    expect(JSON.parse(row!.diagnostics)).toMatchObject({ reportedUser: ben.id, handle: ben.handle });
    expect(JSON.stringify(row)).not.toContain(ana.id);
  });
});
