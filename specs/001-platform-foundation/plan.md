# Plan — Spec 001

Architecture decisions. The data model is in `data-model.md`, the business rules are in `spec.md`,
and the cost strategy is in `free-tier-plan.md`. This file covers *how*.

## 1. Topology

```
┌─ React Native (Expo) ────────────────────────────────────────┐
│  customer          rider             vendor                  │
│  · Supabase SDK    · Supabase SDK    · Supabase SDK          │
│  · SQLite cache    · SQLite (trips)  · SQLite (queue)        │
│  · R2 downloads   · R2 downloads    · R2 downloads          │
└───────┬───────────────────────┬──────────────────────────────┘
        │ HTTPS                 │ HTTPS
        ▼                       ▼
┌───────────────────────┐   ┌──────────────────────────────────┐
│ Cloudflare            │   │ Supabase                        │
│  cdn.  → R2 public    │   │  PostgREST (RPC)                │
│  files. → R2 private  │◄──┤  GoTrue Auth  (only login)      │
│  *.workers.dev        │   │  Postgres + RLS                 │
│  track. (Phase 3)     │   │  pg_cron                        │
│  admin./merchant.     │   │  pg_net (webhook)               │
└───────┬───────────────┘   └──────────────────────────────────┘
        │                                   │
        ▼                                   ▼
   R2 buckets                        FCM / Crashlytics / Analytics
```

## 2. Service boundaries

| Concern | Owner | Not allowed to own |
|---|---|---|
| Business data, money, rules, order state | Supabase | — |
| Login and identity | Supabase Auth | Firebase Auth is not used |
| Files, images, snapshots, archives, backups | R2 | Bytes never enter Postgres |
| Push delivery | FCM, sent by one Worker | Apps never hold credentials |
| Live channels | Durable Objects (Phase 3) | Not the source of truth |
| Edge glue | Workers | Never decide a business rule |
| Client switches | `feature_flags` table | Never authoritative for money |
| Crash/usage telemetry | Firebase | Business truth never comes from here |

---

## 3. Order placement — the critical sequence

This is the path where money is created, so it is the path that must be exactly right.

```
  Customer app                        Supabase
 ─────────────                        ────────
 0. first launch, profile incomplete
    RPC get_profile_status_v1 ───────▶ { profile_completed_at, can_browse, can_order }
    RPC complete_profile_v1 ─────────▶ set name, phone, profile_completed_at

 1. cart changes
    POST sync/cart ───────────────────▶ upsert cart_items (LWW)
                                        reject if vendor_count > max_vendors_per_order
                                        return per-vendor groups + cached totals

 2. entering checkout / vendor added / option changed  (debounced 800 ms)
    RPC quote_order_v1 ───────────────▶ BEGIN
                                        re-read menu_items, option_choices,
                                          item_options, vendors, vendor_schedules,
                                          vendor_holidays, vendor_areas,
                                          delivery_zones, delivery_fee_tiers,
                                          rider_pay_rules, commission_rules,
                                          vouchers, settings
                                        -- per vendor --
                                        validate: open, in schedule, not holiday,
                                          radius, min order value, stock,
                                          required options satisfied
                                        subtotal, discount_share,
                                          commission (0 today), vendor_net_payout
                                        -- whole order --
                                        delivery_fee = base × multiplier(vendor_count)/10000
                                                    + max(0, km − free_radius_km) × per_km_fee
                                        rider_pay    = resolved from rider_pay_rules
                                        platform_cut = delivery_fee − rider_pay
                                        service_fee (if enabled), tip
                                        total = subtotal − discount + delivery_fee
                                                + service_fee + tip
                                        fingerprint = md5(canonical json of the priced inputs)
                                        COMMIT
                                        ◀── quote_id, expires_at (5 min), fingerprint,
                                            fee_breakdown, per_vendor[]

 3. user applies voucher
    RPC apply_voucher_v1 ─────────────▶ validate + re-quote
                                        ◀── new quote or a specific rejection reason

 4. user confirms
    RPC place_order_v1 ──────────────▶ -- PROFILE GATE --
                                        if profile_completed_at is null
                                          → raise PROFILE_INCOMPLETE

                                        BEGIN
                                        SELECT ... FOR UPDATE on the affected wallets
                                        re-price everything again
                                        ── fingerprint matches quote? ──▶ no:
                                          ROLLBACK, raise PRICE_CHANGED
                                          ◀── {code, diff[], new_quote}
                                        ── fingerprint matches? ──▶ yes:
                                          freeze item snapshots AND the fee inputs
                                            (delivery_base_fee, delivery_multiplier_bps,
                                             distance_km, vendor_limit_applied)
                                          create orders + sub_orders + order_items
                                          insert voucher_redemptions
                                          bump voucher usage_count
                                          INSERT INTO events (order.placed)
                                        COMMIT
                                        ◀── order_id, order_number, sub_orders[], totals

 5. UI updates via push / DO channel. Never by polling.
```

