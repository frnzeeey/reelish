// The Reelish API Worker: routes /api/v1 requests, applies rate limits and
// authentication, and turns every failure into a safe JSON error.

import { assertConfigured, ConfigError, type Env } from './env';
import { ApiError, errorResponse, json, requestIdFor } from './http';
import { log } from './audit';
import { authenticate } from './sessions';
import { tmdbRequest } from './tmdb/gateway';
import * as auth from './auth';
import * as web from './web-auth';
import * as sync from './trakt-sync';
import * as alerts from './episode-alerts';
import * as party from './watch-party';
import { pruneAuditEvents } from './retention';
import * as support from './support';
import * as supporters from './supporters';
import * as frames from './frames';
import * as progress from './progress';
import * as collections from './collections';
import * as discoveryPreferences from './discovery-preferences';
import * as social from './social/profiles';
import * as activity from './social/activity';
import * as friends from './social/friends';
import * as recommendations from './social/recommendations';
import * as sharedCollections from './social/shared-collections';
import { pruneSocial } from './social/retention';

export { WatchPartyRoom } from './party-room';
export { TraktEgress } from './trakt-egress';

const version = '/api/v1';

/**
 * The path as logged: a party code is an invitation, and a handle or an id
 * in a Friends path names a person, so each is replaced by a placeholder.
 */
