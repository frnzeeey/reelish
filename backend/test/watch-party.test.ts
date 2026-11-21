import { describe, expect, it, vi } from 'vitest';
import { runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { call, signIn, testEnv } from './helpers';
import { hostQuotaPerHour, newCode, prunePartyCodes } from '../src/watch-party';
import { closeCodes, emptyGraceMs, hostGraceMs, participantId, presenceCheckMs, staleSocketMs, type WatchPartyRoom } from '../src/party-room';

type ErrorBody = { error: { code: string } };
const codeOf = async (response: Response) => ((await response.json()) as ErrorBody).error.code;

const movie = { tmdbId: 603, type: 'movie', title: 'The Matrix', posterPath: '/matrix.jpg' };
const episode = { tmdbId: 1399, type: 'series', season: 1, episode: 2, title: 'Game of Thrones' };

async function create(token: string, body: Record<string, unknown> = {}) {
  const response = await call('/api/v1/party', {
    token,
    body: { content: movie, profile: { name: 'Host', avatar: 'avatar3' }, ...body },
  });
  return response;
}

/** Marks an account as having a verified donation, as the webhook does. */
async function makeSupporter(userId: string) {
  await testEnv.DB.prepare(
    `INSERT INTO supporter_profiles (user_id, support_code, supporter_since, created_at, updated_at)
     VALUES (?, ?, 1000, 1000, 1000)
     ON CONFLICT (user_id) DO UPDATE SET supporter_since = 1000`,
  )
    .bind(userId, `RS-${crypto.randomUUID().slice(0, 8)}`)
    .run();
}

/** A supporter, for the perks that still need one (avatar frames). */
async function supporter(options: { uuid?: string } = {}) {
  const account = await signIn(options);
  await makeSupporter(account.user.id);
  return account;
}

/** A free account hosting a room: hosting needs no entitlement. */
async function host(settings: Record<string, unknown> = {}) {
  const account = await signIn();
  const response = await create(account.session.accessToken, { settings });
  expect(response.status).toBe(201);
  const { code } = (await response.json()) as { code: string };
  return { account, token: account.session.accessToken, code };
}

type Message = Record<string, unknown> & { t: string };

/** A participant's socket that records every message from the room. */
class Client {
  readonly messages: Message[] = [];
  closed: { code: number } | null = null;
  private waiters: (() => void)[] = [];

  constructor(readonly ws: WebSocket) {
    ws.accept();
    ws.addEventListener('message', (event) => {
      this.messages.push(JSON.parse(event.data as string));
      this.wake();
    });
    ws.addEventListener('close', (event) => {
      this.closed = { code: event.code };
      this.wake();
    });
  }

  private wake() {
    const waiting = this.waiters;
    this.waiters = [];
    for (const resolve of waiting) resolve();
  }

  send(body: unknown) {
    this.ws.send(typeof body === 'string' ? body : JSON.stringify(body));
  }

  /** The next message of type [t] after [from] messages, waiting for it. */
  async next(t: string, predicate: (m: Message) => boolean = () => true, from = 0): Promise<Message> {
    const deadline = Date.now() + 3000;
    for (;;) {
      const found = this.messages.slice(from).find((m) => m.t === t && predicate(m));
      if (found) return found;
      if (Date.now() > deadline) throw new Error(`no ${t} message; got ${JSON.stringify(this.messages)}`);
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 100);
      });
    }
  }

  async waitClosed(): Promise<{ code: number }> {
    const deadline = Date.now() + 3000;
    while (!this.closed) {
      if (Date.now() > deadline) throw new Error('socket did not close');
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 100);
      });
    }
    return this.closed;
  }
}

async function connect(token: string, code: string): Promise<Client> {
  const response = await call(`/api/v1/party/${code}/socket`, { token, headers: { Upgrade: 'websocket' } });
  expect(response.status).toBe(101);
  const client = new Client(response.webSocket!);
  await client.next('welcome');
  return client;
}

const stub = (code: string) => testEnv.PARTY_ROOMS.get(testEnv.PARTY_ROOMS.idFromName(`party:${code}`));

