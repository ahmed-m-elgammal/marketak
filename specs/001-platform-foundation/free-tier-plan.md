# Free-Tier Longevity Plan

The question this answers: **how do I keep the free tier for as long as possible without the app
breaking?**

Answer in one paragraph: by treating bytes as a budget. Every design decision below either moves
bytes out of Postgres and out of the metered Supabase egress path, or eliminates a metered
dimension entirely. But the plan is honest about the ceiling — with a single city and a lunch
peak, **the free tier is a build-and-beta tool, not a scale tool**, and the $25 Pro payment is
triggered by order volume, not by features. This document gives the exact trigger.

Assumptions: 4,000 sessions/day, 500 orders/day in the ramp case and 2,000 orders/day in the lunch
peak case, 1.6 vendors and 3 items per order, 150 vendors, 60 riders, 20,000 menu items. All
figures are modelled from row and index sizes, not measured. Re-measure after week 1.

---

## 1. Every cap, ranked by when it will actually hurt

| Resource | Free cap | When it breaks | Verdict |
|---|---|---|---|
| **Postgres disk** | 500 MB | ~59,000 orders un-archived, ~142,000 archived | **The wall.** Everything else is decoration. |
| **Supabase egress** | 5 GB/month | Immediately, if images come from Supabase and apps poll | Fixable by design |
| **Cloudflare DO duration** | 13,000 GB-s/day | At ~1,100 orders/day with a 15 s ping interval | **Cut live tracking in v1** |
| **Supabase CPU** (shared, ~0.5 vCPU) | not published | Lunch peak, before disk ever fills | The real runtime constraint |
| Workers requests | 100,000/day | Never, if events are batched; ~35,000 naive | Fixable by design |
| DO rows written | 100,000/day | ~2,500 orders/day if every ping is persisted | Fixable by design |
| DO requests | 100,000/day | Never | Fits |
| R2 storage | 10 GB | ~10 months at 2,000 orders/day of archive | Fits, and cheap when it doesn't |
| R2 reads / writes | 10M / 1M per month | Never | Fits |
| Supabase Realtime | 200 connections | The first busy Friday | Not used |
| Edge Functions | 500,000 calls/month | Never | Not used in v1 |
| Firebase FCM / Crashlytics / Analytics | No hard cap | Never | Fits |
| Free-plan project pause | 7 days idle | Only on an unused dev project | Annoying, not dangerous |

Only two of these need engineering: **database size** and **egress**. One needs a product
decision: **whether live tracking ships at all**.

---

## 2. Lever 0 — the two facts that decide everything

### Fact 1: Cloudflare egress is free. Supabase egress costs.

This single asymmetry determines the architecture. Any byte you can serve from R2, or push through
a Durable Object, is a byte you stop paying for. Images, menu snapshots, the vendor feed and live
tracking are all on the free path *specifically because* they are moved off Supabase.

Corollary: **live tracking via Durable Objects is cheaper than polling Supabase**, not just
better. Polling is the expensive option.

### Fact 2: Only one number actually matters — bytes per order.

Every database decision reduces to this. Measured at 6.9 KB per order fully indexed with complete
status history. The scenarios below show what moves it.

---

## 3. Database size: the arithmetic

400 MB is the working ceiling (500 MB minus headroom for bloat and TOAST). 400 MB = 409,600 KB.

### 3.1 Bytes per order, itemised

| Table | Rows/order | Bytes/row incl. indexes | Bytes/order |
|---|---|---|---|
| `orders` | 1 | 930 | 930 |
| `sub_orders` | 1.6 | 420 | 672 |
| `order_items` | 3.0 | 506 | 1,518 |
| `order_status_history` | 8.0 | 310 | 2,480 |
| `ledger_entries` | 2.2 | 470 | 1,034 |
| `reviews` | 0.4 | 350 | 140 |
| `voucher_redemptions` | 0.3 | 300 | 90 |
| **Retained total** | | | **6,864 B ≈ 6.9 KB** |

`order_status_history` is 36% of the whole cost, at 310 bytes a row for eight tiny rows. This is
the counter-intuitive finding: **the audit trail costs more than the order.**

### 3.2 Scenario A — a typical implementation, nothing pruned