export function maskPath(path: string): string {
  return path
    .replace(/^(\/api\/v1\/party\/)[^/]+/, '$1:code')
    .replace(/^(\/api\/v1\/social\/(?:friends|requests|blocks)\/)[^/]+/, '$1:handle')
    .replace(/^(\/api\/v1\/social\/friends\/:handle\/collections\/)[^/]+/, '$1:id')
    .replace(/^(\/api\/v1\/social\/recommendations\/)(?!sent$|read$)[^/]+$/, '$1:id');
}

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
  if (post('/auth/web/start')) {
    await limit(env.AUTH_LIMITER, `webstart:${ip}`);
    return web.startWeb(env, request, requestId);
  }
  if (post('/auth/web/poll')) {
    await limit(env.AUTH_LIMITER, `webpoll:${ip}`);
    return web.pollWeb(env, request, requestId);
  }
  if (rest === '/auth/web/callback' && method === 'GET') {
    await limit(env.AUTH_LIMITER, `callback:${ip}`);
    return web.webCallback(env, url);
  }
  if (post('/notifications/episodes')) {
    // Its own narrow token (background checks cannot refresh a session).
    await limit(env.AUTH_LIMITER, `alerts-ip:${ip}`);
    const owner = await alerts.authenticateNotify(env, request);
    await limit(env.SYNC_LIMITER, `alerts:${owner.sessionId}`);
    return alerts.checkEpisodes(env, owner, request, requestId);
  }
  if (post('/webhooks/buymeacoffee')) {
    // Buy Me a Coffee's signed notifications; no session involved.
    await limit(env.AUTH_LIMITER, `bmc:${ip}`);
    return supporters.buyMeACoffeeWebhook(env, request, requestId);
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
  if (rest === '/me/frame' && method === 'PUT') {
    await limit(env.SYNC_LIMITER, `frame:${principal.userId}`);
    return frames.setFrame(env, principal, request, requestId);
  }
  if (rest === '/sessions' && method === 'GET') return auth.listSessions(env, principal, requestId);
  if (post('/notifications/token')) {
    await limit(env.SYNC_LIMITER, principal.userId);
    return alerts.issueToken(env, principal, requestId);
  }
  if (rest === '/trakt/watchlist' && (method === 'GET' || method === 'POST')) {
    await limit(env.SYNC_LIMITER, principal.userId);
    return method === 'GET'
      ? sync.getWatchlist(env, principal, requestId)
      : sync.updateWatchlist(env, principal, request, requestId);
  }
  if (rest === '/progress' && (method === 'GET' || method === 'POST')) {
    await limit(env.SYNC_LIMITER, `progress:${principal.userId}`);
    return method === 'GET'
      ? progress.pullProgress(env, principal, url, requestId)
      : progress.pushProgress(env, principal, request, requestId);
  }
  if (rest === '/discovery/preferences' && (method === 'GET' || method === 'PUT')) {
    await limit(env.SYNC_LIMITER, `discovery:${principal.userId}`);
    return method === 'GET'
      ? discoveryPreferences.getPreferences(env, principal, requestId)
      : discoveryPreferences.putPreferences(env, principal, request, requestId);
  }
  if (rest === '/collections' && (method === 'GET' || method === 'POST')) {
    await limit(env.SYNC_LIMITER, `collections:${principal.userId}`);
    return method === 'GET'
      ? collections.pullCollections(env, principal, url, requestId)
      : collections.pushCollections(env, principal, request, requestId);
  }
  if (rest.startsWith('/social/')) {
    await limit(env.SOCIAL_LIMITER, `social:${principal.userId}`);
    if (rest === '/social/profile') {
      if (method === 'GET') return social.getProfile(env, principal, requestId);
      if (method === 'PUT') {
        // Claiming a handle answers whether it is taken: limited more tightly.
        await limit(env.SOCIAL_LOOKUP_LIMITER, `claim:${principal.userId}`);
        await limit(env.SOCIAL_LOOKUP_LIMITER, `claim-ip:${ip}`);
        return social.putProfile(env, principal, request, requestId);
      }
      if (method === 'DELETE') return social.deleteProfile(env, principal, requestId);
    }
    if (post('/social/profile/code')) {
      await limit(env.SOCIAL_LOOKUP_LIMITER, `code:${principal.userId}`);
      return social.resetFriendCode(env, principal, requestId);
    }
    if (post('/social/requests')) {
      // Finding someone by code or handle: limited so neither can be guessed.
      await limit(env.SOCIAL_LOOKUP_LIMITER, `find:${principal.userId}`);
      await limit(env.SOCIAL_LOOKUP_LIMITER, `find-ip:${ip}`);
      return friends.sendRequest(env, principal, request, requestId);
    }
    const requestRoute = /^\/social\/requests\/([^/]+)(\/accept|\/decline)?$/.exec(rest);
    if (requestRoute) {
      const handle = requestRoute[1];
      if (method === 'POST' && requestRoute[2] === '/accept') {
        return friends.acceptRequest(env, principal, handle, requestId);
      }
      if (method === 'POST' && requestRoute[2] === '/decline') {
        return friends.declineRequest(env, principal, handle, requestId);
      }
      if (method === 'DELETE' && !requestRoute[2]) return friends.cancelRequest(env, principal, handle, requestId);
    }
    if (rest === '/social/friends' && method === 'GET') return friends.listFriends(env, principal, url, requestId);
    const sharedRoute = /^\/social\/friends\/([^/]+)\/collections\/([^/]+)$/.exec(rest);
    if (sharedRoute && method === 'GET') {
      return sharedCollections.friendCollection(env, principal, sharedRoute[1], sharedRoute[2], url, requestId);
    }
    const friendRoute = /^\/social\/friends\/([^/]+)$/.exec(rest);
    if (friendRoute) {
      const handle = friendRoute[1];
      if (method === 'GET') return friends.getFriend(env, principal, handle, requestId);
      if (method === 'DELETE') return friends.removeFriend(env, principal, handle, requestId);
    }
    if (rest === '/social/blocks') {
      if (method === 'GET') return friends.listBlocks(env, principal, requestId);
      if (method === 'POST') return friends.block(env, principal, request, requestId);
    }
    const blockRoute = /^\/social\/blocks\/([^/]+)$/.exec(rest);
    if (blockRoute && method === 'DELETE') {
      return friends.unblock(env, principal, blockRoute[1], requestId);
    }
    if (post('/social/reports')) return friends.reportPerson(env, principal, request, requestId);
    if (rest === '/social/activity') {
      if (method === 'GET') return activity.friendsWatching(env, principal, requestId);
      if (method === 'PUT') return activity.publish(env, principal, request, requestId);
      if (method === 'DELETE') return activity.clear(env, principal, requestId);
    }
    if (rest === '/social/recommendations') {
      if (method === 'GET') return recommendations.inbox(env, principal, url, requestId);
      if (method === 'POST') return recommendations.sendRecommendation(env, principal, request, requestId);
    }
    if (rest === '/social/recommendations/sent' && method === 'GET') {
      return recommendations.sent(env, principal, requestId);
    }
    if (post('/social/recommendations/read')) return recommendations.markRead(env, principal, request, requestId);
    const recommendationRoute = /^\/social\/recommendations\/([^/]+)$/.exec(rest);
    if (recommendationRoute && method === 'DELETE') {
      return recommendations.removeRecommendation(env, principal, recommendationRoute[1], requestId);
    }
  }
  if (rest.startsWith('/supporters/')) {
    await limit(env.SYNC_LIMITER, `supporters:${principal.userId}`);
    if (rest === '/supporters/me' && method === 'GET') {
      return supporters.getStatus(env, principal, requestId);
    }
    if (post('/supporters/claim')) return supporters.requestReview(env, principal, requestId);
    if (rest === '/supporters/recognition' && method === 'PUT') {
      return supporters.setRecognition(env, principal, request, requestId);
    }
    if (rest === '/supporters/public' && method === 'GET') {
      return supporters.publicList(env, requestId);
    }
  }
  if (post('/support/reports')) {
    await limit(env.SYNC_LIMITER, `support:${principal.userId}`);
    return support.submitReport(env, principal, request, requestId);
  }
  if (post('/party')) {
    await limit(env.PARTY_LIMITER, `create:${principal.userId}`);
    return party.createParty(env, principal, request, requestId);
  }
  const partyRoute = /^\/party\/([^/]+)(\/socket)?$/.exec(rest);
  if (partyRoute && method === 'GET') {
    // Lookups are limited per account and per address, so codes cannot be
    // enumerated; a malformed code is answered like an unknown one.
    await limit(env.PARTY_LIMITER, `lookup:${principal.userId}`);
    await limit(env.PARTY_LIMITER, `lookup-ip:${ip}`);
    const code = partyRoute[1];
    if (!party.codePattern.test(code)) {
      throw new ApiError(404, 'party_not_found', 'No party has that code. Check it and try again.');
    }
    return partyRoute[2]
      ? party.connectParty(env, principal, request, code)
      : party.previewParty(env, code, requestId);
  }
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
      // workers.dev also answers plain HTTP. Nothing is processed over it,
      // so a token sent there by mistake never works; no redirect either,
      // so the client sees the failure instead of retrying silently.
      if (new URL(request.url).protocol !== 'https:') {
        throw new ApiError(403, 'https_required', 'Use HTTPS.');
      }
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
    // Path only: query strings can carry search terms. A party code is an
    // invitation, so it is masked too.
    log('info', 'request', {
      requestId,
      method: request.method,
      path: maskPath(new URL(request.url).pathname),
      status: response.status,
      ms: Date.now() - started,
    });
    return response;
  },

  /** The daily cron in wrangler.toml: erases expired security log rows, stale progress, old collection deletion marks and expired social rows. */
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      Promise.all([
        pruneAuditEvents(env),
        support.pruneSupportReports(env),
        progress.pruneProgress(env),
        collections.pruneCollections(env),
        pruneSocial(env),
      ]).then(() => undefined),
    );
  },
} satisfies ExportedHandler<Env>;
