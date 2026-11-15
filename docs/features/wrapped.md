# Reelish Wrapped

A yearly recap of the account's own viewing, told as a story of slides, with
cards to share. Profile > Reelish Wrapped, on phones, TV and Windows. A year
opens on 1 January of the next; a notification says so (once, in January,
under Settings > Notifications > Reelish Wrapped).

## Where the numbers come from

Only from what Reelish itself recorded. Trakt is the sign-in, not a data
source: Reelish does not read Trakt's watch history, so the recap is the
same for every account and never depends on another app's scrobbles.

| Source | What it gives |
|---|---|
| `GET /progress?since=0` (the cross-device sync route, `backend/src/progress.ts`) | Every movie and episode the account played on any device: furthest position, length, and the time of its last change |
| The titles' TMDB details (`TmdbService.detailsJson`, the app's own cached details request) | Names, posters, genres, top-billed cast (with ids), seasons' episode counts |

No new route, table, migration or stored data on the server. The app reads
the whole record (pages of 200, at most 60 pages), looks up the titles
finished in the year (at most 400, four at a time), computes the recap
(`WrappedStats`, `lib/src/wrapped/wrapped_stats.dart`) and keeps it on the
device per account and year (`reelish.wrapped.v1`).

## How each number is counted

| Statistic | Rule |
|---|---|
| Finished | A movie or episode at 90% or more of a known length (`ViewingRules.completedShare`), whose last change was in the year in the device's local time. A length of 0 or over 24 hours is not a viewing |
| Movies, episodes, series | Finished movies; finished episodes; series with a finished episode. One server row per title, so each counts once however often it synced |
| Watch time | **An estimate**, labelled as one: the furthest point in each movie and episode last played in the year, from 90 seconds, never past its length |
| Busiest month and weekday | Of finished titles |
| Top genres | Counted once per finished title (a series once however many episodes), TMDB genres, top five, with each one's share of titles that had a genre |
| Favourite actors | Top ten billed in each finished title, counted per title (by TMDB person id), shown when in two or more titles, top five |
| Most-watched series | Most episodes finished in the year |
| Seasons finished | Every episode of a season finished, the last of them in the year (earlier ones may be from before) |
| Milestones | First movie, first episode, 100th/250th/500th/1000th episode, 25th/50th/100th movie, first season finished, by finish time |
| Personality | Fixed rules, first that holds is the main one, the rest are traits, each shown with its reason and numbers: Genre Devotee (one genre in 40%+ of 5+ titles), Binge Master (4+ episodes of one series in a day, on 3+ days), Story Seeker (20+ episodes, 3× the movies), Cinephile (24+ movies), Genre Explorer (8+ genres, none over 35%), Night Owl (40%+ finished 22:00–05:00, 10+ titles), Weekend Watcher (60%+ on weekends, 10+ titles); otherwise the Curious Viewer. No model, nothing sent |

Not offered, because the data cannot support them: rewatches or "most
revisited" (only the latest position is kept), favourite movie (no ratings),
years before progress sync existed.

## Coverage and recalculation

- The server drops a progress row unchanged for 400 days. A recap opened by
  4 February covers the whole year; one opened later says what it covers
  ("from 12 Mar"), on the slides and on every card (`coveredFrom`).
- Once opened, a recap is kept on the device, so it stays the same when rows
  later drop. "Count again" recomputes; a count that finds fewer finished
  titles than the kept one keeps the kept one.
- Each year is its own entry; nothing overwrites another year.
- A year in progress never opens (debug builds can preview it, not kept).
- Kept recaps are per device; another device computes its own from the same
  server record.

## The story

Slides, each only when its numbers exist: welcome, movies, time, most-watched
series, genres, actors, milestones, personality, and a finale with how
everything was counted. Navigation: taps (left third back) and swipes on
phones; left/right, Enter, Escape and Back/Next buttons on TV and Windows;
Skip and Replay everywhere. The stage stays dark in every theme; numbers
count up as a slide arrives; the Reel turns slowly, still under reduced
motion and on TV.

## Share cards

`WrappedCard` (`wrapped_cards.dart`): hours, movies, top genre, actors,
most-watched series, personality and a year summary, each in Story (9:16),
Portrait (4:5) and Square (1:1), drawn at 360 logical px wide and exported at
1080 px. Recognisable before the logo: the Reel, light leaks on a near-black
stage, Montserrat at display sizes, Reelish coral, the REELISH wordmark and
"WRAPPED <year>". Cards speak in the sharer's voice ("I'm The Story
Seeker").

The viewer chooses the format and whether to show their display name (off
by default), posters and photos, and where to get Reelish. Cards carry no
account id, no watchlist, no title list beyond the posters shown.

Export (`wrapped_export.dart`): the share sheet and Pictures/Reelish
(Android 10+) through the app's own `onfeed/share` channel
(`ShareChannel.kt`; the PNG goes to `cache/shares`, exposed only through the
app's FileProvider, one file at a time); Pictures\Reelish on Windows, with
the file shown in Explorer. Not on TV. Images and the wordmark are loaded
before the capture; a failure says so and nothing half-made is shared.

## Privacy

- Private: computed and kept on the device; nothing new is uploaded or
  stored on the server, and no third party sees the viewing history.
- Sharing is only ever the one image the viewer chose, when they press
  Share or Save; it changes nothing about their profile or Friends.
- The January notification follows the notification settings and quiet
  hours, and is sent once, only when this device saw viewing that year.

## Cost

Once a year per account (plus "Count again"): up to 60 `GET /progress`
requests (the sync limiter allows 30 a minute; a typical year is a few
pages) and one TMDB details request per finished title, most already in the
app's or the edge's 24-hour cache. No D1 writes, no scheduled job, no new
infrastructure.

## Tests

`test/wrapped_test.dart`: counting rules (duplicates, partial and invalid
viewings, local-time year edges, per-title genres and actors, seasons,
milestones, coverage, storage), personalities, the service (paging, failed
lookups, kept recaps, gating), the January notification, every card in every
format exported at 1080 px, every slide at phone and wide sizes, and
keyboard navigation.
