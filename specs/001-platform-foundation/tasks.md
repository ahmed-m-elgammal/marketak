# Tasks — Spec 001

Ordered by dependency. Each task is independently shippable. Money-touching tasks are marked 🔒.

Phases 0–2 are the path to "an order can be placed at the correct price". Nothing after Phase 2
should begin until the price-change rejection path is tested.

---

## Phase -1 — Infrastructure ✅ DONE

Account and tooling setup. Nothing here is application code, and none of it appears in a commit.

- [x] **T-1.1** Node v22.16.0 / npm 10.9.2 verified
- [x] **T-1.2** Supabase CLI 2.119.0 installed globally
- [x] **T-1.3** `wrangler` 4.86.0 installed and authenticated as `ahmedmelgammal6@gmail.com`,
      account `8ae79d52c8b84a170bcb5c4c0485f34c`
- [x] **T-1.4** `firebase` CLI installed and authenticated as `ahmedmelgammal6@gmail.com`
- [x] **T-1.5** MCP: `cloudflare`, `cloudflare-docs`, `cloudflare-bindings`, `cloudflare-builds`,
      `cloudflare-observability`, `supabase`, `firebase` — all connected. Config in
      `~/.config/opencode/opencode.jsonc`
- [x] **T-1.6** Agent skills installed: 16 Cloudflare, 13 Firebase, 2 Supabase → `~/.agents/skills`.
      Relevance noted in `ENVIRONMENT.md` §5
- [x] **T-1.7** Git initialised on `main`, `.gitignore` written, spec committed as `d033c7d`
- [x] **T-1.8** `AGENTS.md`, `ENVIRONMENT.md`, `decisions.md`, `open-questions.md` written
- [x] **T-1.9** Stale `architecture-spec-…md` marked SUPERSEDED with a contradiction table
- [x] **T-1.12** Supabase project `marketak` created — ref `erxxsebcqqcpkipzcdhg`, `eu-central-1`,
      Postgres 17.11, ACTIVE_HEALTHY. Extensions verified available: `pg_trgm`, `btree_gist`,
      `unaccent`, `pg_cron`, `pg_net`, **`pgtap`**, `pg_partman`, `earthdistance`, PostGIS
- [x] **T-1.13** Firebase project `marketak-eg` created (number `283007295790`) and set active
- [x] **T-1.14** R2 enabled in the dashboard. Buckets `marketak-public` and `marketak-private`
      created in `EEUR`
- [x] **T-1.17** Android and iOS apps registered on `marketak-eg` with bundle/package
      `com.jaylak.mobile`. One app for customer + rider, role-switched (ADR 15)
- [ ] **T-1.15** Scope the Supabase MCP to `?project_ref=erxxsebcqqcpkipzcdhg` and add a read-only
      variant. Recipe in `ENVIRONMENT.md` §4.3. **Requires editing the global config, so a restart**
- [ ] **T-1.16** Buy a domain and point it at Cloudflare, then `cdn.`, `track.`, `admin.`,
      `vendor.` hosts. **BLOCKED on purchase** — see `open-questions.md` §3.1
- [ ] **T-1.18** Add the Android release SHA-1 and SHA-256 to the Firebase app. Needed the moment
      App Check or phone-auth verification is switched on
- [ ] **T-1.19** Upload an APNs key once an Apple Developer account exists. **Until then iOS
      receives no push notifications at all** — see `open-questions.md` §1.11
- [ ] **T-1.10** Install Docker Desktop — unblocks `supabase start` for local dev. Optional
- [ ] **T-1.11** Prune the 22 irrelevant agent skills. Optional but recommended

---

## Phase 0 — Foundation

