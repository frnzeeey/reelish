import { describe, expect, it } from 'vitest';
import { runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { call, signIn, testEnv } from './helpers';
import {
  cleanText, conversationId, dailyMessageLimit, mailbox, mailboxCloseCodes, maxMessageChars,
  messageTtlMs, syncBatchSize, type Mailbox,
} from '../src/messaging/mailbox';

type Frame = Record<string, unknown> & { t: string };

/** A device's socket that records every frame from its mailbox. */
class Device {
  readonly frames: Frame[] = [];
  closed: { code: number } | null = null;
  private waiters: (() => void)[] = [];

  constructor(readonly ws: WebSocket) {
    ws.accept();
    ws.addEventListener('message', (event) => {
      this.frames.push(JSON.parse(event.data as string));
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

  async next(t: string, predicate: (f: Frame) => boolean = () => true): Promise<Frame> {
    const deadline = Date.now() + 3000;
    for (;;) {
      const found = this.frames.find((f) => f.t === t && predicate(f));
      if (found) return found;
      if (Date.now() > deadline) throw new Error(`no ${t} frame; got ${JSON.stringify(this.frames)}`);
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 100);
      });
    }
  }

  events(): Frame[] {
    return this.frames.filter((f) => f.t === 'event');
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

  /** Sends a message and waits for the mailbox's answer. */
  async message(to: string, text: string, id = crypto.randomUUID()): Promise<Frame> {
    this.send({ t: 'send', to, id, text });
    const deadline = Date.now() + 3000;
    for (;;) {
      const found = this.frames.find((f) => (f.t === 'sent' || f.t === 'send_error') && f.id === id);
      if (found) return found;
      if (Date.now() > deadline) throw new Error(`no answer for ${id}`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
}

let counter = 0;
const uniqueHandle = () => `mx_${++counter}_${Math.floor(Math.random() * 1e6)}`;

/** A signed-in account with Friends on. */
async function member(uuid?: string) {
  const account = await signIn(uuid ? { uuid } : {});
  const handle = uniqueHandle();
  const response = await call('/api/v1/social/profile', {
    method: 'PUT', token: account.session.accessToken, body: { handle, displayName: handle.toUpperCase() },
  });
  expect(response.status).toBe(201);
  const { profile } = (await response.json()) as { profile: { friendCode: string } };
  return {
    token: account.session.accessToken, id: account.user.id, uuid: account.uuid,
    sessionId: account.session.sessionId, handle, code: profile.friendCode,
  };
}

/** Another device signed in to the same account. */
async function secondDevice(account: { uuid: string }) {
  const again = await signIn({ uuid: account.uuid });
  return { token: again.session.accessToken, sessionId: again.session.sessionId };
}

async function befriend(one: { token: string; code: string }, other: { token: string; handle: string }) {
  await call('/api/v1/social/requests', { token: other.token, body: { code: one.code } });
  const accepted = await call('/api/v1/social/requests/' + other.handle + '/accept', {
    method: 'POST', token: (one as { token: string }).token, body: {},
  });
  expect(accepted.status).toBe(200);
}

async function friends() {
  const ana = await member();
  const ben = await member();
  await befriend(ana, ben);
  return { ana, ben };
}

async function connect(token: string): Promise<Device> {
  const response = await call('/api/v1/messages/socket', { token, headers: { Upgrade: 'websocket' } });
  expect(response.status).toBe(101);
  const device = new Device(response.webSocket!);
  await device.next('ready');
  await device.next('synced');
  return device;
}

const stored = (userId: string) =>
  runInDurableObject(mailbox(testEnv, userId), async (_: Mailbox, state) =>
    state.storage.sql.exec<{ kind: string; client_id: string | null }>(
      `SELECT kind, client_id FROM events ORDER BY seq`,
    ).toArray());

const highestSeq = (device: Device) => Math.max(0, ...device.events().map((e) => e.seq as number));

describe('Private messages', () => {
  it('delivers in real time, acknowledges, deletes and tells the sender', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    const benDevice = await connect(ben.token);

    const sent = await anaDevice.message(ben.handle, 'Hello Ben', 'msg-0001');
    expect(sent).toMatchObject({ t: 'sent', id: 'msg-0001', conv: await conversationId(ana.id, ben.id) });

    const event = await benDevice.next('event', (e) => e.id === 'msg-0001');
    expect(event).toMatchObject({
      kind: 'message', out: false, text: 'Hello Ben',
      peer: { handle: ana.handle, displayName: ana.handle.toUpperCase(), avatar: null },
    });
    // Nothing that identifies an account travels with a message.
    expect(JSON.stringify(event)).not.toContain(ana.id);
    expect(await stored(ben.id)).toHaveLength(1);

    benDevice.send({ t: 'ack', seq: event.seq });
    const receipt = await anaDevice.next('receipt');
    expect(receipt).toMatchObject({ ids: ['msg-0001'], conv: sent.conv });
    // Acknowledged on Ben's only device: the cloud copy is gone.
    expect(await stored(ben.id)).toEqual([]);
    expect(await stored(ana.id)).toEqual([]);
  });

  it('queues for an offline friend, counts it in the summary, and syncs on connect', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    expect((await anaDevice.message(ben.handle, 'One')).t).toBe('sent');
    expect((await anaDevice.message(ben.handle, 'Two')).t).toBe('sent');

    const summary = await call('/api/v1/social/profile', { token: ben.token });
    expect(((await summary.json()) as { counts: { messages: number } }).counts.messages).toBe(2);

    const benDevice = await connect(ben.token);
    expect(benDevice.events().map((e) => e.text)).toEqual(['One', 'Two']);
    benDevice.send({ t: 'ack', seq: highestSeq(benDevice) });
    await anaDevice.next('receipt', (r) => (r.ids as string[]).length === 2);
    expect(await stored(ben.id)).toEqual([]);
  });

  it('stores a retried message once', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    const first = await anaDevice.message(ben.handle, 'Once', 'retry-0001');
    anaDevice.frames.length = 0;
    const second = await anaDevice.message(ben.handle, 'Once', 'retry-0001');
    expect(second).toMatchObject({ t: 'sent', at: first.at });
    expect(await stored(ben.id)).toEqual([{ kind: 'message', client_id: 'retry-0001' }]);
    const counted = await testEnv.DB.prepare(`SELECT messages FROM social_counters WHERE user_id = ?`)
      .bind(ana.id).first<{ messages: number }>();
    expect(counted?.messages).toBe(1);
  });

  it('redelivers what a device received but never acknowledged', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    await anaDevice.message(ben.handle, 'Did you get this?');
    const first = await connect(ben.token);
    expect(first.events()).toHaveLength(1);
    first.ws.close(1000, 'app closed before saving');
    const again = await connect(ben.token);
    expect(again.events().map((e) => e.text)).toEqual(['Did you get this?']);
  });

  it('only lets friends message, and answers strangers like unknown handles', async () => {
    const ana = await member();
    const stranger = await member();
    const anaDevice = await connect(ana.token);
    expect(await anaDevice.message(stranger.handle, 'Hi')).toMatchObject({ t: 'send_error', code: 'not_friends' });
    expect(await anaDevice.message('nobody_here_x', 'Hi')).toMatchObject({ t: 'send_error', code: 'not_friends' });
    expect(await anaDevice.message(ana.handle, 'Me')).toMatchObject({ t: 'send_error', code: 'not_friends' });
    expect(await stored(stranger.id)).toEqual([]);
  });

  it('refuses a blocked person and drops what was waiting', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    await anaDevice.message(ben.handle, 'Before the block');
    expect(await stored(ben.id)).toHaveLength(1);
    const blocked = await call('/api/v1/social/blocks', { token: ben.token, body: { handle: ana.handle } });
    expect(blocked.status).toBe(200);
    expect(await stored(ben.id)).toEqual([]);
    expect(await anaDevice.message(ben.handle, 'After')).toMatchObject({ t: 'send_error', code: 'not_friends' });
  });

  it('stops messages once the friendship ends', async () => {
    const { ana, ben } = await friends();
    await call(`/api/v1/social/friends/${ben.handle}`, { method: 'DELETE', token: ana.token });
    const anaDevice = await connect(ana.token);
    expect(await anaDevice.message(ben.handle, 'Hi')).toMatchObject({ t: 'send_error', code: 'not_friends' });
  });

  it('checks text: trimmed, unsafe characters removed, size limited', async () => {
    expect(cleanText('  hi‮ there \u0000 ')).toBe('hi there');
    expect(cleanText('a\r\nb\n\n\n\n\nc')).toBe('a\nb\n\n\nc');
    expect(cleanText('   ')).toBeNull();
    expect(cleanText(42)).toBeNull();
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    expect(await anaDevice.message(ben.handle, '   ')).toMatchObject({ code: 'empty' });
    expect(await anaDevice.message(ben.handle, 'x'.repeat(maxMessageChars + 1))).toMatchObject({ code: 'too_long' });
    expect((await anaDevice.message(ben.handle, 'x'.repeat(maxMessageChars))).t).toBe('sent');
  });

  it('enforces the daily limit', async () => {
    const { ana, ben } = await friends();
    const day = Math.floor(Date.now() / (24 * 60 * 60 * 1000));
    await testEnv.DB.prepare(
      `INSERT INTO social_counters (user_id, day, messages) VALUES (?, ?, ?)
       ON CONFLICT (user_id, day) DO UPDATE SET messages = excluded.messages`,
    ).bind(ana.id, day, dailyMessageLimit).run();
    const anaDevice = await connect(ana.token);
    expect(await anaDevice.message(ben.handle, 'One more')).toMatchObject({ code: 'daily_limit' });
  });

  it('closes a socket that floods or sends nonsense', async () => {
    const { ana } = await friends();
    const device = await connect(ana.token);
    for (let i = 0; i < 8; i++) device.send('not json');
    expect((await device.waitClosed()).code).toBe(mailboxCloseCodes.rateLimited);
  });

  it('refuses a socket without a session, an upgrade or Friends', async () => {
    expect((await call('/api/v1/messages/socket', { headers: { Upgrade: 'websocket' } })).status).toBe(401);
    const ana = await member();
    expect((await call('/api/v1/messages/socket', { token: ana.token })).status).toBe(426);
    const noFriends = await signIn();
    const response = await call('/api/v1/messages/socket', {
      token: noFriends.session.accessToken, headers: { Upgrade: 'websocket' },
    });
    expect(response.status).toBe(409);
  });

  it('cannot be pointed at another account by a forged header', async () => {
    const { ana, ben } = await friends();
    const response = await call('/api/v1/messages/socket', {
      token: ana.token, headers: { Upgrade: 'websocket', 'X-Mailbox-User': ben.id },
    });
    const device = new Device(response.webSocket!);
    await device.next('synced');
    const other = await connect(ben.token);
    await other.message(ana.handle, 'for Ana');
    // Arrives on Ana's socket: the header was replaced by the Worker.
    await device.next('event', (e) => e.text === 'for Ana');
  });

  it('keeps a message until every device has it, and copies sent ones to the other devices', async () => {
    const { ana, ben } = await friends();
    const benPhone = await connect(ben.token);
    const benTv = await secondDevice(ben);
    const tv = await connect(benTv.token);
    const anaPhone = await connect(ana.token);
    const anaPc = await secondDevice(ana);
    const pc = await connect(anaPc.token);

    await anaPhone.message(ben.handle, 'Both screens', 'multi-0001');
    // Ana's PC learns of the message she sent from her phone.
    const copy = await pc.next('event', (e) => e.id === 'multi-0001');
    expect(copy).toMatchObject({ out: true, peer: { handle: ben.handle } });

    const onPhone = await benPhone.next('event', (e) => e.id === 'multi-0001');
    await tv.next('event', (e) => e.id === 'multi-0001');
    benPhone.send({ t: 'ack', seq: onPhone.seq });
    await anaPhone.next('receipt', (r) => (r.ids as string[]).includes('multi-0001'));
    // The TV has not saved it yet: still in the cloud.
    expect((await stored(ben.id)).map((e) => e.client_id)).toContain('multi-0001');
    tv.send({ t: 'ack', seq: highestSeq(tv) });
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(await stored(ben.id)).toEqual([]);
  });

  it('sends a large backlog in batches, each after the last is saved', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    const total = syncBatchSize + 5;
    await runInDurableObject(mailbox(testEnv, ben.id), async (instance: Mailbox) => {
      for (let i = 0; i < total; i++) {
        await instance.deliver({
          fromUserId: ana.id,
          message: {
            kind: 'message', conv: 'c', id: `bulk-${String(i).padStart(4, '0')}`, out: false,
            peer: { handle: ana.handle, displayName: null, avatar: null }, text: `#${i}`, at: Date.now(),
          },
        });
      }
    });
    anaDevice.ws.close();
    const response = await call('/api/v1/messages/socket', { token: ben.token, headers: { Upgrade: 'websocket' } });
    const device = new Device(response.webSocket!);
    await device.next('ready');
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(device.events()).toHaveLength(syncBatchSize);
    device.send({ t: 'ack', seq: highestSeq(device) });
    await device.next('synced');
    expect(device.events()).toHaveLength(total);
  });

  it('refuses an acknowledgement beyond what was sent', async () => {
    const { ana } = await friends();
    const device = await connect(ana.token);
    device.send({ t: 'ack', seq: 999 });
    expect(await device.next('error')).toMatchObject({ code: 'invalid_message' });
  });

  it('expires undelivered messages and forgets signed-out devices', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    await anaDevice.message(ben.handle, 'Too late');
    await runInDurableObject(mailbox(testEnv, ben.id), async (_: Mailbox, state) => {
      state.storage.sql.exec(`UPDATE events SET created_at = ?`, Date.now() - messageTtlMs - 1);
    });
    await runDurableObjectAlarm(mailbox(testEnv, ben.id));
    expect(await stored(ben.id)).toEqual([]);

    // Ben saved nothing on a device he then signed out of: the device stops
    // counting, and the message waits for a device that is still signed in.
    const benDevice = await connect(ben.token);
    await anaDevice.message(ben.handle, 'Waiting for you');
    await benDevice.next('event', (e) => e.text === 'Waiting for you');
    await call('/api/v1/auth/logout', { method: 'POST', token: ben.token, body: {} });
    await runDurableObjectAlarm(mailbox(testEnv, ben.id));
    const devices = await runInDurableObject(mailbox(testEnv, ben.id), async (_: Mailbox, state) =>
      state.storage.sql.exec(`SELECT session_id FROM devices`).toArray());
    expect(devices).toEqual([]);
    expect((await stored(ben.id)).map((e) => e.kind)).toEqual(['message']);
  });

  it('works again after Friends is turned off and on', async () => {
    const { ana, ben } = await friends();
    await call('/api/v1/social/profile', { method: 'DELETE', token: ben.token });
    const handle = uniqueHandle();
    await call('/api/v1/social/profile', { method: 'PUT', token: ben.token, body: { handle } });
    await befriend(ana, { token: ben.token, handle });
    const anaDevice = await connect(ana.token);
    expect((await anaDevice.message(handle, 'Welcome back')).t).toBe('sent');
    expect(await stored(ben.id)).toHaveLength(1);
  });

  it('closes an open socket once its session is signed out', async () => {
    const { ana, ben } = await friends();
    const device = await connect(ana.token);
    await call('/api/v1/auth/logout', { method: 'POST', token: ana.token, body: {} });
    await runInDurableObject(mailbox(testEnv, ana.id), async (_: Mailbox, state) => {
      for (const ws of state.getWebSockets()) {
        const attachment = ws.deserializeAttachment() as { checkedAt: number };
        ws.serializeAttachment({ ...attachment, checkedAt: 0 });
      }
    });
    device.send({ t: 'send', to: ben.handle, id: crypto.randomUUID(), text: 'still here?' });
    expect((await device.waitClosed()).code).toBe(mailboxCloseCodes.signedOut);
    expect(await stored(ben.id)).toEqual([]);
  });

  it('empties the mailbox when Friends is turned off', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    await anaDevice.message(ben.handle, 'Waiting');
    const benDevice = await connect(ben.token);
    const off = await call('/api/v1/social/profile', { method: 'DELETE', token: ben.token });
    expect(off.status).toBe(200);
    expect((await benDevice.waitClosed()).code).toBe(mailboxCloseCodes.wiped);
    expect(await stored(ben.id)).toEqual([]);
  });

  it('gives the conversation id in the friends list and a friend profile', async () => {
    const { ana, ben } = await friends();
    const expected = await conversationId(ana.id, ben.id);
    expect(expected).toBe(await conversationId(ben.id, ana.id));
    const list = (await (await call('/api/v1/social/friends', { token: ana.token })).json()) as {
      friends: { handle: string; conversation: string }[];
    };
    expect(list.friends.find((f) => f.handle === ben.handle)?.conversation).toBe(expected);
    const profile = (await (await call(`/api/v1/social/friends/${ana.handle}`, { token: ben.token })).json()) as {
      friend: { conversation: string };
    };
    expect(profile.friend.conversation).toBe(expected);
  });

  it('reports waiting messages to the background check, without their text', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    await anaDevice.message(ben.handle, 'Secret words');
    const token = (await (await call('/api/v1/notifications/token', { token: ben.token, body: {} })).json()) as {
      token: string;
    };
    const response = await call('/api/v1/notifications/episodes', {
      token: token.token, body: { series: [], messages: true },
    });
    const body = (await response.json()) as { messages: { count: number; from: string[] } };
    expect(body.messages).toEqual({ count: 1, from: [ana.handle] });
    expect(JSON.stringify(body)).not.toContain('Secret');
    const without = await call('/api/v1/notifications/episodes', { token: token.token, body: { series: [] } });
    expect(((await without.json()) as Record<string, unknown>).messages).toBeUndefined();
  });
});

