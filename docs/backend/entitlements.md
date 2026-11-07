# Entitlements

What an account may use is decided in one place on the server,
`backend/src/entitlements.ts`. The app reads the answer; it never works out an
entitlement itself.

| Entitlement | Who | What they get |
|---|---|---|
| `free` | Every signed-in account | Every free feature |
| `supporter` | A verified, unrefunded donation ([supporters](supporters.md)) | Free, plus every supporter perk |
| `founder` | The Trakt account named by the `FOUNDER_TRAKT_UUID` secret ([badges](badges.md)) | Supporter, plus the Founder identity |

The Founder inherits the Supporter entitlement as a whole. No perk names the
Founder, so a perk added later reaches the Founder with no extra work. The
Founder never needs to donate. If they do, they are still `founder`, and they
also get the Supporter badge they earned.

## The perks

| Perk | Server | App |
|---|---|---|
| `host_watch_party` / `hostWatchParty` | `createParty` calls `requirePerk`: 403 `supporter_required` | The create screen shows the room settings or the Supporter prompt |
| `app_themes` / `appThemes` | Nothing to enforce: a theme is only ever seen by its owner | Settings > Appearance offers the themes; the accent and profile card follow the chosen one |
| `app_icons` / `appIcons` | Nothing to enforce: the icon is a device setting | Applying a supporter icon asks the server afresh first |

## How the app knows

`GET /api/v1/supporters/me` returns `entitlement` beside the donation's own
`status`. A Founder who never donated reads `status: none, entitlement:
founder`, so the Supporters page stays honest about the donation.
`SupporterController.entitlement` keeps the last answer per account, so it shows
at once and offline, and `SupporterController.has(SupporterPerk)` is the only
check a feature makes. An older API, or a status saved before entitlements,
falls back to the donation: verified means `supporter`.

The saved copy only decides what to show. The server enforces what it can.
A supporter app icon is applied only after a fresh answer, so a saved or edited
status, an unreachable server or a signed-out device never unlocks one. The copy
is per account and is replaced as soon as the server answers, so one account's
entitlement never shows for another.

## Badges are not entitlements

Badges are what others see. No check reads a badge: features check the
entitlement, and the entitlement reads the same sources (the donation record and
the Founder secret) directly. A Founder who has not donated has the Founder
badge only. They get the Supporter perks through the entitlement, not a Supporter
badge.

## Adding a supporter perk

1. Name it in `SupporterPerk` in `backend/src/entitlements.ts` and in
   `SupporterPerk` in `lib/src/account/supporter_controller.dart`.
2. Where the server can enforce it, call
   `requirePerk(env, userId, '<perk>')`.
3. In the app, gate it on `SupporterController.has(SupporterPerk.<perk>)`.

Never check `isSupporter`, a badge or the Founder for a perk. `isSupporter`
means a verified donation, which is for the Supporters page and the badge.

Tests: `backend/test/entitlements.test.ts`, `test/entitlements_test.dart`.