| Also retained | Bytes/order |
|---|---|
| Retained total | 6.9 KB |
| `events` (7/order, never pruned) | 2.8 KB |
| `notifications` (6/order, never pruned) | 2.4 KB |
| `rider_location_pings` (20/order, 30-day window) | 4.0 KB |
| `order_eta_snapshots` (3/order, never pruned) | 0.75 KB |
| **Total** | **16.85 KB** |

**24,300 orders. 49 days at 500/day. 12 days at 2,000/day.**

This is the scenario that kills a free-tier launch, and it is what you get by simply not writing
the pruning jobs. Every one of those four tables is a firehose that nobody notices until the disk
is full at 3pm on a Saturday.

### 3.3 Scenario B — prune transients, keep all order rows forever

Prune `events` (7d), `notifications` (30d), `rider_location_pings` (30d), `order_eta_snapshots`
(24h).

**6.9 KB/order → 59,400 orders → 119 days at 500/day, 30 days at 2,000/day.**

Pruning alone is a 2.4× improvement and it is nearly free to implement. It is not enough.

### 3.4 Scenario C — prune transients + archive order detail to R2 at 60 days

At 60 days, move `order_items` and `order_status_history` to
`private/archive/orders/YYYY/MM/{order_id}.json` in R2 and delete them from Postgres. The `orders`
and `sub_orders` rows stay, so totals, statuses, addresses and per-vendor payouts remain queryable
forever. Details come back through a signed URL when the customer opens an old order or an admin
opens a dispute.

Retained per order: 930 + 672 + 1,034 + 140 + 90 = **2,866 B ≈ 2.9 KB**

**142,700 orders → 285 days at 500/day, 71 days at 2,000/day.**

### 3.5 Summary

| Scenario | KB/order | Cumulative orders | 500/day | 2,000/day |
|---|---|---|---|---|
| A — no pruning | 16.9 | 24,300 | 49 days | 12 days |
| B — pruning only | 6.9 | 59,400 | 119 days | 30 days |
| C — pruning + archive | **2.9** | **142,700** | **285 days** | **71 days** |
| C + on-demand `order_items` only (history kept 90d) | 3.7 | 110,000 | 220 days | 55 days |

### 3.6 The honest conclusion

**"Retained indefinitely" and "free tier" are not simultaneously satisfiable at scale.** Even
Scenario C gives 71 days at peak volume. Archiving is not an optimisation here — it is the only
way the retention requirement in `spec.md` §9 can be honoured at all, and it buys 2.4× over naive
pruning.

Two further reductions, if needed, in order of preference:

1. **`order_status_history` to 90 days, then archived.** Saves 2.5 KB/order → 3.5 KB/order
   → 117,000 orders. Disputes rarely reference a nine-month-old transition, and the archived copy
   still exists.
2. **`ledger_entries` stays in Postgres forever, no matter what.** A balance must be computable at
   any time. If this table ever threatens the limit, the answer is Supabase Pro, not archiving. Do
   not archive the ledger.

### 3.7 Operational rules that keep Scenario C true

| Rule | Why |
|---|---|
| Every table above has a named `pg_cron` prune job with an index on the prune column | Un-indexed prune queries are themselves a load problem |
| Prune in batches (`limit 1000`) with a short `pg_sleep` between batches | A single `DELETE` of 2M rows locks and bloats |
| Nightly `VACUUM ANALYZE` on the highest-churn tables | Free-tier IOPS are limited; bloat is the silent killer |
| Alert at 350 MB (70%) | Time to react before customers cannot order |
| Weekly `pg_total_relation_size` report per table | The first sign of rot is one table far larger than its estimate |
| A dead-letter count on `events` older than 1 hour | If pruning runs, the dispatcher is broken and you will not see it |

---

## 4. Egress: the second wall

5 GB/month = ~170 MB/day.

### 4.1 Where the bytes go at 2,000 orders/day

| Path | Volume | Note |
|---|---|---|
| Auth token refresh | 8 MB | Unavoidable |
| `get_flags_v1` × 2 per session | 12 MB | Trim response to active flags only |
| Feed manifest (R2 pointer) | 4 MB | 250 B per call |
| `get_vendor_feed_v1` first page | 29 MB | Only on cache miss |
| `quote_order_v1` | 34 MB | 4 calls per checkout; trim response |
| `place_order_v1` | 12 MB | |
| `transition_order_v1` | 16 MB | 8 per order |
| **Subtotal: necessary** | **115 MB/day** | **3.4 GB/month** |
| Order status polling, 45 s, foreground only | 81 MB | **Remove** |
| Rider availability polling, 60 s | 108 MB | **Remove** |
| Vendor dashboard polling, 60 s | 86 MB | **Remove** |
| **Subtotal: polling** | **275 MB/day** | **8.2 GB/month** |
| **Total as naively built** | **390 MB/day** | **11.7 GB/month — 2.3× over** |

