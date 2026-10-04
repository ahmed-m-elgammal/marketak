# Changelog

All notable changes to Marketak. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is not yet meaningful — there
is no released version, and the schema is still pre-review.

## [Unreleased]

Nothing shipped. This project is specification-only.

### Added

- **Platform specification** for a one-city, lunch-first delivery platform on Supabase +
  Cloudflare + Firebase. Eight documents: constitution, spec, decisions, data-model, contracts,
  plan, free-tier-plan, tasks, open-questions.
- **Multi-vendor checkout model.** One `orders` row plus N `sub_orders`. Order items belong to a
  sub-order, never to an order. This is the requirement the whole schema is shaped around.
- **Configurable delivery fee.** `base × multiplier(vendor_count)` plus a distance component.
  Tiers seed at ×1.00 / ×1.10 / ×1.20 for 1 / 2 / 3 vendors, stored in basis points. Maximum
  vendors per cart is 3, from `settings`. No fee constant appears in code or in a function body.
- **Phased revenue model.** Launch revenue is a cut of the delivery fee taken from the rider.
  Vendor commission on items and a customer service fee exist as inactive rows, activated by an
  `update` around month 3–4. `effective_from` prevents retroactive application.
- **No customer wallet.** The customer pays the rider directly in cash or by Vodafone Cash /
  Instapay. Wallets exist for vendors and riders only. Chosen for money integrity: it removes the
  entire top-up fraud surface and all customer float.
- **Two-phase checkout.** `quote_order_v1` reprices and returns a 5-minute fingerprint;
  `place_order_v1` reprices inside the transaction and aborts with `PRICE_CHANGED` plus an
  itemised diff. The offline cache is display-only and can never produce a wrong charge.
- **Append-only ledger** with Postgres rules forbidding `UPDATE` and `DELETE`. Corrections are
  reversing entries. Money is integer piastres.
- **Free-tier longevity plan.** Byte-level model of every cap, three retention scenarios, a ranked
  list of 14 levers, and a named upgrade trigger: Postgres over 350 MB, or cumulative orders over
  ~40,000, or the first real cash in the system.
- **Agent skills** — 16 Cloudflare, 13 Firebase, 2 Supabase. Relevance recorded in
  `ENVIRONMENT.md` §5.
- **MCP servers** — Cloudflare (API, docs, bindings, builds, observability), Supabase, Firebase.
  All connected and authenticated.

### Infrastructure

- **Supabase project `marketak`** created — ref `erxxsebcqqcpkipzcdhg`, region `eu-central-1`
  (Frankfurt), Postgres 17.11, free plan, `ACTIVE_HEALTHY`. Extensions verified available
  including `pg_tap`, so the RLS policy tests are runnable rather than theoretical.
- **Firebase project `marketak-eg`** created (number `283007295790`) and set active. `marketak`
  was already taken as a global Firebase project id.
- **Firebase apps registered** for Android and iOS under bundle/package `com.jaylak.mobile`.
- **R2 enabled.** Buckets `marketak-public` and `marketak-private` created in `EEUR`.

### Database

Migrations 001–008 written **and applied** to the live project `erxxsebcqqcpkipzcdhg`. 37 tables,
138 indexes, 0 unindexed foreign keys.

- `001_extensions` — `pgcrypto`, `pg_trgm`, `btree_gist`, `unaccent`, `pg_partman`. PostGIS is
  available and deliberately **not** installed: area matching is geohash-prefix plus a haversine
  distance, so nothing in the schema depends on a spatial extension.
- `002_geo_and_config` — `cities`, `areas`, `delivery_zones`, `delivery_fee_tiers`, `settings`
- `002s_seed_fee_tiers` — the ×1.00 / ×1.10 / ×1.20 vendor-count tiers, as data, in a separate file
- `003_identity` — `users`, `user_roles`, `user_auth_providers`, `addresses`, `device_tokens`,
  `feature_flags`, plus the `on_auth_user_created` trigger
- `004_vendors` — `brands`, `vendors`, `vendor_areas`, `vendor_schedules`, `vendor_holidays`,
  `cuisines`, `vendor_cuisines`, `vendor_staff`, `vendor_earnings_daily`
