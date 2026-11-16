// Private messages: one mailbox per account (a SQLite-backed Durable Object)
// holding only what has not yet reached every one of the account's devices.
// docs/messaging/README.md.
//
// A message is written once into the recipient's mailbox and deleted as soon
// as every live device of the recipient has saved it, or after
// [messageTtlMs]. Each device (one Reelish session) keeps a cursor: the
// highest event it has saved. Events are sent to a device in sequence order
// and the device acknowledges the highest one it has written to disk, so one
// cursor update covers any number of messages. Delivery receipts travel
// back to the sender's mailbox the same way.
//
// The WebSockets use the Hibernation API, so an open but quiet connection
// costs no duration; keep-alive pings are answered without waking the
// object. Storage is written only when a message, receipt or cursor changes.

import { DurableObject } from 'cloudflare:workers';
import type { Env } from '../env';
import { log } from '../audit';
import { sha256 } from '../crypto';

const day = 24 * 60 * 60 * 1000;
/** An undelivered message is deleted this long after it was sent. */
export const messageTtlMs = 14 * day;
/** Longest message, in UTF-16 code units (what Dart's String.length counts). */
export const maxMessageChars = 2000;
/** Messages one account may send in a UTC day. */
export const dailyMessageLimit = 1000;
/** Events sent to a device before it acknowledges them. */
export const syncBatchSize = 100;
/** A frame larger than this is refused (a maximal message is ~8 KB in UTF-8). */
const maxFrameBytes = 12 * 1024;
/** Per socket: a burst of 20 frames, refilled at one a second. */
const bucketSize = 20;
const refillPerMs = 1 / 1000;
const maxStrikes = 5;
/** How often an open socket's session is checked again. */
const sessionCheckMs = 10 * 60 * 1000;
/** Handles as the Friends routes accept them. */
const handlePattern = /^[A-Za-z][A-Za-z0-9_]{2,19}$/;
/** A message id chosen by the sending device (a UUID). */
export const messageIdPattern = /^[A-Za-z0-9-]{8,64}$/;
/** A conversation id as [conversationId] makes them (and the app accepts). */
const conversationPattern = /^[A-Za-z0-9_-]{16,64}$/;
/** A message as a device keys it: direction and the sender's id. */
const messageKeyPattern = /^[io]:[A-Za-z0-9-]{8,64}$/;
/** The device's name for a request, echoed in the answer. */
const refPattern = /^[A-Za-z0-9-]{1,40}$/;
/** Longest nickname, in UTF-16 code units. */
export const maxNicknameChars = 32;
/** Conversations one account may keep settings for. */
export const maxConversationPrefs = 1000;
/** Messages one "delete for me" may name. */
const maxHideKeys = 100;

/** Close codes the app understands. */
export const mailboxCloseCodes = {
  replaced: 4001,
  wiped: 4003,
  rateLimited: 4029,
  signedOut: 4401,
} as const;

/** How a person is shown in a conversation: never an account id. */
export interface PeerView {
  handle: string;
  displayName: string | null;
  avatar: string | null;
}

export interface MessagePayload {
  kind: 'message';
  /** The conversation: the same for both people, revealing neither id. */
  conv: string;
  /** The sender's message id. */
  id: string;
  /** True in the sender's own mailbox (a copy for their other devices). */
  out: boolean;
  /** The other person in the conversation, as of sending. */
  peer: PeerView;
  text: string;
  /** Server time (ms) the message was accepted. */
  at: number;
}

export interface ReceiptPayload {
  kind: 'receipt';
  conv: string;
  /** The ids of this account's messages that reached the other person. */
  ids: string[];
  at: number;
}

/** Messages this account deleted for itself, for its other devices. */
export interface HidePayload {
  kind: 'hide';
  conv: string;
  /** Message keys as the devices store them (`i:<id>` / `o:<id>`). */
  keys: string[];
  at: number;
}

/** A message its sender unsent: shown as unsent on every device. */
export interface UnsendPayload {
  kind: 'unsend';
  conv: string;
  /** The sender's message id. */
  id: string;
  /** True in the sender's own mailbox (for their other devices). */
  out: boolean;
  at: number;
}

