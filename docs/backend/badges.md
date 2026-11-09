# Account badges

Badges say who someone is, and nothing checks a badge before allowing an action.
What an account may use is its [entitlement](entitlements.md), worked out from
the same sources. Being the Founder carries the Supporter perks that way, without
a Supporter badge. Reelish has no role or admin system, and this is deliberately
not the start of one: anything needing privileges beyond the supporter perks must
have its own check.

| | Founder | Supporter |
|---|---|---|
| Means | The original creator and developer of Reelish | Financially supports Reelish |
| Holders | One account | Anyone who donates |
| Source | The `FOUNDER_TRAKT_UUID` Worker secret | A verified donation ([supporters](supporters.md)) |
| Can be lost | No | Only if every donation is refunded |
| Look | Violet crown | Gold seal |

`GET /api/v1/me` returns `badges`, worked out by `backend/src/badges.ts`:
`['founder', 'supporter']`, or fewer. An account can hold both, and neither
affects the other. The app reads this in `lib/src/account/account_badges.dart`
and keeps a copy per account for offline use. The copy is display only: the
server's answer replaces it. Unknown names are ignored, so a future badge will
not break older apps.

## Why Founder is a secret, not a row

No request can reach a Worker secret, so no API call, profile edit or changed
local data can grant it. There is no table to write to, and no migration.

It holds Trakt's `uuid` (`users.trakt_uuid`), which stays the same through a
username change, and also survives deleting the account and signing up again,
which `users.id` would not. Names and usernames play no part. Without the secret
nobody is Founder and everything else works as usual.

In a Watch Party, others see the crown beside the name. The Worker adds
`X-Party-Founder` when it opens the room's socket, in headers it builds itself,
so nothing a client sends can set it. The room forwards `founder: true`, and
apps without this change ignore it.

## Setting the owner

Run this once per environment, with `SELECT trakt_uuid FROM users` to find the
value; never commit it:

```sh
cd backend && npx wrangler secret put FOUNDER_TRAKT_UUID --env production
```

If a secret is changed, the badge moves at once, on the next `/me`.

## Where it shows

The profile on every interface shows them as identity capsules beside the name
(`FounderBadge`, `SupporterBadge` in `lib/src/widgets/account_badges.dart`). They
share one geometry (`CapsuleMetrics`). The Founder's Sovereign capsule has a violet gradient and
the crown; Supporter has a flat gold tint and the seal. They move below the name
when it needs the room, and each opens the Supporters page. Watch Party participant
lists show the crown. Badge names shrink to fit rather than being cut short.
