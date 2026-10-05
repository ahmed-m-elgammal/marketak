# Spec 001 — Marketak — Delivery Platform Foundation

**Brand:** Marketak · ماركتك
**Status:** Draft for review
**Stack:** Supabase (Postgres + Auth + RLS + pg_cron) · Cloudflare (R2, Workers, Durable Objects, Pages) · Firebase (FCM, Crashlytics, Analytics)
**Apps:** **One** React Native (Expo) app for customers *and* riders, role-switched after sign-in
(`com.jaylak.mobile`, Android + iOS). Vendor staff and admins use **web dashboards** on Cloudflare
Pages — no native vendor app.
**Market:** Egypt. Arabic and English. **One city at a time**, **lunch service first**
**Infrastructure:** Supabase project `Marketak`, region **eu-central-1 (Frankfurt)**. Cloudflare account `8ae79d52c8b84a170bcb5c4c0485f34c`. R2 buckets `Marketak-public` / `Marketak-private`
**Auth:** Google and Apple only. No email, no password. Phone is collected at profile completion
**Payments in v1:** cash, or the customer transfers to the rider directly by Vodafone Cash /
Instapay. **The platform never holds customer money and there is no customer wallet.**
**Commission:** the platform's launch revenue is a cut of the delivery fee taken from the **rider**.
Vendor commission on items and a customer service fee are modelled but switched off, to be
activated around month 3–4.

---

## 1. Problem and actors

Demand for multi-vendor delivery in this market is strong but thinly served outside a handful of
districts, and payment behaviour is heavily cash-weighted — customers pay the rider on the doorstep,
in cash or by a direct mobile-money transfer. This platform serves **one city at a time** with a
**lunch-first** operation. The city is configuration in the `cities` table, not a constant in code.

### 1.1 Actors

| Actor | Identity | Surface |
|---|---|---|
| Customer | `user_roles.role = 'customer'` | Mobile app |
| Rider | `user_roles.role = 'rider'` + `riders` row | **Same mobile app**, rider surfaces behind a role switch |
| Vendor staff | `vendor_staff` (user ↔ vendor, role) | Web dashboard only |
| Admin | `user_roles.role = 'admin'` | Web dashboard only |

A person may hold several roles. A rider is frequently also a customer; the same `users` row serves
both. This is why roles are a join table, not a column on `users`.

**One app, two roles.** The customer and rider surfaces share a binary, a session, a push token
channel and a Crashlytics install. What that buys and costs:

| | Effect |
|---|---|
| Buys | One store listing, one release train, one update to push. Riders get rider features immediately instead of waiting on a separate app |
| Buys | One push-token table. A user who is both a customer and a rider is one device, so `device_tokens.app_role` must resolve dynamically rather than being fixed at registration |
| Costs | Customer and rider code ship together. A rider-only bug is still a customer-facing release |
| Costs | `app_role` on a device token is a hint, not a permission. Push routing must decide at send time from the order, not from the token |
| Costs | The bundle grows. Keep the rider surface feature-flagged so a customer who is not a rider never downloads or sees it |

**Vendors get a dashboard, not an app.** Merchants and staff do not install anything and never go
through a store review. The cost is that a vendor working from a phone browser gets a worse
experience than a native app, which matters because most vendors will be managing lunch from a
phone. Accept it: a vendor app would be a second store listing, a second release train, and a
second thing to keep in sync — for an audience that logs in to change four things a day.

### 1.2 Authentication and the profile gate

**Sign-in is Google and Apple only.** No email, no password, no phone OTP. The phone number is a
profile field, not a credential.

```
1. Customer taps "Continue with Google" (or Apple)
     native SDK → ID token → Supabase signInWithIdToken
     no browser window
2. A users row is created immediately, profile_completed_at = null, phone_number = null
3. The app detects the incomplete profile and shows the completion screen:
     first name · last name · phone number · first address
4. complete_profile_v1 validates and sets profile_completed_at
5. From then on the customer can browse and order
```

A user who has not completed their profile **can browse but cannot place an order.** This is
enforced in three places, not one, because one is not enough:

| # | Enforcement |
|---|---|
| 1 | `place_order_v1` raises `PROFILE_INCOMPLETE` when `profile_completed_at is null` |
| 2 | An RLS policy denies `insert` on `orders` to any user with a null `profile_completed_at`, so a direct PostgREST call cannot bypass the RPC |
| 3 | The app routes to the completion screen on launch and from settings |

Why phone is collected here rather than at sign-in: Google and Apple both hide the phone number
behind extra consent screens, and in this market the phone is a delivery necessity (the rider calls
the customer) rather than an identity. Asking for it once, after the customer has already seen the
app, converts far better than asking before the first screen.

One person may link both a Google and an Apple identity to the same account. That is normal on iOS
and is handled by `unique (provider_type, provider_id)` plus an account-linking step on sign-in.

### 1.3 Non-goals for v1

- No online payment gateway (card). The extension point is specified in `plan.md` §8; not built.
- No **customer wallet and no top-up flow.** The customer pays the rider directly. Vendor and rider
  wallets exist, because those are balances the platform owes.
- No city-to-city operations tooling beyond multi-city tables being *present*.
- No loyalty points, subscriptions, or scheduled recurring delivery.
- No split delivery to multiple addresses. One checkout, one drop-off address.
- No refunds originating from the platform (vendor rejections only, in v1).
- No ads revenue (slots modelled, unsold).
- No email or phone authentication (multi-country support is a single `country_code` throughout).

---

## 2. The defining requirement: one cart, many vendors

This is the requirement that reshapes the entire order model, so it is stated first and in full.

A customer builds a cart containing items from Vendor A, Vendor B and Vendor C, checks out once,
pays once, and receives one delivery. Each vendor independently accepts, prepares, prices and
cancels their own portion.

### 2.1 Why the simple model is wrong

The naive model — one `orders` row with a `vendor_id` — forces a single global status. It cannot
express "Vendor B rejected while Vendor A is already cooking", cannot compute per-vendor
preparation and delivery fees, cannot pay each merchant separately, and cannot tell a customer
which items are delayed. It also cannot apply a voucher that funds only part of a basket.

### 2.2 The chosen model

```
orders (1)  ── the checkout envelope
  │           payment, voucher, one total, one delivery address, aggregate status
  │
  └── sub_orders (N) ── one per vendor
        │              vendor status, prep time, per-vendor fees, per-vendor payout
        │
        ├── order_items (M) ── item rows belong to a sub-order, never to the order
        ├── order_status_history ── sub-order scoped transitions
        └── order_modifications
```

**Consequences, all deliberate:**

| Concern | Where it lives | Why |
|---|---|---|
| One total, one payment, one voucher | `orders` | The customer experienced one checkout |
| "Vendor B is out of stock" | `sub_orders[].status` | Only that vendor's leg is affected |
| Per-vendor delivery fee | `sub_orders[].delivery_fee_share` | Fees must be attributable for payouts |
| Per-vendor net earning | `sub_orders[].vendor_net_payout` | This is what "merchant earned today" sums |
| Customer-visible ETA | `max(sub_orders[].ready_estimate) + legs` | Derived, never stored authoritatively |
| Aggregate order status | `orders[].status`, derived | The customer's single view |

### 2.3 Aggregate status derivation

`orders.status` is a **derived cache**, recomputed inside the same transaction as any sub-order
transition. It is never set directly.

| Derived status | Rule |
|---|---|
| `pending` | ≥1 sub-order not yet accepted/rejected, none rejected |
| `partially_confirmed` | some accepted, some rejected |
| `preparing` | all accepted, ≥1 in preparation |
| `ready` | all accepted, all ready |
| `picked_up` | rider has all legs |
| `delivering` | rider has ≥1 leg and is on the way |
| `delivered` | all non-cancelled sub-orders delivered |
| `partially_cancelled` | ≥1 sub-order cancelled, ≥1 delivered |
| `cancelled` | all sub-orders cancelled |

### 2.4 Delivery execution model

**One rider, one trip, N vendor pickups, one customer drop-off, one address.**

- One `delivery_assignments` row per `orders`, not per `sub_orders`.
- Pickup sequence derived from vendor distance; the rider app shows an ordered stop list, computed
  once at assignment and stored on `stop_sequence`.
- Maximum **3 vendors per cart**, from `settings.max_vendors_per_order`, overridable lower per
  delivery zone. Beyond the limit the cart cannot be checked out and the customer is told which
  vendor to remove.
