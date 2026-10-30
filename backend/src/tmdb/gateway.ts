// Fetches allowlisted TMDB requests with the server-held credential:
// edge cache first, one shared upstream request per key, bounded retries,
// a timeout, a size cap, and upstream errors translated for the app.

import type { Env } from '../env';
import { ApiError } from '../http';
import { log } from '../audit';
import { allow, cacheTtlSeconds, type AllowedRequest } from './allowlist';

const upstreamTimeoutMs = 10_000;
const maxResponseBytes = 5 * 1024 * 1024;
const maxAttempts = 2;

/** Requests already on their way to TMDB in this isolate, by cache key. */
const inFlight = new Map<string, Promise<CachedBody>>();

interface CachedBody {
  body: string;
  cacheStatus: 'HIT' | 'MISS';
}

export interface GatewayDeps {
  cache?: Cache;
  fetch?: typeof fetch;
  wait?: (ms: number) => Promise<void>;
}

/** Validates [path] and [search] and returns TMDB's JSON body. */
export async function tmdbRequest(
  env: Env,
  path: string,
  search: URLSearchParams,
  deps: GatewayDeps = {},
): Promise<CachedBody> {
  const allowed = allow(path, search);
  if ('reason' in allowed) {
    throw allowed.reason === 'route'
      ? new ApiError(404, 'unknown_route', 'This TMDB request is not available.')
      : new ApiError(400, 'invalid_parameter', `Parameter not allowed: ${allowed.name.slice(0, 40)}`);
  }
  const upstream = upstreamUrl(env, allowed);
  // The cache key is the upstream URL; it never contains the credential.
  const key = upstream.toString();
  const cache = deps.cache ?? caches.default;

  const cached = await cache.match(key);
  if (cached) return { body: await cached.text(), cacheStatus: 'HIT' };

  let pending = inFlight.get(key);
  if (!pending) {
    pending = fetchUpstream(env, upstream, allowed, cache, deps).finally(() => inFlight.delete(key));
    inFlight.set(key, pending);
  }
  return pending;
}

function upstreamUrl(env: Env, request: AllowedRequest): URL {
  const base = new URL(env.TMDB_API_URL);
  // Only TMDB's own host is ever contacted, whatever the path says.
  if (base.protocol !== 'https:' || base.hostname !== 'api.themoviedb.org') {
    throw new ApiError(500, 'misconfigured', 'Gateway is misconfigured.');
  }
  const url = new URL(`${base.pathname.replace(/\/$/, '')}${request.path}`, base.origin);
  for (const [name, value] of request.params) url.searchParams.append(name, value);
  return url;
}

async function fetchUpstream(
  env: Env,
  url: URL,
  request: AllowedRequest,
  cache: Cache,
  deps: GatewayDeps,
): Promise<CachedBody> {
  const doFetch = deps.fetch ?? fetch;
  const wait = deps.wait ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  let lastStatus = 0;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    let response: Response;
    const started = Date.now();
    try {
      response = await doFetch(url.toString(), {
        headers: {
          Authorization: `Bearer ${env.TMDB_READ_TOKEN}`,
          Accept: 'application/json',
        },
        redirect: 'manual',
        signal: AbortSignal.timeout(upstreamTimeoutMs),
      });
    } catch (error) {
      log('warn', 'tmdb.upstream_error', { path: request.path, attempt, message: String(error) });
      if (attempt < maxAttempts) {
        await wait(backoff(attempt));
        continue;
      }
      throw new ApiError(502, 'upstream_unavailable', 'TMDB is not responding.');
    }
    lastStatus = response.status;
    log('info', 'tmdb.upstream', {
      path: request.path,
      status: response.status,
      ms: Date.now() - started,
      attempt,
    });

    if (response.ok) {
      const declared = Number(response.headers.get('Content-Length') ?? '0');
      if (declared > maxResponseBytes) throw tooLarge();
      const body = await response.text();
      if (body.length > maxResponseBytes) throw tooLarge();
      try {
        const parsed: unknown = JSON.parse(body);
        if (typeof parsed !== 'object' || parsed === null) throw new Error('not an object');
      } catch {
        throw new ApiError(502, 'upstream_invalid', 'TMDB sent an unreadable response.');
      }
      await cache.put(
        url.toString(),
        new Response(body, {
          headers: {
            'Content-Type': 'application/json',
            'Cache-Control': `public, max-age=${cacheTtlSeconds[request.cache]}`,
          },
        }),
      );
      return { body, cacheStatus: 'MISS' };
    }

    await response.body?.cancel();
    if (response.status === 404) {
      throw new ApiError(404, 'not_found', 'Not found on TMDB.');
    }
    if (response.status === 401 || response.status === 403) {
      // The server's credential is wrong or revoked: an operator problem.
      log('error', 'tmdb.credential_rejected', { status: response.status });
      throw new ApiError(502, 'upstream_unavailable', 'TMDB is not available right now.');
    }
    const retryable = response.status === 429 || response.status >= 500;
    if (retryable && attempt < maxAttempts) {
      const retryAfter = Number(response.headers.get('Retry-After') ?? '0');
      await wait(Math.min(Math.max(retryAfter * 1000, backoff(attempt)), 2000));
      continue;
    }
    break;
  }
  if (lastStatus === 429) {
    throw new ApiError(503, 'upstream_busy', 'TMDB is busy; try again shortly.', { 'Retry-After': '5' });
  }
  throw new ApiError(502, 'upstream_unavailable', 'TMDB is not available right now.');
}

/** 300 ms, then doubling, each with up to 50% jitter. */
function backoff(attempt: number): number {
  const base = 300 * 2 ** (attempt - 1);
  return base + Math.random() * base * 0.5;
}

function tooLarge(): ApiError {
  return new ApiError(502, 'upstream_too_large', 'TMDB response too large.');
}
