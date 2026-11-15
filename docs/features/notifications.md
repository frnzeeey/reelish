# Notifications

Settings > Notifications, on Android phones and tablets and on Windows. Not
offered on Android TV or Google TV, which have no useful notification shade;
the Follow buttons are hidden there too.

## How alerts work

There is no push service. Each device asks the Reelish API for the public
facts it needs and decides on its own what is news:

1. **When:** every 6 hours. On Android a WorkManager task runs even when the
   app is closed; it carries the session's narrow alert token (`rnt_…`), which
   opens only `POST /notifications/episodes`, so it never rotates a refresh
   token. While the app runs (Android and Windows) a timer, launch and resume
   check too. Windows checks only while Reelish is open.
2. **One request per check:** `EpisodeCheck.run`
   (`lib/src/notifications/episode_check.dart`) sends the series, movies,
   people and collections to ask about; the Worker (`backend/src/episode-alerts.ts`)
   answers from TMDB through the gateway's edge cache, using the app's own
   request shapes so both share cache entries. The Worker stores nothing about
   what anyone follows.
3. **What is news:** pure Dart in `lib/src/notifications/smart_alerts.dart`,
   from the answer and the state kept per account in SharedPreferences
   (`onfeed.episodeAlerts.v1`). A first sight only records, so turning a
   category on, adding a title or following someone never alerts about what
   was already known.
4. **When it shows:** `AlertPlanner` drops news already shown, holds it during
   quiet hours or for a summary, and then the notifier shows it.

## Categories

| Setting | News | Source |
|---|---|---|
| Series on My list, Series you are watching | A new episode aired in the last 3 days, not already watched (on any device: progress syncs) | `lastEpisode` |
| Popular series | Today's popular series with a new episode, one summary a day | TMDB `/tv/popular` |
| My list updates | A season announced; a season premiere dated; a movie given a release date; a movie released (within 30 days) | `seasons`, `nextEpisode`, movie `status` and `releaseDate` |
| People you follow | A new film or series they lead or direct, announced; then released (within 21 days) | Person `combined_credits`, filtered on the server |
| Collections you follow | A new film in the collection announced; then released | Collection `parts` |
| Unfinished series | A series with an episode to go on with, left 3, 7 or 14 days (not more than 45), still in Continue watching; one series a reminder, at most one a day, once per stretch away | This device's progress only: no request |
| Messages from friends | Who wrote, never what | Mailbox count, as before |
| Reelish Wrapped | Last year's recap is out: once, in January, when this device saw viewing that year | No request ([Reelish Wrapped](wrapped.md)) |

Minor metadata (a new poster, an overview, a release date moving again) is
never news. Dates are TMDB's metadata, not playable availability; the alert
text says that whether it plays depends on the user's sources ("has aired",
"is released", never "watch now").

People: leading film roles (billing order 8 or better), series parts of 3 or
more episodes, and directing. Cameos, guest spots, talk, news and reality
shows, playing themselves and producing are left out. Credits older than 45
days are not sent at all.

## Delivery

- **How alerts arrive:** as they happen, a daily summary or a weekly summary.
  A summary goes out at the first check at least 20 hours (or 6 days 20
  hours) after the last one, since checks drift.
- **Quiet hours:** Off, 22:00–07:00, 23:00–08:00 or 21:00–09:00, local time.
  Nothing shows inside them, messages included; what was found waits for the
  first check after.
- **Grouping:** new episodes one by one up to three, then one summary; each
  other category is one alert or one summary, and a newer summary of a
  category replaces the older (fixed notification ids).
- **Deduplication:** every piece of news has a stable key,
  `category:content:event` (for example `watchlist:series:1399:season:9` or
  `person:p:31:movie:550:released`), per account. Shown keys are kept 120
  days; waiting news older than 8 days is dropped; at most 60 wait.
- **Channels (Android):** "New episodes" (as before), "Messages", and
  "Title updates" (low importance) for the rest.

## Taps

An alert about one title, person or collection carries
`{"to": "series:<id>", "n": name}`; summaries carry `recent`. `AlertRoutes`
(`episode_alerts.dart`) parses the payload strictly (kind and numeric TMDB id
only) and hands it to Home, which opens the details page, the person or
collection page, or Settings > Notifications. A tap that launched the app
waits until Home is up (`getNotificationAppLaunchDetails`).

## Following

Person and collection pages (Universal Search) have a Follow button
(`FollowAlertButton`) where alerts exist. Up to 15 people and 15 collections,
kept on the device per account, listed with Unfollow in Settings >
Notifications. Following does not sync between devices.

## Recent

Settings > Notifications lists the last 30 alerts shown, newest first; those
not seen yet carry a dot until the page is opened. A tap opens the alert's
page.

## Saved data

All in the existing `onfeed.episodeAlerts.v1` entry per account. New
settings fields (`watchlist`, `reminderDays`, `people`, `franchises`,
`frequency`, `quietStart`/`quietEnd`) read defaults from older entries:
My list updates, people and collections on; reminders off; as they happen;
no quiet hours. New keys: `follows`, `watch`, `follow` (first-sight state),
`delivered`, `pending`, `recent`, `lastDigest`, `lastReminder`.

## Privacy and security

- What anyone follows, watches or is reminded about never leaves the device,
  except as the TMDB ids of one check, which the Worker does not keep.
- Reminders are worked out from local progress with no request.
- The alert token opens one route, is stored hashed, and dies with its
  session. There are no push tokens and no way for anyone to send another
  user an alert.
- The Worker validates every list (positive integer ids, capped lengths) and
  passes on only the fields the app needs.

## Cost

No new Worker requests: still one per device every 6 hours (4 a day), plus
checks while the app runs. No D1 reads or writes beyond the existing token
lookup. TMDB lookups per check grow by the movies (≤ 30), people (≤ 15) and
collections (≤ 15) asked about, only when those categories are on; they are
the app's own details requests, cached at the edge for 24 hours, so most are
cache hits shared with everyone who opened the same page.

One limit to watch: on the Workers Free plan a request may make at most 50
subrequests. A check with many uncached titles can exceed that, as the
series-only check already could with a long Continue watching; the failed
lookups are skipped, not fatal, and the next check (often from cache) fills
them in.

## Tests

`test/smart_alerts_test.dart` (the rules, quiet hours, summaries, follows,
saved data, the settings page) and `test/episode_alerts_test.dart`;
`backend/test/episode-alerts.test.ts` for the route.
