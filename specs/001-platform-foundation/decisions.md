# Decisions — Spec 001

Fifteen architectural decisions. Each records what was chosen, what was rejected, and why. If you
want to change one, add an amendment at the bottom rather than editing the original — the reason a
decision was made is usually the thing that gets lost.

A change to any of these requires an amendment to `.specify/memory/constitution.md`.

> **Every decision below is `proposed`, not `accepted`.** Nothing here has been reviewed by a human.
> The specification is authored and internally consistent, not approved. Promote an ADR to
> `accepted` only after reading it and agreeing with the trade-off.
>
> Splitting these into `docs/adr/NNNN-slug.md` with an index and per-file `superseded by` links is
> worth doing once they are approved. One file is easier to review as a batch; per-file records are
> better once decisions start superseding each other.

---

## 1. Multi-vendor checkout is a parent order plus sub-orders

**Context.** The defining requirement: a customer builds one cart from up to three different
vendors, checks out once, pays once, and receives one delivery.

**Decision.** `orders` is the checkout envelope (payment, voucher, one total, one address, aggregate
status). `sub_orders` is one row per vendor holding that vendor's items, fees, status, prep time and
payout. `order_items.sub_order_id` is NOT NULL.

**Rejected.** A single `orders` row with a `vendor_id`, one per vendor, grouped by a `checkout_id`.
Both fail the same way: neither can express "vendor B rejected while vendor A is already cooking",
and neither can compute per-vendor fees or per-vendor payouts.

**Consequences.** Aggregate status becomes a derived cache, never set directly. One delivery fee for
the whole order, allocated across sub-orders for reporting only.

---

## 2. No customer wallet. The customer pays the rider directly.

**Context.** Vodafone Cash and Instapay consumer transfers cannot be automated without a payment
gateway, which is out of scope for v1.

**Decision.** There is no `wallets` row for a customer and no top-up flow. The customer pays the
rider in cash or by their own mobile-money transfer to the rider's number. The platform records that
it happened on the order (`payment_method`, `payment_channel`, `payment_reference`).
`ledger_entries.account_type` has no `customer` value.

**Rejected.** A customer wallet funded by an admin-verified top-up flow with receipt screenshots.
It was built, then deleted on the grounds of money integrity: it introduces a fraud surface (fake
receipts, balance manipulation, double-crediting), a reconciliation burden, and a support queue —
all to hold money the platform does not need to hold.

**Consequences.** `platform_float` has exactly one exposure: riders' cash in transit. Wallets exist
for vendors and riders only, because those are balances the platform owes. Funding one is an admin
adjustment with a mandatory reason.

---

## 3. Launch revenue is a cut of the delivery fee, taken from the rider

**Context.** Market entry. Charging merchants commission at launch, in a market with entrenched
incumbents, means they do not sign up.

**Decision.** At launch the platform's only revenue is `commission_rules` scope `rider`, applies_to
`delivery_fee`, seeded active. Vendor commission on items is a row seeded `is_active = false`, to be
activated around month 3–4 once supply is strong enough to absorb it. A customer service fee is gated
by `settings.service_fee_enabled = false`.

**Rejected.** Launching with vendor commission because it is the conventional marketplace model and
revenue "should" come from merchants.

**Consequences.** The rider's pay is the thing under most scrutiny at launch, because it is the only
lever that affects whether riders supply at peak. Rider pay lives in `rider_pay_rules`, admin-editable
per city and per rider with effective dates, so it can be tuned without a deploy.

---

## 4. Delivery fee is a per-vendor multiplier on a base fee

**Context.** One rider making three stops is worth more than one rider making one, and the customer
should see that before checkout.

**Decision.**
```
delivery_fee = round(delivery_base_fee × multiplier_bendor_count / 10000)
             + max(0, distance_km − free_radius_km) × per_km_fee
```
Tiers seed at ×1.00 / ×1.10 / ×1.20 for 1 / 2 / 3 vendors, in `delivery_fee_tiers` as basis points.
Maximum 3 vendors, from `settings.max_vendors_per_order`.

**Rejected.** A percentage of the item subtotal (it makes a cheap basket absurdly expensive to
deliver). A flat fee per extra vendor (it cannot express a 20% uplift as one number). Any of these
hardcoded in a function body.

