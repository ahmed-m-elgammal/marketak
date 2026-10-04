# Constitution — Marketak — Delivery Platform

Non-negotiable principles. Every spec, plan and task must comply. Changing a principle
requires a numbered entry in `specs/001-platform-foundation/decisions.md` and a dated amendment below.

Read `AGENTS.md` first for the reading order and the current project state.

---

## I. Money and truth

1. **Prices, fees, discounts, commissions and delivery fees are computed in Postgres, never in
   the app, never in a CDN snapshot, never in a feature flag.** The client may display an
   estimate; the server decides.
2. **Checkout is a two-phase commit with explicit consent.** `quote_order_v1` returns a signed
   quote with `quote_id` and `expires_at`. `place_order_v1` re-prices inside the transaction and
   **rejects with `PRICE_CHANGED`** if anything moved. The app must show the itemised diff and the
   customer must re-confirm. Silent price drift is a bug, not an optimization.
3. **Money is integer piastres (`int`) plus a `currency` column.** No floats, no `numeric` for
   balances. Never compute totals in the app. Percentages and multipliers are basis points.
4. **The ledger is append-only.** `ledger_entries` are never updated or deleted, enforced by
   Postgres rules. A mistake is corrected by a reversing entry. Balance is a cached column updated
   in the same transaction as the entries that change it.
5. **Every `idempotency_key` is unique.** Placing an order, a payout, a collection and a wallet
   adjustment all carry one. A retried request must never double-charge.
6. **The platform holds no customer money.** There is no customer wallet and no top-up flow. The
   customer pays the rider directly, in cash or by their own Vodafone Cash / Instapay transfer, and
   the platform records that it happened. Wallets exist for vendors and riders only, because those
   are balances the platform owes.
7. **Every money constant is configuration, not code.** The delivery base fee, the per-vendor
   multiplier, the free radius, the per-km fee, the vendor cap, the rider pay rule and the cash
   limit all live in tables an admin edits at runtime. No fee, multiplier or limit is hardcoded in
   an app or a function.
8. **Fee inputs are frozen onto the order at checkout.** `delivery_base_fee`,
   `delivery_multiplier_bps`, `distance_km` and the vendor limit in force are copied onto `orders`,
   so a config change next week cannot retroactively alter what a customer was charged or what a
   rider is owed.
9. **The platform's launch revenue is a cut of the delivery fee taken from the rider.** Vendor
   commission on items and a customer service fee exist as rows and are switched on later. Turning
   one on is an `update`, never a migration, and never applies retroactively.
10. **Cash in transit is reconciled daily, without exception.** `platform_float.variance` must be
    zero or explained in writing before the next settlement run. There is exactly one exposure —
    cash collected by riders and not yet banked — and it is never allowed to become an unknown.

## II. Data model

11. **A checkout is one `orders` row plus N `sub_orders` rows.** One checkout = one payment = one
    total = one delivery. Per-vendor fulfilment, fees, timing, cancellation and payout live on
    `sub_orders`. Never model a multi-vendor cart as a single order with a nullable `vendor_id`.
12. **Order items belong to a sub-order, never directly to an order.** `order_items.sub_order_id`
    is NOT NULL. This is what makes multi-vendor checkout correct.
13. **Anything that is filtered, joined or sorted on is a real column or a real table, never a
    JSON array.** Explicitly: `vendors.area_ids` → `vendor_areas`, `vendors.cuisine_types` →
    `vendor_cuisines`. JSONB is for shapes that are only ever read whole (`selected_options`,
    address snapshots, `nutritional_info`, flag `targeting_rules`).
14. **Order rows are immutable snapshots.** `item_name`, `unit_price`, `selected_options` are
    copied at checkout and never re-read from the catalog. Editing a menu must not change history.
15. **Order status changes only through `transition_order_v1`.** The database enforces the state
    machine; apps have no direct write path to any `status` column.
16. **Every state change writes its `events` row in the same transaction.** Supabase talks to the
    outside world only through `events`.
17. **Soft delete plus `updated_at` on every business table.** Archiving, snapshot invalidation and
    incremental export all depend on them.
18. **Authentication is Google and Apple only.** No email, no password, no phone OTP. The phone
    number is a profile field collected after sign-in, and a user without `profile_completed_at`
    can browse but cannot order. The gate is enforced in the RPC, in RLS, and in the app — one
    layer is not enough.

## III. Architecture

19. **One source of truth: Supabase.** Cloudflare and Firebase hold caches and short-lived state
    only. Neither may hold the only copy of anything.
20. **Supabase Auth is the only identity system.** Workers verify tokens; they never issue them.
    A client-supplied role is never trusted — permission comes from the user's own JWT through RLS.
21. **All business logic is a Postgres RPC, not an Edge Function.** RPC calls are unmetered on the
    free plan. Edge Function quota stays reserved for a future payment gateway.
22. **Bytes never live in Postgres.** Images, menu snapshots, search indexes, archives and backups
    live in R2 behind immutable versioned URLs. The database stores only the path.
23. **Every external provider sits behind an adapter** (FCM, maps/geocoding, R2, later a payment
    gateway) so it can be swapped without touching order logic.
24. **Degrade, do not fail.** If Cloudflare or Firebase is down, ordering and money still work.
    Images, live tracking and push are the only things allowed to degrade.

## IV. Delivery

25. **One rider, one trip, N vendor pickups, one drop-off, one address.** Capped at a configurable
    maximum number of vendors. Customers in the same geohash prefix may be grouped into one trip.
    Per-vendor separate delivery is modelled but is never the default.
26. **ETA is computed, never trusted from the vendor.** `max(sub_order.ready_estimate) + pickup_leg
    + delivery_leg`, with a per-vendor buffer at the lunch peak.
27. **Live location is a later-phase enhancement, not a dependency.** Nothing in ordering, payment
    or settlement may require it. Its absence must be a graceful downgrade.

## V. Operations and cost

28. **Free tier is a design constraint, not an accident.** Every cap has a documented number, a
    70% alert, and a named fallback that keeps the app functional. See `free-tier-plan.md`.
29. **The offline SQLite cache is display-only.** It may never be the source of a price, a fee, a
    discount, an availability decision or a total. Server re-pricing on every checkout is what
    makes a stale cache harmless.
30. **No tight polling of Supabase.** Egress is metered. Status updates arrive by push, by Durable
    Object channel, or by a foreground-only poll no faster than 45 s for a single active order.
31. **Secrets never enter an app or git.** Worker secrets and Supabase secrets only.
32. **Every webhook and event consumer is idempotent.** Delivery is at-least-once by design.
33. **Retention is enforced by a scheduled job, not by hope.** See the retention matrix in
    `spec.md` §9. Un-pruned tables are the only thing that will actually kill the free tier.

---

## Amendments

| Date | Change | Reason |
|---|---|---|
| 2026-10-04 | Initial constitution | First spec of the platform |
| 2026-10-04 | Deleted the customer wallet and top-up verification pipeline; wallets scoped to vendors and riders | The customer pays the rider directly. Removes the entire top-up fraud surface and all customer float. Chosen for money integrity |
| 2026-10-04 | Added principles 7–9: configurable money constants, frozen fee inputs, rider-cut launch revenue | The fee formula and the phased commission strategy are configuration, not code |
| 2026-10-04 | Added principle 18: Google/Apple-only auth with a profile-completion gate | Phone is a profile field, not a credential |
| 2026-10-04 | Dropped the assumption that the city is Cairo; the city is configuration | Confirmed the operating city is not fixed at authoring time |