- [x] **T0.1a** **Extract every fenced SQL block out of `data-model.md` into
      `supabase/migrations/*.sql`, numbered per `data-model.md` §15.2.** Do not hand-write these.
      Doing this by hand is how the spec and the database drift apart.
      **Partially done:** 001–009t written **and applied** to `erxxsebcqqcpkipzcdhg`.
      44 tables, 164 indexes, 0 unindexed foreign keys, profile gate verified across six cases.
      005a–005e, 007a, 007b and 007c are forward fixes written after auditing what actually ran, which
      is the pattern to keep — `data-model.md` §15.1 rule 3 forbids editing an applied migration.
      **Remaining: 021–022, plus six unbuilt money functions** from `contracts.md` §1.8
      (open question 3.30 — `freeze_wallet_v1`, `list_frozen_v1`, `get_commission_v1`,
      `set_commission_rule_v1`, `get_fee_rules_v1`, `set_fee_tier_v1`; the other three contract names are
      folded into `run_payout_v1`). `013` shipped `events`, `014`/`014a` shipped RLS, `015` shipped search,
      `016`/`020` shipped the profile and read RPCs in parallel, `017` shipped checkout, `018` shipped rider
      delivery, `018a` fixed its revenue calculation, and `019` shipped reconciliation and payouts with
      `019a`/`019b` fixing two defects found by executing it; `008` shipped
      `rider_location_pings` **plain and unpartitioned** per
      open question 3.10 — it stays empty until Phase 8, and partitioning it becomes an additive
      migration when the tracking API lands. `order_eta_snapshots` shipped in `007c`, which completes
      the orders domain of §6. `009` shipped the money domain and **added the `sub_orders.payout_id`
      foreign key** that `007` had left out because `payouts` did not exist yet.
      Three conflicts between `data-model.md` §7 and the constitution were resolved **in favour of the
      constitution** and flagged in the changelog: `commission_rules.value` became integer basis
      points (rule III.3), `payouts` gained `idempotency_key` (rule III.5), and
      `platform_float.variance` gained a `CHECK` tying it to `cash_expected - cash_remitted` (rule
      III.10). `wallets.balance` intentionally has **no** non-negativity check — a negative balance is
      a real state.
- [ ] **T0.1** Repo scaffold: `supabase/` (migrations, functions, seed), `apps/mobile`
      (customer + rider, one binary, role-switched), `apps/admin-web`, `apps/vendor-web`,
      `packages/shared`
      (types, error codes, money helpers), `packages/ui`
- [ ] **T0.1b** Create `FEATURES.md` ✅ **done in this commit** and `CHANGELOG.md` ✅ **done in
      this commit**. Keep them updated per Checklist A6 / B6 / C6 — a deliverable without a
      `CHANGELOG` line is an undocumented deliverable
- [ ] **T0.1c** Create the verification toolchain, or **no checklist in `AGENTS.md` can be signed
      off and an agent must say so instead of claiming verification passed**:
      - [ ] root `package.json` with workspaces
      - [ ] `npm run typecheck` → `tsc --noEmit`, `"strict": true`
      - [ ] `npm run lint` → ESLint flat config with `@typescript-eslint`
      - [ ] `npm test` → Jest, with a `pgtap` runner for the SQL tests
      - [ ] `npm run verify` → typecheck + lint + test + test-integrity
      - [ ] `scripts/check-test-integrity.mjs` → fails on `.skip` / `.only` / `.xit`, on
            tautological assertions (`expect(x).toBe(x)`, empty `it` bodies), and on coverage
            regressions below the floor. This is the only enforcement of rule 4
      - [ ] `scripts/check-policies.mjs` → fails on a bare `auth.uid()` inside a policy, on
            `set search_path = public` in a `security definer` function, and on an unindexed
            foreign key (runs the `pg_constraint` query in `data-model.md` §14.2 against the
            database). Enforces `data-model.md` §13.2 and §14.2 mechanically
- [ ] **T0.1d** Decide the styling approach (open question 3.9): plain `StyleSheet` against a
      `src/theme/` token module, or NativeWind. **Blocks Checklist A4 and C3.** Default to plain
      StyleSheet + tokens unless there is a reason not to
- [ ] **T0.1e** `scripts/precommit.sh` — refuse a commit that stages a secret, by scanning the
      index for `*.p8 *.pem *.key *.cer *.p12 *.mobileprovision .env*`. Belt and braces: the
      ignore list already missed an Apple key once
- [x] **T0.2** Migration 001: `pgcrypto`, `pg_trgm`, `btree_gist`, `unaccent`, `pg_partman`.
      **Applied.** `postgis` is available but deliberately not installed — area matching is
      geohash-prefix plus a haversine distance, so nothing depends on it
- [ ] **T0.2a** Create the `private` schema and revoke public access:
      `revoke all on schema public from public`, plus `alter default privileges`. See
      `data-model.md` §13.3. **Deferred to migration 014**, which is where RLS lands