**Consequences.** The percentage applies to the delivery base, not the subtotal. The three inputs are
frozen onto the order at checkout, so changing a fee next week cannot alter what was charged on Monday.

---

## 5. One rider, one trip, N vendor pickups, one drop-off, one address

**Context.** Multi-vendor delivery execution.

**Decision.** One `delivery_assignments` row per `orders`, not per `sub_orders`. Pickup sequence is
computed once at assignment and stored on `stop_sequence`. Max 3 vendors.

**Rejected.** One delivery per vendor with parallel riders. It multiplies rider pay, multiplies the
fee, makes ETA `max()` instead of `sum()`, and needs a customer-facing choice at checkout. Modelled
as `orders.delivery_grouping = 'separate'` but not built.

**Consequences.** Cheapest model in every dimension that matters: one rider earning, one fee, one
location channel, one proof of delivery. Customer ETA becomes `max(sub_order.ready_estimate)` plus
legs, not a sum of full ETAs.

---

## 6. Authentication is Google and Apple only, with a profile-completion gate

**Context.** Phone is a delivery necessity in this market but a poor login credential, because both
Google and Apple hide it behind extra consent screens.

**Decision.** `user_auth_providers.provider_type` is `('google','apple')`. Email and phone are not
credentials. A `users` row is created at OAuth sign-in with `profile_completed_at = null`, and
`complete_profile_v1` later sets it. Enforcement of the ordering gate lives in three places: the RPC,
an RLS policy denying `insert` on `orders`, and the app.

**Rejected.** Phone OTP as the primary identifier. Email and password. Facebook.

**Consequences.** `phone_number` is nullable at the column level — a row must exist before a phone
does — but `check (profile_completed_at is null or phone_number is not null)` encodes the real rule:
a completed profile always has a phone. One user may link both a Google and an Apple identity.

---

## 7. Vendors are single-location. No branches.

**Context.** The original brief defines `vendors` with one latitude, longitude and
`vendor_schedules`. The original architecture spec had `merchants` + `merchant_branches`.

**Decision.** `vendors`, one physical location each. A chain is N vendors sharing a `brand_id`.

**Rejected.** Restoring `merchants` + `merchant_branches`. Only needed if real chains with several
branches are onboarded, and it adds a join to every catalog, fee and payout query.

**Consequences.** `vendor_id` is denormalised onto `menu_items` for RLS and cart grouping, kept
consistent by trigger. Branches can be added later behind the same `brand_id`.

---

## 8. `feature_flags` table replaces Firebase Remote Config

**Context.** Both were proposed.

**Decision.** A `feature_flags` table read through `get_flags_v1`, evaluated in SQL against the
caller's role and app version so one query returns resolved values. Remote Config is not used.

**Rejected.** Keeping Remote Config. It is a second source of truth for business switches, its
targeting cannot join real data, and it adds an SDK and a failure mode for something the database
already knows.

**Consequences.** Flags are public and non-authoritative — never a price, fee, permission or secret.
Fetched at cold start and on foreground, with safe defaults compiled into the app.

---

## 9. Live tracking is Phase 8, flag default off

**Context.** Live rider location was described as optional, with no mapping API budget yet.

**Decision.** Build `OrderRoom`, `tracking-gate` and the driver ping loop in Phase 8, not Phase 1.
`live_tracking_enabled` ships `false`, targetable per area. Nothing in ordering, payment or
settlement may depend on it.

**Rejected.** Shipping it in v1. At 2,000 orders/day a 15-second ping consumes roughly 79% of the
13,000 GB-s/day Durable Objects duration budget — the scarcest Cloudflare resource — in exchange for
a feature push notifications already cover for a 30-minute delivery.

**Consequences.** The entire Durable Objects line item drops to zero while the flag is off. Affordable
during the ramp, unaffordable at peak. Enabling it is configuration, not a rewrite.

---

## 10. `eu-central-1` (Frankfurt) over `ap-south-1` (Mumbai)

**Context.** Permanent-ish. Region decides data residency and drives checkout latency.

**Decision.** Frankfurt. ~7,500 km from Egypt, so expect 100–130 ms to the database.

