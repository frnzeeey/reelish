// Bindings, variables and secrets the Worker runs with.

import type { WatchPartyRoom } from './party-room';

export interface Env {
  DB: D1Database;
  AUTH_LIMITER: RateLimit;
  TMDB_USER_LIMITER: RateLimit;
  TMDB_IP_LIMITER: RateLimit;
  /** Trakt sync calls per user. */
  SYNC_LIMITER: RateLimit;
  /** Watch party creates, code lookups and joins, per user and per IP. */
  PARTY_LIMITER: RateLimit;
  /** One watch party room per code (SQLite-backed Durable Objects). */
  PARTY_ROOMS: DurableObjectNamespace<WatchPartyRoom>;

  ENVIRONMENT: string;
  TRAKT_API_URL: string;
  TMDB_API_URL: string;
  /** Trakt's browser authorization page. */
  TRAKT_AUTHORIZE_URL: string;
  /**
   * This Worker's public HTTPS origin, for the browser sign-in callback
   * (registered as a redirect URI on the Trakt app). Unset turns browser
   * sign-in off; the device code still works.
   */
  PUBLIC_URL?: string;
  /** Most participants a watch party may allow (2–20; default 5). */
  PARTY_MAX_CAPACITY?: string;

  // Secrets (wrangler secret put / .dev.vars).
  /** TMDB API Read Access Token (v4 bearer), sent only to TMDB. */
  TMDB_READ_TOKEN: string;
  TRAKT_CLIENT_ID: string;
  TRAKT_CLIENT_SECRET: string;
  /** 32 random bytes, base64: signs Reelish access tokens. */
  SESSION_SIGNING_KEY: string;
  /** The key before the last rotation, still accepted for verification. */
  SESSION_SIGNING_KEY_PREVIOUS?: string;
  /** 32 random bytes, base64: AES-GCM key for stored Trakt credentials. */
  TOKEN_ENCRYPTION_KEY: string;
}

/** Fails fast, with no secret values in the message, when one is missing. */
export function assertConfigured(env: Env): void {
  const missing = (
    [
      'TMDB_READ_TOKEN',
      'TRAKT_CLIENT_ID',
      'TRAKT_CLIENT_SECRET',
      'SESSION_SIGNING_KEY',
      'TOKEN_ENCRYPTION_KEY',
    ] as const
  ).filter((name) => !env[name]);
  if (missing.length > 0) {
    throw new ConfigError(`Missing secrets: ${missing.join(', ')}`);
  }
}

export class ConfigError extends Error {}
