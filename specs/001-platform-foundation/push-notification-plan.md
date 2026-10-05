# Push notifications — implementation plan

**Status: DRAFT. Nothing in this document is a new design.** Every rule below is cited to the
specification that already decided it. The previous draft of this file proposed seven things the
spec had already settled; section 6 records them, because each one was a case of not reading
before writing.

The short version: **this is not a design problem, it is a build-order problem.** The design is in
`contracts.md` sections 3-4 and `free-tier-plan.md` 3.7, 5.2, 5.3. Section 5 is the preconditions
list for the Worker, re-verified against the live database on 2026-10-05. **Section 7 is the
event-name audit: 8 of the 18 catalogue event names are emitted by nothing, and the mapping from
emitted event to notification template key is written down nowhere. That mapping is what the Worker
needs first.**

`contracts.md` sections 3-4 and `free-tier-plan.md` 3.7, 5.2, 5.3. Section 5 is the preconditions
list for the Worker, re-verified against the live database on 2026-10-05. **Section 7 is the
### The event path - two routes, decided in `free-tier-plan.md` 5.2

| Path | Events | Mechanism | Requests/day |

| **Critical** | `order.placed` (vendor must see it now), `driver.assigned` | Database webhook to Worker | 8,000 |
| **Bulk** | `order.status_changed`, `menu.updated`, `promo.*` | `pg_cron` every 15 s, `claim_events_v1(50)` | 576 |
| | | **Total** | **~21,900/day - 4.5x headroom** |

`contracts.md` 3.1 assigns each event type to one of those two paths; 3.2 sets the guarantees
(at-least-once, FCM collapse key = `event_id`, outage loses nothing, prune 7 days after delivery);
4 defines the 19 template keys and their variables; 4.4 gives the send rules.

### Retention - decided in `free-tier-plan.md` 3.3 and 3.7
| Table | Window | Granularity | Why |
|---|---|---|---|
| `events` | **7 d** | **`DELETE`, unpartitioned, on purpose** | See below |
| `order_eta_snapshots` | **24 h** | `DELETE` | §3.3 |
| `notifications` | 30 d | month (already partitioned) | §3.7 |
| `rider_location_pings` | 30 d | month (already partitioned) | §3.7 |
| `audit_log` | 365 d | month (already partitioned) | §3.7 |

**`events` is deliberately NOT partitioned, and this is the decision I was about to reverse.**
§3.7: *"Monthly partitions cannot express a 7-day window: a September partition still holds
deliverable rows on 1 October, so it survives until ~7 October. That is 37 days of retention in
practice."* Pruned by `DELETE` it measures **45 MB (11%)** of the 400 MB ceiling; partitioned it
would be **239 MB (60%)** for a queue whose rows live a week. `013` ships it unpartitioned and
pruned by `DELETE`, a bitmap index scan on `events_delivered_at`, not a sequential scan.

Prune mechanics, all §3.7: batch `limit 1000` with a short `pg_sleep` between; an index on the prune
column; nightly `VACUUM ANALYZE` on the highest-churn tables.

### Failure handling — decided, and there is no dead-letter table

`free-tier-plan.md` §3.7 and §11 item 8: **"Undelivered `events` older than 1 hour — Any."** That is
an alert, not a retry cutoff. There is no give-up count, no dead-letter queue, and no
`attempts > N` abandonment. `events.attempts` is documented at `contracts.md` §3 as **"Alert above
5"**. A Worker outage delays notifications and loses nothing.

### Worker constraints — `free-tier-plan.md` §5.3

10 ms CPU per request. JWT verify ~1–2 ms; **sign a Google JWT for FCM (RSA) ~3–5 ms, tight — cache
the access token for 55 minutes so signing is rare**; render a template <0.5 ms. Never do JSON work
in a Worker on data Postgres can aggregate. If FCM signing proves unreliable under load, move push
delivery into a Supabase Edge Function, whose 500,000-call/month free quota is already reserved and
unused.

FCM credentials are Worker secrets, never in Postgres — that is why the dispatcher is a Worker.

### Ranking — `free-tier-plan.md` §8

The two levers that are push work:

| # | Lever | Effect | Effort | Risk if skipped |
|---|---|---|---|---|
| 3 | Prune `events`, `notifications`, `pings`, `eta_snapshots` | 6.9 → 2.9 KB/order, **2.4×** | Low | **Disk full in ~2 weeks** |
| 7 | Batched `pg_cron` event drain + one mark per batch | Workers 41,000 → 18,000/day | Low | Little headroom for a viral Friday |