- [x] **T0.2b** Migration 003 installs `on_auth_user_created` with `security definer` and
      `search_path = ''`, and revokes `EXECUTE` from `public, anon, authenticated`.
      **Verified on the live database**
- [ ] **T0.2c** Partition `notifications`, `rider_location_pings` and `audit_log` by month.
      **`events` is deliberately EXCLUDED** — `013` shipped it unpartitioned. Monthly granularity
      over-holds a 7-day retention window by up to 37 days, which measures at 239 MB against a 400 MB
      ceiling versus 45 MB unpartitioned. See T3.3.
      (`data-model.md` §14.1). `pg_partman` 5.3.1 installed. Do **not** partition
      `ledger_entries`
- [ ] **T0.2d** `scripts/check-policies.mjs` is now the mechanical gate. Run these three queries
      after migration 014 and require: zero unindexed foreign keys, every `prosecdef` function with
      `search_path=''`, and no bare `auth.uid()` inside a policy body
- [ ] **T0.3** Migration 002: `cities`, `areas`, `delivery_zones`, `delivery_fee_tiers`, `settings`.
      Seed the operating city (not hardcoded) plus ~20 areas with real geohash prefixes, and the
      1/2/3-vendor tiers at 10000/11000/12000 bps
- [ ] **T0.4** Migration 003: `users`, `user_roles`, `user_auth_providers`, `addresses`,
      `device_tokens`, `feature_flags`. Trigger: `auth.users` insert → `users` row with
      `profile_completed_at = null`
- [ ] **T0.5** Migration 004: `brands`, `vendors`, `vendor_areas`, `vendor_schedules`,
      `vendor_holidays`, `cuisines`, `vendor_cuisines`, `vendor_staff`
- [x] **T0.6** Migration 014 (part): `updated_at` triggers, RLS policies for identity and vendor
      tables, `feature_flags` seed rows — **RLS shipped as `014` + `014a`.** RLS is on all 62 tables
      and partitions, 115 policies, `authenticated` holds `SELECT` on 51 tables and **no write
      privilege anywhere**, `anon` holds nothing. Three spec defects were found by testing rather than
      reading, and are recorded as ADR 17–20: §13.2's helper pattern was non-functional, RLS does not
      propagate to partitions, and one policy reused across the order subtree leaked a co-vendor's
      sub-orders. `feature_flags` seed rows are still outstanding
- [ ] **T0.7** `get_areas_v1`, `get_feed_manifest_v1`, `get_vendor_feed_v1`, `get_vendor_detail_v1`
- [x] **T0.8** Search: normalised generated columns, trigram indexes, `search_catalog_v1` —
      **done in `015`.** `normalize_text_v1` with `text` and `jsonb` overloads, 10 generated columns,
      10 partial trigram indexes, `haversine_km`, and `search_catalog_v1` as
      `SECURITY DEFINER` re-implementing §13.1's visibility rules. Two caveats recorded rather than
      hidden: **the trigram indexes are unused by the planner at the ~4,500-item launch scale** (a seq
      scan wins at 40,000 rows in testing), and **`menu_items.ingredients` has no specified jsonb
      shape**, so the overload flattens all three jsonb types mechanically and would match nothing if
      the searchable part turned out to be the object's keys
- [ ] **T0.9** Seed script: 150 vendors across 20 areas, lunch-only schedules, split shifts
- [ ] **T0.10** Auth: **Google and Apple only.** Native SDK sign-in via `signInWithIdToken`,
      account linking for a user who has both identities, custom SMTP
- [ ] **T0.11** `get_flags_v1`, `get_setting_v1`, `set_setting_v1`
- [ ] **T0.12** `get_profile_status_v1`, `complete_profile_v1`, `update_profile_v1`
- [ ] **T0.13** Profile-completion screen: name, phone, first address. Reachable from settings
- [ ] **T0.14** pgTAP: an incomplete profile can browse but `place_order_v1` raises
      `PROFILE_INCOMPLETE`, and an RLS `insert` on `orders` is denied
- [ ] **T0.15** `effective_cash_limit_v1` and the `rider_max_cash_held_default` setting
- [ ] **T0.16** pgTAP: `phone_number` is required once `profile_completed_at` is set, and the check
      constraint rejects a completion without one

**Exit:** sign in with Google, complete a profile, browse and search vendors against seeded data.

