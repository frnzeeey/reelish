// The Reelish API Worker: routes /api/v1 requests, applies rate limits and
// authentication, and turns every failure into a safe JSON error.

import { assertConfigured, ConfigError, type Env } from './env';
import { ApiError, errorResponse, json, requestIdFor } from './http';
import { log } from './audit';
import { authenticate } from './sessions';
import { tmdbRequest } from './tmdb/gateway';
import * as auth from './auth';

const version = '/api/v1';

async function limit(limiter: RateLimit, key: string): Promise<void> {
  const { success } = await limiter.limit({ key });
  if (!success) {
    throw new ApiError(429, 'rate_limited', 'Too many requests; slow down.', { 'Retry-After': '60' });
  }
}

async function route(request: Request, env: Env, requestId: string): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';

  if (path === '/health' && method === 'GET') {
    return json({ ok: true, environment: env.ENVIRONMENT }, requestId);
  }
  if (!path.startsWith(`${version}/`)) {
    throw new ApiError(404, 'not_found', 'Not found.');
  }
  const rest = path.slice(version.length);

  if (rest.startsWith('/tmdb/')) {
    if (method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Use GET.', { Allow: 'GET' });
    await limit(env.TMDB_IP_LIMITER, ip);
    const principal = await authenticate(env, request);
    await limit(env.TMDB_USER_LIMITER, principal.userId);
    const result = await tmdbRequest(env, rest.slice('/tmdb'.length), url.searchParams);
    return new Response(result.body, {
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'private, no-store',
        'X-Content-Type-Options': 'nosniff',
        'X-Request-Id': requestId,
        'X-Cache': result.cacheStatus,
      },
    });
  }

  const post = (expected: string) => rest === expected && method === 'POST';
  if (post('/auth/device/start')) {
    await limit(env.AUTH_LIMITER, `start:${ip}`);
    return auth.startDevice(env, request, requestId);
  }
  if (post('/auth/device/poll')) {
    await limit(env.AUTH_LIMITER, `poll:${ip}`);
    return auth.pollDevice(env, request, requestId);
  }
  if (post('/auth/refresh')) {
    await limit(env.AUTH_LIMITER, `refresh:${ip}`);
    return auth.refresh(env, request, requestId);
  }

  // Everything below acts on the signed-in account.
  const principal = await authenticate(env, request);
  if (post('/auth/logout')) return auth.logout(env, principal, requestId);
  if (post('/auth/logout-all')) return auth.logoutAll(env, principal, requestId);
  if (rest === '/me' && method === 'GET') return auth.me(env, principal, requestId);
  if (rest === '/me' && method === 'DELETE') return auth.deleteAccount(env, principal, requestId);
  if (rest === '/sessions' && method === 'GET') return auth.listSessions(env, principal, requestId);
  const session = /^\/sessions\/([0-9a-f-]{36})$/.exec(rest);
  if (session && method === 'DELETE') return auth.deleteSession(env, principal, session[1], requestId);
  throw new ApiError(404, 'not_found', 'Not found.');
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const requestId = requestIdFor(request);
    const started = Date.now();
    let response: Response;
    try {
      assertConfigured(env);
      response = await route(request, env, requestId);
    } catch (error) {
      if (error instanceof ApiError) {
        response = errorResponse(error, requestId);
      } else {
        log('error', 'request.failed', {
          requestId,
          message: error instanceof ConfigError ? error.message : String(error),
        });
        response = errorResponse(new ApiError(500, 'internal', 'Something went wrong.'), requestId);
      }
    }
    // Path only: query strings can carry search terms.
    log('info', 'request', {
      requestId,
      method: request.method,
      path: new URL(request.url).pathname,
      status: response.status,
      ms: Date.now() - started,
    });
    return response;
  },
} satisfies ExportedHandler<Env>;