- `005_catalog` — `menu_categories`, `menu_items`, `menu_item_sizes`, `item_options`, `option_choices`
- `005a` – `005e` — forward fixes from auditing the applied migrations: a `bump_menu_version` column
  list, seven integrity defects, a `zone_id` column corrected in the fee-tier monotonicity guard, the
  revoke pass that closed the anon read leak, and the `private` schema
- `006_cart` — `carts`, `cart_items`
- `007_orders` — `orders`, `sub_orders`, `order_items`, `order_status_history`,
  `order_modifications`
- `007a` — `sync_order_status` joined the transition table on a column that does not exist
- `007b` — `orders.item_count` could never become non-zero (see **Fixed**)
- `007c` — `order_eta_snapshots`. Declared in `data-model.md` §6 and assigned to `007` by §15.2, but
  **007 shipped without it.** Adds no constraints beyond the spec — see below
- `008_riders` — `riders`, `driver_shifts`, `delivery_assignments`, `rider_location_pings`, plus
  `effective_cash_limit_v1`

`order_eta_snapshots` exists so "were we late?" is a query rather than an argument: `promised_at` is
what the customer was shown, `predicted_at` is what the system believed at `computed_at`, and the gap
between them is the ETA error. `sub_order_id` is nullable — null is an order-level snapshot, set is a
per-vendor one — which is how §6's three-rows-per-order budget resolves.

`007c` is deliberately a plain DDL translation, unlike `006`, `007` and `008`: no money columns to
guard, **no append-only revoke**, and no `computed_at`-not-in-the-future `CHECK` even though `008`
added the equivalent guard on `rider_location_pings.recorded_at`. That constraint protects a
trip-duration calculation; this table feeds a diagnostic query, where minutes of clock skew cost
nothing and a constraint that blocks an analytics write costs debugging. A revoke would also collide
with the policies migration `014` has yet to write. The omissions are recorded in the migration so
they read as decisions rather than oversights.

`rider_location_pings` is created **empty and stays empty until Phase 8**. ADR 9 defers live
tracking, `contracts.md` defines no RPC that writes to it, and the writer is the Durable Object.
Kept deliberately, for when the tracking API exists. It is created **plain and unpartitioned** —
see open question 3.10. It is also the highest-volume table in the database, budgeted at 4.0 KB per
order, which is why `riders.current_latitude` / `current_longitude` / `last_location_at` exist
alongside it: those three columns are enough to ship "where is my rider", and only the trip trail
needs the pings table.

`order_eta_snapshots` is specified in `data-model.md` §6 and §15.2 but **does not exist yet**, in the
repository or in the database. Not yet migrated.

Verified against the live database rather than assumed: **0 unindexed foreign keys**, every
`security definer` function pinned to `search_path = ''`, and the profile gate proven across six
cases — the trigger fires on sign-in, grants the base `customer` role, leaves the profile
incomplete, rejects a completion with no phone, accepts a valid one, and rejects a duplicate phone.

`order_eta_snapshots` was proven to answer its question rather than merely exist: a two-vendor order
with one envelope snapshot predicted 4 minutes late and two vendor snapshots at −6 and +9 minutes
returns a mean error of 2.3 minutes across 3 rows — 1 order-level, 2 vendor-level — which is exactly
the arithmetic inserted.

**Defect found by applying rather than reading:** `users.id uuid primary key default
auth.users(id)` is illegal — Postgres rejects a column reference in a `DEFAULT` expression
(`ERROR 0A000`). `data-model.md` carried the same bug and was corrected in the same change, so the
spec and the database do not disagree.

### Changed

- **`008` adds constraints that are not in `data-model.md` §8.** Flagged in the migration and
  reversible by dropping the constraint. Each was verified to reject the bad case:
  - Money and domain `CHECK`s on `riders` and `delivery_assignments`, following the rule `007`
    established. Includes `delivery_assignments_rider_pay_sums`, so a frozen pay breakdown cannot
    disagree with its own total.
  - `riders_is_online_consistent` — §8 declares **both** `status` and `is_online` without saying how
    they relate, which is the same desync shape that let `menu_items.vendor_id` drift in `005b`. The
    constraint enforces `is_online = (status <> 'offline')`. **This assumes the two are the same
    fact.** If `is_online` instead means "the app is open" while `status` means "delivery state",
    the constraint is wrong and should be dropped.
  - `driver_shifts_no_overlap` — an `EXCLUDE USING gist` constraint preventing one rider from
    holding two overlapping active shifts, which would let a single rider be matched to two
    concurrent orders. This is what migration `001` installs `btree_gist` for.
  - `riders_location_has_time` — a position with no timestamp reads as current and is not.
  - `effective_cash_limit_v1` does **not** check `p_rider_id` against the caller, so any
    authenticated user can read any rider's cash limit. Minor, but the guard belongs with the
    caller-identity rules in migration `018`.