describe('Watch party rooms', () => {
  it('makes uniform 8-digit codes', () => {
    for (let i = 0; i < 200; i++) expect(newCode()).toMatch(/^\d{8}$/);
  });

  it('creates a room the code previews, with conservative defaults', async () => {
    const { code, token } = await host();
    expect(code).toMatch(/^\d{8}$/);
    const preview = await call(`/api/v1/party/${code}`, { token: (await signIn()).session.accessToken });
    expect(preview.status).toBe(200);
    const body = (await preview.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      code,
      phase: 'lobby',
      content: movie,
      host: { name: 'Host', avatar: 'avatar3' },
      participants: 0,
      capacity: 5,
    });
    expect(JSON.stringify(body)).not.toContain('user');
  });

  it('requires a signed-in account and valid content', async () => {
    expect((await call('/api/v1/party', { body: { content: movie } })).status).toBe(401);
    const { session } = await signIn();
    const bad = await create(session.accessToken, { content: { tmdbId: 'x', type: 'movie', title: 'A' } });
    expect(await codeOf(bad)).toBe('invalid_content');
    const noEpisode = await create(session.accessToken, { content: { tmdbId: 1, type: 'series', title: 'A' } });
    expect(noEpisode.status).toBe(400);
    const ok = await create(session.accessToken, { content: episode, settings: { capacity: 99 } });
    expect(((await ok.json()) as { settings: { capacity: number } }).settings.capacity).toBe(5);
  });

  it('answers unknown and malformed codes alike', async () => {
    const { session } = await signIn();
    for (const code of ['00000001', 'abc', '123']) {
      const response = await call(`/api/v1/party/${code}`, { token: session.accessToken });
      expect(response.status).toBe(404);
      expect(await codeOf(response)).toBe('party_not_found');
    }
  });

  it('a new party ends the host\'s previous one', async () => {
    const first = await host();
    const watcher = await signIn();
    const guest = await connect(watcher.session.accessToken, first.code);
    const second = await create(first.token);
    expect(second.status).toBe(201);
    expect((await guest.next('ended')).reason).toBe('replaced');
    expect((await guest.waitClosed()).code).toBe(closeCodes.ended);
    expect((await call(`/api/v1/party/${first.code}`, { token: watcher.session.accessToken })).status).toBe(404);
  });

  it('joins over a WebSocket with the verified account, never a claimed one', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const welcome = hostClient.messages[0];
    expect(welcome).toMatchObject({ t: 'welcome', room: { code, phase: 'lobby' } });
    expect((welcome.room as { host: { pid: string } }).host.pid).toBe((welcome.you as { pid: string }).pid);

    const guestAccount = await signIn();
    // A forged identity header is dropped by the Worker.
    const response = await call(`/api/v1/party/${code}/socket`, {
      token: guestAccount.session.accessToken,
      headers: { Upgrade: 'websocket', 'X-Party-User': 'someone-else' },
    });
    const guest = new Client(response.webSocket!);
    const guestWelcome = await guest.next('welcome');
    expect((guestWelcome.you as { pid: string }).pid)
      .toBe(await participantId(code, guestAccount.user.id));

    guest.send({ t: 'hello', name: 'Guest‮ evil', avatar: 'avatar9' });
    const list = await hostClient.next('participants', (m) =>
      (m.participants as { name: string }[]).some((p) => p.name === 'Guest evil'));
    const guestEntry = (list.participants as { name: string; avatar: string | null; host: boolean }[])
      .find((p) => p.name === 'Guest evil')!;
    expect(guestEntry).toMatchObject({ avatar: null, host: false });
  });

  it('refuses sockets without a session, without an upgrade, or for a missing room', async () => {
    const { code, token } = await host();
    expect((await call(`/api/v1/party/${code}/socket`, { headers: { Upgrade: 'websocket' } })).status).toBe(401);
    expect((await call(`/api/v1/party/${code}/socket`, { token })).status).toBe(426);
    const missing = await call('/api/v1/party/00000002/socket', { token, headers: { Upgrade: 'websocket' } });
    expect(await codeOf(missing)).toBe('party_not_found');
  });

  it('enforces capacity', async () => {
    const { code, token } = await host({ capacity: 2 });
    await connect(token, code);
    await connect((await signIn()).session.accessToken, code);
    const third = await call(`/api/v1/party/${code}/socket`, {
      token: (await signIn()).session.accessToken,
      headers: { Upgrade: 'websocket' },
    });
    expect(third.status).toBe(409);
    expect(await codeOf(third)).toBe('party_full');
  });

  it('simultaneous joins cannot overfill a room', async () => {
    const { code, token } = await host({ capacity: 2 });
    await connect(token, code);
    // One after the other: sign-in fakes share one fetch mock.
    const a = await signIn();
    const b = await signIn();
    const responses = await Promise.all(
      [a, b].map((account) =>
        call(`/api/v1/party/${code}/socket`, {
          token: account.session.accessToken,
          headers: { Upgrade: 'websocket' },
        })),
    );
    const statuses = responses.map((r) => r.status).sort();
    expect(statuses).toEqual([101, 409]);
    for (const response of responses) response.webSocket?.accept();
  });

  it('only the host controls playback; the room stamps and broadcasts it', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);

    hostClient.send({ t: 'control', action: 'play', positionMs: 0 });
    expect((await hostClient.next('error')).code).toBe('not_started');
    hostClient.send({ t: 'start' });
    await guest.next('room', (m) => (m.room as { phase: string }).phase === 'watching');

    guest.send({ t: 'control', action: 'pause', positionMs: 1000 });
    expect((await guest.next('error')).code).toBe('not_allowed');
    guest.send({ t: 'start' });
    expect((await guest.next('error', () => true, guest.messages.length)).code).toBe('not_allowed');

    const before = Date.now();
    hostClient.send({ t: 'control', action: 'play', positionMs: 5000 });
    const state = await guest.next('state');
    const playback = state.playback as { status: string; positionMs: number; at: number; seq: number };
    expect(playback.status).toBe('playing');
    expect(playback.positionMs).toBe(5000);
    expect(playback.at).toBeGreaterThanOrEqual(before - 1);
    expect(playback.seq).toBe(2);

    hostClient.send({ t: 'control', action: 'seek', positionMs: 60_000 });
    const seek = await guest.next('state', (m) => (m.playback as { seq: number }).seq === 3);
    expect(seek.playback).toMatchObject({ status: 'playing', positionMs: 60_000 });
  });

  it('lets guests control when the host allows it', async () => {
    const { code, token } = await host({ guestControl: true });
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    hostClient.send({ t: 'start' });
    await guest.next('room', (m) => (m.room as { phase: string }).phase === 'watching');
    guest.send({ t: 'control', action: 'pause', positionMs: 1234 });
    const state = await hostClient.next('state');
    expect(state.playback).toMatchObject({ status: 'paused', positionMs: 1234 });
  });

  it('keeps heartbeats in memory unless the host drifted, and ignores stale ones', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    hostClient.send({ t: 'start' });
    hostClient.send({ t: 'control', action: 'play', positionMs: 0 });
    const playing = await guest.next('state');
    const seq = (playing.playback as { seq: number }).seq;

    hostClient.send({ t: 'heartbeat', seq, positionMs: 10, at: Date.now() });
    await guest.next('state', (m) => (m.playback as { positionMs: number }).positionMs === 10);
    const stored = await runInDurableObject(stub(code), async (_: WatchPartyRoom, state) =>
      (await state.storage.get<{ playback: { positionMs: number } }>('room'))!.playback.positionMs);
    expect(stored).toBe(0);

    // A stalled host: written so a woken room has the right timeline.
    hostClient.send({ t: 'heartbeat', seq, positionMs: 0, at: Date.now() + 10_000 });
    hostClient.send({ t: 'heartbeat', seq, positionMs: 1, at: Date.now() });
    await guest.next('state', (m) => (m.playback as { positionMs: number }).positionMs === 1);

    const from = guest.messages.length;
    hostClient.send({ t: 'heartbeat', seq: seq - 1, positionMs: 999_999, at: Date.now() });
    hostClient.send({ t: 'time', c: 1 });
    await hostClient.next('time');
    expect(guest.messages.slice(from).some((m) => m.t === 'state')).toBe(false);
  });

  it('answers clock checks with server time, a few per socket', async () => {
    const { code, token } = await host();
    const client = await connect(token, code);
    client.send({ t: 'time', c: 42 });
    const reply = await client.next('time');
    expect(reply.c).toBe(42);
    expect(Math.abs((reply.s as number) - Date.now())).toBeLessThan(2000);
  });

  it('changing the episode resets playback and asks everyone to load again', async () => {
    const { account, code } = await host();
    const hostClient = await connect(account.session.accessToken, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    guest.send({ t: 'status', state: 'ready' });
    await hostClient.next('participants', (m) =>
      (m.participants as { status: string }[]).some((p) => p.status === 'ready'));
    hostClient.send({ t: 'content', content: episode });
    const changed = await guest.next('room', (m) => (m.room as { content: { tmdbId: number } }).content.tmdbId === 1399);
    const room = changed.room as { content: unknown; playback: { status: string; positionMs: number }; participants: { status: string }[] };
    expect(room.content).toEqual(episode);
    expect(room.playback).toMatchObject({ status: 'paused', positionMs: 0 });
    expect(room.participants.every((p) => p.status === 'loading')).toBe(true);
  });

  it('the host removes a participant, who cannot come back', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guestAccount = await signIn();
    const guest = await connect(guestAccount.session.accessToken, code);
    const pid = (guest.messages[0].you as { pid: string }).pid;
    hostClient.send({ t: 'kick', pid });
    expect((await guest.waitClosed()).code).toBe(closeCodes.removed);
    const again = await call(`/api/v1/party/${code}/socket`, {
      token: guestAccount.session.accessToken,
      headers: { Upgrade: 'websocket' },
    });
    expect(await codeOf(again)).toBe('party_removed');
  });

  it('a second connection replaces the first for the same account', async () => {
    const { code, token } = await host();
    const first = await connect(token, code);
    await connect(token, code);
    expect((await first.waitClosed()).code).toBe(closeCodes.replaced);
  });

  it('transfers host on request, and when the host leaves', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    const guestPid = (guest.messages[0].you as { pid: string }).pid;
    hostClient.send({ t: 'transfer', pid: guestPid });
    await guest.next('room', (m) => (m.room as { host: { pid: string } }).host.pid === guestPid);
    // The old host is now a guest.
    hostClient.send({ t: 'start' });
    expect((await hostClient.next('error')).code).toBe('not_allowed');
    // The new host leaves: host moves back.
    const hostPid = (hostClient.messages[0].you as { pid: string }).pid;
    guest.send({ t: 'leave' });
    await hostClient.next('room', (m) => (m.room as { host: { pid: string } }).host.pid === hostPid);
  });

  it('a disconnected host has a grace period, then the next participant hosts', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    const guestPid = (guest.messages[0].you as { pid: string }).pid;
    hostClient.ws.close(1000, 'gone');
    await guest.next('participants', (m) => m.hostConnected === false);
    // Before the grace ends the alarm leaves the host in place.
    await runDurableObjectAlarm(stub(code));
    await runInDurableObject(stub(code), async (_: WatchPartyRoom, state) => {
      const room = (await state.storage.get<{ hostLeftAt: number }>('room'))!;
      await state.storage.put('room', { ...room, hostLeftAt: Date.now() - hostGraceMs - 1 });
    });
    // The room object caches its record; a fresh instance reads the change.
    await runInDurableObject(stub(code), async (instance: WatchPartyRoom) => {
      (instance as unknown as { room: undefined }).room = undefined;
    });
    await runDurableObjectAlarm(stub(code));
    await guest.next('room', (m) => (m.room as { host: { pid: string } }).host.pid === guestPid);
  });

  it('ends when the host says so, and an empty room expires', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    hostClient.send({ t: 'end' });
    expect((await guest.next('ended')).reason).toBe('host');
    expect((await guest.waitClosed()).code).toBe(closeCodes.ended);

    const second = await host();
    await runInDurableObject(stub(second.code), async (instance: WatchPartyRoom, state) => {
      const room = (await state.storage.get<{ emptySince: number }>('room'))!;
      await state.storage.put('room', { ...room, everJoined: true, emptySince: Date.now() - emptyGraceMs - 1 });
      (instance as unknown as { room: undefined }).room = undefined;
    });
    await runDurableObjectAlarm(stub(second.code));
    expect((await call(`/api/v1/party/${second.code}`, { token: second.token })).status).toBe(404);
  });

  it('rejects malformed messages and closes a socket that keeps sending them', async () => {
    const { code, token } = await host();
    const client = await connect(token, code);
    client.send('not json');
    expect((await client.next('error')).code).toBe('invalid_message');
    client.send({ t: 'control', action: 'play', positionMs: -5 });
    for (let i = 0; i < 6; i++) client.send('[]');
    expect((await client.waitClosed()).code).toBe(closeCodes.rateLimited);
  });

  it('a signed-out session cannot join with its still-valid token', async () => {
    const { code } = await host();
    const guest = await signIn();
    await call('/api/v1/auth/logout', { method: 'POST', token: guest.session.accessToken });
    const response = await call(`/api/v1/party/${code}/socket`, {
      token: guest.session.accessToken,
      headers: { Upgrade: 'websocket' },
    });
    expect(response.status).toBe(401);
  });

  it('a signed-out session cannot host with its still-valid token', async () => {
    const { session } = await signIn();
    await call('/api/v1/auth/logout', { method: 'POST', token: session.accessToken });
    const response = await create(session.accessToken, { content: movie });
    expect(response.status).toBe(401);
    expect(await codeOf(response)).toBe('session_revoked');
  });

  it('tells the app what it supports beyond playback', async () => {
    const { code, token } = await host();
    const client = await connect(token, code);
    expect(client.messages[0].features).toEqual(['reactions', 'chat']);
  });

  it('relays reactions to the others, drops a flood quietly and rejects unknown ones', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    const hostPid = (hostClient.messages[0].you as { pid: string }).pid;

    hostClient.send({ t: 'react', emoji: 'laugh' });
    const reaction = await guest.next('reaction');
    expect(reaction).toEqual({ t: 'reaction', pid: hostPid, emoji: 'laugh' });

    // A burst of 4, then one a second: the rest never reach anyone, and
    // the sender is neither answered nor disconnected.
    for (let i = 0; i < 10; i++) hostClient.send({ t: 'react', emoji: 'fire' });
    hostClient.send({ t: 'status', state: 'ready' });
    await guest.next('participants', (m) =>
      (m.participants as { status: string }[]).some((p) => p.status === 'ready'));
    // The first plus what is left of the burst (one more if a second passed).
    const relayed = guest.messages.filter((m) => m.t === 'reaction').length;
    expect(relayed).toBeGreaterThanOrEqual(4);
    expect(relayed).toBeLessThanOrEqual(5);
    expect(hostClient.messages.filter((m) => m.t === 'reaction')).toHaveLength(0);
    expect(hostClient.messages.filter((m) => m.t === 'error')).toHaveLength(0);
    expect(hostClient.closed).toBeNull();

    guest.send({ t: 'react', emoji: '<script>' });
    expect((await guest.next('error')).code).toBe('invalid_message');
  });

  it('relays chat to everyone under the sender\'s own name, cleaned and capped', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    const guestPid = (guest.messages[0].you as { pid: string }).pid;
    guest.send({ t: 'hello', name: 'Sam', avatar: null });
    await hostClient.next('participants', (m) =>
      (m.participants as { name: string }[]).some((p) => p.name === 'Sam'));

    // Claiming another participant's id or name changes nothing.
    guest.send({ t: 'chat', id: 'm-1', text: '  hi‮  there\n', pid: 'host', name: 'Host' });
    const line = await hostClient.next('chat');
    expect(line).toMatchObject({ t: 'chat', id: 'm-1', pid: guestPid, name: 'Sam', text: 'hi there' });
    expect(typeof line.at).toBe('number');
    // The sender hears it too: its receipt, in the room's order.
    expect((await guest.next('chat')).id).toBe('m-1');

    guest.send({ t: 'chat', text: 'x'.repeat(500) });
    const long = await hostClient.next('chat', (m) => m.id === undefined);
    expect((long.text as string).length).toBe(300);

    guest.send({ t: 'chat', text: '   ' });
    expect((await guest.next('error')).code).toBe('invalid_message');
  });

  it('refuses chat beyond its budget without closing the socket', async () => {
    const { code, token } = await host();
    const client = await connect(token, code);
    for (let i = 0; i < 8; i++) client.send({ t: 'chat', text: `line ${i}` });
    expect((await client.next('error')).code).toBe('chat_rate_limited');
    expect(client.messages.filter((m) => m.t === 'chat').length).toBeLessThanOrEqual(5);
    expect(client.closed).toBeNull();
  });

  it('a host whose connection vanished without closing is found and handed over', async () => {
    const { code, token, account } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    const guestPid = (guest.messages[0].you as { pid: string }).pid;
    // The host's pings stopped long ago; the guest's are recent.
    await runInDurableObject(stub(code), async (instance: WatchPartyRoom) => {
      const ctx = (instance as unknown as { ctx: DurableObjectState }).ctx;
      ctx.getWebSocketAutoResponseTimestamp = (ws: WebSocket) => {
        const a = ws.deserializeAttachment() as { userId: string };
        return a.userId === account.user.id ? new Date(Date.now() - staleSocketMs - 1000) : new Date();
      };
    });
    await runDurableObjectAlarm(stub(code));
    expect((await hostClient.waitClosed()).code).toBe(closeCodes.stale);
    await guest.next('participants', (m) => m.hostConnected === false);
    expect(guest.closed).toBeNull();

    // After the grace, the guest hosts.
    await runInDurableObject(stub(code), async (instance: WatchPartyRoom, state) => {
      const room = (await state.storage.get<{ hostLeftAt: number }>('room'))!;
      await state.storage.put('room', { ...room, hostLeftAt: Date.now() - hostGraceMs - 1 });
      (instance as unknown as { room: undefined }).room = undefined;
    });
    await runDurableObjectAlarm(stub(code));
    await guest.next('room', (m) => (m.room as { host: { pid: string } }).host.pid === guestPid);
  });

  it('checks presence while anyone is connected, not only at the end of the room', async () => {
    const { code, token } = await host();
    await connect(token, code);
    await runInDurableObject(stub(code), async (_: WatchPartyRoom, state) => {
      const alarm = await state.storage.getAlarm();
      expect(alarm).not.toBeNull();
      expect(alarm! - Date.now()).toBeLessThanOrEqual(presenceCheckMs + 1000);
    });
  });

  it('serves a fixed invitation page that never asks the room', async () => {
    const response = await call('/api/v1/join/12345678');
    expect(response.status).toBe(200);
    expect(response.headers.get('Content-Type')).toContain('text/html');
    expect(response.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
    const html = await response.text();
    expect(html).toContain('href="reelish://party/12345678"');
    expect(html).toContain('1234 5678');
    // No room was created or woken for it.
    await runInDurableObject(stub('12345678'), async (_: WatchPartyRoom, state) => {
      expect(await state.storage.get('room')).toBeUndefined();
    });

    const bad = await call('/api/v1/join/%3Cscript%3E');
    expect(bad.status).toBe(404);
    expect(await bad.text()).not.toContain('<script>');
  });

  it('request logs never carry the party code', async () => {
    const { code, token } = await host();
    const lines: string[] = [];
    const spy = vi.spyOn(console, 'log').mockImplementation((line: string) => lines.push(line));
    try {
      await call(`/api/v1/party/${code}`, { token });
    } finally {
      spy.mockRestore();
    }
    const logged = lines.join('\n');
    expect(logged).toContain('/api/v1/party/:code');
    expect(logged).not.toContain(code);
  });
});