type Payload = MessagePayload | ReceiptPayload | HidePayload | UnsendPayload;

/**
 * This account's own settings for one conversation, kept until changed and
 * given to every device of the account; never seen by the other person.
 */
export interface ConversationPrefs {
  conv: string;
  muted: boolean;
  /** What this account calls the other person here; null for their name. */
  nickname: string | null;
  /** Deleted here at this server time (ms): earlier messages are gone. */
  clearedAt: number | null;
}

type PrefsRow = {
  conv: string;
  muted: number;
  nickname: string | null;
  cleared_at: number | null;
};

function prefsView(row: PrefsRow): ConversationPrefs {
  return { conv: row.conv, muted: row.muted === 1, nickname: row.nickname, clearedAt: row.cleared_at };
}

export interface Delivery {
  fromUserId: string;
  message: MessagePayload;
}

/** Kept on each socket (survives hibernation; never written to storage). */
interface Attachment {
  userId: string;
  sessionId: string;
  /** The highest event sent to this socket. */
  sentUpTo: number;
  /** No backlog: new events are pushed as they arrive. */
  live: boolean;
  checkedAt: number;
  tokens: number;
  refilledAt: number;
  strikes: number;
}

/** The conversation id of two accounts, the same from either side. */
export async function conversationId(one: string, other: string): Promise<string> {
  const [a, b] = one < other ? [one, other] : [other, one];
  return (await sha256(`conversation:${a}:${b}`)).slice(0, 22);
}

/** The mailbox of [userId]. */
export function mailbox(env: Env, userId: string) {
  return env.MAILBOXES.get(env.MAILBOXES.idFromName(`mailbox:${userId}`));
}

/** Controls, bidirectional overrides and zero-width characters; newlines and tabs stay. */
const unsafe = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f​-‏‪-‮⁠-⁩﻿]/g;

/** A message as it may be stored and shown, or null when it is empty. */
export function cleanText(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const text = value.replace(/\r\n?/g, '\n').replace(unsafe, '').replace(/\n{4,}/g, '\n\n\n').trim();
  return text ? text : null;
}

/** A nickname as it may be stored: one line, no unsafe characters; null when empty or too long. */
export function cleanNickname(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const text = value.replace(unsafe, '').replace(/\s+/g, ' ').trim();
  return text && text.length <= maxNicknameChars ? text : null;
}