- One drop-off address only. This is what makes the single-rider model possible at all.

This is the cheapest model in every dimension that matters: one rider earning, one delivery fee,
one location channel, one drop-off proof.

The alternative, `separate` — one delivery per vendor with parallel riders — is modelled in the
schema (`orders.delivery_grouping`) but is not the default and is not built in v1.

### 2.5 The delivery fee formula

**Configurable, per zone, never hardcoded.**

```
delivery_fee = round( delivery_base_fee × multiplier(vendor_count) / 10000 )
             + max(0, distance_km − free_radius_km) × per_km_fee
```

| vendors | multiplier | fee on a 25.00 base |
|---|---|---|
| 1 | ×1.00 (`10000` bps) | 25.00 |
| 2 | ×1.10 (`11000` bps) | 27.50 |
| 3 | ×1.20 (`12000` bps) | 30.00 |

The multiplier is a **per-vendor uplift on the delivery base fee**, not a percentage of the item
subtotal. A single-vendor order costs `items + delivery_fee`. A three-vendor order costs
`items + delivery_fee`, where the fee is 20% higher than a single-vendor order — because one rider
making three stops is worth more than one rider making one, and the customer is told so before
checkout.

The three inputs are admin-editable at runtime and stored per zone:

| Input | Where | Default |
|---|---|---|
| `delivery_base_fee` | `delivery_zones` | 25.00 EGP |
| `free_radius_km` | `delivery_zones` | 5 km |
| `per_km_fee` | `delivery_zones` | 2.00 EGP per km beyond the free radius |
| `max_vendors_per_order` | `settings`, per-zone override | 3 |
| `multiplier_bps` per vendor count | `delivery_fee_tiers` | 10000 / 11000 / 12000 |

Two consequences that must not be missed:

1. **The inputs are frozen onto the order** (`delivery_base_fee`, `delivery_multiplier_bps`,
   `distance_km`, `vendor_limit_applied`). Changing a fee next week must not retroactively change
   what a customer was charged, or what a rider is owed.
2. **The fee is one number for the whole order, not per vendor.** It is allocated across
   `sub_orders.delivery_fee_share` for reporting only — proportional to each vendor's subtotal —
   because a rider's pay and the platform's revenue are computed once per order, not per vendor.

### 2.6 Customer experience requirements

- The cart is grouped into vendor sections in the UI, with per-vendor subtotal, per-vendor minimum
  order value, and per-vendor fee. The header shows the combined total.
- The cart shows the vendor count against the 3-vendor limit and blocks checkout past it, rather
  than failing at `place_order_v1`.
- A per-vendor rejection never loses the whole basket. The customer is offered: remove the
  affected vendor, or keep and refund.
- Vouchers may be **vendor-scoped** (`applies_to_vendor_ids`) or order-wide.
- Nothing in the checkout flow may reveal which commission tier a vendor is on, or what the rider
  earns.

---

## 3. Business model

### 3.1 Revenue model — phased, and the phasing is the strategy

This is a market-entry decision, not an accounting detail. Charging merchants at launch in this
market means they do not sign up; the incumbents are already entrenched on price. So the platform
takes its first revenue from the **delivery fee, out of the rider's share**, and only turns on
vendor commission once there is enough supply for merchants to have no alternative.

| # | Revenue line | Launch | Activated | Mechanism |
|---|---|---|---|---|
| 1 | **Rider cut of the delivery fee** | **ON** | At launch | `commission_rules` scope `rider`, applies_to `delivery_fee` |
| 2 | **Vendor commission on items** | **OFF** | ~Month 3–4 | `commission_rules` scope `vendor`, applies_to `subtotal` |
| 3 | Customer service fee | **OFF** | When needed | `settings.service_fee_enabled` |
| 4 | Delivery fee | **ON** | At launch | `delivery_zones` + `delivery_fee_tiers` (§2.5) |
| 5 | Multi-vendor uplift | **ON** | At launch | The per-vendor multiplier in §2.5 |
| 6 | Rider tip | **ON**, default 0 | At launch | `orders.rider_tip` |
| 7 | Ads / banners | Slots exist, unsold | Later | `promo_slots` |