describe('The Founder badge in a party', () => {
  const founderIn = (message: { participants: { pid: string; founder?: boolean }[] }) =>
    message.participants.filter((person) => person.founder).length;

  it('comes from the account, and a client cannot claim it', async () => {
    await testEnv.DB.prepare('DELETE FROM users WHERE trakt_uuid = ?').bind('founder-uuid').run();
    const founder = await supporter({ uuid: 'founder-uuid' });
    const created = await create(founder.session.accessToken);
    const { code } = (await created.json()) as { code: string };
    const owner = await connect(founder.session.accessToken, code);

    // A guest asks for it every way a client can.
    const guest = await signIn();
    const response = await call(`/api/v1/party/${code}/socket`, {
      token: guest.session.accessToken,
      headers: { Upgrade: 'websocket', 'X-Party-Founder': '1' },
    });
    expect(response.status).toBe(101);
    const client = new Client(response.webSocket!);
    await client.next('welcome');
    client.send({ t: 'hello', name: 'Founder', avatar: null, founder: true });
    const seen = (await owner.next(
      'participants',
      (m) => (m.participants as { name: string }[]).some((person) => person.name === 'Founder'),
    )) as unknown as { participants: { pid: string; founder?: boolean }[] };
    expect(seen.participants).toHaveLength(2);
    expect(founderIn(seen)).toBe(1);
  });
});