---

## Phase 1 — Catalog and offline cache

- [ ] **T1.1** Migration 005: `menu_categories`, `menu_items`, `item_options`, `option_choices`,
      the `vendor_id` sync trigger and the `menu_version` bump trigger
- [ ] **T1.2** Vendor menu CRUD RPCs (`upsert_menu_item_v1`, `delete_menu_item_v1`, …)
- [ ] **T1.3** `get_menu_v1` as the fallback path
- [ ] **T1.4** `upload-signer` Worker: JWT + `vendor_staff` check → signed R2 upload URL
- [ ] **T1.5** On-device image resize and WebP compress (max 800 px, target 30 KB) before upload
- [ ] **T1.6** `snapshot-builder` Worker: read menu via RPC → write
      `menus/{vendor_id}/v{n}.json` to R2
- [ ] **T1.7** Customer app: vendor feed from the R2 snapshot, images from the CDN
- [ ] **T1.8** SQLite layer with SQLCipher: key from Android Keystore, non-exportable
- [ ] **T1.9** `catalog_cache` table + version-aware refresh on `menu_version` change
- [ ] **T1.10** Full offline browse test: airplane mode, cold start, open 3 menus, add to cart
- [ ] **T1.11** `sync_changes_v1` cursor endpoint

**Exit:** a vendor edits a price and the change appears on a cold-started device within one
`sync_changes_v1` round trip.

---

## Phase 2 — Cart, pricing and order creation 🔒

- [ ] **T2.1** Migration 006: `carts`, `cart_items` (with `cached_price` marked non-authoritative)
- [ ] **T2.2** Cart RPCs + `cart_summary_v1`
- [ ] **T2.3** Customer app: cart UI grouped by vendor, per-vendor subtotal and minimum
- [ ] **T2.4** Migration 007: `orders`, `sub_orders`, `order_items`, `order_status_history`,
      `order_modifications`, `order_eta_snapshots`
- [ ] **T2.5** `quote_order_v1`: re-read catalog, validate, compute per-vendor and order totals,
      compute the fingerprint
- [ ] **T2.5a** Fee calculation inside the quote: `base × multiplier(vendor_count)/10000` +
      distance beyond `free_radius_km × per_km_fee`. Read from `delivery_zones`,
      `delivery_fee_tiers`, `settings`. Return the full `fee_breakdown` so the app can show it
- [ ] **T2.5b** Vendor cap enforcement: `upsert_cart_item_v1` and `quote_order_v1` both raise
      `TOO_MANY_VENDORS` past `max_vendors_per_order`, and the cart UI blocks it before checkout
- [ ] **T2.5c** pgTAP for the fee: 1/2/3 vendors → ×1.00/×1.10/×1.20 of base; 3.4 km adds nothing
      inside a 5 km free radius and 7 km adds 2 × per-km; a 4th vendor is refused; a changed
      multiplier changes the quote
- [ ] **T2.6** `apply_voucher_v1`
- [ ] **T2.7** `place_order_v1`: profile gate first, then re-price inside the transaction,
      `PRICE_CHANGED` with an itemised diff on mismatch, create order + sub-orders + items +
      history + `events`. **Freeze `delivery_base_fee`, `delivery_multiplier_bps`, `distance_km`
      and `vendor_limit_applied` onto the order**
- [ ] **T2.8** Customer app: quote screen showing the delivery fee with the vendor-count uplift in
      plain language, price-changed diff sheet with mandatory re-confirmation
- [ ] **T2.9** `cancel_order_v1` with the status policy
- [ ] **T2.10** pgTAP: `PRICE_CHANGED` aborts and the diff is correct
- [ ] **T2.11** pgTAP: with 3 vendors in a cart, sub-orders, items, fees and payouts are all correct
- [ ] **T2.12** Idempotency: the same `idempotency_key` twice creates exactly one order
- [ ] **T2.13** `orders.status` derived-cache trigger
- [ ] **T2.14** pgTAP: changing `delivery_fee_tiers` today does not alter yesterday's order totals

**Exit:** a multi-vendor order is created at the correct price, and a mid-checkout price change
produces a clear diff the customer must accept. **Gate: do not proceed until this is proven.**

---

## Phase 3 — Vendors, riders, dispatch

