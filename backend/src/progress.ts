// Playback progress synced across an account's devices: where each movie and
// episode was left, and which titles left Continue watching. Devices push the
// changes they made and pull the rows changed since their cursor; the newest
// change of a title wins, decided here, never by a device alone.
// docs/intelligent-continue-watching/CROSS_DEVICE_SYNC_STRATEGY.md.

import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { requireLiveSession, type Principal } from './sessions';

/** Changes per push; the app sends more in further requests. */
export const maxChanges = 50;
/** Rows per pull page. */
export const pageSize = 200;
/** A push body: 50 changes with card metadata fit well inside it. */
const maxBodyBytes = 32 * 1024;
/** Longer than any title; bounds what a device can store. */
const maxMediaMs = 24 * 60 * 60 * 1000;
/** Rows untouched this long are dropped by the daily cleanup. */
export const progressRetentionMs = 400 * 24 * 60 * 60 * 1000;

const keyPattern = /^(movie:[1-9]\d{0,9}|series:[1-9]\d{0,9}|episode:[1-9]\d{0,9}:\d{1,4}:\d{1,5})$/;
const devicePattern = /^[A-Za-z0-9-]{8,64}$/;
const artworkPattern = /^https:\/\/image\.tmdb\.org\/t\/p\/(w\d{2,4}|original)\/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$/;
const yearPattern = /^\d{4}$/;

export interface ProgressChange {
  key: string;
  positionMs: number;
  durationMs: number;
  next: [number, number] | null;
  removed: boolean;
  title: string | null;
  year: string | null;
  poster: string | null;
  backdrop: string | null;
  device: string;
  seq: number;
  at: number;
}

const invalid = (message: string) => new ApiError(400, 'invalid_progress', message);

const isCount = (value: unknown, max: number): value is number =>
  Number.isSafeInteger(value) && (value as number) >= 0 && (value as number) <= max;

function optionalText(value: unknown, max: number, pattern?: RegExp): string | null {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || value.length > max || (pattern && !pattern.test(value))) {
    throw invalid('A title field is malformed.');
  }
  return value;
}

/** One change as a device sent it, checked field by field. */
export function parseChange(raw: unknown, device: string, now: number): ProgressChange {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) throw invalid('Each change must be an object.');
  const entry = raw as Record<string, unknown>;
  const key = entry.key;
  if (typeof key !== 'string' || !keyPattern.test(key)) throw invalid('Unknown title key.');
  const positionMs = entry.positionMs ?? 0;
  const durationMs = entry.durationMs ?? 0;
  if (!isCount(positionMs, maxMediaMs) || !isCount(durationMs, maxMediaMs)) {
    throw invalid('Positions are whole milliseconds within a day.');
  }
  const seq = entry.seq;
  if (!isCount(seq, Number.MAX_SAFE_INTEGER)) throw invalid('seq must be a whole number.');
  const at = entry.at;
  if (!isCount(at, Number.MAX_SAFE_INTEGER)) throw invalid('at must be a time in milliseconds.');
  let next: [number, number] | null = null;
  if (entry.next !== undefined && entry.next !== null) {
    const value = entry.next;
    if (!key.startsWith('episode:') || !Array.isArray(value) || value.length !== 2
      || !isCount(value[0], 9999) || !isCount(value[1], 99999)) {
      throw invalid('next is a [season, episode] of an episode.');
    }
    next = [value[0], value[1]];
  }
  const removed = entry.removed === true;
  const card = !key.startsWith('episode:');
  return {
    key,
    positionMs,
    durationMs,
    next,
    removed,
    title: card ? optionalText(entry.title, 300) : null,
    year: card ? optionalText(entry.year, 4, yearPattern) : null,
    poster: card ? optionalText(entry.poster, 300, artworkPattern) : null,
    backdrop: card ? optionalText(entry.backdrop, 300, artworkPattern) : null,
    device,
    seq,
    // A device clock ahead of the server cannot make a change newer than now.
    at: Math.min(at, now),
  };
}

