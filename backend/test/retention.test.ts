import { describe, expect, it } from 'vitest';
import { testEnv } from './helpers';
import { auditRetentionSeconds, pruneAuditEvents } from '../src/retention';

describe('Security log retention', () => {
  it('erases events older than the retention period and keeps the rest', async () => {
    const now = 2_000_000_000;
    const insert = (event: string, createdAt: number) =>
      testEnv.DB.prepare(
        `INSERT INTO audit_events (user_id, session_id, event, detail, created_at) VALUES (?, ?, ?, '', ?)`,
      ).bind('u-retention', null, event, createdAt).run();
    await insert('old', now - auditRetentionSeconds - 60);
    await insert('edge', now - auditRetentionSeconds + 60);
    await insert('recent', now - 60);

    expect(await pruneAuditEvents(testEnv, now)).toBe(1);
    const left = await testEnv.DB.prepare(
      `SELECT event FROM audit_events WHERE user_id = 'u-retention' ORDER BY created_at`,
    ).all<{ event: string }>();
    expect(left.results.map((row) => row.event)).toEqual(['edge', 'recent']);
    expect(await pruneAuditEvents(testEnv, now)).toBe(0);
  });
});