**Why re-price twice rather than trust the quote.** The 5-minute window between quote and confirm
is enough for a vendor to change a price, sell out an item, close for the day, or for a voucher to
hit its cap. Charging the quoted price would mean either a wrong charge or a silent price rise.
Aborting and asking is slower and it is the only version that is correct.

**Why a fingerprint rather than storing the whole quote.** A quote is derivable state; storing it
creates a second thing that can disagree with the catalog. The fingerprint is a hash of the inputs,
so any input change invalidates it automatically and there is nothing to expire or clean up.

**Why the fee inputs are copied onto the order.** `delivery_zones` and `delivery_fee_tiers` are
admin-editable at any moment. Without the freeze, changing the base fee on a Tuesday would
retroactively change what Monday's orders cost and what those riders are owed. With it, a customer
disputing a fee can have it recomputed exactly as it stood at checkout.

---

## 4. Payment at delivery, not at checkout

The customer pays the rider directly. The platform is not a party to the transaction and holds no
customer money.

```
PLACE ORDER          total computed and frozen, payment_status = 'unpaid',
                     payment_method = NULL. No money moves anywhere.

ASSIGNMENT           the rider's pay is resolved ONCE from rider_pay_rules and
                     frozen onto delivery_assignments:
                       rider_pay_base     = per_trip_amount + per_km_amount × km
                       rider_pay_bonus    = bonus_per_leg × (vendor_count − 1)
                       rider_pay_total    = the above, capped at pct_of_delivery_fee_bps
                                             of the delivery fee
                       platform_revenue   = commission_rules(rider, delivery_fee)
                                              × delivery_fee / 10000
                                            NOT delivery_fee − rider_pay_total;
                                            see open question 3.28

DELIVERY             customer picks, on the rider's screen or their own:
                       cash   → rider holds `total` physically
                       wallet → customer already transferred `total` to the rider by
                                Vodafone Cash or Instapay. Rider holds 0. The platform
                                is not involved.

  RPC begin_collection_v1 ──────────▶ set payment_method + payment_channel
                                      if cash: refuse if
                                      riders.cash_held + total > effective_cash_limit_v1(rider)

  cash path
    RPC collect_cash_v1 ─────────────▶ ledger_entry('cash_collected', platform, +total)
                                      riders.cash_held += total
                                      platform_float.cash_expected += total

  wallet path
    RPC collect_wallet_v1 ───────────▶ NO platform ledger movement. The money never
                                      touched the platform. Records:
                                      orders.payment_channel = vodafone_cash | instapay
                                      orders.payment_reference = what the rider typed in
                                      platform_float.external_wallet_orders += 1

  both paths
    ledger_entry('rider_cut', platform_earnings, +platform_revenue)   ← launch revenue
    mark every sub_order settlement_status = 'payable' with vendor_net_payout
    complete_delivery_v1 ────────────▶ delivered, actual_delivery_time, proof

SETTLEMENT (pg_cron daily, admin-approved)
  vendor payout   Σ sub_orders.vendor_net_payout
                    WHERE settlement_status = 'payable' AND vendor_id = ?
  → payout(draft) → payout_lines → per sub_order:
        settlement_status = 'in_payout'
        ledger_entry('vendor_payout', vendor, +net)
        ledger_entry('commission', platform_earnings, −commission)   -- 0 until month 3-4
  → approve → payout(paid)

  rider payout    Σ rider_pay_total + tips + bonuses
  → payout_lines → ledger_entry('rider_payout', rider, +net)
  → approve → payout(paid) + platform_float.cash_remitted += collected cash
```