- [ ] **T3.1** Migration 008: `riders` (`car`, `bicycle`, `motorcycle`,
      `scooter`), `driver_shifts`, `delivery_assignments`, `rider_location_pings`
- [ ] **T3.2** Migration 010: `reviews`, `favorites`, `favorite_items`, `notifications`,
      `notification_templates`
- [x] **T3.3** Migration 013: `events` — **done, and shipped UNPARTITIONED on measured evidence.**
      §14.1 lists it as a monthly-partitioned prune target, but its own rationale cannot hold for a
      7-day retention window. Both designs were benchmarked on the live database: partitioning was
      faster per statement (prune 1.77 vs 3.52 ms) yet costs **239 MB vs 45 MB** at peak, because a
      month-old partition cannot be dropped until ~7 days into the next month. Keeping it plain also
      preserves §11's `id bigserial primary key` and `unique id_uuid` verbatim, which partitioning
      would have forced down to the weaker `(id_uuid, created_at)` — a real weakening of the
      "downstream idempotency key" that `contracts.md` §6 relies on in three places
- [ ] **T3.4** `outbox-dispatcher` Worker, webhook path for `order.placed`,
      `vendor.rejected_sub_order`, `driver.assigned`
- [ ] **T3.5** `pg_cron` batched event drain every 15 s, `claim_events_v1(50)`,
      `mark_events_delivered_v1(ids)` — one mark per batch
- [ ] **T3.6** FCM via HTTP v1, WebCrypto JWT signing, Google access token cached 55 minutes
- [ ] **T3.7** `transition_sub_order_v1` with the full state machine, validated in pgTAP
- [ ] **T3.8** `orders.status` and ETA recomputation on every transition
- [ ] **T3.9** Vendor dashboard: accept / reject with reason, bulk prepare, ready, out-of-stock
- [ ] **T3.10** `vendor_staff` RLS: a vendor sees only its own sub-orders, plus the delivery
      address and nothing else
- [ ] **T3.11** Rider app: online status, nearby orders, `claim_order_v1` atomic claim
- [ ] **T3.12** pgTAP: two concurrent `claim_order_v1` calls produce exactly one winner
- [ ] **T3.13** Rider app: multi-stop pickup list computed at assignment, `stop_sequence` stored
- [ ] **T3.14** `get_active_trip_v1`, `arrive_vendor_v1`, `confirm_pickup_v1`
- [ ] **T3.15** `report_issue_v1`; collection RPCs arrive in Phase 4
- [ ] **T3.16** ETA calculation: `max(sub_order.ready_estimate) + pickup legs + delivery leg`,
      with a lunch buffer
- [ ] **T3.17** Merchant dashboard on Cloudflare Pages, static, reading through RPC

**Exit:** a real order flows customer → vendor → rider → delivered, with push at each step.

---

## Phase 4 — Payment at delivery and the ledger 🔒

- [ ] **T4.1** Migration 009: `commission_rules`, `wallets` (vendor/rider only), `ledger_entries`,
      `payouts`, `payout_lines`, `platform_float`, `rider_pay_rules`. Seed the **active rider cut**
      and the **inactive vendor row**
- [ ] **T4.2** Append-only rules on `ledger_entries`, plus the ledger view and balance function.
      `account_type` has no `customer` value
- [ ] **T4.3** `wallets.version` optimistic concurrency; pgTAP for a concurrent collection and
      admin adjustment
- [ ] **T4.4** `begin_collection_v1` with the `effective_cash_limit_v1` guard
- [ ] **T4.5** `collect_cash_v1` — writes `cash_collected`, increments `cash_expected` and
      `riders.cash_held`
- [ ] **T4.6** `collect_wallet_v1` — records `payment_channel` and a reference and **writes no
      platform cash movement**, because the money never touched the platform
- [ ] **T4.7** Rider pay resolution at claim time: read `rider_pay_rules`, freeze
      `rider_pay_base` / `_distance` / `_bonus` / `_total` and `platform_revenue` onto
      `delivery_assignments`. Raise `NO_PAY_RULE` when no rule resolves
- [ ] **T4.8** `rider_cut` ledger entry on completion — the platform's launch revenue
- [ ] **T4.9** pgTAP: `rider_pay_total` never exceeds `pct_of_delivery_fee_bps` of the delivery
      fee; a pay-rule change never alters an existing assignment; a wallet-paid order writes zero
      platform cash entries
