# Reelish Connect

Sharing in Reelish, built on one engine: an app invitation, a friend code, a
movie or series, and a watch party all travel as the same kind of link and
QR code, open the same way, and go through the same server checks.

> A QR code is only a way to carry a link. It never proves anything: every
> code inside it is checked by the server when it is used, exactly as if it
> had been typed.

## What exists, and where

| Piece | Where | Platforms |
|---|---|---|
| Share model (`ShareTarget`: `AppInvite`, `FriendShare`, `TitleShare`, `PartyShare`) | `lib/src/connect/share_target.dart` | all |
| QR encoding, drawing and PNG card (`ReelishQrData`, `ReelishQrCode`, `ReelishQrCard`) | `lib/src/connect/reelish_qr.dart` | all |
| Sharing actions (`ShareService`: link, message, copy, share sheet, share/save card) | `lib/src/connect/share_service.dart` | all |
| The one share dialog (`ShareSheet`) and full-screen code | `lib/src/connect/share_sheet.dart` | all |
| Invitations in the app (`InviteController`) | `lib/src/connect/invite_controller.dart` | all |
| Reelish Connect page (`ConnectScreen`) | `lib/src/connect/connect_screen.dart`, opened from Together | all |
| Incoming links (`PartyLinks` dispatches; `ConnectLinks` holds the rest) | `lib/src/watch_party/party_links.dart`; Home opens them | all |
| Link resolver pages and App Links file | `backend/src/links.ts` | Worker |
| Referrals | `backend/src/referrals.ts`, `backend/migrations/0017_referrals.sql` | Worker |
| Android link intake | `ReelishActivity.kt` (`partyLink`), `AndroidManifest.xml` | Android, TV |
| Windows link intake | `windows/runner/flutter_window.h` (`IsPartyLink`), `main.cpp` (forwarding to the open window) | Windows |
| Share text on Android | `ShareChannel.kt` (`shareText`) | Android phones |

## Decisions

| Question | Decision | Why |
|---|---|---|
| Where links live | The website's address, forwarded to the Reelish API Worker's pages (`/invite/…`, `/movie/…`) | People see Reelish's own address; the Worker is controlled, free tier and rate limited, and already served the party invitation page. The Worker's own address keeps working. |
| QR generation | In the app, with the `qr` package (pure Dart, no network) | No server, no storage, no R2: a code costs nothing to make. |
| Watch party QR | The QR carries the existing 8-digit code | The code is the room's key already. A separate revocable token would add security only if joining by code were turned off, which would break the codes people use. The room's capacity, the host's Remove, ending the party and the room's lifetime still apply. |
| Profile sharing | The friend code (`/add/{code}`), never a public profile page | Friends is opt-in and the server already protects lookups (Found by friend code, blocks, rate limits). A public page would expose people and allow enumeration. |
| Pages | Fixed: they read nothing, fetch no metadata | A page for a code that exists looks the same as one that does not, so links reveal nothing and cost one request. Titles open with their metadata inside the app, through the existing TMDB gateway and cache. |
| Social system | Already built (`backend/src/social/`, Together) | Requests, friendships, blocks, privacy and limits exist; Connect plugs into them rather than adding a second system. |

## Links

| Shares | Web link (on the website, forwarded to the API) | App link |
|---|---|---|
| Reelish, with the inviter's code | `/invite/{code}` | `reelish://invite/{code}` |
| Reelish, no code | `/download` | `reelish://open` |
| A friend code | `/add/{code}` | `reelish://add/{code}` |
| A movie | `/movie/{tmdbId}` | `reelish://movie/{tmdbId}` |
| A series | `/tv/{tmdbId}` | `reelish://tv/{tmdbId}` |
| A watch party | `/party/{code}` (and the earlier `/api/v1/join/{code}`) | `reelish://party/{code}` |