The single most important property: **turning on line 2 is an `update`, not a migration.**
`commission_rules` exists at launch with a row seeded at 0 and `is_active = false`. Going live on
vendor commission is `update commission_rules set is_active = true, value = <n>, effective_from =
now() where scope = 'vendor'`. `effective_from` defaults to the moment of activation, and
`sub_orders.commission_amount` is written at that moment, so no vendor is ever charged
retrospectively.

Line 1 and line 2 are independent. Activating vendor commission does not disturb rider pay.

### 3.2 The money flow, precisely

The customer chooses how to pay **at delivery**, not at checkout, and the platform is not in the
middle of it.

```
PLACE ORDER
  total = subtotal − discount + delivery_fee + service_fee + rider_tip
  where delivery_fee = base × multiplier(vendor_count) + distance component   (§2.5)
  payment_status = 'unpaid'. No money moves. The platform holds nothing.

DELIVERY — customer picks one of:
  cash   → the rider physically holds `total` in hand
  wallet → the customer has already transferred `total` to the rider by Vodafone Cash
           or Instapay. The rider holds 0. The platform is not a party to the transfer.

COLLECTION (rider confirms, app records)
  rider_pay     = resolved from rider_pay_rules for this rider at assignment time
  platform_cut  = commission_rules(scope=rider, applies_to=delivery_fee)
                  x delivery_fee / 10000            ← launch revenue, line 1
                  NOT delivery_fee − rider_pay. See open question 3.28: the subtraction is
                  arithmetically impossible, since per_trip and bonus_per_leg are additive
                  rider costs the platform bears from its own margin, and it can go negative.
  ledger_entry('cash_collected', platform, +total)           only on the cash path
  ledger_entry('rider_cut',     platform_earnings, +platform_cut)
  riders.cash_held += total                                    only on the cash path
  sub_orders.settlement_status = 'payable' with vendor_net_payout

SETTLEMENT (pg_cron daily, admin-approved)
  vendor payout = Σ sub_orders.vendor_net_payout  WHERE settlement_status = 'payable'
  rider payout  = Σ rider_pay + tips + bonuses
  cash remitted = Σ collected_amount on cash orders  → bank or Vodafone Cash
```

### 3.3 Rider pay

Configurable, per city and overridable per rider, with effective dates so a pay change never
rewrites history. `rider_pay_rules` holds:

| Input | Meaning |
|---|---|
| `per_trip_amount` | Fixed amount per completed delivery |
| `per_km_amount` | Per kilometre of the actual trip distance |
| `pct_of_delivery_fee_bps` | The rider's share of the delivery fee. `10000` = keeps all of it, `8000` = keeps 80% |
| `bonus_per_leg` | Extra per vendor pickup, so a 3-vendor trip earns more than a 1-vendor one |
| `effective_from` / `effective_until` | Never retroactively applied |

Resolution order: an active rule for this rider → else the active city-wide rule → else **zero**,
which surfaces as an admin error rather than a silent free delivery. The resolved amounts are
written onto the `delivery_assignments` row at assignment time, so an order's economics are frozen
the moment a rider accepts it.

### 3.4 Wallets: vendors and riders only

**There is no customer wallet, and that is a deliberate money-integrity decision.**

The customer pays the rider directly — cash in hand, or their own Vodafone Cash / Instapay transfer
to the rider's number. The platform records *that it happened* on the order
(`payment_method`, `payment_channel`, `payment_reference`) and never holds the money.

What that buys:

| Risk eliminated | How |
|---|---|
| Fake top-up receipts | There is no top-up flow to fake |
| Balance manipulation | There is no customer balance to manipulate |
| Customer float reconciliation | There is no customer float |
| A support queue about missing balance | Not a failure mode |
| Double-crediting a top-up | Not a failure mode |

What remains to reconcile is exactly one thing: **cash that riders have collected and not yet
banked.** `platform_float` tracks it, `reconcile_day_v1` produces the daily variance, and the target
is zero or explained in writing, every day.

`wallets` therefore exists for vendors and riders only — the two parties the platform owes. Funding
one is an **admin adjustment** (`adjust_wallet_v1`) that writes a signed ledger entry carrying the
admin's id, a mandatory reason and a reference. No self-service path, no customer-facing screen.