/** Sends a request and waits for its answer (`done` or `failed`). */
async function ask(device: Device, frame: Record<string, unknown>): Promise<Frame> {
  const ref = crypto.randomUUID().slice(0, 12);
  device.send({ ...frame, ref });
  const deadline = Date.now() + 3000;
  for (;;) {
    const found = device.frames.find((f) => (f.t === 'done' || f.t === 'failed') && f.ref === ref);
    if (found) return found;
    if (Date.now() > deadline) throw new Error(`no answer for ${ref}; got ${JSON.stringify(device.frames)}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

const readyPrefs = (device: Device) =>
  device.frames.find((f) => f.t === 'ready')!.prefs as Record<string, unknown>[];

const pendingCount = async (token: string) => {
  const summary = await call('/api/v1/social/profile', { token });
  return ((await summary.json()) as { counts: { messages: number } }).counts.messages;
};

describe('Per-account conversation settings, deletion and unsending', () => {
  it('keeps nickname and mute for this account only, on every one of its devices', async () => {
    const { ana, ben } = await friends();
    const conv = await conversationId(ana.id, ben.id);
    const phone = await connect(ana.token);
    const pc = await connect((await secondDevice(ana)).token);

    expect(await ask(phone, { t: 'pref', conv, nickname: '  Benny​  the\n Ben ', muted: true }))
      .toMatchObject({ t: 'done', conv });
    const pushed = await pc.next('prefs');
    expect(pushed.prefs).toEqual([{ conv, muted: true, nickname: 'Benny the Ben', clearedAt: null }]);

    // A device that connects later (or a new one) gets them on connecting.
    const tablet = await connect((await secondDevice(ana)).token);
    expect(readyPrefs(tablet)).toEqual([{ conv, muted: true, nickname: 'Benny the Ben', clearedAt: null }]);
    // Ben sees none of it.
    const benDevice = await connect(ben.token);
    expect(readyPrefs(benDevice)).toEqual([]);

    // Reset: nothing stored any more.
    expect(await ask(pc, { t: 'pref', conv, nickname: null, muted: false })).toMatchObject({ t: 'done' });
    const later = await connect(ana.token);
    expect(readyPrefs(later)).toEqual([]);
  });

  it('validates nicknames and settings', async () => {
    const { ana, ben } = await friends();
    const conv = await conversationId(ana.id, ben.id);
    const device = await connect(ana.token);
    expect(await ask(device, { t: 'pref', conv, nickname: '   ' })).toMatchObject({ t: 'failed', code: 'invalid_nickname' });
    expect(await ask(device, { t: 'pref', conv, nickname: 'x'.repeat(33) }))
      .toMatchObject({ t: 'failed', code: 'invalid_nickname' });
    expect(await ask(device, { t: 'pref', conv, nickname: 42 })).toMatchObject({ t: 'failed', code: 'invalid_nickname' });
    expect(await ask(device, { t: 'pref', conv, muted: 'yes' })).toMatchObject({ t: 'failed', code: 'invalid' });
    expect(await ask(device, { t: 'pref', conv })).toMatchObject({ t: 'failed', code: 'invalid' });
    expect(await ask(device, { t: 'pref', conv: '../../etc', muted: true })).toMatchObject({ t: 'failed', code: 'invalid' });
    expect(await ask(device, { t: 'pref', conv, nickname: 'x'.repeat(32) })).toMatchObject({ t: 'done' });
    // A request without a ref is a protocol error.
    device.send({ t: 'pref', conv, muted: true });
    expect(await device.next('error')).toMatchObject({ code: 'invalid_message' });
  });

  it('leaves a muted conversation out of alerts and the summary, without stopping delivery', async () => {
    const { ana, ben } = await friends();
    const conv = await conversationId(ana.id, ben.id);
    const benDevice = await connect(ben.token);
    await benDevice.message(ana.handle, 'Still delivered');
    expect(await pendingCount(ana.token)).toBe(1);

    const anaDevice = await connect(ana.token);
    expect(anaDevice.events().map((e) => e.text)).toEqual(['Still delivered']);
    expect(await ask(anaDevice, { t: 'pref', conv, muted: true })).toMatchObject({ t: 'done' });
    anaDevice.ws.close(1000, 'closed without saving');
    expect(await pendingCount(ana.token)).toBe(0);
    const token = (await (await call('/api/v1/notifications/token', { token: ana.token, body: {} })).json()) as {
      token: string;
    };
    const check = await call('/api/v1/notifications/episodes', { token: token.token, body: { series: [], messages: true } });
    expect(((await check.json()) as { messages: unknown }).messages).toEqual({ count: 0, from: [] });
    // Still waiting to be delivered: muting stops alerts, not messages.
    expect(await stored(ana.id)).toHaveLength(1);
    const again = await connect(ana.token);
    expect(again.events().map((e) => e.text)).toEqual(['Still delivered']);
    expect(await ask(again, { t: 'pref', conv, muted: false })).toMatchObject({ t: 'done' });
    again.ws.close(1000, 'closed without saving');
    expect(await pendingCount(ana.token)).toBe(1);
    // Ben's own alerts are untouched by Ana's choice.
    expect(readyPrefs(await connect(ben.token))).toEqual([]);
  });

  it('deletes a conversation for this account only; newer messages still arrive', async () => {
    const { ana, ben } = await friends();
    const conv = await conversationId(ana.id, ben.id);
    const benDevice = await connect(ben.token);
    await benDevice.message(ana.handle, 'Before');
    const anaDevice = await connect(ana.token);
    expect(await ask(anaDevice, { t: 'pref', conv, clear: true })).toMatchObject({ t: 'done', conv });
    const prefs = (await anaDevice.next('prefs')).prefs as { clearedAt: number }[];
    expect(prefs[0].clearedAt).toBeGreaterThan(0);
    anaDevice.ws.close(1000, 'closed without saving');
    // What came before the deletion is not announced again.
    expect(await pendingCount(ana.token)).toBe(0);

    // Nothing of Ben's changes: no settings of his, his messages still go.
    expect(readyPrefs(benDevice)).toEqual([]);
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect((await benDevice.message(ana.handle, 'After')).t).toBe('sent');
    expect(await pendingCount(ana.token)).toBe(1);
    const back = await connect(ana.token);
    expect(readyPrefs(back)[0]).toMatchObject({ conv, clearedAt: prefs[0].clearedAt });
    expect(back.events().map((e) => e.text)).toEqual(['Before', 'After']);
  });

  it('tells only this account’s other devices about messages deleted for itself', async () => {
    const { ana, ben } = await friends();
    const conv = await conversationId(ana.id, ben.id);
    const phone = await connect(ana.token);
    expect(await ask(phone, { t: 'hide', conv, keys: ['i:abcdefgh-1234'] })).toMatchObject({ t: 'done' });
    // No other device: nothing is stored.
    expect(await stored(ana.id)).toEqual([]);

    const pc = await connect((await secondDevice(ana)).token);
    expect(await ask(phone, { t: 'hide', conv, keys: ['i:abcdefgh-1234', 'o:ijklmnop-5678'] }))
      .toMatchObject({ t: 'done' });
    expect(await pc.next('event', (e) => e.kind === 'hide'))
      .toMatchObject({ conv, keys: ['i:abcdefgh-1234', 'o:ijklmnop-5678'] });
    expect(await stored(ben.id)).toEqual([]);

    expect(await ask(phone, { t: 'hide', conv, keys: [] })).toMatchObject({ t: 'failed', code: 'invalid' });
    expect(await ask(phone, { t: 'hide', conv, keys: ['x:nope-nope'] })).toMatchObject({ t: 'failed', code: 'invalid' });
    expect(await ask(phone, { t: 'hide', conv: 'short', keys: ['i:abcdefgh-1234'] }))
      .toMatchObject({ t: 'failed', code: 'invalid' });
  });

  it('unsends a waiting message before it is delivered, and tells devices that have it', async () => {
    const { ana, ben } = await friends();
    const conv = await conversationId(ana.id, ben.id);
    const anaPhone = await connect(ana.token);
    const anaPc = await connect((await secondDevice(ana)).token);
    await anaPhone.message(ben.handle, 'Oops', 'unsend-0001');
    expect((await stored(ben.id)).map((e) => e.client_id)).toEqual(['unsend-0001']);

    expect(await ask(anaPhone, { t: 'unsend', to: ben.handle, id: 'unsend-0001' })).toMatchObject({ t: 'done', conv });
    // The text is gone from Ben's mailbox; only the unsend waits.
    expect(await stored(ben.id)).toEqual([{ kind: 'unsend', client_id: null }]);
    expect(await pendingCount(ben.token)).toBe(0);
    // Ana's other device learns of it, as her own message.
    expect(await anaPc.next('event', (e) => e.kind === 'unsend')).toMatchObject({ conv, id: 'unsend-0001', out: true });

    const benDevice = await connect(ben.token);
    expect(benDevice.events()).toEqual([
      expect.objectContaining({ kind: 'unsend', conv, id: 'unsend-0001', out: false }),
    ]);
    expect(JSON.stringify(benDevice.frames)).not.toContain('Oops');
  });

  it('unsends a delivered message on the friend’s devices, and refuses across a block', async () => {
    const { ana, ben } = await friends();
    const conv = await conversationId(ana.id, ben.id);
    const anaDevice = await connect(ana.token);
    const benDevice = await connect(ben.token);
    await anaDevice.message(ben.handle, 'Delivered', 'unsend-0002');
    const event = await benDevice.next('event', (e) => e.id === 'unsend-0002');
    benDevice.send({ t: 'ack', seq: event.seq });
    await anaDevice.next('receipt');

    expect(await ask(anaDevice, { t: 'unsend', to: ben.handle, id: 'unsend-0002' })).toMatchObject({ t: 'done' });
    expect(await benDevice.next('event', (e) => e.kind === 'unsend'))
      .toMatchObject({ conv, id: 'unsend-0002', out: false });

    // Still possible once the friendship ends, never across a block.
    await call(`/api/v1/social/friends/${ben.handle}`, { method: 'DELETE', token: ana.token });
    expect(await ask(anaDevice, { t: 'unsend', to: ben.handle, id: 'unsend-0002' })).toMatchObject({ t: 'done' });
    const pair = await friends();
    const blocker = await connect(pair.ana.token);
    const blocked = await call('/api/v1/social/blocks', { token: pair.ben.token, body: { handle: pair.ana.handle } });
    expect(blocked.status).toBe(200);
    expect(await ask(blocker, { t: 'unsend', to: pair.ben.handle, id: 'unsend-0003' }))
      .toMatchObject({ t: 'failed', code: 'not_friends' });
    expect(await stored(pair.ben.id)).toEqual([]);
    expect(await ask(anaDevice, { t: 'unsend', to: 'nobody_here_x', id: 'unsend-0002' }))
      .toMatchObject({ t: 'failed', code: 'not_friends' });
    expect(await ask(anaDevice, { t: 'unsend', to: ana.handle, id: 'unsend-0002' }))
      .toMatchObject({ t: 'failed', code: 'not_friends' });
  });

  it('cannot reach a friend’s own message: an unsend always names its real sender', async () => {
    const { ana, ben } = await friends();
    const anaDevice = await connect(ana.token);
    const benDevice = await connect(ben.token);
    await benDevice.message(ana.handle, 'Ben wrote this', 'bens-msg-0001');
    await anaDevice.next('event', (e) => e.id === 'bens-msg-0001');
    // Ana names Ben's id: it reaches Ben's devices as about a message from
    // Ana (incoming there, out: false), never as Ben's outgoing one, and
    // nothing reaches Ana's mailbox that could touch her copy of his.
    expect(await ask(anaDevice, { t: 'unsend', to: ben.handle, id: 'bens-msg-0001' })).toMatchObject({ t: 'done' });
    expect(await benDevice.next('event', (e) => e.kind === 'unsend')).toMatchObject({ id: 'bens-msg-0001', out: false });
    expect((await stored(ana.id)).filter((e) => e.kind === 'unsend')).toEqual([]);
  });

  it('forgets the settings when Friends is turned off', async () => {
    const { ana, ben } = await friends();
    const conv = await conversationId(ana.id, ben.id);
    const device = await connect(ana.token);
    expect(await ask(device, { t: 'pref', conv, muted: true })).toMatchObject({ t: 'done' });
    const off = await call('/api/v1/social/profile', { method: 'DELETE', token: ana.token });
    expect(off.status).toBe(200);
    await device.waitClosed();
    const left = await runInDurableObject(mailbox(testEnv, ana.id), async (_: Mailbox, state) =>
      state.storage.sql.exec<{ count: number }>(`SELECT COUNT(*) AS count FROM conversation_prefs`).one());
    expect(left.count).toBe(0);
  });
});
