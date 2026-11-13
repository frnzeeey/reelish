# Smart collections

Four collections fill themselves from data the app already keeps. Nothing
is copied into them: `SmartCollections.of` works each one out from its
sources, and `LibraryViewModel.smart` caches the result until a source
changes.

## Sources

| Source | Where |
|---|---|
| My list | `StorageService.favorites()`, newest first; `savedAt` when known |
| Custom collections | `CollectionLibrary.allEntries`: each title once, its latest `addedAt` |
| Watch history | `StorageService.history()`: the account's last 50 titles, with positions |
| Episode progress | `StorageService.seriesProgress` for the series in the history |

"Saved" below means on My list or in any collection; each title counts once,
with the later of its save times.

## Recently added

Saved titles whose save time is within the last **30 days**, newest first,
at most **60**.

- Only dated saves count: additions to collections, and titles added to My
  list from now on. My list titles saved before this version, and titles the
  Trakt watchlist sync brings in, have no date and are never "recent".
- Trending or recommended titles are never included.

## My list

My list itself, in its own order. It is the existing list, not a copy, so
the Library's My list row, the hearts and Trakt watchlist sync all stay in
step with it.

## Not started

Saved titles without meaningful viewing, in saved order (latest save first).

A title is **started** when the history shows:

- a position of at least **90 seconds**, or
- for a series, any episode watched past 90 seconds.

So a failed start or a few seconds of a trailer-like opening leaves a title
*Not started*; so does a title never opened.

## Finished

History titles watched to the end, most recent first: those with a position
that `ResumeSummary.continues` no longer keeps in Continue watching.

- A movie is finished at 90 % of its length (the existing rule).
- A series is finished when its last episode is watched and no next aired
  episode is known.
- A title with no saved length is never counted as finished.

## Considered and left out

| Candidate | Why not |
|---|---|
| Currently watching | Already the Continue watching row on all three interfaces |
| Recently watched | Already the Watch history row |
| My movies / My TV shows | A filter of My list; adds little over sorting |
| Recently favourited | Same as Recently added restricted to My list |

## Refresh

- Collections change: the store notifies, `LibraryViewModel` drops its
  cache, and pages showing a smart collection rebuild.
- My list or the history change: `LibraryViewModel.load` runs (on My list
  changes, Home's refresh token, or a page opening) and drops the cache.
- Nothing is recomputed on a rebuild that changed no source.

## Edge cases

- **History is capped at 50 titles.** A title watched long ago and since
  pushed out of the history shows as *Not started* again, and drops out of
  *Finished*.
- **Watched on another device.** Continue watching sync (Phase B) brings
  positions over, so *Not started* and *Finished* follow viewing elsewhere
  once synced.
- **Trakt history** is not read (Trakt decision: not now), so viewing done
  only in other apps does not count.
- **Clock changes** only affect the 30-day window of Recently added.