**Four rules that make this safe:**

1. `payable → in_payout → settled` happens in the same transaction as the ledger entries. A payout
   can never be issued twice, and a crash mid-payout leaves the whole batch in `in_payout`,
   visible and recoverable.
2. `payout_lines` has a unique index on `sub_order_id`. Even a manual mistake cannot pay a
   sub-order twice.
3. `ledger_entries` has rules forbidding `UPDATE` and `DELETE`. A mistake is corrected by a
   reversing entry, which preserves the audit trail that disputes depend on.
4. **A wallet-paid order writes no platform cash movement at all.** Only the cash path touches
   `cash_expected`. This is what keeps `platform_float.variance` meaningful: it reconciles exactly
   one exposure instead of two.

---

## 5. Live tracking (Phase 8, behind a flag)

Not built in v1. Designed now so activation is a flag, not a rewrite.

```
OrderRoom (one Durable Object per active order)
  driver  ──wss──▶ tracking-gate ──▶ OrderRoom ──wss──▶ customer
  (accepts `loc` only from the assigned rider's socket)
                     │
                     └── on connect: can_track_order_v1(user's JWT) so RLS decides

  Hibernation API only (ctx.acceptWebSocket). A plain accept() is billed for the
  whole connection duration and would exhaust the free allowance in days.

  Persistence: one row per minute to the object's SQLite. The latest point lives in
  the socket attachment. Nothing in Postgres during the trip.
  On delivered: save_route_summary_v1 once, then self-destruct in ~10 minutes.
```

Fallback ladder if Durable Objects are unavailable, in order: status-only view from push →
foreground poll at 90 s → static ETA. Ordering and settlement never depend on any of them.

---

## 6. Offline sync

### 6.1 Principle

**The device never creates an order.** `place_order_v1` is server-only, by construction. This
removes the single hardest class of offline-first bug — duplicate orders from a retried queued
write — by refusing to let the client write orders at all.

### 6.2 What is cached, and what each cache is allowed to decide

| Cache | Decides | Never decides |
|---|---|---|
| SQLite `catalog_cache` | What to draw | Price, availability, whether an order can be placed |
| R2 menu snapshot | What to draw | Anything; version-checked, and superseded by the quote |
| SQLite `carts` | What the cart looks like offline | The total that will be charged |
| Server `cart_items` | The authoritative cart | — |
| Postgres | Everything that costs money or commits | — |

### 6.3 Sync

```
pull   GET  /sync/changes?since=<cursor>&areas=<list>
       → { cursor, areas[], vendors[], menu_versions[], cart[] }
         areas[] is the small, frequently-changing part; catalog comes from R2

push   POST /sync/cart
       → server wins ties by updated_at; one active cart per user, shared across devices

menu   on `menu_version` change → GET cdn/menus/{vendor}/v{n}.json, diff, bump SQLite
```

Conflict resolution: last-write-wins on `updated_at`, scoped to the cart. There is no case where
two devices editing the cart concurrently loses data that matters, because the cart is not money
and the order is repriced anyway.

### 6.4 Encryption at rest

| Platform | Mechanism | Key storage |
|---|---|---|
| Android | SQLCipher with a 256-bit key | Android Keystore, non-exportable |
| iOS | File protection `completeUntilFirstUserAuthentication` | Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

Keys are generated on first launch and never leave the device. No backup key, because a recoverable
key defeats the purpose. A lost key means a re-login, which is acceptable for a catalog cache and a
cart.

---

## 7. Search

Arabic is the primary language, so normalisation is the whole game.

