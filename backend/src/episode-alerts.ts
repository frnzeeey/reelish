// New-episode checks for the app's background task: a narrow token per
// session, and one route that answers each series' latest aired episode and
// season count, and, for the app's other alerts, the release status of
// movies on My list, the recent and upcoming work of people followed and the
// films of collections followed (public TMDB data, through the gateway's
// cache, with the app's own request shapes so both share it). The app
// decides what is new and shows the alerts; the API stores nothing about
// what anyone follows.

import { randomToken, sha256 } from './crypto';
import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { audit, log } from './audit';
import { requireLiveSession, type Principal } from './sessions';
import { tmdbRequest } from './tmdb/gateway';
import { pendingFor } from './messaging/messages';
import { profileOf } from './social/profiles';

const tokenPrefix = 'rnt_';
/** Series per check; more than My list plus Continue watching. */
const maxSeries = 150;
/** Popular series looked at, from TMDB's first page. */
const popularCount = 20;
/** Movies on My list per check, for release-status alerts. */
const maxMovies = 30;
/** People and collections followed per check (the app's own limits). */
const maxPeople = 15;
const maxCollections = 15;
/** A person's credits answered: the latest and upcoming significant ones. */
const creditsPerPerson = 20;
/** Credits older than this are history, not news. */
const creditWindowDays = 45;
/** TMDB TV genres that are not someone's work: news, reality, talk. */
const appearanceGenres = new Set([10763, 10764, 10767]);
const now = () => Math.floor(Date.now() / 1000);

/** POST /notifications/token: a fresh episode-check token for this session. */
export async function issueToken(env: Env, principal: Principal, requestId: string) {
  await requireLiveSession(env, principal);
  const token = `${tokenPrefix}${randomToken()}`;
  await env.DB.prepare(`UPDATE sessions SET notify_hash = ? WHERE id = ? AND user_id = ?`)
    .bind(await sha256(token), principal.sessionId, principal.userId).run();
  await audit(env, 'notifications.token_issued', principal);
  return json({ token }, requestId);
}

/** The session behind an episode-check token, if it is still live. */
export async function authenticateNotify(env: Env, request: Request): Promise<Principal> {
  const header = request.headers.get('Authorization') ?? '';
  const match = /^Bearer (rnt_[A-Za-z0-9_-]{43})$/.exec(header);
  if (!match) throw new ApiError(401, 'invalid_token', 'Not a valid alert token.');
  const row = await env.DB.prepare(
    `SELECT id, user_id FROM sessions
     WHERE notify_hash = ? AND revoked_at IS NULL AND refresh_expires_at > ?`,
  ).bind(await sha256(match[1]), now()).first<{ id: string; user_id: string }>();
  if (!row) throw new ApiError(401, 'invalid_token', 'Not a valid alert token.');
  return { userId: row.user_id, sessionId: row.id };
}

interface Episode {
  season: number;
  episode: number;
  name: string;
  airDate: string;
}

interface SeriesState {
  tmdbId: number;
  name: string;
  poster: string;
  lastEpisode: Episode | null;
  /** Seasons TMDB lists, specials aside: rises when a season is announced. */
  seasons: number;
  /** TMDB's status: Returning Series, In Production, Ended, Canceled… */
  status: string;
  /** The next scheduled episode, when TMDB knows one. */
  nextEpisode: Episode | null;
}

interface MovieState {
  tmdbId: number;
  title: string;
  /** TMDB's status: Rumored, Planned, In Production, Post Production, Released. */
  status: string;
  /** The primary release date (often in cinemas), or ''. */
  releaseDate: string;
}

interface Credit {
  type: 'movie' | 'series';
  tmdbId: number;
  title: string;
  /** Release or first-air date, or '' when not announced. */
  date: string;
  /** 'cast' or 'director'. */
  role: string;
}

interface PersonState {
  tmdbId: number;
  name: string;
  credits: Credit[];
}

interface CollectionState {
  tmdbId: number;
  name: string;
  parts: { tmdbId: number; title: string; releaseDate: string }[];
}

const text = (value: unknown, max = 200) => (typeof value === 'string' ? value.slice(0, max) : '');
const dateOf = (value: unknown) =>
  typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : '';
const idOf = (value: unknown) =>
  Number.isSafeInteger(value) && (value as number) > 0 ? (value as number) : null;

