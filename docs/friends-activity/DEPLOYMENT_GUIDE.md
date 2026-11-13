# Friends & Activity: deployment guide

How to take Friends from staging to production. Production is changed only
when the owner says so ([CLAUDE.md](../../CLAUDE.md)); staging already runs
everything below.

## What production needs

| Item | State on staging | Production |
|---|---|---|
| Migration `0011_playback_progress.sql` (Continue watching sync) | Applied | Not yet |
| Migration `0012_collection_records.sql` (collection sync) | Applied | Not yet |
| Migration `0013_social.sql` (Friends) | Applied | Not yet |
| Rate-limit bindings `SOCIAL_LIMITER` (3006), `SOCIAL_LOOKUP_LIMITER` (3007) | Bound | In `wrangler.toml` `[env.production]`; bound on deploy |
| Worker with `src/social/` | Deployed | Not yet |
| New secrets | None | None |

The migrations are additive (new tables, one column with a default), so an
app version without Friends keeps working against a migrated database.

## Order

1. Check the free allowances still hold (see
   [the cost analysis](FREE_TIER_COST_ANALYSIS.md) and the Cloudflare
   dashboard's daily Worker requests).
2. Apply the migrations, oldest first (Wrangler applies only the missing
   ones):

   ```sh
   cd backend
   npx wrangler d1 migrations apply reelish-production --remote --env production
   ```

3. Deploy the Worker:

   ```sh
   npx wrangler deploy --env production
   ```

4. Smoke test without a session; every Friends route should answer 401:

   ```sh
   curl -s -o /dev/null -w "%{http_code}\n" https://reelish-api.frnzgularez.workers.dev/api/v1/social/profile
   ```

5. Release the app (CI from a version tag, [releasing](../releasing.md)).
   The backend must be live first: an app with Friends against a backend
   without it shows Friends as unavailable, and nothing else is affected.
6. With two accounts on the released app: turn Friends on, add by code,
   accept, share a title, share a collection, turn on *Share what I'm
   watching* and play something, then turn Friends off on one and check the
   other loses everything.

## Rolling back

- App: the previous release has no Friends entry; data stays on the server.
- Worker: `npx wrangler rollback --env production` to the previous
  version; the Friends routes then answer 404 and the app shows them as
  unavailable.
- Database: the tables can stay. Nothing outside `src/social/` reads them,
  except account deletion (cascade) and the daily prune.

## After release

- The daily cron (03:17 UTC) prunes held handles, old requests and
  recommendations, expired activity and old counters.
- Reports about people arrive in `support_reports` with `kind = 'person'`
  ([operations](../backend/operations.md) covers reading reports).
- Watch for 429s on `/social/requests` in Workers Logs (paths are logged
  with `:handle`, never the handle).