### 4.2 What to cut

| Fix | Saves/day | How |
|---|---|---|
| Customer status updates by push, not polling | 81 MB | FCM carries the state. The app re-reads once on foreground |
| Rider availability via Durable Object `BranchInbox` fan-out, poll every 180 s at most | 96 MB | DO egress is free |
| Vendor dashboard via Durable Object, no polling at all | 86 MB | This is what `BranchInbox` is for |
| `quote_order_v1` on cart commit, not per keystroke | 17 MB | Debounce 800 ms, and quote once at checkout entry |
| `quote_order_v1` returns totals + per-vendor breakdown, not full items | 16 MB | 3 KB → 1 KB response |
| `transition_order_v1` returns `{order_id, status}` only | 8 MB | |
| Rider list returns 10 nearest, minimal fields | 12 MB | Never ship the menu in a list response |
| **Total saved** | **316 MB/day** | |
| **New total** | **~74 MB/day** | **2.2 GB/month** |

**Result: 2.2 GB/month against a 5 GB cap. 56% headroom.**

### 4.3 The one non-negotiable egress rule

**Images must never be served from Supabase Storage.**

20,000 items × 40 KB × (any realistic impression count) is 30–170 GB/month against a 5 GB cap.
Serving them from R2 behind the Cloudflare CDN makes the same traffic free. On-device resize and
WebP compression before upload is what keeps the storage side small; R2 is what makes the delivery
side free.

The same applies to the vendor feed: **serve it as an R2 snapshot with a version pointer**, not as
a PostgREST query. A 40-vendor page is ~48 KB; at 4,000 sessions × 4 feed loads per session that
is 768 MB/month from one screen. As a 250-byte manifest it is 12 MB/month. A 64× difference on
the second most-used screen in the app.

---

## 5. Cloudflare Workers

100,000 requests/day, hard stop with no overage.

### 5.1 Naive approach

| Call | Count/day |
|---|---|
| Database webhook, one per `events` row (7 per order) | 14,000 |
| `mark_event_delivered_v1` callback | 14,000 |
| `tracking-gate` WebSocket upgrades (2 per order) | 4,000 |
| Cron triggers (3) | 4,320 |
| Menu snapshot rebuilds | 3,000 |
| Upload signing | 2,000 |
| **Total** | **41,320/day** — 2.4× headroom |

It fits, but it wastes 14,000 requests/day confirming deliveries, and it leaves too little margin
for a viral Friday.

### 5.2 Recommended: split the event path by urgency

| Path | Events | Mechanism | Requests/day |
|---|---|---|---|
| **Critical** — must be immediate | `order.placed` (vendor must see it now), `driver.assigned` | Database webhook → Worker | 4,000 + 4,000 marks = 8,000 |
| **Bulk** — 15 s delay is acceptable | `order.status_changed` (customer push), `menu.updated`, `promo.*` | `pg_cron` every 15 s, `claim_events_v1(50)` | 288 + 288 = 576 |
| Tracking gate | — | WebSocket upgrades | 4,000 |
| Cron triggers | — | — | 4,320 |
| Snapshot rebuilds, uploads | — | — | 5,000 |
| **Total** | | | **~21,900/day — 4.5× headroom** |

**Better: drop the per-event mark callback entirely.** The webhook Worker marks its whole claimed
batch in one RPC at the end of the invocation, and the cron sweep marks anything delivered more
than an hour ago. That removes 4,000 requests/day and makes the mark idempotent by construction.

### 5.3 CPU limit: 10 ms per request

This is tighter than it looks and it is the constraint most likely to bite first.

| Task | Budget | Risk |
|---|---|---|
| Verify a Supabase JWT with WebCrypto | ~1–2 ms | Safe |
| Sign a Google JWT for FCM (RSA) | ~3–5 ms | **Tight.** Cache the access token for 55 minutes so signing is rare |
| Render a template | < 0.5 ms | Safe |
| FCM HTTP call | I/O, not CPU | Free |
| `JSON.parse` of a 50-event batch | ~1 ms | Safe |

