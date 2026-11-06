import { beforeEach, describe, expect, it } from 'vitest';
import { call, freshIp, signIn, testEnv } from './helpers';
import worker from '../src/index';
import { findSupportCode, newSupportCode } from '../src/supporters';

const secret = 'test-bmc-secret';
const hook = '/api/v1/webhooks/buymeacoffee';

async function sign(body: string, key = secret): Promise<string> {
  const imported = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(key),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', imported, new TextEncoder().encode(body));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

let payment = 1000;

const payload = (data: Record<string, unknown>, type = 'donation.created', live = true) =>
  JSON.stringify({
    event_id: 1234,
    type,
    live_mode: live,
    created: 1719825600,
    attempt: 1,
    data: {
      id: ++payment,
      object: 'payment',
      status: 'succeeded',
      refunded: 'false',
      amount: 5,
      currency: 'USD',
      supporter_name: 'Alex',
      supporter_id: 42,
      supporter_email: 'alex@example.com',
      transaction_id: `pi_${payment}`,
      created_at: 1719825600,
      ...data,
    },
  });

/** Posts the exact bytes, as Buy Me a Coffee does. */
const post = (body: string, headers: Record<string, string>, env = testEnv) =>
  worker.fetch(
    new Request(`https://api.reelish.test${hook}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': freshIp(), ...headers },
      body,
    }),
    env,
  );

async function deliver(body: string, signature?: string): Promise<Response> {
  return post(body, { 'x-signature-sha256': signature ?? (await sign(body)) });
}

const status = async (token: string) => {
  const response = await call('/api/v1/supporters/me', { token });
  expect(response.status).toBe(200);
  return (await response.json()) as {
    code: string;
    status: string;
    since: number | null;
    recognition: { listed: boolean; name: string };
  };
};

const counts = async () => ({
  donations: (await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM donations`).first<{ n: number }>())!.n,
  supporters: (
    await testEnv.DB.prepare(
      `SELECT COUNT(*) AS n FROM supporter_profiles WHERE supporter_since IS NOT NULL`,
    ).first<{ n: number }>()
  )!.n,
});

// The database is shared by the tests in a file.
beforeEach(async () => {
  await testEnv.DB.batch([
    testEnv.DB.prepare('DELETE FROM donations'),
    testEnv.DB.prepare('DELETE FROM supporter_profiles'),
  ]);
});

describe('Supporter codes', () => {
  it('are opaque, and found however they were typed', () => {
    const code = newSupportCode();
    expect(code).toMatch(/^RS-[2-9A-HJKMNP-TV-Z]{4}-[2-9A-HJKMNP-TV-Z]{4}$/);
    expect(findSupportCode(`Thanks! ${code}`)).toBe(code);
    expect(findSupportCode(code.toLowerCase())).toBe(code);
    expect(findSupportCode(code.replace(/-/g, ' '))).toBe(code);
    expect(findSupportCode('Keep up the great work!')).toBeNull();
    expect(findSupportCode(undefined)).toBeNull();
  });
});

describe('Supporter status', () => {
  it('starts empty, with a stable code, for someone who never donated', async () => {
    const { session } = await signIn();
    const first = await status(session.accessToken);
    expect(first.status).toBe('none');
    expect(first.since).toBeNull();
    expect((await status(session.accessToken)).code).toBe(first.code);
  });

  it('needs a signed-in account', async () => {
    expect((await call('/api/v1/supporters/me')).status).toBe(401);
    expect((await call('/api/v1/supporters/public')).status).toBe(401);
  });
});

