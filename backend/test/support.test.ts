import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { dailyReportLimit, pruneSupportReports, reportRetentionSeconds, reporterHash } from '../src/support';

type ErrorBody = { error: { code: string } };
const codeOf = async (response: Response) => ((await response.json()) as ErrorBody).error.code;

const bug = (overrides: Record<string, unknown> = {}) => ({
  kind: 'bug',
  category: 'playback',
  platform: 'android_tv',
  title: 'Video stays black',
  description: 'Audio plays but the picture stays black on episode 2.',
  steps: '1. Open a series\n2. Play episode 2',
  diagnostics: { appVersion: '1.27.0', build: '1027000', os: 'android', secretToken: 'leak' },
  ...overrides,
});

const send = (token: string | undefined, body: unknown) =>
  call('/api/v1/support/reports', { method: 'POST', token, body });

describe('Support reports', () => {
  it('stores a valid report without the account id or unexpected fields', async () => {
    const { session, user } = await signIn();
    const userId = user.id;
    const response = await send(session.accessToken, bug());
    expect(response.status).toBe(201);
    const { id } = (await response.json()) as { id: string };
    const row = await testEnv.DB.prepare(`SELECT * FROM support_reports WHERE id = ?`)
      .bind(id).first<Record<string, string>>();
    expect(row).toMatchObject({
      kind: 'bug',
      category: 'playback',
      platform: 'android_tv',
      title: 'Video stays black',
      steps: '1. Open a series\n2. Play episode 2',
    });
    expect(row!.reporter_hash).toBe(await reporterHash(userId));
    expect(JSON.stringify(row)).not.toContain(userId);
    // Only the known diagnostic keys are kept.
    expect(JSON.parse(row!.diagnostics)).toEqual({ appVersion: '1.27.0', build: '1027000', os: 'android' });
  });

  it('requires a signed-in account', async () => {
    expect((await send(undefined, bug())).status).toBe(401);
  });

  it('rejects incomplete or unknown reports', async () => {
    const { session } = await signIn();
    for (const body of [
      bug({ kind: 'spam' }),
      bug({ category: 'feature_request' }),
      bug({ title: '   ' }),
      bug({ description: 'short' }),
    ]) {
      const response = await send(session.accessToken, body);
      expect(response.status).toBe(400);
      expect(await codeOf(response)).toBe('invalid_report');
    }
    const feedback = await send(session.accessToken, bug({
      kind: 'feedback',
      category: 'feature_request',
      steps: 'ignored for feedback',
      description: 'A queue for what to watch next would help.',
    }));
    expect(feedback.status).toBe(201);
  });

  it('a repeated report returns the first instead of storing it twice', async () => {
    const { session } = await signIn();
    const first = (await (await send(session.accessToken, bug())).json()) as { id: string };
    const again = await send(session.accessToken, bug());
    expect(again.status).toBe(200);
    expect(((await again.json()) as { id: string; duplicate: boolean })).toMatchObject({
      id: first.id,
      duplicate: true,
    });
  });

  it(`allows ${dailyReportLimit} reports a day per account`, async () => {
    const { session } = await signIn();
    for (let n = 0; n < dailyReportLimit; n++) {
      const response = await send(session.accessToken, bug({ title: `Report ${n}` }));
      expect(response.status).toBe(201);
    }
    const over = await send(session.accessToken, bug({ title: 'One too many' }));
    expect(over.status).toBe(429);
    expect(await codeOf(over)).toBe('report_limit');
  });

  it('bodies over 16 KB are refused', async () => {
    const { session } = await signIn();
    const response = await send(session.accessToken, bug({ description: 'x'.repeat(20 * 1024) }));
    expect(response.status).toBe(413);
  });

  it('reports go with the account, and expire after 180 days', async () => {
    const { session, user } = await signIn();
    const userId = user.id;
    await send(session.accessToken, bug({ title: 'Mine' }));
    const hash = await reporterHash(userId);
    const count = async () => (await testEnv.DB.prepare(
      `SELECT COUNT(*) AS n FROM support_reports WHERE reporter_hash = ?`,
    ).bind(hash).first<{ n: number }>())!.n;
    expect(await count()).toBe(1);

    await testEnv.DB.prepare(`UPDATE support_reports SET created_at = ? WHERE reporter_hash = ?`)
      .bind(Math.floor(Date.now() / 1000) - reportRetentionSeconds - 60, hash).run();
    expect(await pruneSupportReports(testEnv)).toBeGreaterThanOrEqual(1);
    expect(await count()).toBe(0);

    await send(session.accessToken, bug({ title: 'Another' }));
    expect(await count()).toBe(1);
    await call('/api/v1/me', { method: 'DELETE', token: session.accessToken });
    expect(await count()).toBe(0);
  });
});