describe('Avatar frames in a party', () => {
  it('others see the frame the account wears, and a client cannot claim one', async () => {
    const owner = await supporter();
    await call('/api/v1/me/frame', { method: 'PUT', token: owner.session.accessToken, body: { frame: 'aurora' } });
    const created = await create(owner.session.accessToken, { profile: { name: 'Sam', avatar: 'avatar3' } });
    const { code } = (await created.json()) as { code: string };
    const host = await connect(owner.session.accessToken, code);

    // A guest without a frame asks for one in the header and the hello.
    const guest = await signIn();
    const response = await call(`/api/v1/party/${code}/socket`, {
      token: guest.session.accessToken,
      headers: { Upgrade: 'websocket', 'X-Party-Frame': 'founder' },
    });
    const client = new Client(response.webSocket!);
    await client.next('welcome');
    client.send({ t: 'hello', name: 'Guest', avatar: null, frame: 'founder' });
    const seen = (await host.next(
      'participants',
      (m) => (m.participants as { name: string }[]).some((person) => person.name === 'Guest'),
    )) as unknown as { participants: { name: string; frame?: string }[] };
    const frameOf = (name: string) => seen.participants.find((p) => p.name === name)?.frame;
    expect(frameOf('Sam')).toBe('aurora');
    expect(frameOf('Guest')).toBeUndefined();
  });
});

