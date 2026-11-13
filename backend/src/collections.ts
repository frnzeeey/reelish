// Custom collections synced across an account's devices: folders, collections
// and the titles in them, one row per record. Devices push the records they
// changed and pull the rows changed since their cursor; the newest change of a
// record wins, decided here, never by a device alone. Every field is checked
// and the stored body is rebuilt from the checked fields.
// docs/custom-collections/COLLECTION_SYNC_STRATEGY.md.

import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { requireLiveSession, type Principal } from './sessions';

/** Records per push; the app sends more in further requests. */
export const maxChanges = 50;
/** Rows per pull page. */
export const pageSize = 200;
/** A push body: 50 records with descriptions and artwork fit inside it. */
const maxBodyBytes = 64 * 1024;
/** Deletion marks are kept this long after the deletion, then dropped. */
export const tombstoneRetentionMs = 400 * 24 * 60 * 60 * 1000;

const idPattern = /^[0-9a-f]{24}$/;
const titlePattern = /^(movie|series):[1-9]\d{0,9}$/;
const entryKeyPattern = /^[0-9a-f]{24}\|(movie|series):[1-9]\d{0,9}$/;
const devicePattern = /^[A-Za-z0-9-]{8,64}$/;
export const artworkPattern = /^https:\/\/image\.tmdb\.org\/t\/p\/(w\d{2,4}|original)\/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$/;
const yearPattern = /^\d{4}$/;

type Kind = 'folder' | 'collection' | 'entry';

export interface CollectionChange {
  kind: Kind;
  key: string;
  body: Record<string, string | number>;
  deleted: boolean;
  /**
   * Who besides the owner may see a collection; entries and folders are
   * private. Null: a collection change that did not say (an older app),
   * which keeps what is stored.
   */
  visibility: 'private' | 'friends' | null;
  device: string;
  seq: number;
  at: number;
}

const invalid = (message: string) => new ApiError(400, 'invalid_collection', message);

const isCount = (value: unknown, max = Number.MAX_SAFE_INTEGER): value is number =>
  Number.isSafeInteger(value) && (value as number) >= 0 && (value as number) <= max;

function text(value: unknown, max: number, { required = false, pattern }: { required?: boolean; pattern?: RegExp } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) throw invalid('A required field is missing.');
    return null;
  }
  if (typeof value !== 'string' || value.length > max || (pattern && !pattern.test(value))) {
    throw invalid('A field is malformed.');
  }
  return value;
}

function order(value: unknown): number {
  if (value === undefined || value === null) return 0;
  if (typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) > 1e9) {
    throw invalid('order must be a number.');
  }
  return value;
}

/** One record as a device sent it, checked field by field. */
export function parseChange(raw: unknown, device: string, now: number): CollectionChange {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) throw invalid('Each change must be an object.');
  const entry = raw as Record<string, unknown>;
  const kind = entry.kind;
  if (kind !== 'folder' && kind !== 'collection' && kind !== 'entry') throw invalid('Unknown record kind.');
  const key = entry.key;
  if (typeof key !== 'string' || !(kind === 'entry' ? entryKeyPattern : idPattern).test(key)) {
    throw invalid('Unknown record key.');
  }
  const seq = entry.seq;
  if (!isCount(seq)) throw invalid('seq must be a whole number.');
  const at = entry.at;
  if (!isCount(at)) throw invalid('at must be a time in milliseconds.');
  const deleted = entry.deleted === true;
  // Only a collection can be shared, and only "friends" shares it; any other
  // value is private. An older app sends nothing: the stored value stays.
  const visibility = deleted || kind !== 'collection'
    ? 'private'
    : entry.visibility === undefined ? null : entry.visibility === 'friends' ? 'friends' : 'private';
  const body: Record<string, string | number> = {};
  const put = (field: string, value: string | number | null) => {
    if (value !== null) body[field] = value;
  };
  // A deletion carries no content: only the mark is kept.
  if (!deleted) {
    if (kind === 'entry') {
      put('name', text(entry.name, 300));
      put('poster', text(entry.poster, 300, { pattern: artworkPattern }));
      put('background', text(entry.background, 300, { pattern: artworkPattern }));
      put('year', text(entry.year, 4, { pattern: yearPattern }));
      if (!isCount(entry.addedAt ?? 0)) throw invalid('addedAt must be a time in milliseconds.');
      put('addedAt', (entry.addedAt as number | undefined) ?? 0);
    } else {
      put('name', text(entry.name, 80, { required: true }));
      put('order', order(entry.order));
      if (!isCount(entry.createdAt ?? 0)) throw invalid('createdAt must be a time in milliseconds.');
      put('createdAt', (entry.createdAt as number | undefined) ?? 0);
      if (kind === 'collection') {
        put('description', text(entry.description, 300));
        put('folderId', text(entry.folderId, 24, { pattern: idPattern }));
        put('cover', text(entry.cover, 30, { pattern: titlePattern }));
        if (visibility === 'friends') put('visibility', visibility);
      }
    }
  }
  return {
    kind,
    key,
    body,
    deleted,
    visibility,
    device,
    seq,
    // A device clock ahead of the server cannot make a change newer than now.
    at: Math.min(at, now),
  };
}

