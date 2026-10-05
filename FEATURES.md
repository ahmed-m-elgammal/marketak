# Features

Every feature the platform is specified to have, and its real state. **No application code exists**; what
is shipped below is database behaviour, verified by direct SQL. See `CHANGELOG.md` for the per-migration
record. **Checkout (C-02, C-08, C-10) was swept at `017a`/`017b` and the rows above are live.** Every other
row is still last swept at `019`, so rows for earlier migrations may still read as not started where the
RPC in fact exists.
This file exists so Checklist A step 6 has somewhere to add a line, and so nobody has to guess what
exists.

Legend: ⬜ not started · 🟡 in progress · ✅ shipped · ❌ cut · DB ready = the database capability exists and
is verified, but no user-facing surface can call it yet, because no application code exists

---

## Customer

| # | Feature | State | Spec |
|---|---|---|---|
| C-01 | Sign in with Google or Apple | ⬜ | FR-C-01 |
| C-02 | Profile completion gate — name, phone, first address. **No profile, no ordering** | ✅ | FR-C-01, §1.2 |
| C-03 | Addresses with default, area label, landmark, delivery instructions | ⬜ | FR-C-02 |
| C-04 | Browse vendors by area, vertical, open-now | ⬜ | FR-C-03 |
| C-05 | Arabic + English search with tashkeel and alef/ya/ta-marbuta normalisation | ⬜ | FR-C-03 |
| C-06 | **Multi-vendor cart**, grouped and totalled per vendor, max 3 vendors | ⬜ | FR-C-04 |
| C-07 | Cart survives app restart, device change and offline | ⬜ | FR-C-05 |
| C-08 | Live price quote with the vendor-count uplift shown in plain language | ✅ | FR-C-06, §2.5 |
| C-09 | Voucher application, scoped per vendor or order-wide | DB ready | FR-C-07 |
| C-10 | Place an order, human-readable order number | ✅ | FR-C-08 |
| C-11 | **Choose cash or wallet at delivery**, not at checkout | ⬜ | FR-C-09 |
| C-12 | Cancel while allowed, policy-gated, reason recorded | ⬜ | FR-C-10 |
| C-13 | Order status and ETA | ⬜ | FR-C-11 |
| C-14 | Live rider location | ⬜ | FR-C-11 — Phase 8, flag defaults off |
| C-15 | Reorder a past order in one tap | ⬜ | FR-C-12 |
| C-16 | Rate vendor and rider **separately** | ⬜ | FR-C-13 |
| C-17 | Offline catalog browse with encrypted SQLite cache | ⬜ | §6.2 |

## Rider

| # | Feature | State | Spec |
|---|---|---|---|
| R-01 | Go online / offline with a shift window | ⬜ | FR-R-01 |
| R-02 | See nearby feasible orders | ⬜ | FR-R-02 |
| R-03 | **Atomic order claim** — exactly one rider wins | ⬜ | FR-R-03 |
| R-04 | Ordered multi-stop pickup list, one drop-off | ⬜ | FR-R-04 |
| R-05 | Collect cash, with a configurable per-rider limit | ⬜ | FR-R-05 |
| R-06 | Confirm a Vodafone Cash / Instapay transfer to their own number | ⬜ | FR-R-05 |
| R-07 | See today's earnings: trips, legs, tips, bonuses, cash held | ⬜ | FR-R-06 |
| R-08 | Cash-limit warning at 80% | ⬜ | FR-R-08 |
| R-09 | Complete a delivery with photo or OTP proof | ⬜ | FR-R-07 |

## Vendor

All vendor surfaces are **web dashboard** (Cloudflare Pages). There is no native vendor app — ADR 15.

| # | Feature | State | Spec |
|---|---|---|---|
| V-01 | Menu CRUD: categories, items, Arabic text, images, prices, stock | ⬜ | FR-V-01 |
| V-02 | Item options with required/optional, min/max, price modifiers | ⬜ | FR-V-02 |
| V-03 | Opening hours with **split shifts** and holidays | ⬜ | FR-V-03 |
| V-04 | Accept or reject a sub-order, with a reason on rejection | ⬜ | FR-V-04 |
| V-05 | Mark preparing, ready, out of stock; request a price change with consent | ⬜ | FR-V-05 |
| V-06 | Live new-order queue | ⬜ | FR-V-06 |
| V-07 | "Earned today" and period history, split cash vs direct transfer | ⬜ | FR-V-07 |
| V-08 | Request a payout and see its status | ⬜ | FR-V-08 |

