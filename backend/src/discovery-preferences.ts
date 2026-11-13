// Discovery preferences synced across an account's devices: whether the genre
// step was completed or skipped, the TMDB genre ids picked, and whether
// personalised rows are wanted. One small record per account; the newest
// change wins, decided here, never by a device alone. Viewing activity and
// recommendation feedback are not sent: they stay on the device.
// docs/discovery/DISCOVERY_IMPLEMENTATION_REPORT.md.

import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { requireLiveSession, type Principal } from './sessions';

/** More than TMDB's movie and TV genre lists together. */
export const maxGenres = 40;
const maxBodyBytes = 4 * 1024;
const devicePattern = /^[A-Za-z0-9-]{8,64}$/;

export type Onboarding = 'completed' | 'skipped';

export interface DiscoveryPreferences {
  /** Null: the genre step was never answered on any device. */
  onboarding: Onboarding | null;
  /** TMDB genre ids, movie or TV. */
  genres: number[];
  personalization: boolean;
}

const invalid = (message: string) => new ApiError(400, 'invalid_preferences', message);

const isCount = (value: unknown): value is number =>
  Number.isSafeInteger(value) && (value as number) >= 0;

/** Preferences as a device sent them, checked field by field and rebuilt. */
export function parsePreferences(raw: unknown): DiscoveryPreferences {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw invalid('preferences must be an object.');
  }
  const entry = raw as Record<string, unknown>;
  const onboarding = entry.onboarding ?? null;
  if (onboarding !== null && onboarding !== 'completed' && onboarding !== 'skipped') {
    throw invalid('onboarding is completed, skipped or null.');
  }
  const genres = entry.genres ?? [];
  if (!Array.isArray(genres) || genres.length > maxGenres) {
    throw invalid(`genres lists at most ${maxGenres} genre ids.`);
  }
  for (const id of genres) {
    // TMDB genre ids are small positive integers (the largest is 10770).
    if (!Number.isSafeInteger(id) || id < 1 || id > 99_999) throw invalid('A genre id is malformed.');
  }
  const personalization = entry.personalization ?? true;
  if (typeof personalization !== 'boolean') throw invalid('personalization is true or false.');
  return {
    onboarding,
    genres: [...new Set(genres as number[])],
    personalization,
  };
}

// The stored row is replaced only by a newer change (see the migration).
const upsert = `
INSERT INTO discovery_preferences (user_id, body, device_id, seq, client_at, changed_at)
VALUES (?1, ?2, ?3, ?4, ?5, ?6)
ON CONFLICT (user_id) DO UPDATE SET
  body = excluded.body,
  device_id = excluded.device_id,
  seq = excluded.seq,
  client_at = excluded.client_at,
  changed_at = excluded.changed_at
WHERE (excluded.device_id = discovery_preferences.device_id AND excluded.seq > discovery_preferences.seq)
   OR (excluded.device_id <> discovery_preferences.device_id AND (
        excluded.client_at > discovery_preferences.client_at
     OR (excluded.client_at = discovery_preferences.client_at
         AND excluded.device_id > discovery_preferences.device_id)))`;

interface Row {
  body: string;
  device_id: string;
  client_at: number;
}

async function stored(env: Env, userId: string) {
  const row = await env.DB.prepare(
    `SELECT body, device_id, client_at FROM discovery_preferences WHERE user_id = ?`,
  ).bind(userId).first<Row>();
  if (!row) return null;
  let preferences: DiscoveryPreferences;
  try {
    preferences = parsePreferences(JSON.parse(row.body));
  } catch {
    return null;
  }
  return { preferences, device: row.device_id, at: row.client_at };
}

/** GET /discovery/preferences: the account's preferences, or null if never saved. */
export async function getPreferences(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  return json({ stored: await stored(env, principal.userId), serverTime: Date.now() }, requestId);
}

/**
 * PUT /discovery/preferences `{device, seq, at, preferences}`: stores them if
 * they are newer than what is stored, and answers with what is stored either
 * way, so a device that lost adopts the winner.
 */
export async function putPreferences(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request, maxBodyBytes);
  const device = body.device;
  if (typeof device !== 'string' || !devicePattern.test(device)) throw invalid('device is malformed.');
  if (!isCount(body.seq)) throw invalid('seq must be a whole number.');
  if (!isCount(body.at)) throw invalid('at must be a time in milliseconds.');
  const preferences = parsePreferences(body.preferences);
  const now = Date.now();
  await requireLiveSession(env, principal);
  const result = await env.DB.prepare(upsert).bind(
    principal.userId,
    JSON.stringify(preferences),
    device,
    body.seq,
    // A device clock ahead of the server cannot make a change newer than now.
    Math.min(body.at, now),
    now,
  ).run();
  return json({
    accepted: (result.meta.changes ?? 0) > 0,
    stored: await stored(env, principal.userId),
    serverTime: now,
  }, requestId);
}