**Rejected.** Mumbai, which is ~4,000 km and 45–70 ms — genuinely closer. Chosen against on data
residency and because a single stable specific region keeps read replicas and API management
available, which general regions do not.

**Consequences.** Acceptable against a 900 ms p95 `place_order_v1` target, but it is the first thing
to revisit if checkout p95 exceeds it. Moving regions is a project-region change and therefore a
migration, not a toggle — do it early if the numbers demand it.

---

## 11. Money is integer piastres; the ledger is append-only

**Context.** Financial correctness is non-negotiable and retrofitting it is expensive.

**Decision.** `integer` piastres plus a `currency` column. Percentages and multipliers are basis
points. `ledger_entries` has Postgres rules forbidding `UPDATE` and `DELETE`. Balances are cached
columns updated in the same transaction as the entries that change them. Corrections are reversing
entries.

**Rejected.** Floats or `numeric` balances. Mutable ledger rows.

**Consequences.** A mistake is auditable forever, which is what dispute resolution requires.
`ledger_entries` is the one table that is never archived, which is a primary reason to budget for
Supabase Pro before real money.

---

## 12. Checkout is quote-then-commit with a fingerprint, not a cached price

**Context.** The app caches catalogs and menus for offline browsing. Prices, fees and discounts
change while a customer is checking out.

**Decision.** Three tiers of truth. Tier 1, the SQLite cache and R2 snapshots, is display-only and
may be arbitrarily stale. Tier 2, `quote_order_v1`, reprices server-side and returns a `quote_id`
with a 5-minute TTL and a fingerprint. Tier 3, `place_order_v1`, reprices again inside the
transaction and aborts with `PRICE_CHANGED` plus an itemised diff if the fingerprint moved. The app
must show the diff and the customer must re-confirm.

**Rejected.** Trusting the client's price. Caching a quote row. Accepting the new price silently.

**Consequences.** A customer is never charged a stale price and never charged silently more than they
saw. The cache needs no invalidation logic to be *correct*, only to be pleasant — which is why
`menu_version` and menu snapshots exist. Voucher expiry, stock changes and vendor closing are all
caught by the same mechanism because they all move the fingerprint.

---

## 13. The offline SQLite cache is display-only and encrypted

**Context.** The app caches server data, refreshes on order and on pull-to-refresh. Prices change.

**Decision.** SQLite holds `catalog_cache`, `carts` and `drafts`. It may never be the source of a
price, a fee, a discount, an availability decision or a total. Encrypted at rest — SQLCipher on
Android with a non-exportable Android Keystore key, `completeUntilFirstUserAuthentication` on iOS.
The device never creates an order; `place_order_v1` is server-only by construction.

**Rejected.** A full offline-first read replica with bidirectional sync. It is a large sync surface
and a genuine conflict-resolution problem, for a catalog that is small and rarely edited.

**Consequences.** Duplicate orders are impossible by construction rather than by testing. Cart
conflicts resolve last-write-wins on `updated_at`, which is acceptable because the cart is not money
and the order is repriced anyway. A lost key means re-login, which is fine for a cache.

---

## 14. Free tier is a design constraint, with a named upgrade trigger

**Context.** Target running cost $0–25/month.

**Decision.** Model every cap in bytes. Images, menus and the vendor feed move to R2 behind
immutable versioned URLs. Apps never poll Supabase. Transient tables are pruned on `pg_cron`, and
order items plus status history are archived to R2 at 60 days, which takes the steady-state cost from
16.9 KB/order to 2.9 KB/order. Upgrade to Supabase Pro when Postgres exceeds 350 MB, or cumulative
orders exceed ~40,000, or the first real cash enters the system.

**Rejected.** Row-level analytics storage. Supabase Realtime for tracking. Shipping live tracking in
v1.

**Consequences.** The free tier is a build-and-beta tool, not a scale tool. No amount of architecture
fixes shared-CPU performance under a lunch peak, which is the strongest argument for Pro before real
money — and Pro is also the only way to get a third project for production.

---

## 15. Area and cuisine are tables, not JSON arrays

**Context.** The brief had `vendors.area_ids` and `cuisine_types` as JSON arrays.

**Decision.** `vendor_areas` (with per-vendor fee override and ETA range) and `vendor_cuisines` +
`cuisines`. `vendors.area_id` is denormalised as the primary area for indexing.