Codes use `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no 0/O, 1/I), 8 long. A movie
and a series with the same TMDB number never meet: the kind is part of the
link. Nothing private is ever in a link.

**Opening a link.** The web link opens the Worker's page. It names what was
shared, shows the code to type when there is one, offers **Open in Reelish**
(the app link) and the download for the visitor's device (a User-Agent guess;
every option is listed anyway). Unsupported devices are told which ones
Reelish runs on. A malformed value gets a plain "not valid" page; nothing
from the URL is echoed into the page.

In the app, `PartyLinks.receive` parses every link with `ShareTarget.parse`
(scheme, kind and value checked; anything else dropped; 128 characters at
most). Party codes go to Join a party, as before. The rest wait in
`ConnectLinks` for Home:

- a title opens its page (`TmdbService.itemById`, cached);
- a friend code opens Add a friend with the code filled in (the request
  still waits for the viewer; with Friends off, Reelish says how to turn it
  on);
- an invitation is kept (`reelish.connect.pendingInvite`) and accepted for
  the signed-in account; a network failure keeps it for the next launch.

**Android.** `reelish://` links with the six kinds open the app. The shared
https links on the production and staging hosts are declared as App Links
(`autoVerify`); they open the app directly once the Worker serves
`/.well-known/assetlinks.json` (`ANDROID_CERT_SHA256`, below). Until then
Android opens the page, whose button opens the app.

**Windows.** The installer registers `reelish:`. A link opened while Reelish
runs goes to that window (WM_COPYDATA), never a second Reelish. Windows
cannot claim https links for a non-MSIX app, so shared web links open the
page first and its button opens Reelish.

**TV.** Nothing on a TV opens links from elsewhere; a TV *shows* codes. Its
share dialog is the code, large, with Close focused for the remote; title
pages and the watch party waiting room have Show QR / Share.

**A link opened before Reelish is installed** shows the page; after
installing, the person opens the link again (the page says so) and the app
takes it from there. Without a store install referrer (Reelish is not in a
store) the destination cannot survive the install by itself.

## QR codes

One component draws every code (`ReelishQrCode`) and one renders the share
image (`ReelishQrCard`, 1080 × 1350 PNG, Living Room colours, the link
spelled out under the code).

Scannability first:

- dark modules (`#14110E`) on light cream (`#F4E9D8`), 15.7 : 1, never
  inverted, in every theme;
