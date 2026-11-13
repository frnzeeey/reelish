# Personalisation data model

## Where it is kept

| Data | Where | Key / file | Bound |
|---|---|---|---|
| Activity, feedback, picked genres | SharedPreferences | `onfeed.discovery.v1.<userId>` | 300 titles, 300 feedback entries, 200 episodes per series |
| Owner of the old device history | SharedPreferences | `onfeed.discovery.historyOwner.v1` | one account id |
| Last computed rows | app support directory (outside Android backup, like `last_streams.v1.json`) | `discovery_<userId>.v1.json` | ≤ 4 rows × ≤ 15 titles |

`<userId>` is the Reelish account id (`AccountController.userId`), the same
key `ProfileController` and `WatchlistSync` use. In file names, characters
outside `[A-Za-z0-9_-]` become `_`.

Writes go through one queue (`DiscoveryStore._serialized`), and the rows file
is written to a temporary file and renamed, so an interrupted write never
leaves it corrupt. Unreadable entries are skipped; an unreadable whole reads
as empty.

## Shapes (version 1)

```jsonc
// onfeed.discovery.v1.<userId>
{
  "v": 1,
  "activity": [
    {
      "type": "movie",            // or "series"
      "id": "157336",             // TMDB id
      "name": "Interstellar",
      "poster": "https://image.tmdb.org/t/p/w500/…",   // optional
      "genres": [12, 18, 878],    // optional
      "first": "2026-05-01T20:11:00.000Z",
      "last": "2026-05-02T21:40:00.000Z",
      "share": 0.97,              // furthest point of the current viewing
      "done": 1,                  // movies: times finished (optional)
      "episodes": {"1:3": 0.95}   // series: furthest share per episode (optional)
    }
  ],
  "feedback": [
    {"kind": "notInterested", "type": "movie", "id": "1", "name": "…",
     "genres": [35], "at": "2026-05-03T09:00:00.000Z"}
  ],
  "genres": [878, 9648],          // picked in Settings (optional)
  "seeded": true                  // device history already considered (optional)
}
```

```jsonc
// discovery_<userId>.v1.json
{
  "at": "2026-05-03T09:00:00.000Z",
  "fingerprint": "157336,…|878,18|42|a1b2c3d4",
  "sections": [
    {"kind": "forYou", "title": "Recommended for you",
     "items": [ /* MediaItem.toJson() */ ],
     "reasons": {"movie:329865": "Because you watched Interstellar"}},
    {"kind": "becauseYouWatched", "seed": "movie:157336", "title": "…",
     "items": [ … ], "reasons": { … }}
  ]
}
```

Existing user data is untouched: history, episode progress and My list keep
their keys and shapes. `StorageService` gained only a static, null-by-default
listener (`onProgressSaved`) called after a save is written.

## Account isolation

- Every read and write names the account; nothing is kept under a shared
  key except the history owner.
- **Old device history** (kept before discovery, device-wide) is read into
  the **first** account that runs discovery on the device, once. Any other
  account starts empty, so a second person signing in on the same device
  does not inherit the first one's tastes.
- `bindUser` clears the in-memory data and rows before loading the new
  account, and every async step checks the account is still the same before
  applying its result.
- Signed out: nothing is loaded, recorded, requested or written. Home is not
  shown signed out anyway (`AccountGate`).
- Sign-out keeps the account's discovery data on the device, as it keeps My
  list and history; signing in again with the same account resumes it.
- Clearing app data removes everything. **Reset recommendations** removes
  the account's activity, feedback and rows; picked genres stay, and the old
  device history is not read in again.

Known limit: Continue watching and My list themselves are device-wide (as
before this feature), so a second account on the device still sees them;
only discovery's own data is per account.

## Privacy

- Viewing activity never leaves the device. Nothing is logged: the
  controller has no log lines, and failures are swallowed without messages.
- The only network use is `TmdbService.recommendations` for up to four seed
  titles, through the Reelish API's TMDB gateway with the session token,
  exactly as opening a title's details or Top 10 already does. The gateway
  does not store request history (`backend/src/tmdb/gateway.ts` caches TMDB
  responses by URL, with no account in the key).
- No Firebase or analytics event was added.

## Synchronisation

The preferences sync through the Reelish API (`GET`/`PUT
/api/v1/discovery/preferences`, D1 table `discovery_preferences`, one row per
account): picked genres, the genre step (`onboarding`: completed or skipped)
and personalisation on/off. The newest change wins, ordered as playback
progress is (per-device counter, then the change time corrected by the
measured clock offset). Activity, feedback and rows stay on the device.
Details: [implementation report](../discovery/DISCOVERY_IMPLEMENTATION_REPORT.md).

Added to `onfeed.discovery.v1.<userId>` (all optional, omitted at their
defaults, so earlier data reads unchanged):

```jsonc
{
  "onboarding": "completed",            // or "skipped"; absent: never answered
  "personalization": false,             // absent: on
  "prefsAt": "2026-11-13T09:00:00.000Z", // last preference change here
  "prefsUnsent": true                   // that change has not reached the API
}
```

The sync's own state is `onfeed.discoveryPrefsSync.v1`:
`{userId: {device, seq, offset}}` (a random device id, the change counter and
the server clock offset).
