# Home discovery audit

Audit of every content-discovery section on Home, as the code stands on
2026-11-13 (after `00092d0`, on-device personalised discovery). It covers
the phone, Android TV / Google TV and Windows interfaces. The proposed
hierarchy is at the end. The implementation is described in
[DISCOVERY_IMPLEMENTATION_REPORT.md](DISCOVERY_IMPLEMENTATION_REPORT.md).

Related: [personalised discovery architecture](../personalized-discovery/PERSONALIZED_DISCOVERY_ARCHITECTURE.md),
[scoring model](../personalized-discovery/RECOMMENDATION_SCORING_MODEL.md),
[TMDB usage](../personalized-discovery/TMDB_API_OPTIMIZATION.md).

## Where Home's sections come from

All TMDB calls go through `TmdbService` (`lib/src/services/tmdb_service.dart`)
to the Reelish API's allowlisted gateway (`backend/src/tmdb/allowlist.ts`).
That path has a shared limiter (4 concurrent, deferred priority for
non-critical calls), de-duplicates requests already in flight, and keeps a
disk cache with stale-while-revalidate (`TmdbResponseCache`, TTLs in
`TmdbCacheTtl`). The gateway adds an edge cache that is not keyed by
account. `HomeViewModel` (`lib/src/viewmodels/home_view_model.dart`) owns
the four paged catalog rows, and each layout draws them its own way:

| Interface | Order on Home |
|---|---|
| Phone, For you tab | Spotlight hero → Continue watching → personalised rows → Top 10 → New releases → Trending now → New movies → Series worth the queue (audited order; since 2026-11-14 Top 10 sits directly under the Spotlight, before Continue watching) |
| Phone, other tabs | Movies = New movies grid; Series = Series worth the queue grid; Trending = Trending grid |
| Android TV | Continue watching → New movies → Series worth the queue → personalised rows → Watch together → Top 10 → New releases → Trending now (focus-driven hero from Spotlight) |
| Windows | Spotlight hero → Top 10 → personalised rows → Trending now → Watch together → New movies → Series worth the queue → New releases (Continue watching is in the sidebar) |

## Section by section

