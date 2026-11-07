# Reelish Supporters

Donors on Buy Me a Coffee receive a permanent Supporter Badge on their Reelish
account. It carries one privilege: hosting a Watch Party. Joining a party, and
everything else in the app, stays open to everyone.

| Piece | Where |
|---|---|
| Webhook, status, review, public list | `backend/src/supporters.ts` |
| Tables | `backend/migrations/0008_supporters.sql` |
| Reviewed grants | `backend/scripts/grant-supporter.mjs` |
| App status | `lib/src/account/supporter_controller.dart` |
| Page and badge | `lib/src/screens/supporters_screen.dart`, `lib/src/widgets/account_badges.dart` |
| Donation link | `SupportConfig.donationUrl` (`REELISH_DONATION_URL`) |

## What Buy Me a Coffee provides

From its [webhook guide](https://help.buymeacoffee.com/en/articles/15743173-how-to-setup-and-use-buy-me-a-coffee-webhooks)
and [OpenAPI schema](https://cdn.buymeacoffee.com/assets/integrations/bmc-webhooks-openapi.json):

- Signed webhooks: `x-signature-sha256`, an HMAC-SHA256 hex digest of the raw
  body. A response is expected within 15 seconds; failed deliveries are retried
  4 times, and a webhook is disabled after 10 consecutive failures.
- A payment id, status, refund state, and `live_mode` (false for dashboard test
  events). `event_id` is 1 for every test event, so it cannot identify one.
- **No custom metadata**, and no documented way to prefill the donation form.
  The only field a donor controls is their message, `support_note`.

`supporter_email` is whatever the donor typed, and Reelish accounts have no
email (sign-in is through Trakt), so it can neither identify nor prove anything.
Display names are not used either.

## How a donation reaches an account

Each account has an opaque code such as `RS-7KMP-3QXA`, made of letters and
digits that are hard to confuse when copied from a TV.

**Automatic, when the code is in the message:**

1. The Supporters page copies the code and opens Buy Me a Coffee.
2. The donor pastes it into their message and donates.
3. The webhook is verified, and the message is searched for a code. The text is
   never stored.
4. A `donations` row is written, and `supporter_since` is set if it is empty.
5. The app picks it up on returning from the browser, on "check again", or the
   next time the profile opens, on any device.

**Reviewed, when the code was forgotten:**

1. The app shows the email to send, to the support address with the code in it,
   and can open an email app. Mail arriving from the donor's address shows they
   own it, which a typed address would not.
2. The donor confirms they sent it, and only then the account shows as pending.
   A request grants nothing. The details stay reachable while pending, and with
   no email app (most TVs) they can be sent from any account.
3. The owner checks that address against the Buy Me a Coffee dashboard, then
   grants the badge:

   ```sh
   cd backend
   node scripts/grant-supporter.mjs --pending --env production
   node scripts/grant-supporter.mjs RS-XXXX-XXXX --env production
   ```

There is no admin endpoint: a grant needs the owner's Cloudflare login. Without
`--env` the script uses staging.

## Rules

- `donation.created`, `recurring_donation.started` and `membership.started`
  qualify, at any amount. Shop purchases, commissions and wishlists do not.
- One badge, with no tiers. Further donations change nothing, and the first date
  stays.
- It never expires, and cancelling monthly support keeps it.
- `donation.refunded` removes it, and the viewer's place on the list, when no
  other donation stands. Otherwise anyone could donate, refund and keep it.
- A reviewed grant is not linked to a payment, so a refund of that donation has
  to be handled by the owner.
- Deleting an account deletes its status; its donations stay, with no account.
  Signing up again is a new account, with no badge.

## Security

- The webhook verifies the signature over the raw bytes, in constant time,
  before reading anything. With no secret it refuses everything (503), and the
  rest of the API is unaffected.
- A session cannot reach a grant: the only writers of `supporter_since` are the
  signed webhook and the script.
- Payment ids make deliveries idempotent, and replays change nothing. A refund
  that arrives first wins.
- Test events are ignored unless `SUPPORTERS_ACCEPT_TEST_EVENTS` is `true`, which
  only staging sets.
- Only a hash of the payment id, the kind, the date and the status are stored:
  no amount, email, name or message. Nothing from the payload is logged.
- The app's saved status is display only. Changing it on a device shows a badge
  on that device alone; the server's answer replaces it, and the public list
  comes from the server.

A leaked code is harmless: its only use is letting someone else pay to give you
a badge. Messages can be public on Buy Me a Coffee, so donors can mark theirs
private: the webhook still delivers a private message, confirmed with a real
donation in November 2026.

## Public list

Off by default. A verified supporter opts in with a name of their choice, and the
list shows that name and nothing else. The month a person joined is returned but
not shown. Photos stay on the device, as everywhere in Reelish.

## Setup

1. Apply the migration and deploy the Worker, staging first
   ([operations](operations.md)).
2. In Buy Me a Coffee, open Integrations › New webhook, with the endpoint
   `https://<api host>/api/v1/webhooks/buymeacoffee` and these events:
   `donation.created`, `donation.refunded`, `recurring_donation.started`,
   `membership.started`.
3. Copy the signing secret into the Worker:

   ```sh
   cd backend && npx wrangler secret put BMC_WEBHOOK_SECRET --env staging
   ```

4. On staging, use **Send test event**, then confirm in the webhook's deliveries
   that it answered 200.
5. Repeat for production, then make one small real donation with a code, check
   the badge, and refund it to check that it goes.

Use a separate webhook for staging and production: each has its own secret.

## Cost

This runs on the Workers and D1 already in use: one Worker request and a few D1
rows per donation, or a page view, against free limits of 100,000 requests and
100,000 row writes a day. Webhooks are a Buy Me a Coffee feature, with no extra
service.
