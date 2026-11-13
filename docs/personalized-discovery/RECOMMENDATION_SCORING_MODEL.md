# Recommendation scoring model

Deterministic and explainable: the same inputs always give the same rows,
ties are broken by `type:id`, and every recommended title carries a reason a
viewer can read. All numbers below are defaults in `DiscoveryWeights`
(`lib/src/discovery/taste_profile.dart`) or constants in `ViewingRules` and
`DiscoveryEngine`; change them there, not in the rules.

## 1. Viewing status (`ViewingRules`)

A saved position under **90 s** never counts (failed start, sampling, a
provider that did not play). An unknown length counts as started, never as
finished.

| Status | Movie | Series |
|---|---|---|
| in progress | furthest point < 60 % | one episode started, none finished |
| mostly watched | ≥ 60 % | episodes started, none finished |
| completed | reached ≥ 90 % once | at least one episode ≥ 90 % |
| rewatched | reached ≥ 90 % twice (started again below 30 % after finishing) | ≥ 3 finished episodes |
| abandoned | < 25 % and untouched for 10 days | same, on its furthest episode |

## 2. Title weight

| Signal | Weight |
|---|---:|
| Movie rewatched | 1.6 |
| Movie completed | 1.0 |
| Movie mostly watched | 0.75 |
| In progress | 0.4 |
| Series | 0.4 + 0.15 × finished episodes, at most 1.6 |
| Abandoned | −0.35 |
| On My list (incl. Trakt watchlist) | 0.6 |
| Feedback: More like this | 1.3 |
| Feedback: Already watched | 0.35 |
| Feedback: Not interested | −0.25 to each of its genres only |

**Recency:** activity and feedback weights are multiplied by
`0.4 + 0.6 × 0.5^(days / 75)`. Old tastes keep at least 40 % of their weight,
so one recent title cannot outweigh months of viewing. My list has no date
and is not decayed.

## 3. Genre affinity

Each title adds `weight / √(number of genres)` to each of its genres (TV
combined genres such as Sci-Fi & Fantasy also count for Sci-Fi and Fantasy,
see `TmdbGenres.equivalents`). The totals are divided by the strongest, so
the top genre is 1.0. Genres picked in Settings get **+0.5**. Affinity is
clamped to **[−0.5, 1]**: feedback can lower a genre but never exclude it.

`seriesShare` is the share of positive weight on series; it feeds the type
term below.

## 4. Seeds

The strongest titles with a numeric TMDB id and positive weight, at most
**4** (`maxSeeds`). When the viewer has both movies and series, at most 3 are
of one kind. Each seed's weight is relative to the strongest (0–1). Seeds are
what TMDB recommendations are fetched for, and what "Because you watched"
rows are named after.

## 5. Candidate eligibility

A candidate is dropped when it is: not a valid TMDB id; a movie or suitable
series (talk, news, reality and soap stay out as elsewhere in Home); rated
under 5.0 or unrated; under 5 votes; released after today; or in the
profile's exclusions (anything started or finished, on My list, or given
feedback).

## 6. Candidate score (0–1 terms, weighted sum)

| Term | Weight | Definition |
|---|---:|---|
| genre match | 0.40 | best positive affinity among its genres × 0.65 + second best × 0.35 (one genre: × 0.8), plus half of the most negative affinity. Range −1 to 1. |
| seed relevance | 0.30 | best of `seed weight / (1 + rank / 8)` over the seeds that recommended it, + 0.1 per further seed. 0 for titles only from Home's rows. |
| quality | 0.18 | `(weighted rating − 5.5) / 3`, clamped. Weighted rating is the shared Bayesian rating in `MediaDiscoveryRanking`. |
| popularity | 0.05 | `log10(1 + popularity) / 3`, clamped. Small on purpose: a close match beats a blockbuster. |
| type fit | 0.07 | `seriesShare` for a series, `1 − seriesShare` for a movie. |

## 7. Rows

Built in this order, each taking titles no earlier row took, and shown only
with at least **6** titles; at most **4** rows.

1. **Recommended for you** (15 titles; "Picked for your genres" when there
   are no seeds). Greedy by score, with two rules:
   - **Diversity:** a leading genre may hold at most 40 % of the row while
     other titles are left (`maxGenreShare`).
   - **Exploration:** every 4th slot (`exploreShare` 0.25) goes to the best
     title with genre match between −0.1 and 0.25 and quality ≥ 0.5, ranked
     by quality 0.5, seed relevance 0.3, popularity 0.2. About 75 % of the
     row follows established tastes and 25 % reaches past them.
2. **Because you watched X** (up to 2 rows, 12 titles each) from one seed's
   list, ranked `0.55 / (1 + rank / 8) + 0.45 × score`. Named "Because you
   saved X" for a My list seed and "More like X" for a More-like-this seed.
3. **Top picks in {genre}** for the strongest genre with affinity ≥ 0.5 that
   has 6 unused titles.
4. **Something different** (viewers with at least 3 signals): the
   exploration titles left, best first.

Shown order: Recommended, Because #1, genre, Because #2, Something different,
cut to 4.

## 8. Reasons

Per title in Recommended for you: the seed that recommended it most strongly
("Because you watched X"), else "Matches your taste for {genre}" when its
genre match is above 0.25, else "Well rated and popular right now";
exploration slots say "Something a little different". Other rows' reasons
are their titles. Scores are never shown.

## 9. Feedback

| Action | Effect |
|---|---|
| Not interested | Hidden at once and from every later build; −0.25 (decaying) to its genres. Settings > Show hidden titles again clears all of these. |
| Already watched | Hidden; +0.35 to its genres. |
| More like this | Hidden; +1.3 to its genres, and it becomes a seed ("More like X"). |

Each can be undone from the notice that follows on the phone. The Windows
cross is Not interested.