- [ ] **T4.10** Customer app: payment choice at delivery — cash, or wallet with the Vodafone Cash /
      Instapay channel and a reference field. No balance to display
- [ ] **T4.11** Rider app: collection screen, amount due, `cash_held` running total, a warning at
      80% of the limit, and wallet collection offered as the alternative when cash is blocked
- [ ] **T4.12** `get_platform_float_v1`, `reconcile_day_v1`
- [ ] **T4.13** Admin reconciliation view: expected cash vs banked vs owed, per account, per day,
      with a required written explanation for any non-zero variance
- [ ] **T4.14** `adjust_wallet_v1` (admin, mandatory reason), `freeze_wallet_v1`, `list_frozen_v1`
- [ ] **T4.15** pgTAP: ledger sums equal cached balances after 100 simulated orders
- [ ] **T4.16** pgTAP: a reversing entry balances to zero and the original row is untouched
- [ ] **T4.17** pgTAP: `adjust_wallet_v1` with an empty reason is rejected
- [ ] **T4.18** Manual acceptance run: 100 orders, cash and direct-transfer mixed, compared against
      a real bank or Vodafone Cash statement. `platform_float.variance = 0`

**Exit:** both collection paths record correctly, the rider's pay is frozen and defensible, and the
daily cash reconciliation balances exactly against an external statement.

---

## Phase 5 — Payouts, earnings, growth

- [x] **T5.1** Migration 012: `rider_earnings_daily`, `event_daily_stats`, `search_daily_stats`,
      `auth_daily_stats`, `audit_log` — **done, six spec defects corrected.** `vendor_earnings_daily`
      already existed from `004`, so the original list overstated the scope; `rider_earnings_daily`
      had never been created by `008` despite being listed here. See `CHANGELOG.md`.
- [ ] **T5.2** Rollup RPCs, `pg_cron` nightly. **`unique_users` must be recomputed over the affected
      window, not incremented** — it is an exact distinct count and is not incrementally upsertable.
      `021` must also satisfy the `zero_result` and `clicks <= results_count` checks in `012`.
- [ ] **T5.3** `run_vendor_payout_v1`, `run_rider_payout_v1`, `approve_payout_v1`;
      `payable → in_payout → settled` in one transaction
- [ ] **T5.4** pgTAP: a sub-order cannot be paid twice; a second payout run finds nothing payable
- [ ] **T5.5** Vendor dashboard: "earned today" and period history, split by cash vs direct transfer
- [ ] **T5.6** Rider app: earnings, `cash_held`, settlement history
- [ ] **T5.7** Migration 011: `vouchers`, `voucher_redemptions`, `promo_slots`
- [ ] **T5.8** Voucher engine inside `quote_order_v1`, including vendor scoping and per-vendor
      discount shares
- [ ] **T5.9** pgTAP: `usage_limit_total`, `usage_limit_per_user`, `max_discount_cap`,
      `min_order_value`, expiry, `first_order_only`
- [ ] **T5.10** `rate_order_v1` with separate vendor and rider ratings; `vendors.rating_avg` trigger
- [ ] **T5.11** `reorder_v1` with unavailable-item handling
- [ ] **T5.12** Admin: metrics, ETA accuracy, payout approval
- [ ] **T5.13** `get_commission_v1` + `set_commission_rule_v1` — verify the rider cut is active and the
      vendor row is not; then activate the vendor rule and confirm the quote changes, `effective_from`
      is `now()`, and no historical sub-order was repriced.
      **This is the test that proves month-3-4 commission activation needs no migration**
- [ ] **T5.14** Admin: fee tier editor (`set_fee_tier_v1`) and a rider pay rule editor, both live.
      Changing a multiplier must not alter any existing order
- [ ] **T5.15** pgTAP: activating the vendor commission applies only to sub_orders created after
      `effective_from`

**Exit:** a vendor sees what he earned today and can be paid; a voucher cannot be abused.

---

## Phase 6 — Operations

- [ ] **T6.1** `notifications` inbox in the mobile app and both dashboards, pruned at 30 days
- [ ] **T6.2** Feature flags surfaced in the admin console; every flag has a default in the app
- [ ] **T6.3** Force-update screen driven by `min_app_version_android` / `_ios`
- [ ] **T6.4** Maintenance mode banner
- [ ] **T6.5** Vendor onboarding: apply → admin approve → schedule → menu
- [ ] **T6.6** Rider verification: documents via signed URLs
- [ ] **T6.7** Crashlytics with `app_role`, app version, current screen, active `order_id`;
      hashed user ids only