The "wallet" label survives in the customer-facing payment choice because that is what the customer
recognises. Internally it is `payment_method = 'wallet'` with `payment_channel` of `vodafone_cash`
or `instapay`, and it is a record of an external settlement rather than a balance.

### 3.5 Unit economics to make visible

For a vendor with `orders_count`, `gross_sales`, `discounts`, `delivery_fees`, `net_payout` in
`vendor_earnings_daily`, the following must be derivable from day one even at 0% commission:

| Metric | Formula | Why it matters |
|---|---|---|
| Gross sales | `SUM(subtotal)` | Demand signal |
| Effective discount rate | `discounts / gross_sales` | Detects voucher abuse |
| Realised commission rate | `commission / gross_sales` | 0% today, the metric that activates it |
| Vendor net payout | `SUM(vendor_net_payout)` | "What he earned today" |
| Cash vs wallet split | `cash_collected / wallet_collected` | Determines settlement method |
| Refund and reject rate | `cancelled / orders_count` | The leading indicator of menu-data rot |

For riders, in `rider_earnings_daily`: deliveries, tips, bonuses, cash held, net payout, hours
online, EGP/hour.

### 3.6 Marketplace dynamics for lunch peak

The lunch peak concentrates 60% of daily volume into roughly three hours. This is the single
biggest operational risk and it shapes the data model:

- `vendor_schedules` supports **split shifts** (two rows per day) so a vendor can be lunch-only.
- `vendors.capacity_per_slot` lets a vendor cap lunch orders.
- `driver_shifts` are explicit windows, so rider supply can be scheduled against the lunch peak
  rather than discovered in it.
- ETAs are **slot-aware**: a vendor's lunch ETA is derived from its own capacity for the current
  slot, not a single global number.
- Every ETA the customer sees is computed with a lunch buffer, so it is never systematically wrong
  at exactly the moment the customer is most sensitive to it.

---

## 4. Functional requirements

### 4.1 Customer

| ID | Requirement |
|---|---|
| FR-C-01 | Sign in with Google or Apple. Complete a profile (name, phone, first address) before ordering. |
| FR-C-02 | Manage addresses with a default, an area label, and delivery instructions. |
| FR-C-03 | Browse and search vendors and items in Arabic and English, filtered by area, open now, and vertical. |
| FR-C-04 | Build a cart spanning up to 3 vendors, grouped and totalled per vendor. |
| FR-C-05 | Cart survives app restart, device change and offline. |
| FR-C-06 | See a live-updating price quote: subtotal, delivery fee with its vendor-count uplift shown, service fee, discount, tip, total — per vendor and combined. |
| FR-C-07 | Apply a voucher and see the discount applied per vendor where applicable. |
| FR-C-08 | Place an order and receive a human-readable order number. |
| FR-C-09 | Choose or change payment method (**cash** or **wallet** = Vodafone Cash / Instapay to the rider) up to the moment of delivery. |
| FR-C-10 | Cancel while allowed, with the reason recorded and the policy applied. |
| FR-C-11 | Track the order: status, ETA, and driver location when live tracking is enabled. |
| FR-C-12 | Reorder any past order in one tap. |
| FR-C-13 | Rate the vendor and the rider separately after delivery. |
| FR-C-14 | See a plain-language explanation of the delivery fee at checkout, including the multi-vendor uplift. |

### 4.2 Vendor

| ID | Requirement |
|---|---|
| FR-V-01 | Manage categories, items, prices, Arabic text, images, availability and stock. |
| FR-V-02 | Define item options with required/optional, min/max selections and price modifiers. |
| FR-V-03 | Set opening hours including split shifts and holidays. |
| FR-V-04 | Accept or reject an incoming sub-order, with a reason on rejection. |
| FR-V-05 | Mark preparing, ready, out-of-stock items, and request a price change with consent. |
| FR-V-06 | See a live queue of new orders. |
| FR-V-07 | See today's earnings, by payment method, with a period history. |
| FR-V-08 | Request a payout and see its status. |

### 4.3 Rider

