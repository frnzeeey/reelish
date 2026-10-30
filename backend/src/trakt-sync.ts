// The user's Trakt watchlist, for syncing with the app's My list. Titles
// are identified by TMDB id; the app merges, the API only reads and edits
// the watchlist as the signed-in user.

import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { log } from './audit';
import { requireLiveSession, type Principal } from './sessions';
import { traktAccessToken, traktApi, type TraktDeps } from './trakt';

type Kind = 'movie' | 'series';

interface WatchlistItem {
  type: Kind;
  tmdbId: number;
  listedAt: string;
}

/** More than any real watchlist; bounds the work per request. */
const maxItems = 5000;
/** Per add or remove list in one request. */
const maxChanges = 100;

/**
 * The user's Trakt access token. A Trakt grant that is gone answers 409,
 * not 401: the Reelish session itself is fine, and a 401 would sign the
 * app out.
 */
async function accessToken(env: Env, principal: Principal, deps: TraktDeps): Promise<string> {
  try {
    return await traktAccessToken(env, principal.userId, deps);
  } catch (error) {
    if (error instanceof ApiError && error.code === 'trakt_reauth_required') {
      throw new ApiError(409, 'trakt_reauth_required', 'Sign in again to reconnect Trakt.');
    }
    throw error;
  }
}

function traktFailure(path: string, status: number): never {
  log('warn', 'trakt.sync_failed', { path, status });
  if (status === 401 || status === 403) {
    throw new ApiError(409, 'trakt_reauth_required', 'Sign in again to reconnect Trakt.');
  }
  if (status === 420) {
    throw new ApiError(409, 'trakt_limit', 'Your Trakt watchlist is full.');
  }
  if (status === 429) {
    throw new ApiError(503, 'trakt_busy', 'Trakt is busy; try again shortly.', { 'Retry-After': '60' });
  }
  throw new ApiError(502, 'trakt_unavailable', 'Trakt is not available right now.');
}

async function readList(env: Env, token: string, kind: Kind, deps: TraktDeps): Promise<WatchlistItem[]> {
  const path = `/sync/watchlist/${kind === 'movie' ? 'movies' : 'shows'}`;
  const response = await traktApi(env, token, path, { method: 'GET' }, deps);
  if (!response.ok) traktFailure(path, response.status);
  let rows: unknown;
  try {
    rows = await response.json();
  } catch {
    traktFailure(path, 502);
  }
  if (!Array.isArray(rows)) traktFailure(path, 502);
  const items: WatchlistItem[] = [];
  for (const row of rows.slice(0, maxItems)) {
    const media = row?.[kind === 'movie' ? 'movie' : 'show'];
    const tmdbId = media?.ids?.tmdb;
    // Titles Trakt cannot match to TMDB have nothing to show in the app.
    if (!Number.isSafeInteger(tmdbId) || tmdbId <= 0) continue;
    items.push({
      type: kind,
      tmdbId,
      listedAt: typeof row.listed_at === 'string' ? row.listed_at.slice(0, 40) : '',
    });
  }
  return items;
}

/** GET /trakt/watchlist */
export async function getWatchlist(env: Env, principal: Principal, requestId: string, deps: TraktDeps = {}) {
  await requireLiveSession(env, principal);
  const token = await accessToken(env, principal, deps);
  const [movies, shows] = await Promise.all([
    readList(env, token, 'movie', deps),
    readList(env, token, 'series', deps),
  ]);
  return json({ items: [...movies, ...shows] }, requestId);
}

function changesFrom(value: unknown, field: string): { type: Kind; tmdbId: number }[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > maxChanges) {
    throw new ApiError(400, 'invalid_watchlist_change', `${field} must list at most ${maxChanges} titles.`);
  }
  return value.map((entry) => {
    const type = entry?.type;
    const tmdbId = entry?.tmdbId;
    if ((type !== 'movie' && type !== 'series') || !Number.isSafeInteger(tmdbId) || tmdbId <= 0 || tmdbId > 1e9) {
      throw new ApiError(400, 'invalid_watchlist_change', 'Each title needs a type and a TMDB id.');
    }
    return { type, tmdbId };
  });
}

const traktBody = (changes: { type: Kind; tmdbId: number }[]) => ({
  movies: changes.filter((c) => c.type === 'movie').map((c) => ({ ids: { tmdb: c.tmdbId } })),
  shows: changes.filter((c) => c.type === 'series').map((c) => ({ ids: { tmdb: c.tmdbId } })),
});

/** Titles Trakt reported it could not find, as the app names them. */
function notFound(body: unknown): { type: Kind; tmdbId: number }[] {
  const missing = (body as { not_found?: { movies?: unknown; shows?: unknown } })?.not_found;
  const ids = (list: unknown, type: Kind) =>
    (Array.isArray(list) ? list : [])
      .map((entry) => entry?.ids?.tmdb)
      .filter((id): id is number => Number.isSafeInteger(id))
      .map((tmdbId) => ({ type, tmdbId }));
  return [...ids(missing?.movies, 'movie'), ...ids(missing?.shows, 'series')];
}

/** POST /trakt/watchlist: `{add, remove}`, each up to 100 titles. */
export async function updateWatchlist(
  env: Env,
  principal: Principal,
  request: Request,
  requestId: string,
  deps: TraktDeps = {},
) {
  const body = await readJsonBody(request);
  const add = changesFrom(body.add, 'add');
  const remove = changesFrom(body.remove, 'remove');
  await requireLiveSession(env, principal);
  if (add.length === 0 && remove.length === 0) {
    return json({ added: 0, removed: 0, notFound: [] }, requestId);
  }
  const token = await accessToken(env, principal, deps);
  const missing: { type: Kind; tmdbId: number }[] = [];
  let added = 0;
  let removed = 0;
  if (add.length > 0) {
    const response = await traktApi(env, token, '/sync/watchlist', { method: 'POST', body: traktBody(add) }, deps);
    if (!response.ok) traktFailure('/sync/watchlist', response.status);
    const result = await response.json().catch(() => ({})) as { added?: { movies?: number; shows?: number } };
    added = (result.added?.movies ?? 0) + (result.added?.shows ?? 0);
    missing.push(...notFound(result));
  }
  if (remove.length > 0) {
    const response = await traktApi(env, token, '/sync/watchlist/remove', { method: 'POST', body: traktBody(remove) }, deps);
    if (!response.ok) traktFailure('/sync/watchlist/remove', response.status);
    const result = await response.json().catch(() => ({})) as { deleted?: { movies?: number; shows?: number } };
    removed = (result.deleted?.movies ?? 0) + (result.deleted?.shows ?? 0);
    missing.push(...notFound(result));
  }
  return json({ added, removed, notFound: missing }, requestId);
}