**Rules:** never do JSON work in a Worker on data that Postgres can aggregate; never fetch a menu
through a Worker; cache the Google token; and if FCM signing proves unreliable under load, move
push delivery into a Supabase Edge Function, where the 500,000-call/month free quota is already
reserved and unused.

---

## 6. Durable Objects — the decision to cut live tracking in v1

Free: 100,000 requests/day · 13,000 GB-s/day duration · 100,000 rows written/day · SQLite only.

### 6.1 At 2,000 orders/day with 15-second pings

| Dimension | Usage | Cap | Headroom |
|---|---|---|---|
| Requests | ~4,000 connections + 8,000 billed messages (160,000 at 20:1) = 12,000 | 100,000 | 8× |
| Rows written | 160,000 if every ping is persisted | 100,000 | **Over** |
| Duration | 160,000 messages × ~1 s resident × 0.128 GB = 20,480 GB-s | 13,000 | **Over** |

### 6.2 Three fixes, each of which degrades something

| Fix | Result | Cost |
|---|---|---|
| Persist one location row per minute, not per ping | 40,000 rows/day | Fits. Coarser replay only |
| Raise the ping interval to 30 s | 10,240 GB-s/day | Fits at 79% of cap. Smoother tracking becomes steppier |
| Do not persist at all; keep the latest point in the hibernation attachment | ~0 rows | Route replay is lost; acceptable in v1 |

With all three: **12,000 requests, 0–40,000 rows, 10,240 GB-s. It fits — at 79% of the scarcest
Cloudflare resource.**

### 6.3 The recommendation

**Do not ship live tracking in v1.** Not because it does not fit, but because it consumes 79% of
the dimension you have least room in, in exchange for a feature that push notifications already
cover adequately for a 30-minute delivery.

Keep all of it and lose nothing:

- Build `OrderRoom` and `tracking-gate` in Phase 3, not Phase 1.
- Ship `live_tracking_enabled = false` as the seeded default, controlled server-side by area.
- Keep the rider ping loop in the rider app behind the flag, so switching it on needs no release.
- Keep `rider_location_pings` and the DO schema so activation is configuration.

Then the entire Durable Objects line item drops to zero, the 13,000 GB-s cap becomes irrelevant,
and the free tier's tightest constraint moves to something with 4× headroom.

**Turn it on when:** DO duration is the constraint, and at 2,000 orders/day it is. At 500
orders/day with 30-second pings, live tracking costs ~2,500 GB-s/day and fits comfortably — so
**live tracking is affordable during the ramp and unaffordable at peak.** That is the trigger.

---

## 7. Supabase compute — the constraint nobody prices

The free plan runs on shared, small CPU. It has no published number, which makes it the hardest
cap to plan against and the most likely to produce a 3pm incident that looks like "the app is
down" and is actually "the free database is CPU-starved".

Peak concentration is the problem. 2,000 orders in three hours is 11 orders/minute, each involving
a quote, a placement, ~8 transitions and several dashboard reads. Add 150 vendor dashboards and 60
riders and the free plan's CPU is the binding constraint well before the disk fills.

| Mitigation | Effect |
|---|---|
| Everything is an RPC, never Edge Functions | Fewer connections, fewer network hops, no cold starts |
| Never poll from an open app | Removes ~340 concurrent requests during peak |
| Menu and feed from R2 | Removes the heaviest read path from the database entirely |
| `pg_cron` batches instead of per-row webhooks | Removes 14,000 HTTP calls/day |
| Connect server-side through the **connection pooler**, never the direct database URL | Workers, Pages and cron must not consume the direct-connection pool, or bursts will exhaust it |
| Cap `work_mem` and connection count per role | Prevents one runaway query from starving the pool |
| Read-only replicas are not available on Free | Accept it; keep queries indexed |

**This is the strongest practical argument for Pro before real money**, and it is not about disk
or backups. It is that a lunch peak on shared CPU with real orders in it is a customer-facing
outage.

---

## 8. The plan, ranked by impact

