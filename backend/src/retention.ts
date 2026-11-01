// Scheduled cleanup: the security log is kept for a fixed period (the
// privacy policy says 12 months), then erased.

import type { Env } from './env';
import { log } from './audit';

export const auditRetentionSeconds = 365 * 24 * 60 * 60;
const batchSize = 5000;
const maxBatches = 20;

/** Deletes audit events older than [auditRetentionSeconds]; returns how many. */
export async function pruneAuditEvents(env: Env, nowSeconds = Math.floor(Date.now() / 1000)): Promise<number> {
  const cutoff = nowSeconds - auditRetentionSeconds;
  let deleted = 0;
  // Small batches keep each statement short; the next run takes the rest.
  for (let batch = 0; batch < maxBatches; batch++) {
    const result = await env.DB.prepare(
      `DELETE FROM audit_events WHERE id IN
         (SELECT id FROM audit_events WHERE created_at < ? LIMIT ?)`,
    ).bind(cutoff, batchSize).run();
    const changes = result.meta.changes ?? 0;
    deleted += changes;
    if (changes < batchSize) break;
  }
  log('info', 'retention.audit_pruned', { deleted });
  return deleted;
}