export class Mailbox extends DurableObject<Env> {
  private readonly sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    // Keep-alives are answered without waking the mailbox or counting a request.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
    this.createTables();
  }

  /** The tables (again after [wipe], which drops them). */
  private createTables() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        peer TEXT NOT NULL,
        client_id TEXT,
        outgoing INTEGER NOT NULL DEFAULT 0,
        body TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS devices (
        session_id TEXT PRIMARY KEY,
        cursor INTEGER NOT NULL,
        seen_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS conversation_prefs (
        conv TEXT PRIMARY KEY,
        muted INTEGER NOT NULL DEFAULT 0,
        nickname TEXT,
        cleared_at INTEGER,
        updated_at INTEGER NOT NULL
      );
    `);
  }

  // ---- RPC from the Worker and other mailboxes ----

  /**
   * Stores a message from [fromUserId] for this account and pushes it to the
   * connected devices. The same message id from the same sender is stored
   * once: a retry answers the first copy.
   */
  async deliver(input: Delivery): Promise<{ at: number; duplicate: boolean }> {
    const { fromUserId, message } = input;
    const existing = this.sql.exec<{ body: string }>(
      `SELECT body FROM events WHERE kind = 'message' AND peer = ? AND outgoing = 0 AND client_id = ? LIMIT 1`,
      fromUserId, message.id,
    ).toArray()[0];
    if (existing) return { at: (JSON.parse(existing.body) as MessagePayload).at, duplicate: true };
    await this.append(fromUserId, message);
    return { at: message.at, duplicate: false };
  }

  /**
   * Tells this account's devices that [ids] reached [fromUserId]. Stored only
   * when some live device is not connected to hear it now.
   */
  async receipt(fromUserId: string, conv: string, ids: string[], at: number): Promise<void> {
    if (ids.length === 0) return;
    const payload: ReceiptPayload = { kind: 'receipt', conv, ids, at };
    const connected = new Set(this.sockets().map(({ attachment }) => attachment.sessionId));
    const offline = this.liveDevices().some((device) => !connected.has(device.session_id));
    if (offline) {
      await this.append(fromUserId, payload);
    } else {
      for (const { socket } of this.sockets()) this.send(socket, { t: 'receipt', conv, ids, at });
    }
  }

  /**
   * Messages this device has not saved yet, and up to three of their senders.
   * Muted conversations are left out (this drives alerts and the summary),
   * and so are messages from before a conversation was deleted here.
   */
  async pending(sessionId: string): Promise<{ count: number; from: string[] }> {
    const cursor = this.cursorOf(sessionId);
    const counted = `kind = 'message' AND outgoing = 0 AND seq > ?
      AND NOT EXISTS (SELECT 1 FROM conversation_prefs p
                       WHERE p.conv = json_extract(events.body, '$.conv')
                         AND (p.muted = 1 OR p.cleared_at >= json_extract(events.body, '$.at')))`;
    const rows = this.sql.exec<{ count: number }>(
      `SELECT COUNT(*) AS count FROM events WHERE ${counted}`, cursor,
    ).one();
    const from = this.sql.exec<{ handle: string }>(
      `SELECT json_extract(body, '$.peer.handle') AS handle FROM events
        WHERE ${counted}
        GROUP BY handle ORDER BY MAX(seq) DESC LIMIT 3`, cursor,
    ).toArray().map((row) => row.handle).filter((handle) => typeof handle === 'string');
    return { count: rows.count, from };
  }

  /**
   * [fromUserId] unsent their message [id]: it is not delivered if it still
   * waits, and the devices that have it show it as unsent. Only the sender's
   * own mailbox calls this, with the sender's verified account, and devices
   * apply it only to that sender's messages, so no one can unsend another's.
   */
  async retract(fromUserId: string, conv: string, id: string, at: number): Promise<void> {
    this.sql.exec(
      `DELETE FROM events WHERE kind = 'message' AND peer = ? AND outgoing = 0 AND client_id = ?`,
      fromUserId, id,
    );
    await this.append(fromUserId, { kind: 'unsend', conv, id, out: false, at });
  }

  /** Removes everything waiting between this account and [peerUserId] (a block). */
  async purgePeer(peerUserId: string): Promise<void> {
    this.sql.exec(`DELETE FROM events WHERE peer = ?`, peerUserId);
  }

  /** Friends turned off or the account deleted: nothing is kept, sockets close. */
  async wipe(): Promise<void> {
    for (const { socket } of this.sockets()) {
      this.closeQuietly(socket, mailboxCloseCodes.wiped, 'Messages are off.');
    }
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    // Friends may be turned on again while this instance is still running.
    this.createTables();
  }

  // ---- WebSockets ----

  /** Accepts a device. The Worker has authenticated the headers' account and session. */
  async fetch(request: Request): Promise<Response> {
    const userId = request.headers.get('X-Mailbox-User');
    const sessionId = request.headers.get('X-Mailbox-Session');
    if (!userId || !sessionId || request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('Expected a WebSocket.', { status: 426 });
    }
    // One connection per device: a reconnect replaces the old one.
    for (const old of this.ctx.getWebSockets(sessionId)) {
      this.closeQuietly(old, mailboxCloseCodes.replaced, 'Connected again.');
    }
    const now = Date.now();
    this.sql.exec(
      `INSERT INTO devices (session_id, cursor, seen_at) VALUES (?, 0, ?)
       ON CONFLICT (session_id) DO UPDATE SET seen_at = excluded.seen_at`,
      sessionId, now,
    );
    const pair = new WebSocketPair();
    const server = pair[1];
    const attachment: Attachment = {
      userId,
      sessionId,
      sentUpTo: this.cursorOf(sessionId),
      live: false,
      checkedAt: now,
      tokens: bucketSize,
      refilledAt: now,
      strikes: 0,
    };
    this.ctx.acceptWebSocket(server, [sessionId]);
    this.send(server, {
      t: 'ready', serverTime: now, limits: { maxChars: maxMessageChars, maxNickname: maxNicknameChars },
      prefs: this.allPrefs(),
    });
    this.sendBatch(server, attachment);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (!attachment) {
      this.closeQuietly(ws, mailboxCloseCodes.signedOut, 'Sign in again.');
      return;
    }
    if (!this.allow(ws, attachment)) return;
    if (typeof message !== 'string' || message.length > maxFrameBytes) {
      this.strike(ws, attachment, 'invalid_message');
      return;
    }
    let msg: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(message);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('shape');
      msg = parsed as Record<string, unknown>;
    } catch {
      this.strike(ws, attachment, 'invalid_message');
      return;
    }
    if (Date.now() - attachment.checkedAt > sessionCheckMs && !(await this.stillSignedIn(ws, attachment))) return;
    switch (msg.t) {
      case 'ack':
        return this.onAck(ws, attachment, msg);
      case 'send':
        return this.onSend(ws, attachment, msg);
      case 'pref':
        return this.onPref(ws, attachment, msg);
      case 'hide':
        return this.onHide(ws, attachment, msg);
      case 'unsend':
        return this.onUnsend(ws, attachment, msg);
      default:
        this.strike(ws, attachment, 'unknown_message');
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    this.closeQuietly(ws, 1000, 'Closed.');
  }

  async webSocketError(): Promise<void> {
    // Nothing to tidy: the cursor is already stored.
  }

  /** Expired messages and devices that are gone; then the next alarm. */
  async alarm(): Promise<void> {
    const now = Date.now();
    this.sql.exec(`DELETE FROM events WHERE created_at <= ?`, now - messageTtlMs);
    this.sql.exec(`DELETE FROM devices WHERE seen_at <= ?`, now - messageTtlMs);
    const devices = this.sql.exec<{ session_id: string }>(`SELECT session_id FROM devices`).toArray();
    if (devices.length > 0) {
      // A signed-out device would otherwise hold messages until they expire.
      try {
        const ids = devices.map((device) => device.session_id);
        const { results } = await this.env.DB.prepare(
          `SELECT id FROM sessions WHERE id IN (${ids.map(() => '?').join(',')})
             AND revoked_at IS NULL AND refresh_expires_at > ?`,
        ).bind(...ids, Math.floor(now / 1000)).all<{ id: string }>();
        const live = new Set(results.map((row) => row.id));
        for (const id of ids) {
          if (!live.has(id)) this.sql.exec(`DELETE FROM devices WHERE session_id = ?`, id);
        }
      } catch (error) {
        log('warn', 'messages.alarm_sessions_failed', { message: String(error).slice(0, 200) });
      }
    }
    this.prune();
    await this.schedule();
  }

  // ---- Message handlers ----

  /** The device saved every event up to `seq`. */
  private async onAck(ws: WebSocket, a: Attachment, msg: Record<string, unknown>) {
    const seq = msg.seq;
    if (!Number.isSafeInteger(seq) || (seq as number) < 0 || (seq as number) > a.sentUpTo) {
      return this.strike(ws, a, 'invalid_message');
    }
    const cursor = seq as number;
    const before = this.cursorOf(a.sessionId);
    if (cursor <= before) {
      if (!a.live && cursor >= a.sentUpTo) this.sendBatch(ws, a);
      return;
    }
    const firstReach = this.sql.exec<{ reached: number | null }>(
      `SELECT MAX(cursor) AS reached FROM devices`,
    ).one().reached ?? 0;
    const now = Date.now();
    this.sql.exec(`UPDATE devices SET cursor = ?, seen_at = ? WHERE session_id = ?`, cursor, now, a.sessionId);

    // Messages no device had saved before this one did: tell their senders.
    if (cursor > firstReach) {
      const rows = this.sql.exec<{ peer: string; client_id: string; body: string }>(
        `SELECT peer, client_id, body FROM events
          WHERE kind = 'message' AND outgoing = 0 AND seq > ? AND seq <= ?`,
        firstReach, cursor,
      ).toArray();
      const bySender = new Map<string, { conv: string; ids: string[] }>();
      for (const row of rows) {
        const conv = (JSON.parse(row.body) as MessagePayload).conv;
        const entry = bySender.get(row.peer) ?? { conv, ids: [] };
        entry.ids.push(row.client_id);
        bySender.set(row.peer, entry);
      }
      await Promise.all([...bySender].map(async ([sender, { conv, ids }]) => {
        try {
          await mailbox(this.env, sender).receipt(a.userId, conv, ids, now);
        } catch (error) {
          // The message was delivered; only the sender's tick is lost.
          log('warn', 'messages.receipt_failed', { message: String(error).slice(0, 200) });
        }
      }));
    }
    this.prune();
    if (!a.live && cursor >= a.sentUpTo) this.sendBatch(ws, a);
  }

  /** `{t:'send', to, id, text}`: a message to a friend, checked at this moment. */
  private async onSend(ws: WebSocket, a: Attachment, msg: Record<string, unknown>) {
    const id = typeof msg.id === 'string' && messageIdPattern.test(msg.id) ? msg.id : null;
    if (!id) return this.strike(ws, a, 'invalid_message');
    const fail = (code: string) => this.send(ws, { t: 'send_error', id, code });
    const to = typeof msg.to === 'string' ? msg.to.replace(/^@/, '') : '';
    if (!handlePattern.test(to)) return fail('not_friends');
    const text = cleanText(msg.text);
    if (!text) return fail('empty');
    if (text.length > maxMessageChars) return fail('too_long');

    const now = Date.now();
    const today = Math.floor(now / day);
    let row: {
      id: string; handle: string; display_name: string | null; avatar_preset: string | null;
      my_handle: string; my_name: string | null; my_avatar: string | null;
      friend: number; blocked: number; sent_today: number | null;
    } | null;
    try {
      // Who the handle is, and whether we are friends with no block, now.
      row = await this.env.DB.prepare(
        `SELECT t.user_id AS id, t.handle, t.display_name, t.avatar_preset,
                m.handle AS my_handle, m.display_name AS my_name, m.avatar_preset AS my_avatar,
                EXISTS (SELECT 1 FROM friendships
                         WHERE (user_a = ?1 AND user_b = t.user_id) OR (user_a = t.user_id AND user_b = ?1)) AS friend,
                EXISTS (SELECT 1 FROM blocks
                         WHERE (blocker_id = ?1 AND blocked_id = t.user_id) OR (blocker_id = t.user_id AND blocked_id = ?1)) AS blocked,
                (SELECT messages FROM social_counters WHERE user_id = ?1 AND day = ?3) AS sent_today
           FROM social_profiles t JOIN social_profiles m ON m.user_id = ?1
          WHERE t.handle_key = ?2`,
      ).bind(a.userId, to.toLowerCase(), today).first();
    } catch (error) {
      log('warn', 'messages.lookup_failed', { message: String(error).slice(0, 200) });
      return fail('unavailable');
    }
    // Unknown, not a friend and blocked all answer the same.
    if (!row || row.id === a.userId || !row.friend || row.blocked) return fail('not_friends');
    if ((row.sent_today ?? 0) >= dailyMessageLimit) return fail('daily_limit');

    const conv = await conversationId(a.userId, row.id);
    const message: MessagePayload = {
      kind: 'message', conv, id, out: false,
      peer: { handle: row.my_handle, displayName: row.my_name, avatar: row.my_avatar },
      text, at: now,
    };
    let result: { at: number; duplicate: boolean };
    try {
      result = await mailbox(this.env, row.id).deliver({ fromUserId: a.userId, message });
    } catch (error) {
      log('warn', 'messages.deliver_failed', { message: String(error).slice(0, 200) });
      return fail('unavailable');
    }
    if (!result.duplicate) {
      try {
        await this.env.DB.prepare(
          `INSERT INTO social_counters (user_id, day, messages) VALUES (?, ?, 1)
           ON CONFLICT (user_id, day) DO UPDATE SET messages = messages + 1`,
        ).bind(a.userId, today).run();
      } catch (error) {
        log('warn', 'messages.count_failed', { message: String(error).slice(0, 200) });
      }
      // A copy for this account's other devices, only when it has any.
      const others = this.liveDevices().some((device) => device.session_id !== a.sessionId);
      if (others) {
        await this.append(row.id, {
          ...message, out: true, at: result.at,
          peer: { handle: row.handle, displayName: row.display_name, avatar: row.avatar_preset },
        });
      }
    }
    this.send(ws, { t: 'sent', id, conv, at: result.at });
  }

  /**
   * `{t:'pref', ref, conv, muted?, nickname?, clear?}`: this account's own
   * settings for a conversation. Stored in this account's mailbox only, then
   * given to every device of the account. `clear` deletes the conversation
   * for this account: its devices drop what came before now.
   */
  private onPref(ws: WebSocket, a: Attachment, msg: Record<string, unknown>) {
    const ref = typeof msg.ref === 'string' && refPattern.test(msg.ref) ? msg.ref : null;
    if (!ref) return this.strike(ws, a, 'invalid_message');
    const fail = (code: string) => this.send(ws, { t: 'failed', ref, code });
    const conv = typeof msg.conv === 'string' && conversationPattern.test(msg.conv) ? msg.conv : null;
    if (!conv) return fail('invalid');
    const current = this.prefRow(conv);
    let muted = current?.muted ?? 0;
    let nickname = current?.nickname ?? null;
    let clearedAt = current?.cleared_at ?? null;
    let changed = false;
    if ('muted' in msg) {
      if (typeof msg.muted !== 'boolean') return fail('invalid');
      muted = msg.muted ? 1 : 0;
      changed = true;
    }
    if ('nickname' in msg) {
      if (msg.nickname === null) {
        nickname = null;
      } else {
        const clean = cleanNickname(msg.nickname);
        if (!clean) return fail('invalid_nickname');
        nickname = clean;
      }
      changed = true;
    }
    if (msg.clear === true) {
      clearedAt = Date.now();
      changed = true;
    }
    if (!changed) return fail('invalid');
    if (muted === 0 && nickname === null && clearedAt === null) {
      this.sql.exec(`DELETE FROM conversation_prefs WHERE conv = ?`, conv);
    } else {
      if (!current) {
        const { count } = this.sql.exec<{ count: number }>(`SELECT COUNT(*) AS count FROM conversation_prefs`).one();
        if (count >= maxConversationPrefs) return fail('too_many');
      }
      this.sql.exec(
        `INSERT INTO conversation_prefs (conv, muted, nickname, cleared_at, updated_at) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (conv) DO UPDATE SET muted = excluded.muted, nickname = excluded.nickname,
           cleared_at = excluded.cleared_at, updated_at = excluded.updated_at`,
        conv, muted, nickname, clearedAt, Date.now(),
      );
    }
    const view = prefsView({ conv, muted, nickname, cleared_at: clearedAt });
    // Every device of this account, this one included, before the answer.
    for (const { socket } of this.sockets()) this.send(socket, { t: 'prefs', prefs: [view] });
    this.send(ws, { t: 'done', ref, conv });
  }

  /**
   * `{t:'hide', ref, conv, keys}`: messages this account deleted for itself.
   * Nothing leaves this mailbox: the account's other devices are told (an
   * event, only when it has others), and the other person keeps theirs.
   */
  private async onHide(ws: WebSocket, a: Attachment, msg: Record<string, unknown>) {
    const ref = typeof msg.ref === 'string' && refPattern.test(msg.ref) ? msg.ref : null;
    if (!ref) return this.strike(ws, a, 'invalid_message');
    const conv = typeof msg.conv === 'string' && conversationPattern.test(msg.conv) ? msg.conv : null;
    const keys = Array.isArray(msg.keys) ? msg.keys : null;
    if (!conv || !keys || keys.length === 0 || keys.length > maxHideKeys
        || !keys.every((key) => typeof key === 'string' && messageKeyPattern.test(key))) {
      return this.send(ws, { t: 'failed', ref, code: 'invalid' });
    }
    const others = this.liveDevices().some((device) => device.session_id !== a.sessionId);
    if (others) {
      await this.append(a.userId, { kind: 'hide', conv, keys: [...new Set(keys as string[])], at: Date.now() });
    }
    this.send(ws, { t: 'done', ref, conv });
  }

  /**
   * `{t:'unsend', ref, to, id}`: this account unsends its own message [id] to
   * [to]. The friend's mailbox drops it if it still waits and tells their
   * devices, which apply it to this account's messages only. Allowed after a
   * friendship ends, never across a block.
   */
  private async onUnsend(ws: WebSocket, a: Attachment, msg: Record<string, unknown>) {
    const ref = typeof msg.ref === 'string' && refPattern.test(msg.ref) ? msg.ref : null;
    if (!ref) return this.strike(ws, a, 'invalid_message');
    const fail = (code: string) => this.send(ws, { t: 'failed', ref, code });
    const id = typeof msg.id === 'string' && messageIdPattern.test(msg.id) ? msg.id : null;
    const to = typeof msg.to === 'string' ? msg.to.replace(/^@/, '') : '';
    if (!id || !handlePattern.test(to)) return fail('not_friends');
    let row: { id: string; blocked: number } | null;
    try {
      row = await this.env.DB.prepare(
        `SELECT t.user_id AS id,
                EXISTS (SELECT 1 FROM blocks
                         WHERE (blocker_id = ?1 AND blocked_id = t.user_id) OR (blocker_id = t.user_id AND blocked_id = ?1)) AS blocked
           FROM social_profiles t WHERE t.handle_key = ?2`,
      ).bind(a.userId, to.toLowerCase()).first();
    } catch (error) {
      log('warn', 'messages.lookup_failed', { message: String(error).slice(0, 200) });
      return fail('unavailable');
    }
    // Unknown and blocked answer the same.
    if (!row || row.id === a.userId || row.blocked) return fail('not_friends');
    const conv = await conversationId(a.userId, row.id);
    const now = Date.now();
    try {
      await mailbox(this.env, row.id).retract(a.userId, conv, id, now);
    } catch (error) {
      log('warn', 'messages.retract_failed', { message: String(error).slice(0, 200) });
      return fail('unavailable');
    }
    const others = this.liveDevices().some((device) => device.session_id !== a.sessionId);
    if (others) await this.append(row.id, { kind: 'unsend', conv, id, out: true, at: now });
    this.send(ws, { t: 'done', ref, conv });
  }

  // ---- Helpers ----

  /** Stores an event and pushes it to every device that is caught up. */
  private async append(peer: string, payload: Payload) {
    const now = Date.now();
    const { seq } = this.sql.exec<{ seq: number }>(
      `INSERT INTO events (kind, peer, client_id, outgoing, body, created_at)
       VALUES (?, ?, ?, ?, ?, ?) RETURNING seq`,
      payload.kind, peer, payload.kind === 'message' ? payload.id : null,
      payload.kind === 'message' && payload.out ? 1 : 0, JSON.stringify(payload), now,
    ).one();
    for (const { socket, attachment } of this.sockets()) {
      if (!attachment.live) continue;
      attachment.sentUpTo = seq;
      socket.serializeAttachment(attachment);
      this.send(socket, { t: 'event', seq, ...payload });
    }
    if ((await this.ctx.storage.getAlarm()) === null) await this.schedule();
  }

  /** The next events after what this socket has been sent. */
  private sendBatch(ws: WebSocket, a: Attachment) {
    const rows = this.sql.exec<{ seq: number; body: string }>(
      `SELECT seq, body FROM events WHERE seq > ? ORDER BY seq LIMIT ?`, a.sentUpTo, syncBatchSize,
    ).toArray();
    for (const row of rows) this.send(ws, { t: 'event', seq: row.seq, ...JSON.parse(row.body) });
    if (rows.length > 0) a.sentUpTo = rows[rows.length - 1].seq;
    a.live = rows.length < syncBatchSize;
    ws.serializeAttachment(a);
    if (a.live) this.send(ws, { t: 'synced', seq: a.sentUpTo });
  }

  /** Deletes what every live device has saved. */
  private prune() {
    const reached = this.sql.exec<{ low: number | null }>(
      `SELECT MIN(cursor) AS low FROM devices WHERE seen_at > ?`, Date.now() - messageTtlMs,
    ).one().low;
    if (reached !== null && reached > 0) this.sql.exec(`DELETE FROM events WHERE seq <= ?`, reached);
  }

  /**
   * While anything waits: an alarm at the oldest event's expiry, or within a
   * day, so a signed-out device stops holding messages back. None when the
   * mailbox is empty.
   */
  private async schedule() {
    const oldest = this.sql.exec<{ at: number | null }>(`SELECT MIN(created_at) AS at FROM events`).one().at;
    if (oldest === null) {
      await this.ctx.storage.deleteAlarm();
      return;
    }
    const now = Date.now();
    await this.ctx.storage.setAlarm(Math.max(Math.min(oldest + messageTtlMs, now + day), now + 1000));
  }

  private prefRow(conv: string): PrefsRow | undefined {
    return this.sql.exec<PrefsRow>(
      `SELECT conv, muted, nickname, cleared_at FROM conversation_prefs WHERE conv = ?`, conv,
    ).toArray()[0];
  }

  private allPrefs(): ConversationPrefs[] {
    return this.sql.exec<PrefsRow>(
      `SELECT conv, muted, nickname, cleared_at FROM conversation_prefs`,
    ).toArray().map(prefsView);
  }

  private cursorOf(sessionId: string): number {
    return this.sql.exec<{ cursor: number }>(
      `SELECT cursor FROM devices WHERE session_id = ?`, sessionId,
    ).toArray()[0]?.cursor ?? 0;
  }

  private liveDevices(): { session_id: string }[] {
    return this.sql.exec<{ session_id: string }>(
      `SELECT session_id FROM devices WHERE seen_at > ?`, Date.now() - messageTtlMs,
    ).toArray();
  }

  /** The session and its Friends profile still exist; otherwise the socket closes. */
  private async stillSignedIn(ws: WebSocket, a: Attachment): Promise<boolean> {
    let ok = false;
    try {
      const row = await this.env.DB.prepare(
        `SELECT EXISTS (SELECT 1 FROM sessions WHERE id = ?1 AND user_id = ?2
                          AND revoked_at IS NULL AND refresh_expires_at > ?3)
            AND EXISTS (SELECT 1 FROM social_profiles WHERE user_id = ?2) AS ok`,
      ).bind(a.sessionId, a.userId, Math.floor(Date.now() / 1000)).first<{ ok: number }>();
      ok = row?.ok === 1;
    } catch {
      // D1 unavailable: keep the socket and check again on the next frame.
      return true;
    }
    if (!ok) {
      this.closeQuietly(ws, mailboxCloseCodes.signedOut, 'Sign in again.');
      return false;
    }
    a.checkedAt = Date.now();
    ws.serializeAttachment(a);
    return true;
  }

  private sockets(): { socket: WebSocket; attachment: Attachment }[] {
    const out: { socket: WebSocket; attachment: Attachment }[] = [];
    for (const socket of this.ctx.getWebSockets()) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      const attachment = socket.deserializeAttachment() as Attachment | null;
      if (attachment) out.push({ socket, attachment });
    }
    return out;
  }

  private send(ws: WebSocket, body: unknown) {
    try {
      ws.send(JSON.stringify(body));
    } catch {
      // Closing.
    }
  }

  private strike(ws: WebSocket, a: Attachment, code: string) {
    a.strikes += 1;
    ws.serializeAttachment(a);
    if (a.strikes > maxStrikes) {
      this.closeQuietly(ws, mailboxCloseCodes.rateLimited, 'Too many invalid messages.');
    } else {
      this.send(ws, { t: 'error', code });
    }
  }

  /** A token bucket per socket; a flood closes the socket. */
  private allow(ws: WebSocket, a: Attachment): boolean {
    const now = Date.now();
    a.tokens = Math.min(bucketSize, a.tokens + (now - a.refilledAt) * refillPerMs);
    a.refilledAt = now;
    if (a.tokens < 1) {
      this.strike(ws, a, 'rate_limited');
      return false;
    }
    a.tokens -= 1;
    ws.serializeAttachment(a);
    return true;
  }

  private closeQuietly(ws: WebSocket, code: number, reason: string) {
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }
}