| ID | Requirement |
|---|---|
| FR-R-01 | Go online/offline, with an availability window. |
| FR-R-02 | See nearby available orders, filtered by pickup and delivery feasibility. |
| FR-R-03 | Claim an order atomically; exactly one rider wins. |
| FR-R-04 | Follow an ordered multi-stop pickup list and one drop-off. |
| FR-R-05 | Collect cash and record the exact amount, or confirm a Vodafone Cash / Instapay transfer to their own number. |
| FR-R-06 | See today's earnings: trips, legs, tips, bonuses, cash held, net payout. |
| FR-R-07 | Report a completed delivery with proof, including a photo or OTP confirmation. |
| FR-R-08 | See a warning before accepting when holding cash near their limit, and be blocked from accepting cash orders past it. |

### 4.4 Admin

| ID | Requirement |
|---|---|
| FR-A-01 | Approve vendors, configure areas, zones, delivery fee tiers, rider pay rules and verticals — all without a deploy. |
| FR-A-02 | Verify riders and vendors, manage documents with signed URLs. |
| FR-A-03 | Run the daily cash reconciliation and explain any variance before the next settlement. |
| FR-A-04 | Create vouchers with scoping, caps, and usage limits. |
| FR-A-05 | Set, target and toggle feature flags without a release. |
| FR-A-06 | Run and approve settlement and payout batches. |
| FR-A-07 | See live orders and intervene. |
| FR-A-08 | Read analytics: funnel, city/area performance, delivery-time percentiles. |
| FR-A-09 | Turn vendor commission on when the supply base is strong enough to absorb it. |
| FR-A-10 | Adjust a vendor or rider wallet, with a mandatory reason recorded against a signed ledger entry. |

---

## 5. Order state machine

Enforced by `transition_order_v1`. All transitions write `order_status_history` and an `events`
row in one transaction.

### 5.1 Sub-order (vendor) states

```
pending  ──accept──▶ accepted ──start──▶ preparing ──ready──▶ ready ──pickup──▶ picked_up ──deliver──▶ delivered
   │
   ├──reject──▶ rejected
   │
   └──cancel──▶ cancelled
```

| From | Allowed to | Actor |
|---|---|---|
| `pending` | `accepted`, `rejected`, `cancelled` | vendor staff, admin, system |
| `accepted` | `preparing`, `cancelled` | vendor staff, admin |
| `preparing` | `ready`, `cancelled` | vendor staff, admin |
| `ready` | `picked_up` | rider, admin |
| `picked_up` | `delivered` | rider, admin |
| any non-terminal | `cancelled` | customer (policy-gated), admin |

Cancellation policy: customer may cancel while `pending`, or while `accepted` before `preparing`
starts. After `preparing`, customer cancellation is refused; only admin can cancel, and the vendor
is compensated per `cancellation_policy`.

### 5.2 Rider states

```
offline ──go_online──▶ available ──accept_order──▶ assigned ──arrive_vendor──▶ at_pickup ──picked_up──▶ delivering ──arrive──▶ arrived ──deliver──▶ completed ──settle──▶ offline
```

### 5.3 Item states

`confirmed` (default) · `out_of_stock` · `price_updated` · `limited_stock` · `replacement`

An item in a non-`confirmed` state requires explicit customer consent before the order advances,
and `order_modifications` records the original total, new total and difference.

---

## 6. Offline, cache and the pricing question

The requirement was: *"the app caches server data and refetches on order or pull-to-refresh — but
what happens when prices or discounts change?"*

**Answer: nothing breaks, because the cache is never trusted for money.**

There are exactly three tiers of truth, and they have different jobs:

| Tier | Source | Authority | Holds |
|---|---|---|---|
| 1. Display | SQLite cache + R2 snapshots | **None.** May be arbitrarily stale | Names, images, descriptions, cached price for display only |
| 2. Quote | `quote_order_v1` → Postgres | Authoritative, expires in 5 min | Repriced cart, real fees, real voucher, real availability, real stock |
| 3. Commit | `place_order_v1` → Postgres | Authoritative, transactional | The order, its items, its prices |

### 6.1 The mechanism

1. The app may show a cached price. It is labelled as an estimate.
2. On entering checkout the app calls `quote_order_v1`. The server re-reads `menu_items`,
   `option_choices`, `item_options`, `vendors`, `vendor_schedules`, `delivery_zones`,
   `delivery_fee_tiers` and the voucher, and returns a `quote_id` with
   `expires_at`.
3. `place_order_v1` re-prices **again**, inside the transaction that creates the order. It compares
   against the `quote_id`'s fingerprint.