| # | Lever | Effect | Effort | Risk if skipped |
|---|---|---|---|---|
| 1 | **Do not ship live tracking** | Removes DO entirely: 13,000 GB-s, 100,000 rows, 100,000 requests → 0 | Medium (defer Phase 3) | Free-tier CPU and Cloudflare pressure at peak |
| 2 | **Archive `order_items` + history to R2 at 60 days** | 6.9 → 2.9 KB/order, **2.4×** | Medium | Disk full in ~4 weeks at peak |
| 3 | **Prune `events`, `notifications`, `pings`, `eta_snapshots`** | Removes 9.9 KB/order of transients, **2.4×** | Low | Disk full in ~2 weeks |
| 4 | **Images on R2 + CDN, never Supabase Storage** | Egress 170 GB → 0 | Medium (already designed) | **2–3× over the egress cap immediately** |
| 5 | **Vendor feed as an R2 snapshot, not a PostgREST query** | Egress 768 MB → 12 MB/month | Medium | Egress cap exceeded by the second most-used screen |
| 6 | **Zero polling from open apps** | Egress −275 MB/day | Low | 2.3× over the egress cap |
| 7 | **Batched `pg_cron` event drain + one mark per batch** | Workers 41,000 → 18,000/day | Low | Little headroom for a viral Friday |
| 8 | **Persist one location row per minute, not per ping** | DO rows 160,000 → 40,000 | Low | Over cap whenever tracking is on |
| 9 | **Daily rollups instead of row-level analytics** | Avoids ~4 GB/month of raw events | Medium | Retention requirements physically impossible |
| 10 | **RPC only, no Edge Functions** | Keeps 500,000 free calls unused; fewer connections | None (already the plan) | — |
| 11 | **0% commission = fewer ledger rows** | ~0.8 KB/order saved vs a commission-active design | None | — |
| 12 | **One city, lunch-only** | Smaller catalog, fewer snapshot rebuilds, tighter peak | None | — |
| 13 | **Pooler for all server-side Supabase calls** | Prevents connection exhaustion | Low | Bursty 500s under peak |
| 14 | **70% alerts on every cap + weekly size report** | Turns every cliff into a warning | Low | You find out at 3pm on a Saturday |

### What levers 1–13 buy, together

| | Free tier, no levers | Free tier, all levers | Supabase Pro |
|---|---|---|---|
| Cumulative orders before disk wall | 24,300 | **142,700** | Effectively unlimited at launch volumes |
| Wall clock at 500 orders/day | 49 days | **285 days** | n/a |
| Wall clock at 2,000 orders/day | 12 days | **71 days** | n/a |
| Egress | 11.7 GB/month (**2.3× over**) | **2.2 GB/month** | 250 GB included |
| Cloudflare DO | Over cap on 2 of 4 dimensions | **Unused** | Unused |
| Workers requests | 41,000/day | **18,000/day** | Unlimited at $5 |
| Peak CPU | Over budget | **Still over budget** | Comfortable |

The last row is the point. **Levers 1–13 buy you months of headroom on storage and egress, and
nothing at all on peak CPU.** No amount of architecture fixes a shared-CPU plan under a lunch peak.

---

## 9. The upgrade trigger — one number, three conditions

Pay the $25 for Supabase Pro when **any** of these is true:

1. **Postgres disk above 350 MB** (70% of 500 MB). Check weekly.
2. **Cumulative orders above ~40,000** with real money in the ledger. At that point archiving is
   already running and you want the disk headroom, not the risk.
3. **First real cash in the system.** This is not a technical trigger, it is a judgement trigger,
   and it is the one that matters. Daily backups, no pausing and 8 GB of disk are worth $25 the
   moment a rider is holding EGP 3,000 of the platform's money.

Do **not** upgrade for: more features, more analytics, better search, or live tracking. None of
those are blocked by the free tier.

After Pro, in order, when each becomes real:

| When | Buy | Cost |
|---|---|---|
| Workers above ~80,000 requests/day | Workers Paid | $5/month |
| R2 above ~50 GB of archive | Pay-as-you-go R2 | ~$0.75/month |
| Wallet balances need point-in-time recovery | PITR add-on | from $100/month — decide before the first balance, because PITR is only useful if enabled *before* the incident |
| Supabase CPU saturated on Pro | Larger compute | $15–60/month |

**Expected cost: $0 through build and closed beta. $25/month from first real money to roughly
1,500 orders/day. $45–60/month at sustained peak.** Firebase and R2 stay effectively free
indefinitely.

---

## 10. What is deliberately given up to stay free

Stated plainly, because a spec that only lists benefits is not making a decision.