- **`driver_shifts.area_ids` stays a `uuid[]`, as specced.** §16 removed JSON arrays from `vendors`
  for exactly this reason — "JSON arrays cannot be indexed; forces a scan on every availability
  check" — and then used an array here. A join table would be consistent with `vendor_areas` and
  would make the shift-area lookup indexable. Not changed unilaterally: that means adding a table
  nobody approved. Recorded for a decision.

### Fixed

- **`orders.item_count` could never become non-zero.** `sync_order_status()` derives `item_count`
  from `order_items`, but it was only ever attached to `sub_orders`. `order_items.sub_order_id` is a
  `NOT NULL` foreign key, so an order line cannot exist until after its sub-order does — the
  aggregate was therefore always recomputed *before* any line was counted, and nothing recomputed it
  afterwards. Every order would have carried `item_count = 0` while holding real items.

  Proven by execution, not inference, on a two-vendor order:

  | step | before | after | actual |
  |---|---|---|---|
  | after inserting lines | 0 | 5 | 5 |
  | one of two sub-orders accepted | 0 | 5 | 5 |
  | a line's quantity 2 → 4 | 0 | 7 | 7 |
  | a line deleted | 0 | 4 | 4 |
  | both sub-orders delivered | 0 | 4 | 4 |

  `vendor_count` was always correct, because it reads `sub_orders` — the table that actually fired the
  trigger. That asymmetry is what identified the cause.

  Fixed in `007b`. The aggregate `UPDATE` moved into `private.recompute_order_aggregates(uuid)` so
  `sub_orders` and `order_items` share one definition instead of two copies that can drift, and
  `order_items` gained statement-level triggers for insert, update and delete. The UPDATE trigger
  reads both transition tables, because `order_items.order_id` is derived from `sub_order_id` — so
  moving a line to a different sub-order moves it to a different order, and the order it left would
  otherwise keep counting a line it no longer has. The helper lives in `private` because it takes an
  argument, which would otherwise make it a callable PostgREST RPC — the problem `005e` moved
  `private.is_admin()` out of `public` to solve.

### Security

- Purged an Apple App Store Connect private key (`*.p8`) and an iOS distribution certificate
  (`*.cer`) from git history after they were committed by a `git add -A`. `.gitignore` extended
  to cover `*.p8 *.cer *.p12 *.pfx *.jks *.mobileprovision` and the `appstore/` directory.
  `git add -A` is now forbidden by the commit protocol in `AGENTS.md`.
- The App Store Connect key should still be revoked and regenerated. It was never pushed to a
  remote, but an App Store Connect key can read sales data and manage builds, and it does not
  expire on its own.

### Deprecated

- `architecture-spec-supabase-cloudflare-firebase.md` — the original v1 architecture spec.
  Superseded. Marked with a contradiction table so it is not implemented from by mistake. Retained
  only as a historical artifact.

## Known gaps

Recorded in `open-questions.md` §6. The significant ones:

- Migrations 009–022 have **not** been written. `009` (`money`) is next, and is where `payouts`
  lands — therefore where `sub_orders.payout_id` gets its foreign key.
- No application code. No `apps/`. No `package.json`.
- `npm run typecheck`, `npm run lint`, `npm test`, `npm run verify` do not exist, so **no
  engineering checklist can currently be signed off.** See `AGENTS.md` §Verification commands.
  Migration assertions to date have been run by hand against the live database.
- `scripts/check-test-integrity.mjs` does not exist, so rule 4 is unenforced.
- `scripts/check_schema_drift.py` exists and compares the live database against `data-model.md`, but
  it reports rather than gates: no baseline has been agreed, so its findings are not yet a build
  failure.
- RLS is disabled on all 32 tables. Grants are revoked, so `anon` and `authenticated` can read
  nothing; the policies land in `014`.
- The spec has never been reviewed by a human. Every number in it is a proposal.