describe('Hosting and joining are for everyone', () => {
  it('every entitlement hosts alike: free, pending, supporter, refunded and the Founder', async () => {
    const free = await signIn();
    expect((await create(free.session.accessToken)).status).toBe(201);

    const pending = await signIn();
    await testEnv.DB.prepare(
      `INSERT INTO supporter_profiles (user_id, support_code, claim_requested_at, created_at, updated_at)
       VALUES (?, ?, 1000, 1000, 1000)`,
    )
      .bind(pending.user.id, `RS-${crypto.randomUUID().slice(0, 8)}`)
      .run();
    expect((await create(pending.session.accessToken)).status).toBe(201);

    const backer = await supporter();
    expect((await create(backer.session.accessToken)).status).toBe(201);

    await testEnv.DB.prepare('UPDATE supporter_profiles SET supporter_since = NULL WHERE user_id = ?')
      .bind(backer.user.id)
      .run();
    expect((await create(backer.session.accessToken)).status).toBe(201);

    const founder = await signIn({ uuid: 'founder-uuid' });
    expect((await create(founder.session.accessToken)).status).toBe(201);
  });

  it('a free host and a free guest stay in sync; a late joiner gets the current state', async () => {
    const { code, token } = await host();
    const viewer = await signIn();
    expect((await call(`/api/v1/party/${code}`, { token: viewer.session.accessToken })).status).toBe(200);
    const hostClient = await connect(token, code);
    const guest = await connect(viewer.session.accessToken, code);
    hostClient.send({ t: 'start' });
    await guest.next('room', (m) => (m.room as { phase: string }).phase === 'watching');
    hostClient.send({ t: 'control', action: 'play', positionMs: 0 });
    expect((await guest.next('state', (m) => (m.playback as { status: string }).status === 'playing')).playback)
      .toMatchObject({ status: 'playing', positionMs: 0 });
    hostClient.send({ t: 'control', action: 'pause', positionMs: 4000 });
    expect((await guest.next('state', (m) => (m.playback as { status: string }).status === 'paused')).playback)
      .toMatchObject({ status: 'paused', positionMs: 4000 });
    hostClient.send({ t: 'control', action: 'seek', positionMs: 90_000 });
    const seek = await guest.next('state', (m) => (m.playback as { positionMs: number }).positionMs === 90_000);
    expect(seek.playback).toMatchObject({ status: 'paused', positionMs: 90_000 });

    const late = await connect((await signIn()).session.accessToken, code);
    const welcome = await late.next('welcome');
    expect((welcome.room as { phase: string; playback: unknown })).toMatchObject({
      phase: 'watching',
      playback: { status: 'paused', positionMs: 90_000 },
    });
  });

  it('a free host\'s guests cannot control playback or take over the room', async () => {
    const { code, token } = await host();
    const hostClient = await connect(token, code);
    const guest = await connect((await signIn()).session.accessToken, code);
    hostClient.send({ t: 'start' });
    await guest.next('room', (m) => (m.room as { phase: string }).phase === 'watching');
    const welcome = guest.messages.find((m) => m.t === 'welcome')!;
    const hostPid = (welcome.room as { host: { pid: string } }).host.pid;

    for (const attempt of [
      { t: 'control', action: 'play', positionMs: 1000 },
      { t: 'heartbeat', positionMs: 1000, seq: 1 },
      { t: 'settings', guestControl: true },
      { t: 'transfer', pid: (welcome.you as { pid: string }).pid },
      { t: 'kick', pid: hostPid },
      { t: 'end' },
    ]) {
      const seen = guest.messages.length;
      guest.send(attempt);
      expect((await guest.next('error', () => true, seen)).code).toBe('not_allowed');
    }
    // The host is unchanged and the room still answers the host.
    hostClient.send({ t: 'control', action: 'play', positionMs: 2000 });
    expect((await guest.next('state', (m) => (m.playback as { positionMs: number }).positionMs === 2000)).playback)
      .toMatchObject({ status: 'playing', by: hostPid });
    expect(hostClient.closed).toBeNull();
  });
});

