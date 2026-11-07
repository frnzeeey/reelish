// Sends a request to Trakt from another Cloudflare region. Trakt sits behind a
// Cloudflare rate limit that all Workers in a region appear to share, so a busy
// region can refuse every Trakt call (error 1015). A Durable Object stays where
// it was created, which gives a way to leave that region when it happens.

import { DurableObject } from 'cloudflare:workers';
import type { Env } from './env';

export class TraktEgress extends DurableObject<Env> {
  override async fetch(request: Request): Promise<Response> {
    // Only ever Trakt: the secrets this carries must not go anywhere else.
    const allowed = new URL(this.env.TRAKT_API_URL);
    const target = new URL(request.url);
    if (target.protocol !== 'https:' || target.hostname !== allowed.hostname) {
      return new Response('Not allowed.', { status: 400 });
    }
    return fetch(request);
  }
}