```sql
create or replace function public.normalize_text_v1(t text)
returns text language sql immutable as $$
  select lower(
    regexp_replace(
      unaccent(
        translate(t,
          'آأإا'||'ى'||'ة'||'ؤ'||'ئ'||'ـ',   -- alef variants → ا, alef maqsura → ي,
          'ا'  ||'ي'||'ه'||'و'||'ي'||''         -- ta marbuta → ه, hamza forms, tatweel
        )
      ),
      '[ً-ْـ]', '', 'g'                        -- strip tashkeel and tatweel
    )
  );
$$;
```

Generated columns `search_name`, `search_name_ar`, `search_description` on `vendors` and
`menu_items`, each with a `gin_trgm_ops` index. `search_catalog_v1(query, area, filters)` ranks by
`similarity` with open-now and distance as tie-breakers.

Not needed at 150 vendors and 20,000 items. If it ever is, the R2 search-index path from the
architecture spec takes over with an on-device library and costs nothing.

---

## 8. Payment gateway — the extension point, not built

The v1 design keeps the slot open so adding a gateway later requires no refactor:

1. A `payments` table (`order_id`, `provider`, `provider_reference`, `status`, amounts) and an
   adapter interface (`create_payment`, `handle_callback`, `refund`).
2. A Worker for provider callbacks, verifying the signature and idempotently keyed on the provider
   transaction id, calling `confirm_payment_v1`.
3. One Edge Function for the create and refund calls — the only place an external call must happen
   inside a flow. This is why the 500,000-call/month free quota stays reserved.
4. A reconciliation job for missed callbacks, because every gateway has them.
5. `payment_channel` gains `'gateway'`. Nothing in `transition_order_v1`, `ledger_entries` or
   `events` changes, and `platform_float` gains one more reconciled column rather than a new
   mechanism.

**A gateway does not replace the direct-transfer path.** Customers here pay by cash and mobile
money to the person at the door, and a gateway that only accepts cards solves a problem they do not
have. If a gateway is ever added it becomes a *third* `payment_channel` alongside `cod`,
`vodafone_cash` and `instapay` — not a replacement for them.

---

## 9. Deployment

| Environment | Supabase | Cloudflare | Purpose |
|---|---|---|---|
| Local | `supabase start` (Docker) | `wrangler dev` | Full stack offline, free |
| Staging | 1 free project | `*.workers.dev`, Pages preview | Integration testing |
| Production | 1 free project, Pro at first real money | Custom domain | Live |

**Chosen infrastructure (decided, not assumed):**

| Thing | Value | Note |
|---|---|---|
| Supabase project name | `Marketak` | Display name **Marketak / ماركتك** |
| Supabase region | `eu-central-1` (Frankfurt) | Chosen over `ap-south-1` despite the longer distance. Data residency and a single stable region beat ~50 ms of latency for a 900 ms p95 checkout target |
| Cloudflare account | `8ae79d52c8b84a170bcb5c4c0485f34c` | `ahmedmelgammal6@gmail.com` |
| R2 buckets | `Marketak-public`, `Marketak-private` | Prefixed so they cannot collide with another project's buckets |
| Firebase project | created after Supabase | FCM + Crashlytics + Analytics only |

Frankfurt is roughly 7,500 km from Egypt, which is a real cost: expect ~100–130 ms to the database.
That is acceptable at a 900 ms p95 `place_order_v1` target, but it is the first thing to revisit if
checkout p95 ever exceeds it — moving to `ap-south-1` is a project-region change and therefore a
migration, not a toggle. Do it early if the numbers demand it.

**Docker is not currently installed**, so `supabase start` cannot run yet. Until it is, local
development works against the hosted staging project with `supabase db push --dry-run` for
migration review, or via the MCP `apply_migration` tool.

Free plan allows 2 active projects, so local + staging is the maximum. Production sharing the
staging project is **not** acceptable once real orders exist. This is the practical reason the $25
is unavoidable: it is not just more disk, it is the third project.

Rollout: migrations are forward-only and additive. RPC functions are versioned `_v1`; a breaking
change adds `_v2` and both run until old app versions are retired. `feature_flags.min_app_version_*`
is the retirement mechanism, so no store review is needed to kill an old build.

---

## 10. Build order