// A stored row is replaced only by a newer change (see the migration).
const upsert = `
INSERT INTO playback_progress (user_id, media_key, position_ms, duration_ms, next_season, next_episode,
  removed, title, year, poster, backdrop, device_id, seq, client_at, changed_at)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
ON CONFLICT (user_id, media_key) DO UPDATE SET
  position_ms = excluded.position_ms,
  duration_ms = excluded.duration_ms,
  next_season = excluded.next_season,
  next_episode = excluded.next_episode,
  removed = excluded.removed,
  title = COALESCE(excluded.title, playback_progress.title),
  year = COALESCE(excluded.year, playback_progress.year),
  poster = COALESCE(excluded.poster, playback_progress.poster),
  backdrop = COALESCE(excluded.backdrop, playback_progress.backdrop),
  device_id = excluded.device_id,
  seq = excluded.seq,
  client_at = excluded.client_at,
  changed_at = excluded.changed_at
WHERE (excluded.device_id = playback_progress.device_id AND excluded.seq > playback_progress.seq)
   OR (excluded.device_id <> playback_progress.device_id AND (
        excluded.client_at > playback_progress.client_at
     OR (excluded.client_at = playback_progress.client_at AND excluded.device_id > playback_progress.device_id)))`;

/** POST /progress `{device, changes: [...]}`: stores the changes that are newer. */
export async function pushProgress(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request, maxBodyBytes);
  const device = body.device;
  if (typeof device !== 'string' || !devicePattern.test(device)) throw invalid('device is malformed.');
  const raw = body.changes;
  if (!Array.isArray(raw) || raw.length > maxChanges) {
    throw invalid(`changes must list at most ${maxChanges} titles.`);
  }
  const now = Date.now();
  const changes = raw.map((entry) => parseChange(entry, device, now));
  await requireLiveSession(env, principal);
  let accepted = 0;
  if (changes.length > 0) {
    const results = await env.DB.batch(changes.map((change) => env.DB.prepare(upsert).bind(
      principal.userId,
      change.key,
      change.positionMs,
      change.durationMs,
      change.next?.[0] ?? null,
      change.next?.[1] ?? null,
      change.removed ? 1 : 0,
      change.title,
      change.year,
      change.poster,
      change.backdrop,
      change.device,
      change.seq,
      change.at,
      now,
    )));
    accepted = results.reduce((sum, result) => sum + (result.meta.changes ?? 0), 0);
  }
  return json({ accepted, serverTime: now }, requestId);
}

interface ProgressRow {
  media_key: string;
  position_ms: number;
  duration_ms: number;
  next_season: number | null;
  next_episode: number | null;
  removed: number;
  title: string | null;
  year: string | null;
  poster: string | null;
  backdrop: string | null;
  device_id: string;
  seq: number;
  client_at: number;
  changed_at: number;
}

/**
 * GET /progress?since=<cursor>: rows changed at or after the cursor, oldest
 * first. Rows changed in the cursor's own millisecond come again; applying a
 * row twice changes nothing on the device.
 */
export async function pullProgress(env: Env, principal: Principal, url: URL, requestId: string) {
  const sinceText = url.searchParams.get('since') ?? '0';
  const since = Number(sinceText);
  if (!/^\d{1,16}$/.test(sinceText) || !Number.isSafeInteger(since)) throw invalid('since is a cursor from a pull.');
  await requireLiveSession(env, principal);
  const { results } = await env.DB.prepare(
    `SELECT media_key, position_ms, duration_ms, next_season, next_episode, removed, title, year, poster,
            backdrop, device_id, seq, client_at, changed_at
       FROM playback_progress WHERE user_id = ? AND changed_at >= ?
      ORDER BY changed_at, media_key LIMIT ?`,
  ).bind(principal.userId, since, pageSize + 1).all<ProgressRow>();
  const more = results.length > pageSize;
  const rows = results.slice(0, pageSize);
  const last = rows.at(-1)?.changed_at;
  // A full page of one millisecond would never move on; step past it.
  const cursor = last === undefined ? since : more && last === since ? last + 1 : last;
  return json({
    items: rows.map((row) => ({
      key: row.media_key,
      positionMs: row.position_ms,
      durationMs: row.duration_ms,
      next: row.next_season === null || row.next_episode === null ? null : [row.next_season, row.next_episode],
      removed: row.removed === 1,
      title: row.title,
      year: row.year,
      poster: row.poster,
      backdrop: row.backdrop,
      device: row.device_id,
      at: row.client_at,
    })),
    cursor,
    more,
    serverTime: Date.now(),
  }, requestId);
}

/** The daily cleanup: progress untouched for over a year goes; returns how many. */
export async function pruneProgress(env: Env, now = Date.now()): Promise<number> {
  const result = await env.DB.prepare(
    `DELETE FROM playback_progress WHERE rowid IN
       (SELECT rowid FROM playback_progress WHERE changed_at < ? LIMIT 5000)`,
  ).bind(now - progressRetentionMs).run();
  return result.meta.changes ?? 0;
}
