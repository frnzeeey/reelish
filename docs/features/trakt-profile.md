# Trakt username and avatar on every device

Every Reelish device signs in with Trakt, so each one knows the account. The
Trakt username and avatar come from Trakt, and the Reelish API keeps them per
account, so every device shows the same ones. That includes a device that
signed in months ago, after the person renamed themselves on Trakt.

## Where it lives

| What | Where | Source |
|---|---|---|
| Username, avatar URL | D1 `users.trakt_username`, `users.trakt_avatar_url` | Trakt `/users/settings` |
| When they were last read | `users.trakt_profile_checked_at` | The API |
| The device's copy | The stored session (secure storage), `username` and `traktAvatarUrl` | GET `/me` |
| The image itself | Flutter's image cache, while the app runs | Trakt's image host |

D1 already holds the accounts, so this adds two columns
(`backend/migrations/0009_trakt_profile.sql`) and no new service. R2 is not
involved: this is a few fields per account, read and updated in place, which is
what a database is for. Only the avatar's URL is stored; the image is never
copied or proxied.

## When it is read

- At sign-in. Trakt's answer is stored at once, and the sign-in response carries
  the avatar, so the new device shows it straight away.
- On GET `/me`, when the stored profile is more than a day old
  (`backend/src/profile.ts`). The app calls `/me` once per launch, after Home
  has drawn, and when the profile opens (`AccountController.fetchMe`, shared
  with the badges).

Most `/me` calls cost one D1 read and no Trakt call. A refresh starts with a
conditional update that claims it, so two devices asking at once make a single
Trakt call. The username and avatar are written only when they changed, and only
when Trakt's answer is for the same Trakt account (`trakt_uuid`).

## When something goes wrong

- Trakt down, an expired grant, or an answer without a username: the stored
  profile is kept, and the next try waits an hour, not until the next request.
- A Trakt account without an avatar gets none, not Trakt's stand-in picture, and
  the app shows the initial. Removing the avatar on Trakt removes it here too.
- The avatar URL is checked on both sides: HTTPS on Trakt's image hosts or
  Gravatar, with no credentials or unusual port. Anything else counts as no
  avatar.
- Offline, the device shows its saved copy. An answer for a different account,
  or one that arrives after sign-out, is ignored.
- Signing out deletes the device's copy with the session. Deleting the account
  deletes the row.

## In the app

Profiles now start with the Trakt picture (`AvatarKind.trakt`), which shows the
initial when there is none. A preset or photo chosen on a device still wins on
that device; those choices, and the display name, stay device-local as before.
Profiles saved before this change stored `initials` whether or not it was
chosen, so that value now means the Trakt picture. An initial chosen from now on
is saved as `initial`.

Watch Party does not send the Trakt picture; others still see presets or the
initial.

## Cost

With D1's free plan (5 million rows read and 100,000 written a day), each active
account costs about one write a day, plus one more when its profile changed, and
a few reads per launch. Trakt sees at most one profile request per account a
day.

Tests: `backend/test/profile.test.ts`, `test/trakt_profile_sync_test.dart`.