Phases are ordered by dependency and by what must be true before money can move.

| Phase | Contents | Exit criterion |
|---|---|---|
| 0 | Migrations 001–004, cities, areas, zones, fee tiers, identity, vendors, profile completion | Seed 150 vendors via script; sign in with Google and complete a profile |
| 1 | Migrations 005–007 + catalog RPCs + vendor feed + SQLite catalog cache | Browse, search and open a menu offline |
| 2 | Migrations 006–007, cart, `quote_order_v1`, `place_order_v1` | **Order end to end at the correct price, including the vendor-count uplift** |
| 3 | Migrations 008–013, riders, dispatch, vendor dashboard on Pages | Merchant accepts, rider claims, customer sees status |
| 4 | Migration 009, payment at delivery, cash limit, rider pay resolution | Cash and direct-transfer both record, variance reconciles |
| 5 | Payouts, earnings dashboards, vouchers, reviews, analytics | Vendor sees what he earned today; payout runs |
| 6 | Notifications, `feature_flags`, admin console, reconciliation tool | Kill switches work without a release |
| 7 | Retention, archive, prune jobs | Measured bytes per order replace the estimates |
| 8 | Live tracking via Durable Objects | **Deferred — flag defaults to off** |

Phase 2 is the gate. Nothing after it should be started until the price-change rejection path is
tested end to end, because every later feature depends on pricing being correct.

---

## 11. Testing strategy

| Layer | Tool | What it must prove |
|---|---|---|
| RLS | `pgTAP` in migration 022 | Every cross-tenant read returns zero rows, and the profile gate blocks `orders` inserts. **Build fails without it** |
| RPC | `pgTAP` | Price change between quote and place aborts with `PRICE_CHANGED` and a correct diff |
| Fee formula | `pgTAP` | 1/2/3 vendors produce ×1.00/×1.10/×1.20 of base; distance beyond the free radius adds correctly; a 4th vendor is refused |
| Rider pay | `pgTAP` | `rider_pay_total` never exceeds `pct_of_delivery_fee_bps` of the fee; a pay-rule change never alters an existing assignment |
| Money | `pgTAP` | Ledger sums equal balances; a double payout attempt fails; a reversal balances to zero; a wallet-paid order writes **no** platform cash entry |
| Concurrency | `pgTAP` with two sessions | Two `claim_order_v1` calls → exactly one winner |
| Integration | Playwright against staging | Multi-vendor checkout with a price change mid-checkout |
| Load | k6 | 100 concurrent `place_order_v1` through the lunch window; asserts p95 < 900 ms |
| App | Detox | Offline cart → reconnect → order placed once; profile gate blocks checkout |
| Money acceptance | Manual script | 100 simulated orders, cash and direct-transfer mixed, `platform_float.variance = 0` |

The money acceptance script is not optional and not automated. A delivery platform's failure mode
is not a crash; it is a balance that quietly disagrees with itself.

---

## 12. Decisions carried over from the architecture spec

| Decision | Change | Reason |
|---|---|---|
| Supabase owns business data | Unchanged | Confirmed |
| Cloudflare R2 for all bytes | Unchanged | It is the only reason egress is survivable |
| Supabase Auth is the only login | Unchanged, narrowed to Google + Apple | Firebase Auth would break RLS |
| RPC only, no Edge Functions in v1 | Unchanged | Keeps the free quota reserved |
| Outbox pattern via `events` | Unchanged, plus aggressive pruning | Forgetting the pruner is the most likely failure |
| Durable Objects with hibernation only | Unchanged, but **deferred to Phase 8** | 79% of the scarcest cap for a deferrable feature |
| Firebase Remote Config for flags | **Replaced by `feature_flags` table** | Confirmed: one source of truth, targetable against real data |
| `merchants` + `merchant_branches` | **Flattened to `vendors`, one location each** | Confirmed. A chain is N vendors sharing a `brand_id` |
| Live tracking in v1 | **Deferred**, flag defaults to off | Confirmed: location is optional for now |
| Nightly export to R2 as interim backup | Unchanged | Must be restore-tested before launch, not merely written |