**Rejected.** Keeping the JSON arrays.

**Consequences.** JSON arrays cannot be indexed, so every "which vendors serve this address?" check
— the hottest query in the product — would be a sequential scan. At 150 vendors it would still
appear to work, which is exactly why it would survive to production.

---

## 15. One mobile app for customer and rider; vendors get a web dashboard

**Context.** The original plan was three React Native apps — customer, rider, vendor — each with its
own store listing.

**Decision.** **One** mobile app, `com.jaylak.mobile`, for Android and iOS. The rider surfaces sit
behind a role switch available to anyone holding the `rider` role, so a user who is both a customer
and a rider is one install and one session. Vendor staff and admins use web dashboards on Cloudflare
Pages. There is no native vendor app.

**Rejected.** Three separate apps. A second and third store listing, a second and third release
train, and two more things to keep in sync — for an audience whose entire daily workflow is changing
four things. Also rejected: one app with the rider role assigned by an admin only, which would stop
riders who are also customers from using their normal account.

**Consequences.**

- One store listing, one release train, one update to push. Riders get features immediately.
- `device_tokens.app_role` becomes a **hint, not a permission**. Push routing must decide from the
  order at send time, never from the token's role, because one device can be both.
- Customer and rider code ship together, so a rider-only bug is still a customer-facing release.
  Keep the rider surface behind `feature_flags` so a plain customer never sees or downloads it.
- The bundle grows. Two web dashboards are separate deploys from Cloudflare Pages, not store apps.
- The accepted cost: most vendors will manage lunch **from a phone browser**, which is a worse
  experience than native. Accepted deliberately.

---

## Amendments

| # | Date | Change | Reason |
|---|---|---|---|
| 1 | 2026-10-04 | Initial set of 15 ADRs | Recorded during spec authoring |
| 2 | 2026-10-04 | Split ADR 15 out as its own decision | One-app topology was decided after the first 14 were written |

---

## 17. Client access is RLS over `SELECT`-granted tables, with all mutations behind RPCs

**Status:** accepted · **Date:** 2026-10-04 · **Supersedes:** nothing, resolves the contradiction
inside `data-model.md` §13.3