| Section | Data source | Trakt | Personalised | Cache | Pagination |
|---|---|---|---|---|---|
| **Spotlight** | No request. `TmdbService.spotlight()` ranks page 1 of New releases, New movies and Series (`MediaDiscoveryRanking.spotlightCandidates`): high quality, released, recent first, 6 movies + 6 series interleaved | No | No | Inherits from the rows | No |
| **Continue watching** | Local history (per account), synced by `ProgressSync` (`/api/v1/progress`) | No | Yes (own viewing) | Local | No |
| **New movies** | `/discover/movie`, first and general (theatrical/digital) release in the last 365 days, `popularity.desc`, ≥ 5 votes, re-ranked by `MediaDiscoveryRanking.newMovies` | No | No | 20 min SWR + edge | Paged (`PagedFeedController`) |
| **Series worth the queue** | `/discover/tv`, scripted only, an episode aired in the last 730 days, `popularity.desc`, ≥ 5 votes, re-ranked by `worthQueueSeries` | No | No | 20 min SWR + edge | Paged |
| **New releases** | 3 merged `/discover` queries: movies released in the last 180 days, series that premiered in it, series with an episode in it; ≥ 25 votes, rating ≥ 7 | No | No | 20 min SWR + edge | Paged; loads when near the screen |
| **Top 10 recommendations** | `/recommendations` of the best movie and the best series on page 1 of New movies / Series, ranked by vote-weighted score | No | **No** (seeds are catalog titles, not the viewer's) | 20 min SWR + edge | Paged to 10; loads when near the screen |
| **Trending now** | `/trending/all/day`, page 1 (20 mixed titles) | No | No | 20 min SWR + edge | None on Home |
| **Recommended for you** | `DiscoveryEngine`: TMDB `/recommendations` of up to 4 seed titles + the rows above as a pool, scored on genre affinity, seed relevance, quality, popularity, movie/series balance; ~1 in 4 slots exploratory; 40 % cap per leading genre | Indirectly (Trakt watchlist via My list) | Yes | Rows cached per account on disk, rebuilt after 6 h or when tastes change | No (15 titles) |
| **Because you watched X** (≤ 2) | Seed's `/recommendations` | Indirectly | Yes | As above | No (12) |
| **Top picks in &lt;genre&gt;** | Pool + seed lists filtered to the strongest genre | No | Yes | As above | No (12) |
| **Something different** | Well-rated candidates with a weak genre match; only after 3+ signals | No | Yes (inverse) | As above | No (12) |
| Popular movies / series | `TmdbService.popular()` exists, **no caller** | — | — | — | — |
| Upcoming, Top rated | Not implemented | — | — | — | — |

## Findings

**Overlap and duplicates**

- *New movies ↔ Trending ↔ Series worth the queue.* All three sort by
  popularity over recent titles, so Trending (day) repeats several cards
  from the other two. Trending is not de-duplicated against anything.
- *New releases* is already de-duplicated against New movies and Series
  (`HomeViewModel.distinctReleases`, as long as 6 titles remain). It is the
  only row with a quality bar (rating ≥ 7), and the only one that surfaces
  new episodes of older series. It is distinct.
- *Top 10* excludes its two seeds but not the other rows. Because its seeds
  are the most popular recent titles, it overlaps the catalog rows
  moderately. Its title says "recommendations", but nothing in it comes from
  the viewer. **The label overstates personalisation.**
- *Personalised rows* use the catalog rows as a candidate pool, so they can
  repeat a card shown further down. Inside the personalised rows, no title
  appears twice.
- *Spotlight* repeats titles from the rows by design: it is a hero, not a
  row.

**Personalisation gaps**

1. **Genres alone produce almost nothing.** With picked genres only, the
   engine draws on the ~100–200 recent, popular titles Home already
   loaded, because the gateway refuses `with_genres` on `/discover`. A
   viewer who picks Western, Documentary, War or History will usually get
   fewer than 6 matches, which hides the row. An onboarding genre picker
   would therefore promise more than Home can deliver until
   `with_genres` is allowed.
2. **No first-run genre step.** Genres can be picked only in Settings >
   Recommendations, which a new account never opens. A new account sees a
   generic Home until it has watched something.
3. **No way to turn personalisation off** short of resetting it.
4. **Genre preferences are per device.** Viewing progress and collections
   sync through the Reelish API; discovery preferences do not.
5. **Genre names are a static table** (`TmdbGenres`). TMDB's genre ids are
   stable, but `/genre/{movie,tv}/list` is not on the gateway allowlist, so
   the app cannot read them from TMDB today.

**Requests and cost.** A cold Home makes at most: New movies 1, Series 1,
New releases 3, Top 10 2, Trending 1, personalised seeds ≤ 4. That is 12
requests, all cached for 20 min on device and at the edge. Personalised rows
cost 0 at launch (disk) and ≤ 4 requests per 6 h. The only redundancy is
eager Trending on TV and Windows (`initState`); the phone loads it as it nears
the screen. It is one cached request and was left as is.

**Relevance to returning users.** Continue watching and the personalised
rows change for each viewer. The catalog rows change with TMDB's popularity
and release dates (20 min), not with the viewer. Top 10 is the same for
everyone.

## Recommendation per section

| Section | Data Source | Purpose | Overlap | Recommendation |
|---|---|---|---|---|
| Spotlight | Ranked from New releases / New movies / Series page 1 | Editorial hero, quality + recency | Repeats row titles (by design) | **Keep** as is; its own identity, not merged into personalisation |
| Continue watching | Local + `/progress` sync | Resume | None | **Keep** |
| Recommended for you | `DiscoveryEngine` | Primary personalised discovery | Can repeat catalog cards | **Keep, primary.** Feed it genre-discover candidates so genre-only accounts get rows |
| Because you watched X | Seed `/recommendations` | Contextual personal | None within personal rows | **Keep** |
| Because you like &lt;genre&gt; *(new)* | `/discover` with `with_genres`, per picked genre | Contextual personal, works from day one | Excludes titles in other personal rows | **Add.** Replaces "Top picks in &lt;genre&gt;" when genre-discover candidates exist; shown only with ≥ 6 titles |
| Something different | `DiscoveryEngine` exploration | Anti echo-chamber | None | **Keep** |
| Top 10 recommendations | `/recommendations` of top catalog titles | Popular, highly rated | Moderate with catalog rows | **Keep, relabel** to "Top 10 picks": it is not personal |
| New releases | 3 × `/discover` | Recently released, quality ≥ 7, new episodes | De-duplicated already | **Keep** |
| Trending now | `/trending/all/day` | What everyone watches today, outside your genres | High with New movies / Series | **Keep, secondary.** De-duplicate against personal rows and Top 10 when enough titles remain |
| New movies | `/discover/movie` | Broad recent movies; Movies tab; Spotlight + Top 10 source | With Trending | **Keep** (sources Spotlight, Top 10, the Movies tab) |
| Series worth the queue | `/discover/tv` | Broad active series; Series tab; Spotlight + Top 10 source | With Trending | **Keep** (same reasons) |
| Popular (`TmdbService.popular`) | `/movie|tv/popular` | — | Would duplicate New movies / Trending | **Do not add.** Dead method; left for a separate cleanup |
| Upcoming | — | — | — | **Do not add**: nothing to play yet; keeps "new" meaning "available" |

Nothing is removed. Each existing row either feeds another one (Spotlight,
Top 10, the tabs) or carries a distinct filter.

## Proposed hierarchy

Personalised rows lead, general discovery follows. Each interface keeps its
own layout:

1. Spotlight (phone, Windows hero; TV focus hero)
2. Continue watching (phone, TV; Windows sidebar)
3. Discovery prompt *(existing accounts without preferences only;
   dismissible)*
4. Recommended for you
5. Because you watched X / Because you like &lt;genre&gt; (≤ 2 + 1)
6. Something different (after 3+ signals)
7. Top 10 picks
8. New releases
9. Trending now (de-duplicated)
10. New movies, Series worth the queue

The phone already follows this order. Windows keeps Top 10 directly under
the hero, a deliberate earlier choice for a 1280 × 720 fold. TV keeps New
movies and Series first: personalised rows come from an asynchronous disk
read, and inserting rows above the focused row moves focus on a remote.
Moving TV's personalised rows up needs focus-preserving insertion and a
device test, so it is listed as a follow-up.