## Admin

| # | Feature | State | Spec |
|---|---|---|---|
| A-01 | Approve vendors; configure areas, zones, **fee tiers** and **rider pay rules** live | ⬜ | FR-A-01 |
| A-02 | Verify riders and vendors, documents via signed URLs | ⬜ | FR-A-02 |
| A-03 | Daily cash reconciliation, with a written explanation for any variance | ✅ | FR-A-03 |
| A-04 | Create vouchers with scoping, caps and usage limits | DB ready | FR-A-04 |
| A-05 | Set, target and toggle feature flags without a release | ⬜ | FR-A-05 |
| A-06 | Run and approve settlement and payout batches | ✅ | FR-A-06 |
| A-07 | Live order monitor with intervention | ⬜ | FR-A-07 |
| A-08 | Analytics: funnel, area performance, delivery-time percentiles | ⬜ | FR-A-08 |
| A-09 | **Turn vendor commission on** when supply can absorb it | ⬜ | FR-A-09, ADR 3 |
| A-10 | Adjust a vendor or rider wallet, mandatory reason, signed ledger entry | ✅ | FR-A-10 |

**Database capability shipped, features still ⬜.** Three migrations provide the RPCs behind A-01
(areas, zones, fee tiers, vendors), A-02 (vendor approval) and A-09 (turn vendor commission on), plus
a wallet freeze that no feature row covers.

| Migration | What it provides |
|---|---|
| `025_admin_money_config` | `get_fee_rules_v1`, `set_fee_tier_v1`, `get_commission_v1`, `set_commission_rule_v1`, `freeze_wallet_v1`, `list_frozen_v1` |
| `026_admin_geo_vendor` | 30 functions over `cities`, `areas`, `vendors`, `brands`, `cuisines`, `vendor_areas`, `vendor_cuisines`, `vendor_schedules`, `vendor_holidays`, `vendor_staff` — upsert, soft delete, restore |
| `027_admin_menu` | 15 functions over `menu_categories`, `menu_items`, `menu_item_sizes`, `item_options`, `option_choices` — upsert, soft delete, restore |
| `036_voucher_scope_fix` | Makes C-09 possible. An empty `applies_to_vendor_ids` now means **every vendor** rather than none, so "all shops" stops being inexpressible and a voucher survives vendors onboarded later |
| `037_voucher_admin_rpc` | A-04. `admin_upsert_voucher_v1`, `admin_delete_voucher_v1`, `admin_restore_voucher_v1` - the RPCs behind the voucher screen, which had none before |

**Verified end-to-end against the live database.** `036` and `037` were proven by executing the
surface, not by reading it. Scopes all behave: an empty list works everywhere, one vendor applies to
that vendor, two vendors apply to either, and a mis-scoped code is still refused with
`VOUCHER_NOT_APPLICABLE`. Two-vendor checkout money splits exactly - delivery fee 3000 split 1607 +
1393, discount 5600 split 3000 + 2600. Driver claims, delivers and collects cash end to end. The
reusable fixture is `specs/001-platform-foundation/e2e-fixture.json`.

**One known gap.** Reviews never roll up: a 5-star review leaves `vendors.rating_avg` at 0.00 because
nothing on `public.reviews` updates it. C-16 and every vendor rating surface are affected. Not fixed.
A merchant **can** be loaded end-to-end — geography, identity and dishes — through `026`, `027` and
`027a`, and does appear in the customer app. That was verified by execution, not inspection: 59
behavioural probes plus the fifteen-function auth gate, all re-run against the live database after
`027a`. The features stay ⬜ because **there is no application code** — no admin console exists to
call any of it, and a ⬜ here means "a user cannot do this yet".

`027` shipped applied and green, and was unusable for two days. Recorded because it is the general
warning, not an anecdote about this file: **an assertion block that only reads `pg_proc` and
`pg_policies` as text cannot tell working code from dead code.** All thirteen of `027`'s assertions
passed, and so did `tests.run_all()` 11/11, while a function that had never once succeeded sat in the
middle of the catalog. `admin-crud-plan.md` §7 has been amended to require executing a function body
and a policy, not inspecting them, and `027a` ships the two assertions that would have caught both.

## Money