Lever 1 (do not ship live tracking) is already honoured — ADR 6 cut Durable Objects, and §10 gives up
live tracking in v1 because "push notifications plus an honest ETA cover a 30-minute delivery". Push
is what substitutes for tracking; it is not itself lever 1.

## 2. What exists, and what does not

Verified against the live database on 2026-10-05.

| Piece | State |
|---|---|
| `events` table, indexes, RLS | **Complete.** No client role can read or write it |
| `notifications` | **Complete.** Partitioned; `notifications_2026_10`, `notifications_2026_11`. RLS present, `authenticated` holds SELECT |
| `notification_templates` | **Complete.** 38 rows = 19 keys x ar/en, all `push`, all active, matching `contracts.md` section 4 exactly |
| `device_tokens` + indexes | **Complete** as a table. `data-model.md:393` gives `index on device_tokens (user_id, app_role)` |
| `private.ensure_month_partition` | **Now called.** `035` wired it into `private.ensure_partitions`, scheduled monthly |
| `order_eta_snapshots (computed_at)` index | **Added by `035`**, named `order_eta_snapshots_computed_at` |
| `claim_order_v1` | Exists - the rider-acceptance queue of section 14.4 |
| `claim_events_v1` | **MISSING** - named in `free-tier-plan.md` 5.2 with a `(50)` batch argument and in `data-model.md` 14.4. Confirmed 0 matching functions |
| prune functions (4 tables) | **Present.** All four created by `035`, all revoked from `public`, `anon`, `authenticated`, all executed against aged probe rows and proven in both directions |
| `pg_cron` | **Installed by `035`.** Six jobs scheduled and active, verified in `cron.job` |
| `mark_events_delivered_v1` / batch mark | **MISSING** - 0 event mark/claim functions of any kind. Required by 5.2's "one RPC at the end of the invocation" |
| `functions/outbox-dispatcher` | **MISSING** - `functions/` does not exist; 0 TypeScript files in the repo |
| a way for a client to insert into `device_tokens` | **MISSING, and not named in any spec** - see section 4 |

Grants on `device_tokens`, verified: `postgres` yes, `service_role` no, `authenticated` **no**. Two
RLS policies exist. A client cannot register a push token today and cannot until an RPC exists.

## 3. Build order
**Step 1 - the retention half is DONE; the drain half is NOT, and the Worker still cannot start.**

Levers 3 and 7 are both marked **Low** effort in 8 and both are database work. Neither depends on the
Worker, and lever 3 is the one that says "disk full in ~2 weeks".

**Done, applied as `035_retention_and_cron`:**

- `prune_events` (7 d, delivered only), `prune_order_eta_snapshots` (24 h), `prune_notifications` (30 d),
  `prune_rider_location_pings` (30 d) — each batched `limit 1000` with `pg_sleep`, each on a named cron
  schedule, hourly for the first two and daily for the 30-day tables.
- `events` pruned by `DELETE` on `events_delivered_at`, **not** partitioned - 3.7.
- Nightly `VACUUM ANALYZE` on the highest-churn tables.
- A monthly partition creator calling `private.ensure_month_partition`, so `notifications` cannot fail
  on 2026-12-01 when `notifications_2026_12` does not exist. This helper existed with **no callers**;
  `035` gave it one.
- `order_eta_snapshots_computed_at`, the one prune column of the four that had no index.

**Still missing, and both are lever 7:**

- `claim_events_v1(p_limit int)` using `for update skip locked` per `data-model.md` 14.4.
- A batch mark RPC, per 5.2's "marks its whole claimed batch in one RPC".

`035` needed three attempts. The first two failed **in the migration's own assertion block**, on the
probe rather than the schema: it inserted into `order_eta_snapshots` and `rider_location_pings` with
invented uuids where both `order_id` and `rider_id` are `not null` foreign keys — and `rider_id`
references `public.riders`, not `auth.users`, because a rider is onboarded through verification, not
sign-up. It also passed uuids for two `bigint` sequence ids. The probe now stands on a real `riders`
row and a real `orders` row and reads sequence ids back. Both failures rolled back completely, leaving
`pg_cron` uninstalled, which is what the file's header argues for by having no `begin;`/`commit;`.

Worth stating plainly: this file went through several safety reviews before it landed, and its
assertions had still never been executed. Two of them had been **inverted**, so they would have failed
*because* the prune succeeded, and two more referenced columns that do not have the shape the probe
assumed. Reviewing a file is not testing it.