describe('The webhook', () => {
  it('grants the badge for a donation naming a code, on every device', async () => {
    const first = await signIn({ uuid: 'same-account' });
    const { code } = await status(first.session.accessToken);
    const response = await deliver(payload({ support_note: `Love the app ${code}` }));
    expect(response.status).toBe(200);
    expect((await status(first.session.accessToken)).status).toBe('verified');
    // Another device signs in to the same account.
    const second = await signIn({ uuid: 'same-account' });
    const other = await status(second.session.accessToken);
    expect(other.status).toBe('verified');
    expect(other.since).toBe(1719825600);
  });

  it('stores nothing about the donor', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: `A private message ${code}` }));
    const { results } = await testEnv.DB.prepare(`SELECT * FROM donations`).all();
    const stored = JSON.stringify(results);
    for (const secretValue of ['alex@example.com', 'Alex', 'private message', 'pi_', code]) {
      expect(stored).not.toContain(secretValue);
    }
    expect(Object.keys(results[0])).not.toContain('amount');
  });

  it('a repeated delivery changes nothing', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    const body = payload({ support_note: code });
    await deliver(body);
    const before = await counts();
    const since = (await status(session.accessToken)).since;
    for (let i = 0; i < 3; i++) expect((await deliver(body)).status).toBe(200);
    expect(await counts()).toEqual(before);
    expect((await status(session.accessToken)).since).toBe(since);
  });

  it('another donation keeps one badge and the first date', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: code, created_at: 1000000 }));
    await deliver(payload({ support_note: code, created_at: 2000000 }));
    expect((await status(session.accessToken)).since).toBe(1000000);
    expect((await counts()).supporters).toBe(1);
  });

  it('refuses a forged or unsigned request', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    const body = payload({ support_note: code });
    expect((await deliver(body, await sign(body, 'wrong-secret'))).status).toBe(401);
    expect((await deliver(body, 'not-hex')).status).toBe(401);
    expect((await post(body, {})).status).toBe(401);
    // A signature for other content does not carry over.
    expect((await deliver(body, await sign(`${body} `))).status).toBe(401);
    expect((await status(session.accessToken)).status).toBe('none');
    expect((await counts()).donations).toBe(0);
  });

  it('a session cannot grant a badge by calling the webhook', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    const response = await call(hook, {
      method: 'POST',
      token: session.accessToken,
      body: { type: 'donation.created', live_mode: true, data: { id: 1, support_note: code } },
    });
    expect(response.status).toBe(401);
    expect((await status(session.accessToken)).status).toBe('none');
  });

  it('dashboard test events never make a supporter', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    const response = await deliver(payload({ support_note: code }, 'donation.created', false));
    expect(response.status).toBe(200);
    expect((await status(session.accessToken)).status).toBe('none');
    expect((await counts()).donations).toBe(0);
  });

  it('a donation that did not succeed earns nothing', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: code, status: 'refunded' }));
    await deliver(payload({ support_note: code, refunded: 'true' }));
    expect((await status(session.accessToken)).status).toBe('none');
  });

  it('an unknown code or no code keeps the donation without an account', async () => {
    const { session } = await signIn();
    await deliver(payload({ support_note: 'RS-AAAA-AAAA' }));
    await deliver(payload({ support_note: 'Great app' }));
    expect((await status(session.accessToken)).status).toBe('none');
    expect(await counts()).toMatchObject({ donations: 2, supporters: 0 });
  });

  it('monthly support and memberships qualify, and cancelling keeps the badge', async () => {
    const monthly = await signIn();
    const member = await signIn();
    const monthlyCode = (await status(monthly.session.accessToken)).code;
    const memberCode = (await status(member.session.accessToken)).code;
    await deliver(payload({ support_note: monthlyCode, started_at: 1719825600 }, 'recurring_donation.started'));
    await deliver(payload({ support_note: memberCode }, 'membership.started'));
    await deliver(payload({ support_note: monthlyCode }, 'recurring_donation.cancelled'));
    expect((await status(monthly.session.accessToken)).status).toBe('verified');
    expect((await status(member.session.accessToken)).status).toBe('verified');
  });

  it('a shop purchase is not a donation', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: code }, 'extra_purchase.created'));
    expect((await status(session.accessToken)).status).toBe('none');
  });

  it('a refund removes the badge unless another donation stands', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: code, id: 501 }));
    await deliver(payload({ support_note: code, id: 502 }));
    await deliver(payload({ id: 501, status: 'refunded', refunded: 'true' }, 'donation.refunded'));
    expect((await status(session.accessToken)).status).toBe('verified');
    await deliver(payload({ id: 502, status: 'refunded', refunded: 'true' }, 'donation.refunded'));
    const after = await status(session.accessToken);
    expect(after.status).toBe('none');
    expect(after.recognition.listed).toBe(false);
  });

  it('a refund arriving before its donation still wins', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ id: 601, refunded: 'true' }, 'donation.refunded'));
    await deliver(payload({ id: 601, support_note: code }));
    expect((await status(session.accessToken)).status).toBe('none');
  });

  it('fails closed when no secret is configured', async () => {
    const body = payload({});
    const response = await post(
      body,
      { 'x-signature-sha256': await sign(body) },
      { ...testEnv, BMC_WEBHOOK_SECRET: undefined },
    );
    expect(response.status).toBe(503);
  });
});