| Given up | Why it is acceptable |
|---|---|
| Live driver tracking in v1 | Push notifications plus an honest ETA cover a 30-minute delivery. Re-enablable per area by flag |
| Row-level audit log | Daily aggregates plus R2 monthly exports. Free tier has no audit log at all; this is strictly better |
| Row-level search and auth analytics | Daily rollups plus Firebase's own retention. Meets the 1-year and 365-day requirements at a few hundred rows per day |
| Instant in-app flag propagation | Fetched at cold start and on foreground. Acceptable for kill switches; business rules are in the database anyway |
| Point-in-time recovery | Nightly export to R2 as the interim. Must be restore-tested before launch, not just written |
| Seven days of push-notification history | Push is transient by nature. In-app `notifications` keeps 30 days |
| Multi-region | Single city, single region, chosen closest to the operating city |

---

## 11. Weekly review checklist

Run this every Monday. It is the whole operational cost of the free tier.

| # | Check | Threshold |
|---|---|---|
| 1 | `pg_database_size` | Alert at 350 MB |
| 2 | Per-table `pg_total_relation_size`, top 10 | Any table > 2× its modelled size |
| 3 | Cumulative order count vs the 142,700 ceiling | Project the wall date |
| 4 | R2 bucket size and monthly operation counts | Alert at 8 GB |
| 5 | Cloudflare Workers requests yesterday | Alert at 70,000 |
| 6 | DO duration, requests and rows (if tracking is on) | Alert at 9,100 GB-s, 70,000 req, 70,000 rows |
| 7 | Supabase egress this month | Alert at 3.5 GB |
| 8 | Undelivered `events` older than 1 hour | Any |
| 9 | `platform_float.variance` for yesterday | Zero, or explained in writing |
| 10 | Oldest un-pruned row in `events`, `notifications`, `rider_location_pings` | Within its retention window |
| 11 | p95 checkout latency during the lunch window | Under 900 ms |
| 12 | Failed `place_order_v1` attempts (price changed, out of stock) | Sudden change means menu data is rotting |

Item 9 is the only one on this list that is about money rather than infrastructure. It is also the
one that will be skipped first under pressure, and the one that, if skipped, turns a
reconciliation problem into an insolvency problem.

---

## 12. Assumptions to verify in week 1

| Assumption | Verify by |
|---|---|
| Modelled row and index sizes are within 2× | `pg_total_relation_size` after 1,000 real orders |
| Supabase free-plan CPU is not the binding constraint | Load test 100 concurrent checkouts through the lunch window |
| R2 does not require a payment method at signup | Check at signup — if it does, the images decision needs a different home |
| The connection pooler is used by every server-side caller | Inspect Workers and Pages config |
| PostGIS availability, if wanted | Dashboard; the design assumes geohash instead and does not need it |
| Cloudflare DO memory is billed at 128 MB for SQLite-backed objects | Confirm in the dashboard before enabling tracking |

If the row sizes come in at 2× the model, the Scenario C ceiling is 71,000 orders, not 142,700,
and the $25 trigger arrives at 20,000 cumulative orders rather than 40,000. Re-run this document's
arithmetic with measured numbers after week one rather than trusting the model for a quarter.

### 12.1 Changes made after the first draft

| Change | Effect on the numbers |
|---|---|
| Deleted `wallet_topups` and the whole top-up verification pipeline | **Slightly better.** That table was never in the per-order byte model, and removing it removes one high-write table from the write path |
| No customer wallet; wallets scoped to vendors and riders | Neutral. `wallets` is a per-account table, not per-order |
| Added `delivery_fee_tiers` and `rider_pay_rules` | +2 tiny config tables. No measurable effect |
| Added `delivery_base_fee`, `delivery_multiplier_bps`, `distance_km`, `vendor_limit_applied` to `orders` | +~12 B per order row. The `orders` figure moves from ~930 B to ~942 B, which changes the Scenario C total by under 0.2% and rounds to the same numbers |
| Added `rider_pay_*` and `platform_revenue` to `delivery_assignments` | +~40 B per assignment, ~24 B per order after dividing by 1.6 vendors. Immaterial |
| Revenue now recognised from a rider cut rather than a vendor commission | No database effect. It reduces ledger rows per order slightly, since one `rider_cut` entry per order replaces a per-sub-order commission entry |

**Every table in §3.1 stands.** The revisions change the schema but not the shape of the problem.