describe('Free hosting stays within the Free plan', () => {
  const indexed = async (code: string) =>
    (await testEnv.DB.prepare('SELECT 1 FROM party_codes WHERE code = ?').bind(code).first()) !== null;

  it(`one account creates at most ${hostQuotaPerHour} rooms an hour; a refusal ends nothing`, async () => {
    const { session, user } = await signIn();
    let last = '';
    for (let i = 0; i < hostQuotaPerHour; i++) {
      const response = await create(session.accessToken);
      expect(response.status).toBe(201);
      last = ((await response.json()) as { code: string }).code;
    }
    const watcher = await signIn();
    const guest = await connect(watcher.session.accessToken, last);

    const refused = await create(session.accessToken);
    expect(refused.status).toBe(429);
    expect(await codeOf(refused)).toBe('party_quota');
    expect(Number(refused.headers.get('Retry-After'))).toBeGreaterThan(0);
    // The open room carries on.
    expect((await call(`/api/v1/party/${last}`, { token: watcher.session.accessToken })).status).toBe(200);
    expect(guest.closed).toBeNull();

    // An hour later the budget is whole again.
    await testEnv.DB.prepare('UPDATE party_hosts SET window_start = window_start - 3601 WHERE user_id = ?')
      .bind(user.id).run();
    expect((await create(session.accessToken)).status).toBe(201);
    const row = await testEnv.DB.prepare('SELECT window_count FROM party_hosts WHERE user_id = ?')
      .bind(user.id).first<{ window_count: number }>();
    expect(row!.window_count).toBe(1);
  });

  it('the quota is per account: another host is unaffected', async () => {
    const busy = await signIn();
    for (let i = 0; i < hostQuotaPerHour; i++) expect((await create(busy.session.accessToken)).status).toBe(201);
    expect((await create(busy.session.accessToken)).status).toBe(429);
    expect((await create((await signIn()).session.accessToken)).status).toBe(201);
  });

  it('lookups for codes not issued stop at D1, before any room is asked', async () => {
    const { code, token } = await host();
    expect(await indexed(code)).toBe(true);
    // The room is still there, but without its index row nothing reaches it.
    await testEnv.DB.prepare('DELETE FROM party_codes WHERE code = ?').bind(code).run();
    const preview = await call(`/api/v1/party/${code}`, { token });
    expect(preview.status).toBe(404);
    expect(await codeOf(preview)).toBe('party_not_found');
    const socket = await call(`/api/v1/party/${code}/socket`, { token, headers: { Upgrade: 'websocket' } });
    expect(socket.status).toBe(404);
  });

  it('an ended room leaves the index, and a replaced one too', async () => {
    const first = await host();
    const hostClient = await connect(first.token, first.code);
    hostClient.send({ t: 'end' });
    await hostClient.waitClosed();
    await vi.waitFor(async () => expect(await indexed(first.code)).toBe(false));

    const second = await host();
    expect((await create(second.token)).status).toBe(201);
    await vi.waitFor(async () => expect(await indexed(second.code)).toBe(false));
  });

  it('joining still reports a full room and a removed participant', async () => {
    const { code, token } = await host({ capacity: 2 });
    const hostClient = await connect(token, code);
    const guest = await signIn();
    const guestClient = await connect(guest.session.accessToken, code);
    const third = await call(`/api/v1/party/${code}/socket`, {
      token: (await signIn()).session.accessToken,
      headers: { Upgrade: 'websocket' },
    });
    expect(third.status).toBe(409);
    expect(await codeOf(third)).toBe('party_full');

    const guestPid = (guestClient.messages.find((m) => m.t === 'welcome')!.you as { pid: string }).pid;
    hostClient.send({ t: 'kick', pid: guestPid });
    await guestClient.waitClosed();
    const back = await call(`/api/v1/party/${code}/socket`, {
      token: guest.session.accessToken,
      headers: { Upgrade: 'websocket' },
    });
    expect(back.status).toBe(403);
    expect(await codeOf(back)).toBe('party_removed');
  });

  it('the daily cron forgets codes older than a room\'s lifetime', async () => {
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare('INSERT INTO party_codes (code, created_at) VALUES (?, ?), (?, ?)')
      .bind('00000001', now - 13 * 3600, '00000002', now - 3600).run();
    expect(await prunePartyCodes(testEnv, now)).toBeGreaterThanOrEqual(1);
    expect(await indexed('00000001')).toBe(false);
    expect(await indexed('00000002')).toBe(true);
  });
});