/** Looks [path] up through the gateway, null when it cannot be had. */
async function lookup(env: Env, path: string, params: Record<string, string>) {
  try {
    const result = await tmdbRequest(env, path, new URLSearchParams(params));
    return JSON.parse(result.body) as Record<string, unknown>;
  } catch (error) {
    // One unavailable title does not fail the check.
    if (!(error instanceof ApiError) || error.status >= 500) {
      log('warn', 'alerts.lookup_failed', { message: String(error).slice(0, 200) });
    }
    return null;
  }
}

/** [ids] looked up a few at a time: the gateway deduplicates and caches, TMDB rate-limits. */
async function inBatches<T>(ids: number[], one: (id: number) => Promise<T | null>): Promise<T[]> {
  const out: T[] = [];
  for (let i = 0; i < ids.length; i += 8) {
    const batch = await Promise.all(ids.slice(i, i + 8).map(one));
    out.push(...batch.filter((s): s is Awaited<T> => s !== null));
  }
  return out;
}

async function movie(env: Env, tmdbId: number): Promise<MovieState | null> {
  // The app's details request, so both share the gateway's cache.
  const data = await lookup(env, `/movie/${tmdbId}`, { append_to_response: 'credits,external_ids' });
  if (!data) return null;
  return { tmdbId, title: text(data.title), status: text(data.status, 40), releaseDate: dateOf(data.release_date) };
}

/** A day [days] before today, as YYYY-MM-DD. */
function daysAgo(days: number): string {
  return new Date(Date.now() - days * 86400_000).toISOString().slice(0, 10);
}

async function person(env: Env, tmdbId: number): Promise<PersonState | null> {
  // The app's person page request.
  const data = await lookup(env, `/person/${tmdbId}`, { append_to_response: 'combined_credits' });
  if (!data) return null;
  const combined = (data.combined_credits ?? {}) as { cast?: unknown[]; crew?: unknown[] };
  const since = daysAgo(creditWindowDays);
  const byKey = new Map<string, Credit>();
  const add = (raw: unknown, role: string) => {
    const c = raw as Record<string, unknown>;
    const id = idOf(c?.id);
    const type = c?.media_type === 'movie' ? 'movie' : c?.media_type === 'tv' ? 'series' : null;
    if (!id || !type) return;
    const date = dateOf(type === 'movie' ? c.release_date : c.first_air_date);
    // Recent or upcoming only: older work is never news.
    if (date && date < since) return;
    const key = `${type}:${id}`;
    if (byKey.has(key)) return;
    byKey.set(key, { type, tmdbId: id, title: text(type === 'movie' ? c.title : c.name), date, role });
  };
  for (const raw of combined.cast ?? []) {
    const c = raw as Record<string, unknown>;
    const genres = Array.isArray(c?.genre_ids) ? (c.genre_ids as unknown[]) : [];
    const character = text(c?.character).toLowerCase();
    // A real part, not a guest spot, a talk show or playing themselves.
    if (genres.some((g) => appearanceGenres.has(g as number))) continue;
    if (/\b(self|himself|herself|themselves|narrator)\b/.test(character)) continue;
    if (c?.media_type === 'movie' && !(Number.isSafeInteger(c.order) && (c.order as number) <= 8)) continue;
    if (c?.media_type === 'tv' && !(Number.isSafeInteger(c.episode_count) && (c.episode_count as number) >= 3)) continue;
    add(raw, 'cast');
  }
  for (const raw of combined.crew ?? []) {
    if ((raw as Record<string, unknown>)?.job === 'Director') add(raw, 'director');
  }
  // Undated (announced) first, then the newest.
  const credits = [...byKey.values()]
    .sort((a, b) => (a.date === b.date ? 0 : a.date === '' ? -1 : b.date === '' ? 1 : a.date < b.date ? 1 : -1))
    .slice(0, creditsPerPerson);
  return { tmdbId, name: text(data.name), credits };
}

async function collection(env: Env, tmdbId: number): Promise<CollectionState | null> {
  // The app's collection page request.
  const data = await lookup(env, `/collection/${tmdbId}`, {});
  if (!data) return null;
  const parts = (Array.isArray(data.parts) ? data.parts : [])
    .map((raw) => {
      const p = raw as Record<string, unknown>;
      const id = idOf(p?.id);
      return id ? { tmdbId: id, title: text(p.title), releaseDate: dateOf(p.release_date) } : null;
    })
    .filter((p): p is CollectionState['parts'][number] => p !== null)
    .slice(0, 40);
  return { tmdbId, name: text(data.name), parts };
}