**Context.** §13.1 states visibility as row rules ("Own", "Own vendor's sub-orders", "Assigned
only") and §13.2 is entirely about policy query performance, both of which describe RLS. §13.3 then
says "`anon` gets no direct table access at all — every read goes through an RPC", while the grant
table in the same section gives `authenticated` "SELECT on read tables". The spec contradicts itself
and the choice changes the shape of all 62 tables.

**Decision.** `authenticated` receives table-level `SELECT` on 51 read tables, gated by RLS. It
receives **no `INSERT`, `UPDATE` or `DELETE` on any table** — every mutation is a `security definer`
RPC, which is what makes the RPC the single place a permission decision is written
(constitution III.21). `anon` receives nothing at all.

**Alternatives rejected.**

- *RPC-only.* Strictly tighter and simpler to reason about, but it disables PostgREST and Realtime
  on tables, and pushes every read into the 016–020 RPC surface — a much larger audit surface to
  get right in one pass.
- *Granting `SELECT` on everything and filtering in the app.* Rejected outright; it is the failure
  mode RLS exists to prevent.

**Consequences.**

- Realtime on `orders` works for order-status push, which is the product's core loop.
- A client bug can widen *reads* only within the policy, never past it, because the policy is
  evaluated by the database.
- The privilege surface is one query: `information_schema.role_table_grants` must show `SELECT` and
  nothing else for `anon` and `authenticated`. 014 asserts this and 022 re-checks it in CI.

---

## 18. RLS is per-relation, so partitioned tables need policies on every partition

**Status:** accepted · **Date:** 2026-10-04

**Context.** §14.1 makes `notifications` and `audit_log` monthly-partitioned. Enabling RLS and adding
a policy to the **parent** leaves every partition with `relrowsecurity = false` and zero policies —
verified on this database with a throwaway partitioned table, not inferred. The partitions live in
`public`, which `authenticated` holds `USAGE` on, so `select * from notifications_2026_10` bypasses the
parent's policy entirely.

**Decision.** RLS is enabled on every table *and every partition*. Parent policies are mirrored onto
each partition, and `private.ensure_month_partition` was rewritten so a partition created later by
021's `pg_cron` job is born with RLS and the correct policy.

**Alternatives rejected.**

- *Grant nothing on partitions.* Works today, because the current posture grants only the parent, but
  it is one `grant` away from exposing every notification in the system. It also leaves the §13.3
  `alter default privileges` line as a loaded gun.
- *`FORCE ROW LEVEL SECURITY`.* Unrelated mechanism; it affects the table owner, not partitions.

**Consequences.**

- Retention keeps working. Dropping a partition drops its policies with it.
- 014 verifies the fix by **temporarily granting** on a partition and confirming the policy still
  filters — proving the defence holds under the exact condition that would have exposed it.

---

## 19. A vendor sees its own sub-orders, not its co-vendors' — even on a shared order

**Status:** accepted · **Date:** 2026-10-04

**Context.** §13.1 invariant 2 requires that "a vendor can read only its own sub-orders", and
invariant 2's stated risk is leaking "the customer's other orders or reviews". §13.1 also gives the
vendor the parent `orders` row, which is correct: a vendor needs the order total, the delivery fee
share and the delivery address.

So the vendor has two different entitlements that look alike: *the order I am part of* and *my slice
of it*. Migration 014 collapsed them into one rule (`order_id ∈ visible_order_ids`, which unions
"own order / order containing my sub-order / order I'm delivering") and applied it to the whole
subtree. Its comment claimed invariant 2 was thereby enforced. It was not.

**Decision.** `sub_orders` and `order_items` are filtered by `vendor_id` OR by
`private.owned_or_assigned_order_ids` — own order or assigned order, both of which legitimately show
every sub-order. An order that merely *contains* the vendor's sub-order shows only that vendor's rows.
The parent `orders` row keeps the wider rule.

**Alternatives rejected.**

- *Filtering by `sub_order_id ∈ (sub_orders I own)`.* Equivalent, but re-derives the join on every
  row instead of once per query as an InitPlan.
- *Adding a `vendor_id` to `order_status_history` and `order_modifications`.* Rejected as inventing
  schema to serve a policy. Both are per-order facts — a status transition is something the customer,
  the preparing vendor and the carrying rider all already know — and neither table carries the column.

**Consequences.**

- Found by testing, not by reading: on a two-vendor fixture, vendor 1's staff read **3** sub-orders
  where 2 was correct, one of them a competitor's line items and commission share. `014a` fixes it and
  asserts the policy shape so it cannot be reintroduced.
- A general rule this exposes: **a policy reused across a subtree is only correct while every table in
  that subtree has the same entitlement grain.** `orders` is per-order; `sub_orders` is per-vendor.

---

## 20. `riders` is not readable by clients; `riders_public` carries the projection

**Status:** accepted · **Date:** 2026-10-04

**Context.** §13.1 says a customer sees `riders` — "Public fields only". RLS filters rows and never
columns, so this is not expressible as a policy. `riders` holds `phone_number`, `current_latitude`,
`current_longitude`, `vehicle_plate`, `cash_held`, `max_cash_held` and `user_id`. A grant on the table
exposes all of them, and no row policy can prevent it.

The required product behaviour is more specific than "public fields": **a customer sees each rider's
name, vehicle, rating and phone number** — the customer pays at the door and has to be able to call.
**A rider sees the customer's name, phone number and location, but only for an order they have
accepted**, which rides on the order policies via `delivery_assignments` rather than on `riders`.

**Decision.** `riders` gets **no grant to any client role.** `public.riders_public` exposes `id`,
`first_name`, `last_name`, `phone_number`, `vehicle_type`, `vehicle_plate`, `rating_avg`,
`rating_count` for active riders.

**Alternatives rejected.**

- *`GRANT SELECT (col, col) ON riders`.* Breaks `select=*` in PostgREST, and silently changes meaning
  every time a column is added — a new column is neither included nor visibly excluded.
- *Grant the table and rely on a row policy.* Does not satisfy the requirement at all; exposes every
  rider's phone number and live location to every signed-in user.

**Consequences.**

- `user_id` never leaves the database, which matters because it is the key `010a`'s cash-limit leak
  walked. `cash_held` and `max_cash_held` are unreachable, so the rider's cash position is not
  readable by competitors or customers.
- The rider-to-customer direction is enforced by `users_read` plus the order subtree, so it ends
  automatically when the assignment ends. Nothing extra to keep in sync.
- **Known residual exposure:** the assigned rider can read the whole `users` row for that customer,
  which includes `email`. RLS cannot mask a column on an allowed row. Accepted for v1 because the
  rider already receives the delivery address and phone from the order itself; revisit if customer
  email is ever used for marketing consent, at which point it needs its own projection.
- 014 asserts that no client grant on `riders` exists, so the view cannot be bypassed by accident.

## 21. A payout line names the thing it pays: `sub_order_id` for a vendor, `assignment_id` for a trip

**Status:** accepted — **Date:** 2026-10-05

**Context.** `payout_lines` (§7) had one optional foreign key, `sub_order_id`, and a
`UNIQUE (sub_order_id) WHERE NOT NULL` index. `019` had to pay both parties from it, and those are
two different things:

- a **vendor leg** — one merchant's portion of one order. `sub_order_id` names it exactly.
- a **rider trip** — one journey, which may serve N vendor legs. `sub_order_id` does not name it. One
  trip has N legs, so no single `sub_order_id` identifies it, and the global UNIQUE index is already
  consumed by the vendor payout for that leg.

So a rider payout line had to carry `sub_order_id = NULL`. Two consequences, both real:

1. **It had no double-payment protection.** Its only guard was
   `payouts.idempotency_key`, which is derived from (type, account, period). That stops a retried job
   but not two *overlapping* periods paying the same trip — and nothing else stood in the way.
2. **Cash in transit had to be re-derived rather than read.** The amount a rider is holding is
   `delivery_assignments.collected_amount`; the amount a line carries is `net_amount`, which is what
   the rider is **owed**. On the reference order those are 13,000 and 500. An earlier draft read one
   where the other belonged and banked the wrong figure — a bug the `platform_float_variance_consistent`
   CHECK could not catch, because the resulting row was arithmetically consistent. The only thing that
   caught it was `reconcile_day_v1` refusing to return a non-zero variance without a written
   explanation, which is worth knowing as a fact about this schema.

**Decision.** `payout_lines` gains `assignment_id uuid REFERENCES delivery_assignments(id)`, nullable,
plus `UNIQUE (assignment_id, payout_line_type) WHERE assignment_id IS NOT NULL`, plus a
`payout_lines_shape` CHECK that makes a mis-paired line impossible:

| line type | `sub_order_id` | `assignment_id` |
|---|---|---|
| `vendor_earning` | required | must be null |
| `rider_trip` | must be null | required |
| `tip`, `bonus` | must be null | required |
| `adjustment` | must be null | must be null |

Uniqueness is per `(assignment_id, payout_line_type)`, **not** on `assignment_id` alone. One trip
legitimately earns two lines — a `rider_trip` line and a `tip` line — and single-column uniqueness
aborted the first tipped payout. That is `019a`, and it exists because the original index was wrong in
a way only execution revealed.

**Alternatives rejected.**

- *Read cash from `delivery_assignments` by (rider_id, status, delivered_at) window.* No schema change,
  but it is the re-derivation that already produced a wrong-column bug, it leaves a payout line
  untraceable to its trip, and it has a boundary case: a trip completing between `create` and `approve`
  on the same day has its cash swept into the remittance with no line for it.
- *`GRANT`-free uniqueness by convention.* `payout_lines_sub_order_unique` exists precisely because
  plan.md §4 rule 2 says a manual mistake must not be able to pay a sub-order twice. Extending that
  guarantee to trips is the same requirement, not a new one.
- *Make `payout_line_type` carry the trip instead.* Constitution II.13: anything filtered, joined or
  sorted on is a real column, not a value smuggled into another one.

**Consequences.**

- Cash in transit is now read from the rows the batch is actually paying, so the figure cannot drift
  from what is being settled, and the date-window boundary case disappears.
- A trip cannot be paid twice, and neither can its tip.
- `payout_lines_shape` replaces `payout_lines_sub_order_type`, which only forbade `tip`/`bonus` from
  carrying a `sub_order_id`. One rule to read instead of two overlapping ones.
- The change is additive on an empty table: nullable, no default, no rewrite, no backfill, and no
  application code exists yet to break.
- `run_payout_v1` now writes `wallets.balance` for the party it pays. Constitution I.4 requires a
  cached balance to move in the same transaction as the entries that change it, and `tasks.md` T4.15
  asserts ledger sums equal cached balances — so leaving the wallet alone would satisfy every
  individual line of the spec and break the invariant binding them. The wallet is **not** an accrual
  ledger: a payout credits it, and `adjust_wallet_v1` remains the only way money enters a wallet
  without one, which is what `spec.md` §3.4 means by funding being an admin adjustment.
---

## 22. Availability is refused, not fingerprinted; stock is never decremented

**Status:** accepted · **Date:** 2026-10-05

**Context.** `spec.md` 6.1 claimed that `is_available` and `stock_count` are caught "the same way" as
voucher expiry and fee changes - by living in the price fingerprint. Executing the checkout path showed
that claim was false in both directions. The fingerprint at `017_rpc_core.sql:579-592` contains neither
column. `stock_count` was not consulted anywhere on the purchase path at all: with `stock_count = 0` on
the only line in the cart, `quote_order_v1` issued a quote and `place_order_v1` completed the sale. The
only reference to the column in any migration was `020_rpc_read.sql:528`, *reading* it to hide sold-out
items from browse.

Chasing that surfaced a second defect in the refusal path itself. With `is_available` flipped false
between quote and place the order was correctly not placed, but the error was `22P02 invalid input syntax
for type json` rather than a `contracts.md` code, because in
`place_order_v1:809` `||` binds tighter than `->`: `'prose' || v_q -> 'rejections'::text` concatenates the
prose first and hands it to `->` as JSON. `private.err` was never entered, so **every** rejection code in
the quote - `ITEM_UNAVAILABLE`, `ITEM_RETIRED`, `VENDOR_UNAVAILABLE` and the rest - reached the client as
an opaque Postgres error.

**Decision.** `stock_count <= 0` is refused with a new `OUT_OF_STOCK` rejection, computed in
`private.compute_quote` alongside the six rejections already there, and `null` still means unlimited.
`place_order_v1` raises `CART_NOT_PLACABLE` with a readable message, parenthesised. Stock is **not** added
to the fingerprint and is **not** decremented.

**Alternatives rejected.**

- *Put `is_available` and `stock_count` in the fingerprint.* This is what `spec.md` 6.1 actually claimed,
  and it was rejected on consequence rather than principle: a vendor adjusting stock would invalidate every
  customer's live checkout and show a "prices changed" sheet for an item whose price never moved. Price
  consent and availability are different questions, and a price diff is the wrong instrument for the
  second one.
- *Decrement `stock_count` atomically inside `place_order_v1`.* The only option that prevents two
  customers buying the last unit, and genuinely tempting. Rejected because it makes the column
  authoritative, which needs a reversal path on cancel and refund, and removes the vendor's control over
  a field the schema documents as theirs (`null = unlimited`). That is a product decision with operational
  consequences, not a bug fix, and it was not taken here. **Known and accepted: overselling remains
  possible until a vendor sets `stock_count` to zero.**
- *Revoke `EXECUTE` on the checkout RPCs.* Irrelevant; they are the only way to order.

**Consequences.**

- A sold-out line can no longer be bought, and `OUT_OF_STOCK` is now a code the application can render.
- `CART_NOT_PLACABLE` is reachable for the first time, so all seven rejection codes surface as domain
  errors instead of `22P02`. This is the fix that made the stock fix safe to ship.
- `spec.md` 6.1 has been corrected: it no longer claims availability is fingerprinted.
- `contracts.md` 1.7 listed `OUT_OF_STOCK` all along and described a code that no function raised. It now
  does.
- Forward migrations `017a` and `017b`; `017` is applied and was not edited. `017b` exists only because the
  live application of `017a` was made from a hand-typed copy that dropped code - recorded in
  `001-020-integrity-notes.md` section 7a-bis.
- Accepted cost: overselling is still possible, and nothing decrements stock, so `stock_count` is a vendor
  setting rather than a system-owned counter. Revisit if a vendor complains or if overselling becomes
  measurable.
