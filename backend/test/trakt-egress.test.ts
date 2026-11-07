import { afterEach, describe, expect, it, vi } from 'vitest';
import { testEnv } from './helpers';
import {
  egressRegions,
  exchangeAuthorizationCode,
  startDeviceCode,
  type EgressRegion,
} from '../src/trakt';
import { ApiError } from '../src/http';

const refused = () =>
  new Response('error code: 1015\n', {
    status: 429,
    headers: { 'Content-Type': 'text/plain', 'Retry-After': '120', Server: 'cloudflare' },
  });

const deviceCode = () =>
  new Response(
    JSON.stringify({
      device_code: 'device',
      user_code: 'ABCD1234',
      verification_url: 'https://trakt.tv/activate',
      expires_in: 600,
      interval: 5,
    }),
    { status: 200 },
  );

const tokens = () =>
  new Response(
    JSON.stringify({
      access_token: 'access',
      refresh_token: 'refresh',
      expires_in: 86400,
      created_at: 1,
      scope: 'public',
    }),
    { status: 200 },
  );

/** Regions in the order they were tried, answering with [answers]. */
function regions(answers: Partial<Record<EgressRegion, () => Response>>) {
  const tried: EgressRegion[] = [];
  const bodies: (string | undefined)[] = [];
  const egress = async (region: EgressRegion, _url: string, init: RequestInit) => {
    tried.push(region);
    bodies.push(init.body as string | undefined);
    const answer = answers[region];
    if (!answer) throw new Error('unreachable');
    return answer();
  };
  return { tried, bodies, egress };
}

afterEach(() => vi.restoreAllMocks());

describe('When Trakt refuses this region', () => {
  it('leaves a healthy region alone', async () => {
    const route = regions({ enam: deviceCode });
    const code = await startDeviceCode(testEnv, {
      fetch: async () => deviceCode(),
      egress: route.egress,
    });
    expect(code.user_code).toBe('ABCD1234');
    expect(route.tried).toEqual([]);
  });

  it('retries from another region, unchanged', async () => {
    const route = regions({ enam: deviceCode });
    const code = await startDeviceCode(testEnv, {
      fetch: async () => refused(),
      egress: route.egress,
    });
    expect(code.user_code).toBe('ABCD1234');
    expect(route.tried).toEqual(['enam']);
    expect(route.bodies[0]).toContain(testEnv.TRAKT_CLIENT_ID);
  });

  it('moves on from a region that is refused too, or unreachable', async () => {
    const route = regions({ enam: refused, oc: deviceCode });
    await startDeviceCode(testEnv, { fetch: async () => refused(), egress: route.egress });
    expect(route.tried).toEqual(['enam', 'weur', 'oc']);
  });

  it('finishes a browser sign-in, which needs the client secret', async () => {
    const route = regions({ enam: tokens });
    const result = await exchangeAuthorizationCode(testEnv, 'code', 'https://x.test/cb', 'verifier', {
      fetch: async () => refused(),
      egress: route.egress,
    });
    expect(result?.access_token).toBe('access');
  });

  it('reports a failure when every region is refused', async () => {
    const route = regions({ enam: refused, weur: refused, oc: refused });
    await expect(
      startDeviceCode(testEnv, { fetch: async () => refused(), egress: route.egress }),
    ).rejects.toMatchObject({ code: 'trakt_unavailable' });
    expect(route.tried).toEqual([...egressRegions]);
  });

  it('leaves Trakt\'s own rate limit to its usual handling', async () => {
    const route = regions({ enam: deviceCode });
    const waits: number[] = [];
    const answers = [
      new Response('{}', { status: 429, headers: { 'Retry-After': '1' } }),
      deviceCode(),
    ];
    await startDeviceCode(testEnv, {
      fetch: async () => answers.shift()!,
      wait: async (ms) => void waits.push(ms),
      egress: route.egress,
    });
    expect(waits).toEqual([1000]);
    expect(route.tried).toEqual([]);
  });

  it('does not retry an answer from Trakt itself', async () => {
    const route = regions({ enam: deviceCode });
    await expect(
      startDeviceCode(testEnv, {
        fetch: async () => new Response('nope', { status: 500 }),
        egress: route.egress,
      }),
    ).rejects.toBeInstanceOf(ApiError);
    expect(route.tried).toEqual([]);
  });
});

describe('The egress object', () => {
  const stub = () => testEnv.TRAKT_EGRESS.get(testEnv.TRAKT_EGRESS.idFromName('test'));

  it('only ever reaches Trakt, so its secrets cannot go anywhere else', async () => {
    const outbound = vi.spyOn(globalThis, 'fetch');
    const elsewhere = await stub().fetch('https://evil.example/oauth/token', { method: 'POST' });
    const lookalike = await stub().fetch('https://api.trakt.tv.evil.example/oauth/token');
    const insecure = await stub().fetch('http://api.trakt.tv/oauth/token');
    expect([elsewhere.status, lookalike.status, insecure.status]).toEqual([400, 400, 400]);
    expect(outbound).not.toHaveBeenCalled();
  });
});
