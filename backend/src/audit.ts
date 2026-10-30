// Security audit trail and structured logs. Never pass tokens, codes or
// secrets here: only ids and short event details.

import type { Env } from './env';

export async function audit(
  env: Env,
  event: string,
  context: { userId?: string; sessionId?: string; detail?: string } = {},
): Promise<void> {
  try {
    await env.DB.prepare(
      `INSERT INTO audit_events (user_id, session_id, event, detail, created_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
      .bind(context.userId ?? null, context.sessionId ?? null, event,
        (context.detail ?? '').slice(0, 200), Math.floor(Date.now() / 1000))
      .run();
  } catch (error) {
    // The audit trail must never take a request down with it.
    log('error', 'audit.write_failed', { event, message: String(error) });
  }
}

/** One JSON line per event, for Workers Logs. */
export function log(
  level: 'info' | 'warn' | 'error',
  event: string,
  fields: Record<string, unknown> = {},
): void {
  const line = JSON.stringify({ level, event, ...fields });
  if (level === 'error') console.error(line);
  else if (level === 'warn') console.warn(line);
  else console.log(line);
}
