import { describe, expect, it } from 'vitest';
import { runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { call, signIn, testEnv } from './helpers';
import { newCode } from '../src/watch-party';
import { closeCodes, emptyGraceMs, hostGraceMs, participantId, type WatchPartyRoom } from '../src/party-room';

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
});
