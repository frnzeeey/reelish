// The TMDB requests Reelish makes, and nothing else: each route's path
// pattern, its allowed query parameters and their formats, and how long
// its responses may be cached. Mirrors lib/src/services/tmdb_service.dart.

export type CacheClass = 'catalog' | 'search' | 'metadata' | 'identifiers';

/** Edge cache lifetimes (seconds); the app keeps its own cache as well. */
export const cacheTtlSeconds: Record<CacheClass, number> = {
  catalog: 20 * 60,
  search: 3 * 60,
  metadata: 24 * 60 * 60,
  identifiers: 7 * 24 * 60 * 60,
};

type Validator = (value: string) => boolean;

const pattern = (regex: RegExp): Validator => (value) => regex.test(value);
const oneOf = (...values: string[]): Validator => (value) => values.includes(value);

const page: Validator = (value) => /^[1-9]\d{0,2}$/.test(value) && Number(value) <= 500;
const date = pattern(/^\d{4}-\d{2}-\d{2}$/);
const number = pattern(/^\d{1,5}(\.\d{1,2})?$/);
const idList = pattern(/^\d{1,6}([|,]\d{1,6}){0,20}$/);
const language = pattern(/^[a-z]{2}(-[A-Z]{2})?$/);
const query: Validator = (value) =>
  value.trim().length > 0 && value.length <= 200 && !/[\u0000-\u001f\u007f]/.test(value);

/** Sent with every route by the app when it has a language set. */
const common: Record<string, Validator> = { language };

const discoverMovie: Record<string, Validator> = {
  page,
  sort_by: oneOf('popularity.desc', 'primary_release_date.desc'),
  'vote_count.gte': number,
  'vote_average.gte': number,
  'primary_release_date.gte': date,
  'primary_release_date.lte': date,
  'release_date.gte': date,
  'release_date.lte': date,
  with_release_type: pattern(/^[1-6](\|[1-6]){0,5}$/),
  region: pattern(/^[A-Z]{2}$/),
};

const discoverTv: Record<string, Validator> = {
  page,
  sort_by: oneOf('popularity.desc', 'first_air_date.desc'),
  'vote_count.gte': number,
  'vote_average.gte': number,
  'air_date.gte': date,
  'air_date.lte': date,
  'first_air_date.gte': date,
  'first_air_date.lte': date,
  with_type: idList,
  without_genres: idList,
};

interface Route {
  path: RegExp;
  params: Record<string, Validator>;
  cache: CacheClass;
  /** Parameters the request must carry. */
  required?: string[];
}

const id = '[1-9]\\d{0,9}';

const routes: Route[] = [
  { path: /^\/(movie|tv)\/popular$/, params: { page }, cache: 'catalog' },
  { path: /^\/discover\/movie$/, params: discoverMovie, cache: 'catalog' },
  { path: /^\/discover\/tv$/, params: discoverTv, cache: 'catalog' },
  { path: /^\/trending\/all\/day$/, params: { page }, cache: 'catalog' },
  {
    path: new RegExp(`^/(movie|tv)/${id}$`),
    params: { append_to_response: oneOf('credits,external_ids') },
    cache: 'metadata',
  },
  { path: new RegExp(`^/(movie|tv)/${id}/recommendations$`), params: { page }, cache: 'catalog' },
  {
    path: new RegExp(`^/(movie|tv)/${id}/images$`),
    params: { include_image_language: pattern(/^([a-z]{2}|null)(,([a-z]{2}|null)){0,3}$/) },
    cache: 'metadata',
  },
  { path: new RegExp(`^/tv/${id}/season/\\d{1,3}$`), params: {}, cache: 'metadata' },
  { path: /^\/search\/multi$/, params: { query, page }, cache: 'search', required: ['query'] },
  {
    path: /^\/find\/tt\d{5,10}$/,
    params: { external_source: oneOf('imdb_id') },
    cache: 'identifiers',
    required: ['external_source'],
  },
];

export interface AllowedRequest {
  /** The TMDB path, e.g. `/movie/550`. */
  path: string;
  /** Validated parameters, sorted, as TMDB will receive them. */
  params: [string, string][];
  cache: CacheClass;
}

export type Rejection = { reason: 'route' } | { reason: 'param'; name: string };

/** Checks a request against the allowlist; anything unlisted is refused. */
export function allow(path: string, search: URLSearchParams): AllowedRequest | Rejection {
  const route = routes.find((candidate) => candidate.path.test(path));
  if (!route) return { reason: 'route' };
  const seen = new Set<string>();
  const params: [string, string][] = [];
  for (const [name, value] of search) {
    const validate = route.params[name] ?? common[name];
    if (!validate || seen.has(name) || !validate(value)) {
      return { reason: 'param', name };
    }
    seen.add(name);
    params.push([name, value]);
  }
  for (const name of route.required ?? []) {
    if (!seen.has(name)) return { reason: 'param', name };
  }
  params.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return { path, params, cache: route.cache };
}