describe('Asking for a review', () => {
  it('shows pending, and a claim alone never grants the badge', async () => {
    const { session } = await signIn();
    const response = await call('/api/v1/supporters/claim', {
      method: 'POST',
      token: session.accessToken,
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { status: string; since: number | null };
    expect(body.status).toBe('pending');
    expect(body.since).toBeNull();
    expect((await counts()).supporters).toBe(0);
  });

  it('ends when a donation with the code arrives', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await call('/api/v1/supporters/claim', { method: 'POST', token: session.accessToken });
    await deliver(payload({ support_note: code }));
    expect((await status(session.accessToken)).status).toBe('verified');
  });
});

describe('Public recognition', () => {
  const recognize = (token: string, body: unknown) =>
    call('/api/v1/supporters/recognition', { method: 'PUT', token, body });
  const list = async (token: string) =>
    ((await (await call('/api/v1/supporters/public', { token })).json()) as {
      supporters: { name: string; since: string }[];
    }).supporters;

  it('is off by default, and anonymous supporters keep the badge', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: code }));
    expect((await status(session.accessToken)).status).toBe('verified');
    expect(await list(session.accessToken)).toEqual([]);
  });

  it('shows only the chosen name and a month', async () => {
    const { session, user } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: code, created_at: 1719825600 }));
    expect((await recognize(session.accessToken, { listed: true, name: 'Sam' })).status).toBe(200);
    const shown = await list(session.accessToken);
    expect(shown).toEqual([{ name: 'Sam', since: '2024-07' }]);
    const text = JSON.stringify(shown);
    expect(text).not.toContain(user.id);
    expect(text).not.toContain(code);
    expect((await recognize(session.accessToken, { listed: false })).status).toBe(200);
    expect(await list(session.accessToken)).toEqual([]);
    expect((await status(session.accessToken)).status).toBe('verified');
  });

  it('is only for supporters, and refuses links in names', async () => {
    const { session } = await signIn();
    expect((await recognize(session.accessToken, { listed: true, name: 'Sam' })).status).toBe(409);
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: code }));
    const link = await recognize(session.accessToken, { listed: true, name: 'https://spam.example' });
    expect(link.status).toBe(400);
  });
});

describe('Account deletion', () => {
  it('removes the supporter record and keeps no link to the donation', async () => {
    const { session } = await signIn();
    const { code } = await status(session.accessToken);
    await deliver(payload({ support_note: code }));
    await call('/api/v1/me', { method: 'DELETE', token: session.accessToken });
    expect((await counts()).supporters).toBe(0);
    const row = await testEnv.DB.prepare(`SELECT user_id FROM donations`).first<{ user_id: string | null }>();
    expect(row?.user_id).toBeNull();
  });
});
