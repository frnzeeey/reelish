# Playback progress: data model

Everything here is local, in SharedPreferences, written through
`StorageService`. Persisted shapes are user data: new fields are optional
and old values still load.

## Keys

| Key | Holds | Bound |
|---|---|---|
| `onfeed.history.u.<userId>` | Watch history of one account: a list of JSON `MediaItem`s, newest first | 50 titles |
| `onfeed.history.episodes.v1.u.<userId>` | Per-episode progress of one account, by series | 100 series |
| `onfeed.history` | Device-wide history kept before accounts were separated; read only while signed out, and moved into its owner (below) | — |
| `onfeed.history.episodes.v1` | The same, for episode progress | — |
| `onfeed.discovery.historyOwner.v1` | The account that owns the device-wide history (shared with personalised discovery) | — |

`<userId>` is the Reelish account id (a UUID issued by the Reelish API),
never a Trakt token or name.

## Movie progress: the history entry

A `MediaItem` with two progress fields:

```json
{"id":"27205","type":"movie","name":"Inception", "...": "...",
 "resumeMs": 2555000, "durationMs": 8880000}
```

- Identity is `type` + TMDB `id` (`movie:27205`), never the title.
- `durationMs` is 0 when unknown (entries saved before lengths were
  recorded, or live streams); such an entry shows its position only and
  stays in Continue watching.
- A series also has a history entry; its `resumeMs` is the last episode's
  position and only marks it as started. Episode positions live in the
  episode store.

## Episode progress

```json
{
  "series:1396": {
    "last": [1, 3],
    "next": [1, 4],
    "episodes": {"1:1": [2820000, 2880000], "1:3": [2830000, 2880000]}
  }
}
```

- Each episode has its own `[positionMs, durationMs]` under `season:episode`,
  so one episode never resumes at another's position.
- `last` is the episode watched most recently.
- `next` (**new**, optional) is the episode after `last`, written only when
  `last` was saved as watched and the episode list named an aired next
  episode. Any later save of an unfinished episode drops it. Entries without
  it load as before (`SeriesProgress.next == null`).
- Map order runs least to most recently watched; the oldest series is
  dropped past 100.

## Derived state (not stored)

| Value | Rule | Code |
|---|---|---|
| Watched share | `positionMs / durationMs`, 0 when the length is unknown | `EpisodeProgress.fraction` |
| Completed | share ≥ 0.9 | `EpisodeProgress.isWatched` |
| Shown as in progress | ≥ 1 minute in and not completed | `EpisodeProgress.isInProgress` |
| Resume position | its position, or 0 once completed | `EpisodeProgress.resumeMs` |
| Episode to continue | `last` while unfinished, else `next` | `SeriesProgress.continueAt` |
| In Continue watching | started, and not (a completed movie, or a series with nothing to continue) | `ResumeSummary.continues` |
| Start position checked against the stream | 0 when the saved position is in the completed share of the stream's own length | `CustomVideoPlayer.validResume` |

## Save times (Phase B)

Each stored position carries when it was saved, on this device's clock (a
position pulled from another device is converted to it):

- history entry: `"progressAt": 1763030400000` (omitted when unknown);
- episode: a third element, `[positionMs, durationMs, at]`.

Values saved before sync have none (0). Older app versions ignore the extra
field and element, so a downgrade still reads the data.

## Sync state (Phase B)

`onfeed.progressSync.v1`, per account:
`{userId: {device, seq, cursor, offset, seeded, outbox: {key: at}}}` —
the random device id, this device's change counter, the pull cursor, the
measured server-clock offset, whether the first upload happened, and the
titles waiting to be sent ([sync strategy](CROSS_DEVICE_SYNC_STRATEGY.md)).
Sync keys are `movie:<tmdb>`, `series:<tmdb>` and
`episode:<tmdb>:<season>:<episode>`; titles without a numeric TMDB id are
not synced.

## Migration

`StorageService.useAccount(userId, ownsDeviceHistory:)`, called by
`AccountHistory` when the signed-in account changes:

1. The account's keys are used from that moment, for reads and writes.
2. `DiscoveryStore.claimDeviceHistory(userId)` decides ownership: the first
   account to claim the device's history owns it (the same owner
   personalised discovery already uses, so the two never disagree).
3. For the owner, inside the write queue: the device-wide history is merged
   under the account's own entries (the account's entry wins for a title in
   both), the episode store likewise, then the device-wide keys are removed.
   Repeating it is safe; the removal comes last.
4. Reads wait for the move, so Home never shows a half-moved history.

Another account never receives the device-wide history; it stays in place
for its owner. The Android background episode check reads the account's own
keys; until the app has run once after updating, it does not see history
that has not moved yet.