**Step 2 - the Worker.** Blocked on step 1, because both push routes drain through RPCs that do not
exist yet: the webhook route needs the batch mark, and the cron route needs `claim_events_v1`. A
Worker written before those exist can send notifications but cannot record that it did, which is the
one thing `contracts.md` 3.2 requires. The rules, once unblocked, are 5.3's CPU budget, a Google
token cached 55 minutes, `rider.new_offer` batched to 3 and never a blast (4.4), no PII in title or
body (4.4), and templates rendered in `users.preferred_language` (4).

**Step 3 - the weekly review checklist** (11) becomes real, and item 8 - undelivered `events` older
than 1 hour - becomes the thing that tells you step 2 is broken.

---

## 4. The one genuine gap, and it is a question, not a plan

`data-model.md` 379 declares `device_tokens` with its indexes. `admin-crud-plan.md` 4 classifies it
**Tier 2 - read only, written by "the customer's own RPCs"**. **No specification anywhere names those
RPCs.** They do not exist in the database either.

`authenticated` holds SELECT and **no INSERT** on `device_tokens`, which is correct per constitution
II - so a client cannot register a push token today, and cannot until an RPC exists. Re-verified on
2026-10-05: `authenticated` still holds no INSERT grant.

This is the only item in section 2 that is a gap in the specification rather than unbuilt code. It
needs one decision from you, because three things interact and the spec is silent on all three:

1. **What the RPC is called** - naming is a `contracts.md` 1.8 change, not a free choice.
2. **Upsert key.** `data-model.md` 393 indexes `(user_id, app_role)` for routing. A push token rotates
   on reinstall, so `(user_id, token)` is the natural upsert key - but that index does not exist and
   would need adding.
3. **`app_role` at registration.** `spec.md:45` says it "must resolve dynamically rather than being
   fixed at registration"; `decisions.md:305` says it is "a hint, not a permission" that routing
   ignores. And its `CHECK` is `{customer, rider, admin}`, while `user_roles.role` also allows
   `support`. So for a user who is both, what does the app send?

I am not proposing answers to those three. They are the questions.

---

## 5. What the Worker needs before the first line is written

This is a checklist, not a design. Everything in it is a precondition and none of it is optional.

### Blocked - the database side

| # | Needed | Why it blocks |
|---|---|---|
| 1 | ~~Apply `035_retention_and_cron.sql`~~ | **DONE.** `pg_cron` installed, six jobs active, four prunes verified by execution. Retains on a timer; does not deliver |
| 2 | `claim_events_v1(p_limit int)` | The **bulk** route has nothing to call. `free-tier-plan.md` 5.2 names it with a `(50)` batch argument; `data-model.md` 14.4 names it again. Confirmed 0 functions matching |
| 3 | A batch mark RPC | 5.2 is explicit: "the webhook Worker marks its whole claimed batch in one RPC at the end of the invocation." Without it the Worker sends and cannot record that it sent, which is the one thing `contracts.md` 3.2 requires |
| 4 | A `device_tokens` write path | `authenticated` holds SELECT and **no INSERT** on `device_tokens`, verified. **The Worker can send to nobody** until a client can register a token. This is the section 4 gap and it needs a decision from you |

Items 1-3 are buildable now and are the previous step 1. Item 4 is a question, not code.

### Blocked - the account and project side

