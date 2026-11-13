// A friend's shared collections: read straight from collection_records, the
// rows the owner's devices sync. Only a collection whose visibility is
// "friends" (and is not deleted) is listed, and its titles are read only
// through it, so a title has no visibility of its own to leak. Every read
// checks the friendship at that moment.
// docs/friends-activity/TECHNICAL_ARCHITECTURE.md, Collections integration.

import type { Env } from '../env';
import { ApiError, json } from '../http';
import { requireLiveSession, type Principal } from '../sessions';
import { handleFrom } from './friends';
import { requireProfile, type ProfileRow } from './profiles';
import { relationship } from './relationship';

/** Shared collections listed on a friend's page. */
export const maxSharedListed = 100;
/** Titles per page of a shared collection. */
export const titlesPageSize = 200;

const idPattern = /^[0-9a-f]{24}$/;
const titleKeyPattern = /^(movie|series):[1-9]\d{0,9}$/;
const notFound = () => new ApiError(404, 'not_found', 'Not found.');

function fields(body: string): Record<string, unknown> {
  try {
    const value = JSON.parse(body) as unknown;
    return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

const textOf = (value: unknown) => (typeof value === 'string' ? value : null);

/** The friend named by [handle], or 404 for anyone who is not a friend now. */
async function friendByHandle(env: Env, me: string, handle: string): Promise<ProfileRow> {
  const other = await env.DB.prepare(`SELECT * FROM social_profiles WHERE handle_key = ?`)
    .bind(handleFrom(handle)).first<ProfileRow>();
  if (!other || (await relationship(env, me, other.user_id)) !== 'friend') throw notFound();
  return other;
}

interface CollectionRow {
  record_key: string;
  body: string;
}

/**
 * [ownerId]'s shared collections with their title counts and up to four
 * posters each (the chosen cover first, then the newest titles').
 */
export async function sharedCollectionsOf(env: Env, ownerId: string) {
  const { results } = await env.DB.prepare(
    `SELECT record_key, body FROM collection_records
      WHERE user_id = ? AND kind = 'collection' AND visibility = 'friends' AND deleted = 0
      LIMIT ${maxSharedListed}`,
  ).bind(ownerId).all<CollectionRow>();
  if (results.length === 0) return [];
  const ids = results.map((row) => row.record_key);
  const placeholders = ids.map((_, index) => `?${index + 2}`).join(', ');
  const [counts, posters] = await env.DB.batch([
    env.DB.prepare(
      `SELECT substr(record_key, 1, 24) AS id, COUNT(*) AS n FROM collection_records
        WHERE user_id = ?1 AND kind = 'entry' AND deleted = 0 AND substr(record_key, 1, 24) IN (${placeholders})
        GROUP BY id`,
    ).bind(ownerId, ...ids),
    env.DB.prepare(
      `SELECT id, title, poster FROM (
         SELECT substr(record_key, 1, 24) AS id, substr(record_key, 26) AS title,
                json_extract(body, '$.poster') AS poster,
                ROW_NUMBER() OVER (PARTITION BY substr(record_key, 1, 24)
                                   ORDER BY json_extract(body, '$.addedAt') DESC, record_key) AS rank
           FROM collection_records
          WHERE user_id = ?1 AND kind = 'entry' AND deleted = 0
            AND substr(record_key, 1, 24) IN (${placeholders})
            AND json_extract(body, '$.poster') IS NOT NULL)
       WHERE rank <= 8`,
    ).bind(ownerId, ...ids),
  ]);
  const countOf = new Map((counts.results as { id: string; n: number }[]).map((row) => [row.id, row.n]));
  const postersOf = new Map<string, { title: string; poster: string }[]>();
  for (const row of posters.results as { id: string; title: string; poster: string }[]) {
    postersOf.set(row.id, [...(postersOf.get(row.id) ?? []), row]);
  }
  return results
    .map((row) => {
      const body = fields(row.body);
      const cover = textOf(body.cover);
      const candidates = postersOf.get(row.record_key) ?? [];
      const ordered = [
        ...candidates.filter((item) => item.title === cover),
        ...candidates.filter((item) => item.title !== cover),
      ];
      return {
        id: row.record_key,
        name: textOf(body.name) ?? '',
        description: textOf(body.description),
        count: countOf.get(row.record_key) ?? 0,
        posters: ordered.slice(0, 4).map((item) => item.poster),
        order: typeof body.order === 'number' ? body.order : 0,
      };
    })
    .filter((collection) => collection.name !== '')
    .sort((a, b) => a.order - b.order || a.name.localeCompare(b.name))
    .map(({ order: _order, ...collection }) => collection);
}

/**
 * GET /social/friends/{handle}/collections/{id}?cursor=: one shared
 * collection of a friend and its titles, 200 a page in key order.
 */
export async function friendCollection(
  env: Env, principal: Principal, handle: string, id: string, url: URL, requestId: string,
) {
  if (!idPattern.test(id)) throw notFound();
  const cursor = url.searchParams.get('cursor') ?? '';
  if (cursor !== '' && !titleKeyPattern.test(cursor)) {
    throw new ApiError(400, 'invalid_cursor', 'cursor is from a previous page.');
  }
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  const owner = await friendByHandle(env, principal.userId, handle);
  const collection = await env.DB.prepare(
    `SELECT record_key, body FROM collection_records
      WHERE user_id = ? AND kind = 'collection' AND record_key = ? AND visibility = 'friends' AND deleted = 0`,
  ).bind(owner.user_id, id).first<CollectionRow>();
  if (!collection) throw notFound();
  // Titles are "<collection id>|<type>:<tmdb id>"; '}' sorts right after '|'.
  const { results } = await env.DB.prepare(
    `SELECT record_key, body FROM collection_records
      WHERE user_id = ?1 AND kind = 'entry' AND deleted = 0
        AND record_key > ?2 AND record_key < ?3
      ORDER BY record_key LIMIT ?4`,
  ).bind(owner.user_id, `${id}|${cursor}`, `${id}}`, titlesPageSize + 1).all<CollectionRow>();
  const more = results.length > titlesPageSize;
  const rows = results.slice(0, titlesPageSize);
  const body = fields(collection.body);
  const page: Record<string, unknown> = {
    items: rows.map((row) => {
      const [type, tmdbId] = row.record_key.slice(25).split(':');
      const entry = fields(row.body);
      return {
        type,
        id: tmdbId,
        title: textOf(entry.name) ?? '',
        year: textOf(entry.year),
        poster: textOf(entry.poster),
        addedAt: typeof entry.addedAt === 'number' ? entry.addedAt : 0,
      };
    }),
    cursor: more ? rows.at(-1)!.record_key.slice(25) : null,
  };
  if (cursor === '') {
    page.collection = {
      id,
      name: textOf(body.name) ?? '',
      description: textOf(body.description),
      count: (await env.DB.prepare(
        `SELECT COUNT(*) AS n FROM collection_records
          WHERE user_id = ?1 AND kind = 'entry' AND deleted = 0 AND record_key > ?2 AND record_key < ?3`,
      ).bind(owner.user_id, `${id}|`, `${id}}`).first<{ n: number }>())!.n,
    };
  }
  return json(page, requestId);
}
