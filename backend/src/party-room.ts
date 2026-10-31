// A watch party room: one Durable Object per room code. It holds the shared
// playback state (the room is the authority, not any client), the
// participants' WebSockets through the Hibernation API, so an idle room
// costs no duration, and the alarms that end abandoned rooms.
//
// Storage is written only when something changes (create, join, a play,
// pause, seek or episode, a settings or host change); host heartbeats stay
// in memory unless the host has drifted from the stored timeline.

import { DurableObject } from 'cloudflare:workers';
import type { Env } from './env';
import { log } from './audit';
import { sha256 } from './crypto';

export type ContentType = 'movie' | 'series';

export interface PartyContent {
  tmdbId: number;
  type: ContentType;
  season?: number;
  episode?: number;
  title: string;
  posterPath?: string;
}

export interface PartySettings {
  capacity: number;
  /** Whether participants other than the host may play, pause and seek. */
  guestControl: boolean;
  /** Whether the host's app waits for everyone to be ready before playing. */
  waitForAll: boolean;
}

export interface PartyProfile {
  name: string;
  /** A preset id (`avatar1`…`avatar8`) or null for the name's initial. */
  avatar: string | null;
}

export interface Playback {
  status: 'idle' | 'playing' | 'paused' | 'ended';
  positionMs: number;
  rate: number;
  /** Server time (ms) at which [positionMs] was true. */
  at: number;
  /** Increases with every change; clients drop anything older. */
  seq: number;
  /** The participant id that made the change. */
  by: string | null;
}

type ParticipantStatus = 'joined' | 'loading' | 'ready' | 'playing' | 'paused' | 'buffering' | 'unavailable' | 'error';
const statuses = new Set<ParticipantStatus>(['joined', 'loading', 'ready', 'playing', 'paused', 'buffering', 'unavailable', 'error']);

interface RoomRecord {
  code: string;
  createdAt: number;
  expiresAt: number;
  hostUserId: string;
  hostPid: string;
  host: PartyProfile;
  content: PartyContent;
  settings: PartySettings;
  phase: 'lobby' | 'watching';
  playback: Playback;
  removed: string[];
  everJoined: boolean;
  hostLeftAt: number | null;
  emptySince: number | null;
}

/** Kept on each socket (survives hibernation; never written to storage). */
interface Attachment {
  userId: string;
  pid: string;
  name: string;
  avatar: string | null;
  status: ParticipantStatus;
  joinedAt: number;
  tokens: number;
  refilledAt: number;
  strikes: number;
  timeChecks: number;
}

export interface CreateRoom {
  code: string;
  hostUserId: string;
  host: PartyProfile;
  content: PartyContent;
  settings: PartySettings;
}

export interface RoomPreview {
  code: string;
  phase: 'lobby' | 'watching';
  content: PartyContent;
  host: PartyProfile;
  participants: number;
  capacity: number;
}

export type JoinCheck = 'ok' | 'not_found' | 'full' | 'removed';

export const roomLifetimeMs = 12 * 60 * 60 * 1000;
/** An empty room ends this long after its last participant leaves. */
export const emptyGraceMs = 30 * 60 * 1000;
/** A room nobody ever joined ends sooner. */
export const unjoinedGraceMs = 60 * 60 * 1000;
/** A disconnected host keeps the room this long before host moves on. */
export const hostGraceMs = 60 * 1000;
/** A heartbeat this far from the stored timeline is written (host stalled). */
const driftWriteMs = 2000;
const maxMessageBytes = 2048;
const maxPositionMs = 24 * 60 * 60 * 1000;
/** Per socket: a burst of 20 messages, refilled at 2 a second. */
const bucketSize = 20;
const refillPerMs = 2 / 1000;
const maxStrikes = 5;
const maxTimeChecks = 8;

/** Close codes the app understands. */
export const closeCodes = {
  ended: 4000,
  replaced: 4001,
  removed: 4003,
  notFound: 4004,
  full: 4009,
  rateLimited: 4029,
} as const;

