// Calls the Worker in-process and fakes Trakt and TMDB at the fetch layer.

import { env } from 'cloudflare:test';
import { vi } from 'vitest';
import worker from '../src/index';
import type { Env } from '../src/env';

export const testEnv = env as unknown as Env;

let ipCounter = 0;
/** A fresh client IP per call site, so edge rate limits stay out of the way. */
export function freshIp(): string {
  ipCounter += 1;
  return `198.51.100.${ipCounter % 250}`;
}

export async function call(
  path: string,
  init: { method?: string; body?: unknown; token?: string; ip?: string; headers?: Record<string, string> } = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    'CF-Connecting-IP': init.ip ?? freshIp(),
    ...init.headers,
  };
  if (init.body !== undefined) headers['Content-Type'] = 'application/json';
  if (init.token) headers.Authorization = `Bearer ${init.token}`;
  return worker.fetch(
    new Request(`https://api.reelish.test${path}`, {
      method: init.method ?? (init.body === undefined ? 'GET' : 'POST'),
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    }),
    testEnv,
  );
}

export type Upstream = (url: URL, init: RequestInit) => Response | Promise<Response>;

/** Routes the Worker's outbound fetches to [handler]; records every call. */
export function fakeUpstream(handler: Upstream) {
  const calls: { url: URL; init: RequestInit }[] = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init = {}) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    calls.push({ url, init });
    return handler(url, init);
  });
  return calls;
}

export const jsonResponse = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });

let accountCounter = 0;

/**
 * Signs a new Trakt account in through the device flow and returns its
 * Reelish session. Trakt is faked; [uuid] is the account's stable id.
 */
export async function signIn(options: { uuid?: string; username?: string; platform?: string } = {}) {
  accountCounter += 1;
  const uuid = options.uuid ?? `uuid-${accountCounter}-${crypto.randomUUID()}`;
  const username = options.username ?? `viewer${accountCounter}`;
  fakeUpstream((url) => {
    if (url.pathname === '/oauth/device/code') {
      return jsonResponse({
        device_code: `device-${accountCounter}`,
        user_code: 'ABCD1234',
        verification_url: 'https://trakt.tv/activate',
        expires_in: 600,
        interval: 1,
      });
    }
    if (url.pathname === '/oauth/device/token') {
      return jsonResponse({
        access_token: `trakt-access-${accountCounter}`,
        refresh_token: `trakt-refresh-${accountCounter}`,
        expires_in: 86400,
        created_at: Math.floor(Date.now() / 1000),
        scope: 'public',
      });
    }
    if (url.pathname === '/users/settings') {
      return jsonResponse({ user: { username, ids: { slug: username, uuid } } });
    }
    return new Response('unexpected', { status: 500 });
  });
  const start = await call('/api/v1/auth/device/start', {
    body: { platform: options.platform ?? 'android', deviceName: 'Pixel' },
  });
  const { pollToken } = (await start.json()) as { pollToken: string };
  // The first poll is allowed once the interval has passed.
  await testEnv.DB.prepare(`UPDATE device_authorizations SET next_poll_at = 0`).run();
  const poll = await call('/api/v1/auth/device/poll', { body: { pollToken } });
  const body = (await poll.json()) as {
    status: string;
    session: { accessToken: string; refreshToken: string; sessionId: string };
    user: { id: string; username: string };
  };
  vi.restoreAllMocks();
  return { ...body, uuid, pollToken };
}
