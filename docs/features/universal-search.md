# Universal Search

One search for movies, series, people (actors, directors, writers…) and
movie collections. It is the Search page on TV and Windows, and a
full-screen page from the Search button on phones. It replaced three
separate title-only searches (the phone's inline field in Home,
`TvSearchPage`, `DesktopSearchPage` and their `SearchViewModel`).

## Three separate responsibilities

| Layer | Code | Job |
|---|---|---|
| Metadata search | `TmdbService.searchMultiJson`, `searchCategoryJson`, `discoverJson`, `personJson`, `collectionJson` | TMDB through the Reelish API, with the app's existing cache, request sharing and queue |
| Orchestration | `lib/src/search/universal_search_controller.dart`, `search_ranking.dart`, `search_models.dart` | Debounce, stale answers, categories, ranking, filters, paging, recent searches, parsing |
| Playback discovery | `lib/src/search/playback_availability.dart` | Whether enabled providers list sources for the best match; independent of search |

A slow or failing provider never delays or breaks a search, and TMDB is
never treated as a playback source.

## What is requested

| The viewer… | Requests |
|---|---|
| types words (after a 400 ms pause) | `/search/multi` (titles and people, in TMDB's relevance order) and `/search/collection`: 2 |
| …and nothing matches, the words ending in a year ("dune 2021") | `/search/movie` and `/search/tv` with that year: 2 more |
| sets genre, year or rating filters | `/search/movie` and `/search/tv` (TMDB narrows a single year itself; genres, rating and year ranges are applied in the app over up to 3 pages) |
| sets filters with no words | `/discover/movie` and `/discover/tv` with the filters |
| opens a category | that category's search, a page at a time (up to 10 pages) |
| opens a person or a collection | `/person/{id}` (with all credits) or `/collection/{id}` |

Every answer goes through `TmdbService`'s memory and disk cache (search: 3
minutes; people and collections: 24 hours) and the gateway's edge cache. An
answer to an older query is dropped. Collections failing never fails the
search.

## Ranking

TMDB's order is kept, with exact and leading matches lifted first (case,
accents, punctuation and a leading "the" ignored; original titles count). A
**Top result** is shown only when one result's name matches what was typed
exactly or at its start; TMDB's mixed order decides between kinds.

## Filters

Movies and series only; people and collections have no genre, year or
rating, so their categories hide the bar and the All view hides them while
filtering (and says so).

- **Genre:** Reelish's picker genres; a title matches any chosen. Series
  use TMDB's combined genres (Science fiction finds Sci-Fi & Fantasy), as on
  Home.
- **Year:** presets and single years; first air year for series. Titles
  without a date are left out while a year is set.
- **Rating:** TMDB's user score (0–10) only, counted for titles with at
  least 20 votes. No other provider's ratings are mixed in.

## Provider sources

For a movie as the top result, Reelish asks the viewer's providers through
`ProviderPluginService.streams`, the same lookup Play uses: by TMDB id
(never by title), only enabled providers (respecting this device's
compatibility and the review hold), the Playback settings' allowed providers
and torrent setting, the existing per-provider limits and deduplication.

- One check at a time; a new search cancels the previous one (no new
  providers start). At most 45 seconds; a finished check is reused for 10
  minutes.
- Shown: how many sources each provider listed, and the quality label,
  torrent and subtitle facts the provider itself supplied. Nothing is
  guessed.
- "Listed by providers, not tried yet": a source found is not a stream that
  plays. Nothing starts playing; the title's own page plays it as before.
- Series are not checked: providers look series up one episode at a time.

## Interfaces

| | Phone | TV | Windows |
|---|---|---|---|
| Entry | Search button in Home's header | Search in the rail | Search in the sidebar |
| Field | Text field | TV keyboard dialog (`TvTextField`) | Text field |
| Results | Rows by kind; categories as grids | Same, each card a remote focus target; no "See all" (the category chips do that) | Same, hover |
| Person, collection | Pushed page | Pushed page | Pushed page; Esc goes back |

Recent searches (8, this device only) keep the Windows page's key
`onfeed.search.recent.v1`, so existing history still shows.

## Security

TMDB answers are untrusted: wrong types are dropped, text is capped, image
paths must look like TMDB's own (`/abc.jpg`) and become `image.tmdb.org`
URLs. Queries are trimmed, stripped of control characters and capped at 100
characters before they leave the device. The API accepts only the listed
routes and parameters (`backend/src/tmdb/allowlist.ts`). Provider results
pass through the existing stream normaliser and validator; availability
grants nothing: playing still goes through the normal flow.

## Cost

No new service, storage or dependency. The only backend change is six
allowlisted TMDB routes, served by the existing gateway and cached at the
edge. A typed search costs 2 TMDB requests (the old search cost 1), mostly
answered from cache for common queries. TMDB's own rate limits and the
gateway's per-user limit (240 a minute) still apply. Provider checks run on
the device and contact the providers' sites, as Play does.

## Limits

- Filters with words look through the best matches (up to 3 pages per
  type), not every title on TMDB; filters without words browse all of TMDB.
- People and collections cannot be filtered; TMDB offers no such fields.
- Reelish's own collections (Library) are not searched here.
- Provider availability is for movies only, and only the top result.

## Tests

`universal_search_test` (ranking, requests per case, debounce, stale
answers, paging, filters, discover parameters, recent searches, person and
collection parsing, untrusted shapes, provider discovery: grouping,
duplicates, reuse, timeouts, failures, cancellation, series),
`universal_search_screens_test` (Windows results and sources, person and
collection pages, categories and filters, TV remote, phone page, failure),
`backend/test/allowlist.test.ts` (the new routes and what they refuse), and
the updated Home, TV and journey tests.