- a four-module quiet zone;
- the code holds the link exactly as shared, in lower case. Phone scanners
  offer to open only links they recognise: an earlier version carried the
  link in capitals (QR's compact alphanumeric mode) and phones showed it as
  text to copy. Capital paths still open the right page, since the
  Worker's kinds are case-insensitive;
- error correction Q (25%) keeps every Reelish link at version 5
  (production) or 6 (staging), which have no alignment pattern in the
  centre. A link that would need version 7 or more is drawn plain at H
  (30%);
- the emblem sits in the centre only for versions 2–6 and only when it
  hides at most 10% of the modules (~6–9% for Reelish links, well inside
  Q's 25%); it never touches a finder pattern;
- finder patterns are drawn as rounded squares, the brand shape, at their
  standard proportions.

Tests check the version, the error correction, the logo's coverage and its distance from the
finder patterns for every kind of link on both hosts. A camera scan of the
rendered codes is part of release testing (below).

## Invitations (referrals)

`GET /api/v1/referrals/me` makes the caller's invite code on first ask and
returns how many accounts joined with it. `POST /api/v1/referrals/claim`
credits the caller to the code's owner.

| Rule | How |
|---|---|
| One inviter per account, once | `referrals.referred_id` is the primary key |
| Never yourself | Checked, and a CHECK constraint |
| Only new accounts | Created within 14 days (`claimWindowMs`) |
| No farming | At most 25 credits per inviter per UTC day (`dailyCreditLimit`), logged when hit |
| No guessing codes | Claims share the lookup rate limit; unknown and malformed codes get the same 404 |
| Deleting an account | Cascades: its code and its referrals go |

Nothing is rewarded, so the count is information, not currency. No other
event is stored: the pages log nothing beyond the masked request line
(`/invite/:id`).

## Profiles and privacy

Profile sharing is the friend code, which exists only once Friends is on. A
scan can only start a request; the server still applies Found by friend code
(Friends & privacy), blocks (a blocked person gets the same "not found"),
the daily request limit and the lookup rate limit. Turning Friends off
removes the code; getting a new code retires the old one. Viewing activity
stays off by default. No email, account id, Trakt data, history or settings
is ever in a link or page.

## Watch party

The waiting room's **Show QR code** opens the share dialog for the party's
code; on TV it is the big screen everyone can scan. Joining from a QR code is
joining with the code: the room checks capacity and removals, the host can
remove anyone, and the code ends with the party. Hosting and joining stay
free for everyone.

## The Reelish Connect page

Opened from Together on every interface (Friends on or off), so no new
navigation item. Sections: Invite friends (your invitation's QR and link, who
joined, entering a friend's code), Your friend code (its QR, or how to turn
Friends on), Share movies and series (where Share is), Watch party (Join with
a code). Every row does something real.

## Security assessment

| Threat | Handling |
|---|---|
| QR leads somewhere malicious | The app only reacts to its own `reelish://` kinds and shared paths, parsed strictly; it never opens a URL from a link. The pages contain no script (CSP `default-src 'none'`). |
| Link spoofing or code guessing | Codes are random (32⁸ ≈ 10¹²); lookups and claims are rate limited; unknown, hidden and blocked look identical. |
| Account enumeration | Pages read nothing; friend lookups keep their existing protections; no public profile exists. |
| Unauthorised party access | The room's own checks; a QR carries nothing a typed code does not. |
| Referral abuse | Self, double and late claims refused; a daily cap per inviter; no reward to farm. |
| Injection through the URL | Values are validated against fixed patterns before use; the page escapes everything it prints. |
| Logs | Request lines mask the code or id (`maskPath`). |

## Cost

| Feature | Cost |
|---|---|
| QR codes and cards | None: made on the device |
| Link pages | One Worker request each, no D1 or room access |
| Invite code and count | One small D1 row per account that asks; one indexed count per view |
| Claims | At most one D1 row per account |
| App Links file | One cached request per Android verification |

Everything fits the Workers and D1 free tiers at Reelish's scale. Nothing
uses R2 or Firebase. The only growth with users is D1 rows (two small rows
per inviting account) and page requests.

## Deployment and configuration

1. **Migration.** `npx wrangler d1 migrations apply reelish-staging --remote
   --env staging`, then production before a release that ships the app side
   (`docs/backend/operations.md`).
2. **Worker.** `npm run deploy:staging`, then production when approved.
3. **Android App Links (optional, recommended).** Get the release signing
   certificate's SHA-256 (`apksigner verify --print-certs reelish.apk`, the
   "SHA-256 digest", written as colon-separated pairs) and set it on each
   environment: `ANDROID_CERT_SHA256` as a Worker var. It is public, not a
   secret. Android verifies on install; until it is set, links open their
   page first.
4. **The website.** Shared links and QR codes use
   `https://reelishofficial.netlify.app` (`BackendConfig.shareUrl`; a build
   can set another with `--dart-define=REELISH_SHARE_URL=…`). The website's
   `netlify.toml` (repository `reelish_web-page`) proxies `/invite/*`,
   `/add/*`, `/movie/*`, `/tv/*`, `/party/*`, `/download` and
   `/.well-known/assetlinks.json` to the production Worker with status 200,
   so the address bar keeps the website's name. Every build uses this one
   address: the pages read nothing, and the app checks codes against its own
   API. **Deploy the website before releasing an app that shares these
   links**, or they answer 404. Older links on the API host keep working.

## Status

| Feature | State |
|---|---|
| Share model, link parsing, link pages, QR drawing and card | Implemented |
| Invite links, QR, counts, accepting (link or typed code) | Implemented; needs the migration on each environment |
| Movie and series sharing (phone, TV, Windows title pages) | Implemented |
| Watch party QR | Implemented |
| Friend-code QR and Connect page | Implemented |
| Website domain for links (`reelishofficial.netlify.app`) | Implemented in the app; the website change awaits its deploy |
| Android App Links (https opens the app directly) | Implemented; `ANDROID_CERT_SHA256` set on staging and production |
| Revocable party tokens | Not planned (see Decisions) |
| Public profiles, public watchlists | Not planned: privacy |
| Store install referrer (link survives install) | Blocked: Reelish is not in a store |

## Testing

- `backend/test/connect.test.ts`: every link kind and invalid value, device
  guesses, headers, that pages read nothing, log masking, App Links, every
  referral rule (self, twice, second inviter, late, daily cap, deletion,
  auth).
- `test/reelish_connect_test.dart`: share targets round-trip (web and app,
  capitals, the old party path), foreign links dropped, QR version and logo
  safety for every kind on both hosts, the PNG card, share text, invitation
  accepting and keeping, the Connect page, the dialog on phone/Windows and
  TV, a build without an API.
- Release testing: scan each kind of code from a phone camera off a phone,
  a TV and a Windows screen, in dim and bright light.
