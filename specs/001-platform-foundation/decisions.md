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