| # | Needed |
|---|---|
| 5 | `functions/` directory and `wrangler.toml`. **Neither exists.** `apps/`, `functions/`, `scripts/` and `package.json` are all absent from the repo |
| 6 | Node + `package.json` at the repo root. T0.1c in `tasks.md` also owns `npm run typecheck`, `npm run lint`, `npm test` and `npm run verify` - **none of these commands exist**, so no engineering checklist can be signed off yet |
| 7 | FCM service-account credentials as Worker secrets: client email, private key, project id. **Never in Postgres** - that is the reason the dispatcher is a Worker rather than a database function |
| 8 | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` and `JWT_SECRET` as Worker secrets |
| 9 | A Cloudflare account with Workers enabled, and the project linked |

### Not blocked - decide these while the above is built

- **Which events are critical, and what they are actually called.** 5.2 names `order.placed` and
  `driver.assigned` as the webhook route. Neither `driver.assigned` nor `payment.collected` nor
  `menu.updated` is emitted by anything. This decides which events a database webhook is even
  configured for, so it has to be settled first. **Measured on the live database, not inferred** -
  see section 7 for the full event-name audit and the three-layer naming problem underneath it. Not
  something to guess at in the Worker.
- **Whether push goes to the Worker or an Edge Function.** 5.3 reserves 500,000 Edge Function calls
  per month and leaves the fallback open "if FCM signing proves unreliable under load". Worth
  building the Worker first and watching the CPU numbers.

---

## 6. What I removed from the previous draft, and why

Recorded because the failure mode - inventing design the spec already contains - is what `AGENTS.md`
rule 9 exists to prevent, and it is worth being concrete about where it happened.

1. **"Should `events` be partitioned, or pruned by `DELETE`?"** - Decided, with a benchmark.
   `free-tier-plan.md` 3.7 chose `DELETE` *because* partitioning cannot express a 7-day window and
   would cost 239 MB against 45 MB. I proposed the option the document had already priced and
   rejected. I read `data-model.md` 14.1's "partition by month" instinct and missed that
   `free-tier-plan.md` 3.7 exists specifically to correct it for this one table.
2. **"I suggest 5 attempts with backoff, then dead-letter."** - Decided, and the opposite of what I
   said. 3.2: an outage loses nothing, the cron retries every minute. `attempts` is an alert
   threshold. My suggestion would have silently dropped notifications.
3. **"Should `notifications` carry a dedup key?"** — §5.2 already made the mark idempotent by
   construction, by dropping the per-event callback and marking per batch.
4. **Language fallback chain** — §4 says `preferred_language`. There is no chain.
5. **"Who inserts the `notifications` row?"** — §4.4: the row is already there, independent of the
   send. That is what makes it the in-app fallback.
6. **A single 15-second cron drain** — §5.2 splits critical from bulk and budgets each. I built the
   simple version and treated it as the design.
7. **`claim_events_v1` as a bare drain** — §5.2 calls `claim_events_v1(50)`. It takes a batch limit.

---

## 7. Event-name audit, measured against the live database

Run on 2026-10-05. Method: every string literal matching `<noun>.<verb>` was extracted from
`pg_proc.prosrc` for all 127 `public` + `private` functions, filtered to those passed to
`insert into public.events`, and compared against the catalogue. **No migration was read and no
migration was applied to produce this.** The `events` table itself is empty, so a `select distinct type
from events` would have returned nothing and told us nothing; the names have to come from the code
that writes them.

### 7.1 The numbers

| Measure | Count |
|---|---|
| Distinct event names emitted by live functions | **63** |
| Names listed in `contracts.md` 3.1 | 18 |
| Of those, emitted under the exact same name | **10** |
| Of those, **never emitted by anything** | **8** |
| Emitted but absent from the 3.1 catalogue | **53** |
| `notification_templates` rows | 38 = 19 keys x ar/en, all `push`, all active |

### 7.2 The eight catalogue names with no emitter

| Catalogue name (3.1) | What the code actually emits |
|---|---|
| `order.placed` | `order.placed` - **matches** |
| `order.status_changed` | `order.status_changed` - **matches** |
| `order.delivered` | `order.delivered` - **matches** |
| `order.cancelled` | `order.cancelled` - **matches** |
| `payout.paid` | `payout.paid` - **matches** |
| `commission.activated` | `commission.activated` - **matches** |
| `fee_tier.set` | `fee_tier.set` - **matches** |
| `wallet.frozen` | `wallet.frozen` - **matches** |
| `user.profile_completed` | `user.profile_completed` - **matches** |
| `user.profile_updated` | `user.profile_updated` - **matches** |

Those ten are fine. The other eight have **no emitting function at all**, which is the finding that
blocks the Worker:

| Catalogue name (3.1) | Closest thing actually emitted | Verdict |
|---|---|---|
| `driver.assigned` | `order.claimed`, from `claim_order_v1` | **Renamed.** Payload carries `rider_id`, `assignment_id`, `rider_pay_total`, `platform_revenue`, `distance_km` - a superset of what 3.1 promises |
| `payment.collected` | `order.collected`, from **both** `collect_cash_v1` and `collect_wallet_v1` | **Renamed, and ambiguous by construction.** One name for two methods, distinguished only by payload `method` and `channel` |
| `menu.updated` | Five separate names: `menu_item.updated`, `menu_category.updated`, `menu_item_size.updated`, `item_option.updated`, `option_choice.updated` - plus 10 more `.deleted` / `.restored` variants | **Split five ways.** 3.1 wants one "menu changed" signal; the code says which entity changed, which is arguably better but is not what the catalogue says |
| `vendor.rejected_sub_order` | nothing. `transition_order_v1` folds a rejection into `order.status_changed` with `to = 'rejected'` | **Missing.** The customer-facing rejection push in 4.4 has no dedicated event to hang off |
| `driver.arrived` | nothing. `delivery_assignments.arrived_at` and `arrived_vendor_at` columns exist and are never written | **Missing, and the columns are dead.** 3.1 says "OrderRoom push only, no push notification", so it is low value - but an unused column that the spec promises will move is a trap |
| `rider.cash_limit_warning` | nothing. `rider_pay_rules` and `riders.cash_held` exist, and `effective_cash_limit_v1` computes the number | **Missing.** There is a template key for it and no producer for it |
| `voucher.created` | `voucher.updated`, with `payload->>'created' = true` | **Renamed and overloaded.** Create and update share one name; 3.1 lists them separately |
| `vendor.earnings_rolled` | nothing | **Missing.** 3.1 marks it "None in v1" anyway, so it is inert documentation |

### 7.3 The bigger problem: three naming layers, only the middle one exists

This is the part that actually blocks the Worker, and it is not visible from the 3.1 table alone.
There are **three** namespaces and the mapping between them is written down nowhere:

| Layer | Example | Where it lives |
|---|---|---|
| 1. **Catalogue event type** | `driver.assigned` | `contracts.md` 3.1 |
| 2. **Emitted `events.type`** | `order.claimed` | the function body |
| 3. **`notification_templates.key`** | `rider.order_assigned` | `public.notification_templates`, 19 keys |

Layer 3 is populated - 19 keys, ar and en, every one a real template with declared variables. But
**nothing maps layer 2 to layer 3.** The names do not line up:

| Emitted event | Nearest template key | State |
|---|---|---|
| `order.claimed` | `rider.order_assigned` | Same meaning, different name. Nothing records that they are the same event |
| `order.collected` | *none* | **No template exists for collection.** 4.4 wants an FCM to the customer on payment; there is no key to render |
| `order.status_changed` | 7 separate keys: `order.vendor_accepted`, `order.vendor_rejected`, `order.preparing`, `order.ready`, `order.picked_up`, `order.arriving`, `order.delivered` | One event fans out to seven templates, and the fan-out rule is not written anywhere |
| `order.placed` | `order.placed` | **The only clean 1:1 in the whole set.** Also `vendor.new_order` exists for the vendor half |
| `order.delivered` | `order.delivered` | Matches, but `order.status_changed` also fires on the same transition, so it would be sent twice unless de-duplicated |
| `order.cancelled` | `order.cancelled`, `vendor.order_cancelled`, `rider.customer_cancelled` | Three recipients, one event. Correct in principle, undefined in practice |
| `payout.paid` | `vendor.payout_paid`, `rider.payout_paid` | Same |
| `voucher.updated` | `voucher.available` | Not connected |
| `menu_item.updated` and 14 siblings | *none* | Correct - 3.1 says "rebuild the R2 snapshot", not push |


### 7.4 What this means for the Worker, concretely

The Worker needs a lookup from an `events` row to a template key, per recipient role. That lookup
does not exist and cannot be inferred, because three of the entries above are one-to-many and one is
one-to-none. Concretely, before the Worker can be written someone has to decide:

1. **Which emitted name is authoritative?** Either 3.1 is amended to the code's names, or the emitters
   are renamed to 3.1's. They cannot both stand. Note that `order.claimed` is a *better* name than
   `driver.assigned` - it is what actually happened - which argues for amending the catalogue rather
   than renaming working code.
2. **Does `order.status_changed` fan out to seven templates, or is that seven separate events?** If it
   fans out, the Worker must read `to` from the payload and pick a key, and `order.delivered` needs an
   explicit suppression rule so the customer is not told twice.
3. **Is there a push for collection at all?** 4.4 wants one and no template exists. Either add the key
   (which is 2 rows, ar and en) or record that collection is in-app only.
4. **Should the four missing emitters be built?** `vendor.rejected_sub_order` and
   `rider.cash_limit_warning` each have a template and no producer, which reads as an oversight.
   `driver.arrived` has neither a producer nor a template and is marked "no push notification" anyway.

**None of this can be decided inside the Worker.** It is an ADR against `contracts.md` 3.1 and 4,
plus in some cases small emitter changes. The Worker should not be written against a guessed mapping.