/** A participant id: stable per room and account, revealing neither. */
export async function participantId(code: string, userId: string): Promise<string> {
  return (await sha256(`party:${code}:${userId}`)).slice(0, 16);
}

/** Bidirectional and zero-width controls, stripped from shown names. */
const invisible = /[\u0000-\u001f\u007f​-‏‪-‮⁦-⁩﻿]/g;

export function cleanProfile(value: unknown): PartyProfile {
  const raw = (value && typeof value === 'object' ? value : {}) as Record<string, unknown>;
  const name = typeof raw.name === 'string'
    ? raw.name.replace(/\s+/g, ' ').replace(invisible, '').trim().slice(0, 40)
    : '';
  const avatar = typeof raw.avatar === 'string' && /^avatar[1-8]$/.test(raw.avatar) ? raw.avatar : null;
  return { name: name || 'Viewer', avatar };
}

/** The content a room plays, or null when any field is out of range. */
export function cleanContent(value: unknown): PartyContent | null {
  if (!value || typeof value !== 'object') return null;
  const raw = value as Record<string, unknown>;
  const int = (v: unknown, min: number, max: number) =>
    typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max ? v : null;
  const tmdbId = int(raw.tmdbId, 1, 2 ** 31 - 1);
  const type = raw.type === 'movie' || raw.type === 'series' ? raw.type : null;
  const title = typeof raw.title === 'string' ? raw.title.replace(invisible, '').trim().slice(0, 160) : '';
  if (tmdbId === null || type === null || !title) return null;
  const content: PartyContent = { tmdbId, type, title };
  if (type === 'series') {
    const season = int(raw.season, 0, 1000);
    const episode = int(raw.episode, 0, 10000);
    if (season === null || episode === null) return null;
    content.season = season;
    content.episode = episode;
  }
  if (typeof raw.posterPath === 'string' && /^\/[A-Za-z0-9._-]{1,100}$/.test(raw.posterPath)) {
    content.posterPath = raw.posterPath;
  }
  return content;
}

export class WatchPartyRoom extends DurableObject<Env> {
  private room: RoomRecord | null | undefined;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keep-alives are answered without waking the room or counting a request.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  private async load(): Promise<RoomRecord | null> {
    if (this.room === undefined) this.room = (await this.ctx.storage.get<RoomRecord>('room')) ?? null;
    return this.room;
  }

  private async save(room: RoomRecord): Promise<void> {
    this.room = room;
    await this.ctx.storage.put('room', room);
  }

  // ---- RPC from the Worker ----

  /** Claims this code for a new room; false when it is already in use. */
  async create(input: CreateRoom): Promise<{ ok: boolean; expiresAt: number }> {
    const existing = await this.load();
    if (existing) return { ok: false, expiresAt: 0 };
    const now = Date.now();
    const room: RoomRecord = {
      code: input.code,
      createdAt: now,
      expiresAt: now + roomLifetimeMs,
      hostUserId: input.hostUserId,
      hostPid: await participantId(input.code, input.hostUserId),
      host: input.host,
      content: input.content,
      settings: input.settings,
      phase: 'lobby',
      playback: { status: 'idle', positionMs: 0, rate: 1, at: now, seq: 0, by: null },
      removed: [],
      everJoined: false,
      hostLeftAt: null,
      emptySince: now,
    };
    await this.save(room);
    await this.schedule(room);
    return { ok: true, expiresAt: room.expiresAt };
  }

  async preview(): Promise<RoomPreview | null> {
    const room = await this.load();
    if (!room) return null;
    return {
      code: room.code,
      phase: room.phase,
      content: room.content,
      host: room.host,
      participants: this.connected().length,
      capacity: room.settings.capacity,
    };
  }

  async check(userId: string): Promise<JoinCheck> {
    return this.verdict(await this.load(), userId);
  }

  private verdict(room: RoomRecord | null, userId: string): JoinCheck {
    if (!room) return 'not_found';
    if (room.removed.includes(userId)) return 'removed';
    const others = this.connected().filter((a) => a.userId !== userId);
    return others.length >= room.settings.capacity ? 'full' : 'ok';
  }

