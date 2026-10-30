# Reelish API operations

Setting up, deploying and running the Reelish API. Architecture and the
API reference are in [the backend overview](README.md).

## Accounts and credentials needed

| What | Where to get it | Stored as |
|---|---|---|
| Cloudflare account | dash.cloudflare.com | — |
| Trakt application | trakt.tv → Settings → Your API Apps → New. Redirect URI `urn:ietf:wg:oauth:2.0:oob` (device flow) | `TRAKT_CLIENT_ID`, `TRAKT_CLIENT_SECRET` Worker secrets |
| TMDB API Read Access Token | themoviedb.org → Settings → API | `TMDB_READ_TOKEN` Worker secret |
| Session signing key | `node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"` | `SESSION_SIGNING_KEY` Worker secret |
| Token encryption key | same command, a different value | `TOKEN_ENCRYPTION_KEY` Worker secret |

Use separate Trakt applications, TMDB tokens and keys for staging and
production. Never put a real value in `wrangler.toml`, the repository, an
issue or a log.

## First setup

```sh
cd backend
npm ci
npx wrangler login
npx wrangler d1 create reelish-staging        # copy database_id into wrangler.toml [env.staging]
npx wrangler d1 create reelish-production     # copy database_id into wrangler.toml [env.production]
for name in TMDB_READ_TOKEN TRAKT_CLIENT_ID TRAKT_CLIENT_SECRET SESSION_SIGNING_KEY TOKEN_ENCRYPTION_KEY; do
  npx wrangler secret put "$name" --env staging
done
npx wrangler d1 migrations apply reelish-staging --remote --env staging
npx wrangler deploy --env staging
```

Then give the Worker a route or custom domain (for example
`api.example.com`) in the Cloudflare dashboard, and repeat for production.

GitHub (Settings → Secrets and variables → Actions):

- Variable `REELISH_API_URL`: the production API origin, e.g.
  `https://api.example.com`. The release workflows compile it into the
  app and fail if it is missing or not HTTPS.
- Environments `staging` and `production` (production with required
  reviewers), each with secret `CLOUDFLARE_API_TOKEN` (Workers Scripts:
  Edit and D1: Edit, this account only), variable `CLOUDFLARE_ACCOUNT_ID`,
  and variable `REELISH_API_URL` for its health check.
- The old `ONFEED_TMDB_API_KEY` secret is no longer used by any workflow.

## Local development

```sh
cd backend
cp .dev.vars.example .dev.vars   # fill in staging values
npm test                         # workerd + local D1, Trakt/TMDB faked
npx wrangler dev                 # http://127.0.0.1:8787
```

The app refuses local and non-HTTPS hosts (its network policy blocks
them), so run the app against the staging deployment:

```sh
flutter run --dart-define=REELISH_API_URL=https://staging-api.example.com
```

## Deploying

Deploys go through the `Backend` workflow: Actions → Backend → Run
workflow → environment. It typechecks, tests, applies D1 migrations,
deploys and checks `/health`. Deploy staging first, sign in from a staging
build, then deploy production.

Order matters when the app gains a new TMDB request: deploy the API with
the allowlist change first, then release the app.

Migrations must stay backward compatible with the running Worker (add
columns and tables; do not drop or rename in the same release).

## Rollback

- **Worker:** `npx wrangler rollback --env production` returns to the
  previous version (`npx wrangler deployments list --env production` lists
  them). Secrets are unaffected.
- **Database:** D1 Time Travel restores to any minute in the last 30 days:
  `npx wrangler d1 time-travel restore reelish-production --timestamp=<ISO time>`.
  It replaces the whole database, so sessions issued since then are lost
  (users sign in again).
- **App:** the API keeps `/api/v1` stable; an older app keeps working
  across Worker rollbacks.

## Backups

D1 Time Travel is always on (30 days on the paid plan, 7 on free). For an
off-platform copy: `npx wrangler d1 export reelish-production --remote
--output=backup.sql`, stored encrypted outside the repository. The export
contains encrypted Trakt tokens and hashed refresh tokens; treat it as
sensitive.

## Credential rotation

| Credential | How | Effect on users |
|---|---|---|
| `TMDB_READ_TOKEN` | Create a new token at TMDB, `wrangler secret put`, then revoke the old one | None |
| `TRAKT_CLIENT_SECRET` | Regenerate in the Trakt app, `wrangler secret put` | Pending sign-ins fail; stored Trakt tokens keep working |
| `SESSION_SIGNING_KEY` | Move the current value to `SESSION_SIGNING_KEY_PREVIOUS`, put a new `SESSION_SIGNING_KEY`; remove the previous one after 15 minutes | None (both verify meanwhile) |
| `TOKEN_ENCRYPTION_KEY` | No dual-key support yet: rotating it makes stored Trakt tokens unreadable, so users must sign in again. Rotate only on compromise | All users sign in again |
| Old embedded TMDB key | Revoke it at TMDB once most installs run a gateway build (see below) | Apps older than the gateway release stop loading the catalog |

**Retiring the embedded key.** Releases before the gateway carry the TMDB
key in the app. After the first gateway release, watch adoption (the
in-app updater offers it), then revoke the old key at TMDB. Until then the
old key remains extractable from old APKs and installers.

## Monitoring

Workers Logs (enabled in `wrangler.toml`) receive one JSON line per
request (`event: "request"`: method, path, status, ms, requestId) and per
upstream call (`tmdb.upstream`). Search by the `X-Request-Id` a user
reports. Worth alerting on (Cloudflare notifications or a Logpush
destination):

- `tmdb.credential_rejected`: the TMDB token was revoked or is wrong.
- `request.failed`: unexpected errors (also covers missing secrets).
- A rise in 429s (`rate_limited`, `upstream_busy`) or 5xx.
- `session.refresh_reuse` audit events: possible stolen refresh tokens.

Never log tokens, authorization codes, device codes or query strings;
the code logs paths and ids only.

## Incidents

| Symptom | Check | Action |
|---|---|---|
| Catalog empty for everyone | Logs for `tmdb.credential_rejected` or `upstream_unavailable` | Rotate `TMDB_READ_TOKEN`; check TMDB status |
| Sign-in fails | Logs for `trakt.device_code_failed` / `trakt.unreachable` | Check Trakt status, client id/secret |
| Everyone signed out | Was `SESSION_SIGNING_KEY` changed without keeping the previous key? | Restore it as `SESSION_SIGNING_KEY_PREVIOUS` |
| Suspected database leak | — | Rotate `TOKEN_ENCRYPTION_KEY` and `SESSION_SIGNING_KEY` (both, no previous), `TRAKT_CLIENT_SECRET`; users sign in again |
| Abuse from one account | `audit_events`, logs by user | Revoke its sessions (`UPDATE sessions SET revoked_at = unixepoch() WHERE user_id = ?` with `wrangler d1 execute`) |

## Costs

| Usage | Workers | D1 | Notes |
|---|---|---|---|
| Development | Free (100k requests/day) | Free (5M rows read/day) | — |
| Small production (≈1k daily users, ~150 requests each) | Free tier at the limit; Workers Paid $5/month gives 10M requests | Free | Edge cache serves most catalog requests |
| Growth (≈20k daily users) | ~$5 + $0.30 per extra million requests | Free to a few $/month | TMDB per-IP limits matter more than cost |

On the free plan, requests beyond the daily limit fail until the next
day; the paid plan avoids that. TMDB's API is free for non-commercial use
under its terms, which still apply when the key is hidden; check them
before any commercial use.