- [ ] **T6.8** Firebase Analytics funnel events; no PII in events or properties
- [ ] **T6.9** `export-jobs` Worker: nightly incremental export of `ledger_entries`, `orders`,
      `sub_orders`, `order_items`, `wallets`, `payouts`, `platform_float` to R2 private, 30-day rotation
- [ ] **T6.10** **Restore test.** Restore a full backup to a scratch project and reconcile balances
      against the source. An untested backup is not a backup
- [ ] **T6.11** Connection pooler configured for every server-side Supabase caller
- [ ] **T6.12** 70% alerts on: DB size, egress, Workers requests, DO duration, DO rows, R2 ops

**Exit:** a kill switch works without a release, and a backup has been proven to restore.

---

## Phase 7 — Retention and archive

- [ ] **T7.1** `pg_cron` prune jobs, all batched with `limit` + `pg_sleep`, each with an index on
      its prune column: `events` 7 d, `notifications` 30 d, `rider_location_pings` 30 d,
      `order_eta_snapshots` 24 h, collection proof paths 90 d, `audit_log` 365 d
- [ ] **T7.2** `archive_orders_v1`: at 60 days move `order_items` and `order_status_history` to
      R2 `private/archive/orders/YYYY/MM/{order_id}.json`, keep the slim `orders` row
- [ ] **T7.3** `get_order_v1` serves archived detail via signed URL
- [ ] **T7.4** Analytics monthly aggregate export to R2 (2-year cold requirement). Note there are no
      wallet top-up proofs to prune any more
- [ ] **T7.5** Nightly `VACUUM ANALYZE` on `orders`, `order_items`, `events`, `notifications`
- [ ] **T7.6** Dead-letter alert on `events` older than 1 hour
- [ ] **T7.7** Weekly size report per table; recalibrate the free-tier model against measurements
- [ ] **T7.8** Re-run the `free-tier-plan.md` arithmetic with real numbers. Replace every estimate

**Exit:** measured bytes per order are documented, and the wall-clock date for the free tier is
known with real data.

---

## Phase 8 — Live tracking (deferred)

**Do not start until Phase 7 is complete and measured usage justifies it.** See
`free-tier-plan.md` §6.

- [ ] **T8.1** `OrderRoom` and `BranchInbox` Durable Objects, `acceptWebSocket` hibernation only
- [ ] **T8.2** `tracking-gate` Worker: JWT + `can_track_order_v1`, never a client-supplied role
- [ ] **T8.3** `live_tracking_enabled` flag, default off, targetable per area
- [ ] **T8.4** Driver ping loop behind the flag, interval from `driver_ping_interval_sec`
- [ ] **T8.5** One location row per minute, not per ping; latest point in the socket attachment
- [ ] **T8.6** `save_route_summary_v1` on delivery, then object self-destruct
- [ ] **T8.7** Fallback ladder: push → 90 s poll → static ETA
- [ ] **T8.8** Measure DO duration against the 13,000 GB-s/day cap before enabling broadly

---

## Cross-cutting

- [ ] **X.1** `pgTAP` policy tests in migration 022: every cross-tenant read returns zero
      rows, and the profile-completion insert guard holds. Build fails without them
- [ ] **X.2** k6 load test: 100 concurrent `place_order_v1` through the lunch window, p95 < 900 ms
- [ ] **X.3** Detox: offline cart → reconnect → exactly one order placed
- [ ] **X.4** Detox: force-kill during `place_order_v1` → retry with the same idempotency key →
      one order
- [ ] **X.5** Error catalogue wired end to end; no raw Postgres message ever reaches a user
- [ ] **X.6** Arabic and English coverage for every customer-facing string
- [ ] **X.7** Accessibility pass: contrast, minimum 48 px touch targets, screen-reader labels on
      the cart and checkout
- [ ] **X.8** Offline behaviour documented per screen; nothing dead-ends
- [ ] **X.9** Weekly review checklist (`free-tier-plan.md` §11) running from week 1
- [ ] **X.10** Restore drill rehearsed before the first real order, not just before the first audit