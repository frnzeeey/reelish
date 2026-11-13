# Friends & Activity: free-tier cost analysis

## Limits (checked 2026-11-13)

| Service | Free allowance | Source |
|---|---|---|
| Cloudflare D1 | 5 million rows read a day; 100,000 rows written a day (index writes count); 5 GB storage per account, 500 MB per database; resets 00:00 UTC; queries fail when exceeded | [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/), [D1 limits](https://developers.cloudflare.com/d1/platform/limits/) |
| Cloudflare Workers | 100,000 requests a day, shared by every route of the Reelish API (TMDB gateway, sync, Watch Party, social) | [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/) |
| Firestore (for comparison) | 50,000 reads, 20,000 writes, 20,000 deletes a day on Spark; usage stops when exceeded | [Firestore quotas](https://firebase.google.com/docs/firestore/quotas) |
| Cloud Functions (for comparison) | Requires the Blaze (billing) plan | [Firebase plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans) |

Prices and allowances change; re-check before a release that depends on
them. Nothing here enables billing or upgrades a plan.

**The binding limit is Worker requests**, not D1. Social traffic adds to
the same 100,000 requests a day as the TMDB gateway, which is already the
largest consumer. Measure current daily requests in the Cloudflare
dashboard before release.

## Per active user per day (estimate)

Assumptions: an active user opens the app twice, opens Friends once, plays
two titles, sends one recommendation every other day, and has 15 friends.

| Action | Worker requests | D1 rows read | D1 rows written |
|---|---|---|---|
| Summary on start and return (2×) | 2 | ~10 | 0 |
| Friends page (list + pending) | 1 | ~50 | 0 |
| Watching now | 1 | ~35 | 0 |
| A friend's profile and one shared collection | 2 | ~120 | 0 |
| Inbox | 1 | ~30 | 1 (mark read) |
| Send a recommendation (½ a day) | 0.5 | ~10 | ~3 (row, index, counter) |
| Activity: 2 plays × (start + close), only when sharing is on (assume 30 %) | 1.2 | ~3 | ~5 |
| Friend requests (rare) | 0.1 | ~2 | ~1 |
| **Total** | **≈ 9** | **≈ 260** | **≈ 10** |

Collection visibility adds nothing per day: it travels inside the existing
collection sync.

## Scenarios

Daily active users assumed at 30 % of registered users.

| Registered | Daily active | Social Worker requests / day | D1 rows read / day | D1 rows written / day | Share of Workers free requests |
|---|---|---|---|---|---|
| 100 | 30 | ~270 | ~8 k | ~300 | 0.3 % |
| 500 | 150 | ~1,350 | ~40 k | ~1.5 k | 1.4 % |
| 1,000 | 300 | ~2,700 | ~80 k | ~3 k | 2.7 % |
| 5,000 | 1,500 | ~13,500 | ~390 k | ~15 k | 13.5 % |

D1 stays far inside its limits in every scenario (under 8 % of reads and
15 % of writes at 5,000 users). Storage is negligible: a profile is about
300 bytes, a recommendation about 400 bytes; 5,000 users with 200
recommendations each is under 0.5 GB with indexes, inside the 500 MB
database limit but worth watching. The 180-day recommendation pruning keeps
it bounded.

## What could spike costs, and the guard

| Risk | Guard |
|---|---|
| A live listener per friend | None used; reads only on open or refresh |
| Activity updates on every position | One write at start, one at episode change, one at close; at most one a minute |
| Re-reading whole collections | Paged (200), and only when a collection is opened |
| A friends list of thousands | 500-friend cap, 50 a page |
| Abuse (scripted requests) | Rate-limit bindings, daily counters, unique constraints |
| Many users opening Friends repeatedly | The summary is cached in the app for a few minutes |
| Expired rows piling up | The existing daily cron prunes activity, old requests, old recommendations and counters (a few `DELETE … LIMIT` statements) |

## Firestore comparison (same usage)

At 5,000 users, about 390 k document reads a day if each D1 row read were a
document read, which is about 8× the Spark allowance of 50,000. Firestore
would also need denormalised friend lists for its rules and a second
identity system. That is a further reason to stay on D1.

## When free stops being enough

If Worker requests approach the daily allowance (all routes together), the
next step is the Workers Paid plan, which needs the owner's approval. Before
that: longer client caching of the summary, folding the summary into an
existing request at start, and the TMDB cache (the largest consumer).