/** [value], a list of at most [max] TMDB ids, deduplicated; throws otherwise. */
function idList(value: unknown, max: number, name: string): number[] {
  const list = value ?? [];
  if (!Array.isArray(list) || list.length > max ||
      !list.every((id) => Number.isSafeInteger(id) && id > 0 && id <= 1e9)) {
    throw new ApiError(400, `invalid_${name}`, `${name} must list at most ${max} TMDB ids.`);
  }
  return [...new Set(list as number[])];
}

function episodeOf(value: unknown): Episode | null {
  const e = value as Record<string, unknown> | null;
  if (!e || !Number.isSafeInteger(e.season_number) || !Number.isSafeInteger(e.episode_number)) return null;
  const airDate = typeof e.air_date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(e.air_date) ? e.air_date : '';
  return {
    season: e.season_number as number,
    episode: e.episode_number as number,
    name: typeof e.name === 'string' ? e.name.slice(0, 200) : '',
    airDate,
  };
}

async function series(env: Env, tmdbId: number): Promise<SeriesState | null> {
  try {
    // The app's details request, so both share the gateway's cache.
    const result = await tmdbRequest(env, `/tv/${tmdbId}`, new URLSearchParams({
      append_to_response: 'credits,external_ids',
    }));
    const data = JSON.parse(result.body) as Record<string, unknown>;
    return {
      tmdbId,
      name: typeof data.name === 'string' ? data.name.slice(0, 200) : '',
      poster: typeof data.poster_path === 'string' ? data.poster_path.slice(0, 200) : '',
      lastEpisode: episodeOf(data.last_episode_to_air),
      seasons: Array.isArray(data.seasons)
        ? data.seasons.filter((s) => {
            const n = (s as Record<string, unknown>)?.season_number;
            return Number.isSafeInteger(n) && (n as number) > 0;
          }).length
        : 0,
      status: text(data.status, 40),
      nextEpisode: episodeOf(data.next_episode_to_air),
    };
  } catch (error) {
    // One unavailable series does not fail the check.
    if (!(error instanceof ApiError) || error.status >= 500) {
      log('warn', 'alerts.series_failed', { message: String(error).slice(0, 200) });
    }
    return null;
  }
}

/**
 * POST /notifications/episodes `{series: [tmdbId], popular: bool, messages: bool,
 * movies?: [tmdbId], people?: [tmdbId], collections?: [tmdbId]}` with an
 * episode-check token: each series' latest aired episode, season count, status
 * and next episode, plus TMDB's most popular series when asked, plus how many
 * messages wait for this device and from whom (up to three handles) when
 * asked; and, when listed, each movie's release status, each person's recent
 * and upcoming significant credits and each collection's films.
 */
export async function checkEpisodes(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  const wanted = idList(body.series, maxSeries, 'series');
  const movieIds = idList(body.movies, maxMovies, 'movies');
  const personIds = idList(body.people, maxPeople, 'people');
  const collectionIds = idList(body.collections, maxCollections, 'collections');
  let popular: number[] = [];
  if (body.popular === true) {
    try {
      const page = await tmdbRequest(env, '/tv/popular', new URLSearchParams({ page: '1' }));
      const results = (JSON.parse(page.body) as { results?: { id?: unknown }[] }).results ?? [];
      popular = results
        .map((r) => r.id)
        .filter((id): id is number => Number.isSafeInteger(id) && (id as number) > 0)
        .slice(0, popularCount);
    } catch (error) {
      log('warn', 'alerts.popular_failed', { message: String(error).slice(0, 200) });
    }
  }
  const all = [...new Set([...wanted, ...popular])];
  const states = await inBatches(all, (id) => series(env, id));
  const byId = new Map(states.map((s) => [s.tmdbId, s]));
  const movies = await inBatches(movieIds, (id) => movie(env, id));
  const people = await inBatches(personIds, (id) => person(env, id));
  const collections = await inBatches(collectionIds, (id) => collection(env, id));
  // Messages waiting for this device, folded into the same request so the
  // background task makes no second one. Counts and handles only, never text.
  // Only with Friends on: no mailbox is woken (or made) for anyone else.
  const messages = body.messages === true && (await profileOf(env, principal.userId))
    ? await pendingFor(env, principal)
    : undefined;
  return json({
    series: wanted.map((id) => byId.get(id)).filter(Boolean),
    popular: popular.map((id) => byId.get(id)).filter(Boolean),
    ...(messages ? { messages } : {}),
    // Only when asked, so an older app's answer is unchanged.
    ...(body.movies !== undefined ? { movies } : {}),
    ...(body.people !== undefined ? { people } : {}),
    ...(body.collections !== undefined ? { collections } : {}),
  }, requestId);
}