4. If anything changed, it **aborts and returns `PRICE_CHANGED`** with an itemised diff: which item,
   old price, new price, and which voucher no longer applies.
5. The app shows a clear "prices changed" sheet. The customer re-confirms. Only then is the order
   created at the new price.

**Consequences:**

- A customer is never charged a stale price, and never charged silently more than they saw.
- Voucher expiry, voucher exhaustion, stock changes and fee changes are all handled by the same
  mechanism, because they all change the fingerprint.
- The cache needs no invalidation logic to be *correct*. It only needs to be invalidated to be
  *pleasant*. That is why `menu_version` and a menu snapshot exist — they are a performance
  feature, not a correctness feature.
- Availability is handled **differently** from the four above, and the difference is deliberate. A voucher
  that expires or a fee that changes alters what the customer is charged, so it belongs in the fingerprint
  and surfaces as a price diff. Availability does not alter the price — it removes the line — so it is
  refused outright: `stock_count <= 0` raises `OUT_OF_STOCK`, and `is_available = false` raises
  `ITEM_UNAVAILABLE`. Both surface in `quote_order_v1`'s `rejections`, one per vendor, which is what
  spec 2.6's "one bad vendor never loses the whole basket" needs. **Stock is not in the fingerprint**, and
  `stock_count` is never decremented — it is vendor-maintained and `null` means unlimited, so two customers
  can still race for the last unit. See ADR 22.

### 6.2 What the offline cache stores

| Store | Contents | Size target |
|---|---|---|
| SQLite `catalog_cache` | Vendors, categories, items, options for cached areas | < 8 MB |
| SQLite `carts` | Active cart + recent order history | < 1 MB |
| SQLite `drafts` | Addresses, voucher entry, form state | < 200 KB |
| AsyncStorage / MMKV | Session token, flags cache, last `menu_version` map | < 200 KB |

Encrypted at rest with SQLCipher (Android) / the platform keychain equivalent (iOS), keyed from a
value in the secure enclave or Android Keystore. Nothing secret is written to plain storage.

### 6.3 Sync contract

```
pull  GET /sync/changes?since=<cursor>      → deltas by table, ordered, cursor-based
push  POST /sync/cart                       → cart upsert, server wins on conflict by
                                               updated_at, cart is last-write-wins because
                                               only one device is authoritative per user
```

The cart is server-authoritative with last-write-wins. Orders are never pushed from the device —
they are only ever created by `place_order_v1` on the server. This removes the hardest class of
offline-first bug (duplicate orders) by construction.

---

## 7. Non-functional requirements

| ID | Requirement | Target |
|---|---|---|
| NFR-01 | Checkout quote latency | < 400 ms p95 |
| NFR-02 | Place order latency | < 900 ms p95 |
| NFR-03 | Vendor feed first paint | < 1.2 s on 4G |
| NFR-04 | Menu cached and browsable with zero network | Full offline browse |
| NFR-05 | App cold start | < 2 s |
| NFR-06 | Push delivery (order placed → vendor notified) | < 5 s p95 |
| NFR-07 | Zero order loss on network failure mid-checkout | Idempotent `place_order_v1` |
| NFR-08 | No duplicate order, payout or ledger entry ever | Unique idempotency keys |
| NFR-09 | Arabic search handles tashkeel and alef/ya/ta-marbuta variants | Normalised columns + trigram |
| NFR-10 | Running cost at launch | $0–25/month |
| NFR-11 | No customer PII in logs, analytics or crash reports | Hashed ids only |
| NFR-12 | RLS blocks all cross-tenant reads | Policy tests required |

---

## 8. Success criteria

| Metric | Target at 90 days |
|---|---|
| Orders/day, lunch peak | 500 sustained, 1,000 ceiling |
| Vendors live | 150 |
| Riders live | 60 |
| Vendor acceptance rate | > 95% |
| Order cancellation rate (vendor-side) | < 3% |
| Order delivered within quoted window | > 85% |
| Crash-free sessions | > 99.5% |
| Cash reconciliation breaks | 0 unexplained |
| Monthly infrastructure cost | < $25 |
| Time from "no active order" to "order delivered" | < 45 min at lunch |

---

## 9. Data retention

