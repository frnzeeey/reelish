// Help & Support: bug reports and feedback from signed-in app users, kept in
// D1 for the developer to read (docs/backend/operations.md). Every field is
// validated and bounded here; the reporter is stored only as a hash.

import type { Env } from './env';
import { ApiError, json, readJsonBody, shortText } from './http';
import { audit } from './audit';
import { sha256 } from './crypto';
import { requireLiveSession, type Principal } from './sessions';

export const reportRetentionSeconds = 180 * 24 * 60 * 60;
/** Reports one account may send in 24 hours. */
export const dailyReportLimit = 5;
const maxBodyBytes = 16 * 1024;

const kinds = new Set(['bug', 'feedback']);
const categories: Record<string, Set<string>> = {
  bug: new Set([
    'playback', 'sources', 'catalog', 'subtitles', 'trakt', 'watch_party',
    'updates', 'account', 'performance', 'other',
  ]),
  feedback: new Set(['feature_request', 'suggestion', 'question', 'other']),
};
const platforms = new Set(['android_phone', 'android_tv', 'windows', 'other']);
const diagnosticKeys = [
  'appVersion', 'build', 'os', 'osVersion', 'interface', 'locale', 'timestamp',
] as const;

const now = () => Math.floor(Date.now() / 1000);

/** The stored stand-in for an account id. */
export function reporterHash(userId: string): Promise<string> {
  return sha256(`support-reporter:${userId}`);
}

function required(value: unknown, max: number, field: string): string {
  const text = shortText(value, max);
  if (!text) throw new ApiError(400, 'invalid_report', `${field} is required.`);
  return text;
}

/** Keeps line breaks in long text; drops other control characters. */
function longText(value: unknown, max: number): string {
  if (typeof value !== 'string') return '';
  return value
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, '')
    .trim()
    .slice(0, max);
}

/** POST /support/reports */
export async function submitReport(env: Env, principal: Principal, request: Request, requestId: string) {
  await requireLiveSession(env, principal);
  const body = await readJsonBody(request, maxBodyBytes);

  const kind = typeof body.kind === 'string' && kinds.has(body.kind) ? body.kind : null;
  if (!kind) throw new ApiError(400, 'invalid_report', 'Choose a report type.');
  const category = typeof body.category === 'string' && categories[kind].has(body.category)
    ? body.category
    : null;
  if (!category) throw new ApiError(400, 'invalid_report', 'Choose a category.');
  const platform = typeof body.platform === 'string' && platforms.has(body.platform) ? body.platform : 'other';
  const title = required(body.title, 120, 'A title');
  const description = longText(body.description, 4000);
  if (description.length < 10) {
    throw new ApiError(400, 'invalid_report', 'Describe the problem in a sentence or two.');
  }
  const steps = kind === 'bug' ? longText(body.steps, 2000) : '';
  const raw = body.diagnostics && typeof body.diagnostics === 'object' && !Array.isArray(body.diagnostics)
    ? (body.diagnostics as Record<string, unknown>)
    : {};
  // Only the expected keys, as short text: nothing else from the client.
  const diagnostics: Record<string, string> = {};
  for (const key of diagnosticKeys) {
    const value = shortText(raw[key], 100);
    if (value) diagnostics[key] = value;
  }

  const reporter = await reporterHash(principal.userId);
  const since = now() - 24 * 60 * 60;
  // The same report sent twice (a double tap, a retry after a lost answer)
  // returns the first one instead of storing it again.
  const duplicate = await env.DB.prepare(
    `SELECT id, created_at FROM support_reports
     WHERE reporter_hash = ? AND title = ? AND description = ? AND created_at > ?`,
  ).bind(reporter, title, description, now() - 10 * 60).first<{ id: string; created_at: number }>();
  if (duplicate) {
    return json({ id: duplicate.id, createdAt: duplicate.created_at, duplicate: true }, requestId);
  }
  const recent = await env.DB.prepare(
    `SELECT COUNT(*) AS count FROM support_reports WHERE reporter_hash = ? AND created_at > ?`,
  ).bind(reporter, since).first<{ count: number }>();
  if ((recent?.count ?? 0) >= dailyReportLimit) {
    throw new ApiError(429, 'report_limit', 'You have sent several reports today. Try again tomorrow.', {
      'Retry-After': '3600',
    });
  }

  const id = crypto.randomUUID();
  const createdAt = now();
  await env.DB.prepare(
    `INSERT INTO support_reports
       (id, reporter_hash, kind, category, title, description, steps, platform, diagnostics, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(id, reporter, kind, category, title, description, steps, platform,
    JSON.stringify(diagnostics), createdAt).run();
  // The event only: never the report's text.
  await audit(env, 'support.report', { userId: principal.userId, detail: `${kind}:${category}` });
  return json({ id, createdAt }, requestId, 201);
}

/** Deletes reports older than [reportRetentionSeconds]; returns how many. */
export async function pruneSupportReports(env: Env, nowSeconds = now()): Promise<number> {
  const result = await env.DB.prepare(`DELETE FROM support_reports WHERE created_at < ?`)
    .bind(nowSeconds - reportRetentionSeconds).run();
  return result.meta.changes ?? 0;
}

/** Removes everything [userId] reported, when the account is deleted. */
export async function deleteReportsOf(env: Env, userId: string): Promise<void> {
  await env.DB.prepare(`DELETE FROM support_reports WHERE reporter_hash = ?`)
    .bind(await reporterHash(userId)).run();
}