| # | Feature | State | Spec |
|---|---|---|---|
| M-01 | Integer-piastre money with basis-point percentages | ⬜ | constitution I |
| M-02 | Two-phase checkout with `PRICE_CHANGED` rejection and itemised diff | ⬜ | ADR 12 |
| M-03 | Append-only `ledger_entries`, protected by database rules | ⬜ | ADR 11 |
| M-04 | Configurable delivery base fee and per-vendor multiplier | ⬜ | ADR 4 |
| M-05 | Configurable rider pay rules with effective dates, frozen per trip | ⬜ | §3.3 |
| M-06 | Rider cut of the delivery fee — **the launch revenue line, active** | ⬜ | ADR 3 |
| M-07 | Vendor commission on items — **inactive until month 3–4** | ⬜ | ADR 3 |
| M-08 | Customer service fee — inactive | ⬜ | §3.1 |
| M-09 | Per-rider configurable cash limit with a `cash_held` running total | ⬜ | constitution I |
| M-10 | Vendor and rider payout runs with `payable → in_payout → settled` | ✅ | §3.2 |
| M-11 | `platform_float` with a daily variance that must reach zero | ✅ | §3.4 |
| M-12 | Wallet adjustment by admin, append-only, mandatory reason | ✅ | FR-A-10 |
| M-13 | Payment gateway | ❌ | §6.4 — extension point only, not built |

## Platform

| # | Feature | State | Spec |
|---|---|---|---|
| P-01 | Server-side `feature_flags`, targeted in SQL | ⬜ | ADR 8 |
| P-02 | Supabase Auth as the only identity system | ⬜ | constitution III |
| P-03 | RLS on every table, with policy tests that fail the build | ⬜ | T0.14, migration 022 |
| P-04 | Outbox via `events`, every state change in the same transaction | ⬜ | constitution II |
| P-05 | R2 images, menu snapshots, archives, backups | ⬜ | plan §3 |
| P-06 | Cloudflare Workers: outbox dispatcher, upload signer, snapshot builder, file access, export | ⬜ | plan §1 |
| P-07 | FCM push, batched 15 s for non-critical events | ⬜ | contracts §3.1 |
| P-08 | Crashlytics with `app_role`, version and screen, hashed ids only | ⬜ | plan §5 |
| P-09 | Firebase Analytics funnel, no PII | ⬜ | plan §5 |
| P-10 | Durable Objects live tracking | ⬜ | Phase 8, flag off |
| P-11 | Retention jobs: prune transients, archive order detail at 60 days | DB ready — half | §9, T7.1 |
| P-12 | Nightly export to R2, with a restore test before launch | ⬜ | T6.9, T6.10 |

**`035_retention_and_cron` covers the pruning half of P-11, and only that half.** `pg_cron` is
installed and six jobs are scheduled and active: `prune_events` (7 d, hourly), `prune_order_eta_snapshots`
(24 h, hourly), `prune_notifications` (30 d, daily), `prune_rider_location_pings` (30 d, daily),
`ensure_partitions` (monthly, creating the current and next month so `notifications` cannot fail on the
1st), and a nightly `VACUUM ANALYZE` on the four highest-churn tables. Each prune batches `limit 1000`
with a `pg_sleep` between, and each has an index on its prune column.

Two things P-11 still wants and `035` does not do: `audit_log` is partitioned for a 365-day window but
**has no prune job**, and the 60-day order-detail archive does not exist. P-11 is also not marked ✅
because the push-notification drain it partly exists to protect (`claim_events_v1`) is still missing.

---

## Explicitly cut

Recorded so they are not mistaken for oversights.

| Feature | Why |
|---|---|
| Customer wallet and top-ups | ADR 2. The customer pays the rider directly |
| Native vendor app | ADR 15. Vendors use a web dashboard |
| Separate app per role | ADR 15. One app, role-switched |
| Firebase Auth, Firestore, Storage, Functions, Hosting, Remote Config | constitution III. Supabase owns identity and data; Cloudflare owns files |
| Tight client polling | constitution V. Egress is metered |
| Live tracking in v1 | ADR 9. 79% of the scarcest Cloudflare budget |
| Split delivery to multiple addresses | One checkout is one address |
| More than 3 vendors per cart | §2.4 |
| Scheduled / recurring delivery | Not specced |
| Loyalty and subscriptions | Not specced |
| Ads revenue | Slots modelled, unsold |
