// New-episode checks for the app's background task: a narrow token per
// session, and one route that answers each series' latest aired episode
// (public TMDB data, through the gateway's cache). The app decides what is
// new and shows the alerts; the API stores nothing about the series.

import { randomToken, sha256 } from './crypto';
import type { Env } from './env';
import { ApiError, json, readJsonBody } from './http';
import { audit, log } from './audit';
import { requireLiveSession, type Principal } from './sessions';
import { tmdbRequest } from './tmdb/gateway';

const tokenPrefix = 'rnt_';
/** Series per check; more than My list plus Continue watching. */
const maxSeries = 150;
/** Popular series looked at, from TMDB's first page. */
const popularCount = 20;
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
 * POST /notifications/episodes `{series: [tmdbId], popular: bool}` with an
 * episode-check token: each series' latest aired episode, plus TMDB's most
 * popular series when asked.
 */
export async function checkEpisodes(env: Env, principal: Principal, request: Request, requestId: string) {
  const body = await readJsonBody(request);
  const ids = body.series ?? [];
  if (!Array.isArray(ids) || ids.length > maxSeries ||
      !ids.every((id) => Number.isSafeInteger(id) && id > 0 && id <= 1e9)) {
    throw new ApiError(400, 'invalid_series', `series must list at most ${maxSeries} TMDB ids.`);
  }
  const wanted = [...new Set(ids as number[])];
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
  // A few at a time: the gateway deduplicates and caches, TMDB rate-limits.
  const states: SeriesState[] = [];
  for (let i = 0; i < all.length; i += 8) {
    const batch = await Promise.all(all.slice(i, i + 8).map((id) => series(env, id)));
    states.push(...batch.filter((s): s is SeriesState => s !== null));
  }
  const byId = new Map(states.map((s) => [s.tmdbId, s]));
  return json({
    series: wanted.map((id) => byId.get(id)).filter(Boolean),
    popular: popular.map((id) => byId.get(id)).filter(Boolean),
  }, requestId);
}