Enforced by `pg_cron`, not by intention. Every row below has a named job.

| Data | Hot | Cold | Enforcement | Notes |
|---|---|---|---|---|
| Orders, sub-orders | Indefinite (slim row) | Items and status history → R2 `private/archive/` after 60 days | `archive_orders_v1` nightly | Satisfies "retained indefinitely" for reorder and disputes; the slim row keeps totals, statuses, addresses and payouts, which is what those two use cases need |
| Order items | 60 days in Postgres | R2 archive, retained indefinitely | same job | |
| Ledger entries | **Indefinite in Postgres. Never archived.** | Postgres backups only | none — append-only | This is the one table that must never leave Postgres, because a balance must be computable at any time. It is also the main reason to budget for Pro before real money |
| Rider location traces | 30 days | None | `prune_location_pings` hourly | Traces in Durable Object SQLite are deleted with the object |
| Analytics events | 90 days hot | 2 years as monthly aggregates in R2 | `rollup_analytics` monthly | |
| Search events | Not stored row-wise in Postgres | Firebase Analytics (14-month retention ≈ the 1-year requirement) + a small `search_daily_stats` aggregate | `rollup_search_stats` nightly | Storing raw search events in Postgres would consume the entire database budget — see `free-tier-plan.md` §4 |
| Auth logs | 365 days as daily aggregates | Postgres | `rollup_auth_stats` nightly | Free tier has no row-level audit log; daily aggregates are the honest maximum |
| Notifications | 30 days | None | `prune_notifications` daily | |
| `events` outbox | 7 days delivered | None | `prune_events` hourly | Forgetting this is the most common way a free-tier database dies |
| Rider documents | 3 years | R2 `private/` | none — small, low volume | Compliance, not growth |
| Collection proof photos | 90 days | R2 `private/` | `prune_proofs` weekly | Needed for dispute windows, not indefinitely |

---

## 10. Out of scope, explicitly

Recorded so it is not re-litigated mid-build:

- Payment gateway integration (spec'd as an extension point in `plan.md` §8, not built)
- **Customer wallet, top-ups, and any payment automation.** Cash and Vodafone Cash / Instapay,
  settled directly between customer and rider
- Email or phone sign-in (Google and Apple only)
- Loyalty, subscription, or customer tiering
- Scheduled / recurring orders
- Split delivery to multiple addresses, or to multiple addresses on one order
- More than 3 vendors in one cart
- Separate deliveries per vendor (parallel riders); modelled but not built
- Refunds originating from the platform (vendor rejections only, in v1)
- Ads revenue (slots modelled, unsold)
- Multi-country support (single `country_code` throughout)

---

## 11. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Cash in transit is stolen or lost** | High | Per-rider configurable cash limits, collection proof, short settlement cycles, `cash_held` visible per rider, daily variance must reach zero |
| **Rider cash limit throttles supply at lunch** | High | The limit blocks cash orders, so riders stop accepting entirely. Alert on riders hitting 80% and settle proactively during the peak |
| **Launching rider commission causes riders to leave** | High | It is the only revenue line at launch, so it is also the only one that can be tuned. `pct_of_delivery_fee_bps` is admin-editable per rider and per city without a deploy |
| **Turning on vendor commission at month 3–4 feels like a bait-and-switch** | High | Disclose before activation, never silently apply, keep `commission_rules.effective_from`, and offer vendors a rate card they can see |
| Database hits the free-tier size wall | High | Pruning plus archival; `free-tier-plan.md` §3 gives the trigger point |
| Lunch peak overwhelms rider supply | High | Shift scheduling, `capacity_per_slot`, explicit wait time quoted rather than a wrong ETA |
| Vendor menu data rots, causing cancellations | Medium | Stock and availability shown as a per-vendor quality metric; decline-queue review |
| Profile completion is a drop-off point | Medium | Ask for the phone *after* the customer has seen the app, not at sign-in. Offer sign-in with Apple first on iOS, which needs no new field |
| Multi-vendor baskets are abandoned out of proportion to their convenience | Medium | 3-vendor cap surfaced early, per-vendor minimum order value shown early, v1 measures the funnel |
| A customer disputes a delivery fee | Medium | The fee inputs are frozen onto the order, so the quote can be recomputed exactly as it stood at checkout |