// A stored row is replaced only by a newer change (see the migration).
const upsert = `
INSERT INTO collection_records (user_id, kind, record_key, body, deleted, device_id, seq, client_at, changed_at, visibility)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, COALESCE(?10, 'private'))
ON CONFLICT (user_id, kind, record_key) DO UPDATE SET
  body = CASE WHEN ?10 IS NULL AND collection_records.visibility = 'friends'
              THEN json_set(excluded.body, '$.visibility', 'friends') ELSE excluded.body END,
  deleted = excluded.deleted,
  visibility = COALESCE(?10, collection_records.visibility),
  device_id = excluded.device_id,
  seq = excluded.seq,
  client_at = excluded.client_at,
  changed_at = excluded.changed_at
WHERE (excluded.device_id = collection_records.device_id AND excluded.seq > collection_records.seq)
   OR (excluded.device_id <> collection_records.device_id AND (
        excluded.client_at > collection_records.client_at
     OR (excluded.client_at = collection_records.client_at AND excluded.device_id > collection_records.device_id)))`;

/** POST /collections `{device, changes: [...]}`: stores the records that are newer. */
export async function pushCollections(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request, maxBodyBytes);
  const device = body.device;
  if (typeof device !== 'string' || !devicePattern.test(device)) throw invalid('device is malformed.');
  const raw = body.changes;
  if (!Array.isArray(raw) || raw.length > maxChanges) {
    throw invalid(`changes must list at most ${maxChanges} records.`);
  }
  const now = Date.now();
  const changes = raw.map((entry) => parseChange(entry, device, now));
  await requireLiveSession(env, principal);
  let accepted = 0;
  if (changes.length > 0) {
    const results = await env.DB.batch(changes.map((change) => env.DB.prepare(upsert).bind(
      principal.userId,
      change.kind,
      change.key,
      JSON.stringify(change.body),
      change.deleted ? 1 : 0,
      change.device,
      change.seq,
      change.at,
      now,
      change.visibility,
    )));
    accepted = results.reduce((sum, result) => sum + (result.meta.changes ?? 0), 0);
  }
  return json({ accepted, serverTime: now }, requestId);
}

interface RecordRow {
  kind: Kind;
  record_key: string;
  body: string;
  deleted: number;
  device_id: string;
  client_at: number;
  changed_at: number;
}

/**
 * GET /collections?since=<cursor>: rows changed at or after the cursor, oldest
 * first. Rows changed in the cursor's own millisecond come again; applying a
 * row twice changes nothing on the device.
 */
export async function pullCollections(env: Env, principal: Principal, url: URL, requestId: string) {
  const sinceText = url.searchParams.get('since') ?? '0';
  const since = Number(sinceText);
  if (!/^\d{1,16}$/.test(sinceText) || !Number.isSafeInteger(since)) throw invalid('since is a cursor from a pull.');
  await requireLiveSession(env, principal);
  const { results } = await env.DB.prepare(
    `SELECT kind, record_key, body, deleted, device_id, client_at, changed_at
       FROM collection_records WHERE user_id = ? AND changed_at >= ?
      ORDER BY changed_at, kind, record_key LIMIT ?`,
  ).bind(principal.userId, since, pageSize + 1).all<RecordRow>();
  const more = results.length > pageSize;
  const rows = results.slice(0, pageSize);
  const last = rows.at(-1)?.changed_at;
  // A full page of one millisecond would never move on; step past it.
  const cursor = last === undefined ? since : more && last === since ? last + 1 : last;
  return json({
    items: rows.map((row) => {
      let fields: Record<string, unknown> = {};
      try {
        fields = JSON.parse(row.body) as Record<string, unknown>;
      } catch {
        // Bodies are written only by pushCollections; an unreadable one is sent empty.
      }
      return {
        ...fields,
        kind: row.kind,
        key: row.record_key,
        deleted: row.deleted === 1,
        device: row.device_id,
        at: row.client_at,
      };
    }),
    cursor,
    more,
    serverTime: Date.now(),
  }, requestId);
}

/** The daily cleanup: deletion marks older than the retention go; returns how many. */
export async function pruneCollections(env: Env, now = Date.now()): Promise<number> {
  const result = await env.DB.prepare(
    `DELETE FROM collection_records WHERE rowid IN
       (SELECT rowid FROM collection_records WHERE deleted = 1 AND changed_at < ? LIMIT 5000)`,
  ).bind(now - tombstoneRetentionMs).run();
  return result.meta.changes ?? 0;
}