  /** Ends the room if [userId] hosts it (a new party replaces the old). */
  async endIfHost(userId: string): Promise<void> {
    const room = await this.load();
    if (room && room.hostUserId === userId) await this.end('replaced');
  }

  // ---- WebSockets ----

  /** Accepts a participant. The Worker has authenticated X-Party-User. */
  async fetch(request: Request): Promise<Response> {
    const userId = request.headers.get('X-Party-User');
    if (!userId || request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('Expected a WebSocket.', { status: 426 });
    }
    const loaded = await this.load();
    const pid = loaded ? await participantId(loaded.code, userId) : '';
    // Nothing is awaited from the check until the socket is accepted with
    // its identity, so simultaneous joins cannot overfill the room and no
    // message can arrive before the socket knows whose it is.
    const room = this.room ?? null;
    const verdict = this.verdict(room, userId);
    if (verdict !== 'ok' || !room) {
      return new Response(verdict, { status: verdict === 'not_found' ? 404 : verdict === 'full' ? 409 : 403 });
    }
    // One connection per account: a reconnect or second device replaces it.
    for (const old of this.ctx.getWebSockets(userId)) {
      try {
        old.close(closeCodes.replaced, 'Connected elsewhere.');
      } catch {
        // Already closing.
      }
    }
    const now = Date.now();
    const pair = new WebSocketPair();
    const server = pair[1];
    const attachment: Attachment = {
      userId,
      pid,
      name: userId === room.hostUserId ? room.host.name : 'Viewer',
      avatar: userId === room.hostUserId ? room.host.avatar : null,
      status: 'joined',
      joinedAt: now,
      tokens: bucketSize,
      refilledAt: now,
      strikes: 0,
      timeChecks: 0,
    };
    this.ctx.acceptWebSocket(server, [userId]);
    server.serializeAttachment(attachment);
    const hostBack = userId === room.hostUserId && room.hostLeftAt !== null;
    if (!room.everJoined || room.emptySince !== null || hostBack) {
      room.everJoined = true;
      room.emptySince = null;
      if (hostBack) room.hostLeftAt = null;
      await this.save(room);
      await this.schedule(room);
    }
    this.send(server, { t: 'welcome', you: { pid: attachment.pid }, room: this.snapshot(room), serverTime: now });
    this.broadcastParticipants(room);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const room = await this.load();
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (!room || !attachment) {
      this.closeQuietly(ws, closeCodes.notFound, 'Room not found.');
      return;
    }
    if (!this.allow(ws, attachment)) return;
    if (typeof message !== 'string' || message.length > maxMessageBytes) {
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
    const isHost = attachment.userId === room.hostUserId;
    switch (msg.t) {
      case 'hello':
        return this.onHello(ws, attachment, room, msg);
      case 'time':
        return this.onTime(ws, attachment, msg);
      case 'status':
        return this.onStatus(ws, attachment, room, msg);
      case 'control':
        if (!isHost && !room.settings.guestControl) return this.reject(ws, 'not_allowed');
        return this.onControl(ws, attachment, room, msg);
      case 'heartbeat':
        if (!isHost) return this.reject(ws, 'not_allowed');
        return this.onHeartbeat(room, msg);
      case 'leave':
        return this.onLeave(ws, attachment, room);
    }
    if (!isHost) return this.reject(ws, 'not_allowed');
    switch (msg.t) {
      case 'start':
        return this.onStart(attachment, room);
      case 'content':
        return this.onContent(ws, attachment, room, msg);
      case 'settings':
        return this.onSettings(room, msg);
      case 'kick':
        return this.onKick(ws, room, msg);
      case 'transfer':
        return this.onTransfer(ws, room, msg);
      case 'end':
        return this.end('host');
      default:
        this.strike(ws, attachment, 'unknown_message');
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    this.closeQuietly(ws, 1000, 'Closed.');
    await this.departed(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.departed(ws);
  }

  async alarm(): Promise<void> {
    const room = await this.load();
    if (!room) return;
    const now = Date.now();
    if (now >= room.expiresAt) return this.end('expired');
    const connected = this.connected();
    if (connected.length === 0) {
      const since = room.emptySince ?? now;
      const grace = room.everJoined ? emptyGraceMs : unjoinedGraceMs;
      if (now >= since + grace) return this.end('empty');
      if (room.emptySince === null) {
        room.emptySince = now;
        await this.save(room);
      }
    } else if (room.hostLeftAt !== null && now >= room.hostLeftAt + hostGraceMs) {
      // The host did not come back: the longest-connected participant hosts.
      const next = [...connected].sort((a, b) => a.joinedAt - b.joinedAt)[0];
      await this.makeHost(room, next);
    }
    await this.schedule(room);
  }

  // ---- Message handlers ----

  private async onHello(ws: WebSocket, a: Attachment, room: RoomRecord, msg: Record<string, unknown>) {
    const profile = cleanProfile(msg);
    a.name = profile.name;
    a.avatar = profile.avatar;
    ws.serializeAttachment(a);
    if (a.userId === room.hostUserId &&
        (room.host.name !== profile.name || room.host.avatar !== profile.avatar)) {
      room.host = profile;
      await this.save(room);
    }
    this.broadcastParticipants(room);
  }

  private onTime(ws: WebSocket, a: Attachment, msg: Record<string, unknown>) {
    if (a.timeChecks >= maxTimeChecks) return this.reject(ws, 'rate_limited');
    a.timeChecks += 1;
    ws.serializeAttachment(a);
    const c = typeof msg.c === 'number' && Number.isFinite(msg.c) ? msg.c : 0;
    this.send(ws, { t: 'time', c, s: Date.now() });
  }

  private onStatus(ws: WebSocket, a: Attachment, room: RoomRecord, msg: Record<string, unknown>) {
    const status = msg.state as ParticipantStatus;
    if (!statuses.has(status)) return this.reject(ws, 'invalid_message');
    if (a.status === status) return;
    a.status = status;
    ws.serializeAttachment(a);
    this.broadcastParticipants(room);
  }

  private async onControl(ws: WebSocket, a: Attachment, room: RoomRecord, msg: Record<string, unknown>) {
    if (room.phase !== 'watching') return this.reject(ws, 'not_started');
    const position = this.position(msg.positionMs);
    if (position === null) return this.reject(ws, 'invalid_message');
    const at = this.stamp(msg.at);
    const previous = room.playback;
    let status: Playback['status'];
    switch (msg.action) {
      case 'play': status = 'playing'; break;
      case 'pause': status = 'paused'; break;
      case 'seek': status = previous.status === 'playing' ? 'playing' : 'paused'; break;
      case 'ended': status = 'ended'; break;
      default: return this.reject(ws, 'invalid_message');
    }
    room.playback = { status, positionMs: position, rate: 1, at, seq: previous.seq + 1, by: a.pid };
    await this.save(room);
    this.broadcast({ t: 'state', playback: room.playback, serverTime: Date.now() });
  }

  private async onHeartbeat(room: RoomRecord, msg: Record<string, unknown>) {
    const playback = room.playback;
    // Only for the state the host has seen; a late heartbeat is ignored.
    if (playback.status !== 'playing' || msg.seq !== playback.seq) return;
    const position = this.position(msg.positionMs);
    if (position === null) return;
    const at = this.stamp(msg.at);
    const expected = playback.positionMs + (at - playback.at) * playback.rate;
    room.playback = { ...playback, positionMs: position, at };
    if (Math.abs(expected - position) > driftWriteMs) {
      await this.save(room);
    } else {
      this.room = room;
    }
    this.broadcast({ t: 'state', playback: room.playback, serverTime: Date.now() });
  }

  private async onStart(a: Attachment, room: RoomRecord) {
    room.phase = 'watching';
    room.playback = { status: 'paused', positionMs: 0, rate: 1, at: Date.now(), seq: room.playback.seq + 1, by: a.pid };
    await this.save(room);
    this.broadcast({ t: 'room', room: this.snapshot(room), serverTime: Date.now() });
  }

  private async onContent(ws: WebSocket, a: Attachment, room: RoomRecord, msg: Record<string, unknown>) {
    const content = cleanContent(msg.content);
    if (!content) return this.reject(ws, 'invalid_message');
    room.content = content;
    room.playback = { status: 'paused', positionMs: 0, rate: 1, at: Date.now(), seq: room.playback.seq + 1, by: a.pid };
    // Everyone loads the new title again.
    for (const socket of this.ctx.getWebSockets()) {
      const other = socket.deserializeAttachment() as Attachment | null;
      if (other) {
        other.status = 'loading';
        socket.serializeAttachment(other);
      }
    }
    await this.save(room);
    this.broadcast({ t: 'room', room: this.snapshot(room), serverTime: Date.now() });
  }

  private async onSettings(room: RoomRecord, msg: Record<string, unknown>) {
    const settings = { ...room.settings };
    if (typeof msg.guestControl === 'boolean') settings.guestControl = msg.guestControl;
    if (typeof msg.waitForAll === 'boolean') settings.waitForAll = msg.waitForAll;
    if (typeof msg.capacity === 'number' && Number.isInteger(msg.capacity)) {
      settings.capacity = Math.min(Math.max(msg.capacity, 2), maxCapacity(this.env));
    }
    room.settings = settings;
    await this.save(room);
    this.broadcast({ t: 'room', room: this.snapshot(room), serverTime: Date.now() });
  }

  private async onKick(ws: WebSocket, room: RoomRecord, msg: Record<string, unknown>) {
    const target = this.byPid(msg.pid);
    if (!target || target.attachment.userId === room.hostUserId) return this.reject(ws, 'invalid_message');
    room.removed = [...room.removed, target.attachment.userId].slice(-100);
    await this.save(room);
    this.send(target.socket, { t: 'removed' });
    this.closeQuietly(target.socket, closeCodes.removed, 'Removed by the host.');
    this.broadcastParticipants(room, target.socket);
  }

  private async onTransfer(ws: WebSocket, room: RoomRecord, msg: Record<string, unknown>) {
    const target = this.byPid(msg.pid);
    if (!target || target.attachment.userId === room.hostUserId) return this.reject(ws, 'invalid_message');
    await this.makeHost(room, target.attachment);
  }

  private async onLeave(ws: WebSocket, a: Attachment, room: RoomRecord) {
    if (a.userId === room.hostUserId) {
      const next = this.connected()
        .filter((other) => other.userId !== a.userId)
        .sort((x, y) => x.joinedAt - y.joinedAt)[0];
      if (next) await this.makeHost(room, next);
    }
    this.closeQuietly(ws, 1000, 'Left the party.');
    await this.departed(ws);
  }

  // ---- Helpers ----

  private async makeHost(room: RoomRecord, next: Attachment) {
    room.hostUserId = next.userId;
    room.hostPid = next.pid;
    room.host = { name: next.name, avatar: next.avatar };
    room.hostLeftAt = null;
    await this.save(room);
    this.broadcast({ t: 'room', room: this.snapshot(room), serverTime: Date.now() });
    this.broadcastParticipants(room);
  }

  /** After a socket closed: host grace, empty-room timer, the new list. */
  private async departed(ws: WebSocket) {
    const room = await this.load();
    const gone = ws.deserializeAttachment() as Attachment | null;
    if (!room || !gone) return;
    const connected = this.connected(ws);
    if (connected.some((a) => a.userId === gone.userId)) return;
    let changed = false;
    if (gone.userId === room.hostUserId && room.hostLeftAt === null) {
      room.hostLeftAt = Date.now();
      changed = true;
    }
    if (connected.length === 0 && room.emptySince === null) {
      room.emptySince = Date.now();
      changed = true;
    }
    if (changed) {
      await this.save(room);
      await this.schedule(room);
    }
    this.broadcastParticipants(room, ws);
  }

  private async schedule(room: RoomRecord) {
    let next = room.expiresAt;
    if (room.emptySince !== null) {
      next = Math.min(next, room.emptySince + (room.everJoined ? emptyGraceMs : unjoinedGraceMs));
    }
    if (room.hostLeftAt !== null) next = Math.min(next, room.hostLeftAt + hostGraceMs);
    await this.ctx.storage.setAlarm(Math.max(next, Date.now() + 1000));
  }

  private async end(reason: 'host' | 'expired' | 'empty' | 'replaced') {
    for (const socket of this.ctx.getWebSockets()) {
      this.send(socket, { t: 'ended', reason });
      this.closeQuietly(socket, closeCodes.ended, 'The party ended.');
    }
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    this.room = null;
    log('info', 'party.ended', { reason });
  }

  /** Open sockets' attachments, optionally leaving one out. */
  private connected(except?: WebSocket): Attachment[] {
    const seen = new Map<string, Attachment>();
    for (const socket of this.ctx.getWebSockets()) {
      // A just-accepted socket may still be connecting; it holds a place.
      if (socket === except || socket.readyState >= WebSocket.CLOSING) continue;
      const a = socket.deserializeAttachment() as Attachment | null;
      if (a) seen.set(a.userId, a);
    }
    return [...seen.values()];
  }

  private byPid(pid: unknown): { socket: WebSocket; attachment: Attachment } | null {
    if (typeof pid !== 'string') return null;
    for (const socket of this.ctx.getWebSockets()) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      const a = socket.deserializeAttachment() as Attachment | null;
      if (a?.pid === pid) return { socket, attachment: a };
    }
    return null;
  }

  private snapshot(room: RoomRecord) {
    return {
      code: room.code,
      phase: room.phase,
      content: room.content,
      settings: room.settings,
      host: { pid: room.hostPid, ...room.host },
      hostConnected: room.hostLeftAt === null,
      playback: room.playback,
      expiresAt: room.expiresAt,
      participants: this.participants(room),
    };
  }

  private participants(room: RoomRecord, except?: WebSocket) {
    return this.connected(except)
      .sort((a, b) => a.joinedAt - b.joinedAt)
      .map((a) => ({
        pid: a.pid,
        name: a.name,
        avatar: a.avatar,
        host: a.userId === room.hostUserId,
        status: a.status,
      }));
  }

  private broadcastParticipants(room: RoomRecord, except?: WebSocket) {
    this.broadcast({ t: 'participants', participants: this.participants(room, except), hostConnected: room.hostLeftAt === null }, except);
  }

  private broadcast(body: unknown, except?: WebSocket) {
    const text = JSON.stringify(body);
    for (const socket of this.ctx.getWebSockets()) {
      if (socket === except || socket.readyState !== WebSocket.OPEN) continue;
      try {
        socket.send(text);
      } catch {
        // Closing; its close handler updates the room.
      }
    }
  }

  private send(ws: WebSocket, body: unknown) {
    try {
      ws.send(JSON.stringify(body));
    } catch {
      // Closing.
    }
  }

  private reject(ws: WebSocket, code: string) {
    this.send(ws, { t: 'error', code });
  }

  private strike(ws: WebSocket, a: Attachment, code: string) {
    a.strikes += 1;
    ws.serializeAttachment(a);
    if (a.strikes > maxStrikes) {
      this.closeQuietly(ws, closeCodes.rateLimited, 'Too many invalid messages.');
    } else {
      this.reject(ws, code);
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

  private position(value: unknown): number | null {
    return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= maxPositionMs
      ? Math.round(value)
      : null;
  }

  /** The sender's estimate of server time, kept to the recent past. */
  private stamp(value: unknown): number {
    const now = Date.now();
    if (typeof value !== 'number' || !Number.isFinite(value)) return now;
    return Math.min(now, Math.max(now - 3000, Math.round(value)));
  }

  private closeQuietly(ws: WebSocket, code: number, reason: string) {
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }
}

/** The most participants a room may allow, from PARTY_MAX_CAPACITY. */
export function maxCapacity(env: Env): number {
  const configured = Number(env.PARTY_MAX_CAPACITY ?? '5');
  return Number.isInteger(configured) && configured >= 2 && configured <= 20 ? configured : 5;
}
