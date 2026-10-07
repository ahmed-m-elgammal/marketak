# Marketak — Data Model

**Source of truth: the live Supabase project `erxxsebcqqcpkipzcdhg` (marketak, eu-central-1, Postgres 17.11).**
Every table name, column, type, constraint, index, trigger, policy, function signature and seed row below was read out of the running database via the Supabase MCP server. Nothing here was reconstructed from `supabase/migrations/`, and nothing is aspirational.

The machine-readable form of everything in this document is in `schema/*.sql`, file by file.

---

## Contents

1. [What this system is](#1-what-this-system-is)
2. [The three invariants that shaped everything](#2-the-three-invariants-that-shaped-everything)
3. [Reading the numbers](#3-reading-the-numbers)
4. [Geo and platform configuration](#4-geo-and-platform-configuration)
5. [Identity](#5-identity)
6. [Vendors and catalogue](#6-vendors-and-catalogue)
7. [Cart](#7-cart)
8. [Orders — the centre of the model](#8-orders--the-centre-of-the-model)
9. [Delivery](#9-delivery)
10. [Money](#10-money)
11. [Engagement, events and operations](#11-engagement-events-and-operations)
12. [The money path end to end](#12-the-money-path-end-to-end)
13. [How money is protected](#13-how-money-is-protected)
14. [Indexes: what the design leans on](#14-indexes-what-the-design-leans-on)
15. [Partitioning and retention](#15-partitioning-and-retention)
16. [Security model](#16-security-model)
17. [Known rough edges in the live schema](#17-known-rough-edges-in-the-live-schema)
18. [File map](#18-file-map)

---

## 1. What this system is

A multi-vendor delivery platform for one city at a time, lunch service first. Arabic and English. Four roles: **customer**, **rider**, **vendor**, **admin**.

There are three parts to the business and each one has its own shape in the data:

| Part | Shape | Where it lives |
|---|---|---|
| Commerce | a customer baskets items across several vendors in one checkout | `orders` + `sub_orders` |
| Fulfilment | a rider carries one trip with several stops | `delivery_assignments` |
| Settlement | money is split between vendor, rider and platform, then reconciled | `ledger_entries`, `payouts`, `platform_float` |

62 tables in `public` (60 plain + 2 partitioned), 0 in `private`, 1 view, 139 functions (105 `public` + 34 `private`), 373 constraints (62 PK, 22 UNIQUE, 176 CHECK, 107 FK, 5 deferred-trigger, 1 EXCLUDE), 249 indexes, 72 triggers, 115 RLS policies, 11 extensions. RLS is enabled on all 62 tables, and **0 of the 115 policies are anything other than `FOR SELECT`**.

---

## 2. The three invariants that shaped everything

These are not stylistic preferences. Each one is enforced somewhere the application cannot bypass.

### 2.1 A checkout is one `orders` row plus N `sub_orders` rows

There is no `vendor_id` on `orders`. Ever. One checkout spanning three restaurants produces three `sub_orders` rows, each with its own status, its own prep estimate and its own payout figure.

This is why the schema has the shape it does:

- `sub_orders` has `UNIQUE (order_id, vendor_id)` — a vendor appears at most once per checkout, even if the customer added items from it in three separate browsing sessions.
- `sub_orders` has `UNIQUE (order_id, sequence)` — the pickup order is stable.
- `orders.status` is **derived**, never written by a client. `sync_order_status()` and `private.recompute_order_aggregates()` fold the sub_order states with a most-terminal-wins rule, and they are the only writers.
- `orders.vendor_count` and `orders.item_count` are trigger-maintained from the children.

The alternative design — one order row with a nullable `vendor_id` — cannot express "two restaurants in one bag, arriving separately" without either duplicating the header or leaving the vendor ambiguous. That is the whole reason this schema exists.

### 2.2 The platform holds no customer money

There is no customer wallet and no top-up flow. `wallets.owner_type` is CHECK-constrained to `('vendor','rider')` — a customer row cannot be inserted even by a bug.

What the platform does track is **the cash a rider is physically carrying** for cash-on-delivery orders. That is not a balance to be topped up; it is a liability to be reconciled. It lives in `riders.cash_held` and `platform_float`, and it is the reason `effective_cash_limit_v1`, `begin_collection_v1` and `collect_cash_v1` exist.

The customer pays the rider directly at the door. The database's job is to *record* that it happened, and to refuse to let the recorded amount drift from what is owed.

### 2.3 Never trust the client for money

The client never sends a price. It sends a `quote_id`. `place_order_v1()` re-runs the entire pricing engine inside the writing transaction and aborts with `PRICE_CHANGED` if the fingerprint moved.

```
client                          database
  │  quote_order_v1(cart, address, voucher, tip)
  │ ──────────────────────────▶  private.compute_quote()
  │                              reads delivery_zones + delivery_fee_tiers
  │                              reads vouchers, menu_items, option_choices
  │                              returns totals + a fingerprint
  │ ◀──────────────────────────  quote_id, expires_at = now() + 5 min
  │                              (fingerprint parked on carts.quote_*)
  │
  │  place_order_v1(quote_id, 'cash', idempotency_key)
  │ ──────────────────────────▶  idempotency lookup   ← FIRST
  │                              profile gate
  │                              quote expiry check
  │                              private.compute_quote()  ← AGAIN, same engine
  │                              fingerprint compare
  │                              PRICE_CHANGED if different → ABORT
  │                              only now: INSERT orders + sub_orders + items
  │                              INSERT events (same transaction)
  │ ◀──────────────────────────  order_id, order_number, sub_orders
```

Two calls to the same function. If they disagree, nothing is written. This is the single most important property in the system and everything in `schema/16_functions_checkout.sql` exists to serve it.

The error carries an itemised diff — which item moved, old price, new price, and both totals — because a "prices changed" screen with no numbers in it is not consent.

---

## 3. Reading the numbers

- **Every money column is an `integer` in the currency's minor unit.** EGP piastres. 1 EGP = 100 piastres. There is no `numeric` money anywhere, and no `float`.
- **Multipliers and percentages are integer basis points.** `multiplier_bps`, `pct_of_delivery_fee_bps`, `delivery_multiplier_bps`. 10000 = 1.00x = 100%. Never `0.15`, never `15`.
- **Coordinates are `numeric(9,6)`**, degrees, ~11 cm precision. Overkill, but it means a distance computation is reproducible forever.
- **IDs are `uuid` `gen_random_uuid()`**, except `events`, `notifications`, `audit_log` and `rider_location_pings`, which use `bigint` sequences. The reason is in §15.
- **Temporal types are honest.** `timestamptz` for instants (`created_at`, `delivered_at`), `time without time zone` for opening hours (`vendor_schedules.opens_at` — "11:00" is a wall-clock concept, not an instant), `date` for business days (`platform_float.business_date`, `vendor_earnings_daily`).
- **Soft deletes are `deleted_at timestamptz`.** Present on the catalog and identity tables, absent on financial records. `orders` has no `deleted_at` and never will: an order is not deletable.
- **No enums.** 0 enum types in the schema. Every closed set is a `text` column with a `CHECK (col = ANY (ARRAY[...]))`. This is deliberate — adding a vendor vertical or a notification channel is then a migration on a CHECK rather than an `ALTER TYPE` that can invalidate a running client.

---

## 4. Geo and platform configuration

`cities → areas → delivery_zones` is the spatial spine. An address resolves to an area; the area resolves to a zone; the zone holds the fee.

| Table | Role | Notable |
|---|---|---|
| `cities` | the delivery city | `is_primary` with `UNIQUE (is_primary) WHERE is_primary` — at most one primary city, enforced in the index |
| `areas` | named neighbourhood | `geohash_prefix` is the join key; no PostGIS point-in-polygon on the hot path |
| `delivery_zones` | **the money and policy unit** | every fee constant in the system |
| `delivery_fee_tiers` | fee multiplier by vendor count | `PRIMARY KEY (zone_id, vendor_count)` |
| `settings` | global key/value | 13 rows; read through `private.setting_*()` |
| `feature_flags` | remote config | `value_type` so the client knows how to parse |

### The fee formula

From `delivery_zones`, verbatim from `private.compute_quote()`:

```
delivery_fee = round(base_fee × multiplier_bps / 10000)
             + max(0, distance_km − free_radius_km) × per_km_fee
```

- `distance_km` is the distance to the **furthest** vendor in the basket, not the average and not the nearest. One trip to the far end of the zone covers all the stops.
- `multiplier_bps` comes from `delivery_fee_tiers` by the basket's vendor count. `assert_fee_tiers_monotonic()` refuses any schedule that would make a bigger basket cheaper.
- The live seed has 3 tiers at `10000` bps — a **flat fee**. Adding a second vendor does not change the price at launch. The mechanism exists so this can become a rising schedule with no code change.

### No fee constant is a literal

`delivery_base_fee`, `per_km_fee`, `free_radius_km`, `max_vendors_per_order`, `rider_max_cash_held_default`, `service_fee_*`, `order_number_prefix` — none of these appear as a literal in application code or in a SQL function body. They are columns or `settings` rows, read at call time. `compute_quote()` reads even its own fallbacks from `settings`:

```sql
v_max_vendors := coalesce(v_zone.max_vendors_per_order,
                           private.setting_int('max_vendors_per_order', 3));
```

The three-character default is the only literal, and it is unreachable while the seed row exists. Grep for a fee number in code and you should find nothing.

### Two numbers that encode the launch revenue model

| Setting | Value | Meaning |
|---|---|---|
| `rider_commission_enabled` | `true` | the platform takes a cut of the delivery fee from the **rider** |
| `vendor_commission_enabled` | `false` | no vendor commission at launch |
| `service_fee_enabled` | `false` | no customer service fee at launch |

Paired with two `commission_rules`:

```
rider  / delivery_fee / percentage / 2000 bps / ACTIVE    ← 20% of delivery fee
vendor / subtotal      / percentage /    0 bps / INACTIVE  ← ready, off
```

So at launch the platform's revenue is 20% of the delivery fee, taken from the rider's cut, and nothing else. Turning on vendor commission later is one UPDATE — which is exactly why it is a setting and a row rather than a code path.

---

## 5. Identity

Supabase Auth is the identity system. `public.users` is the profile.

```
auth.users  (Supabase-managed)
    │  1:1, ON DELETE CASCADE
    ▼
users ──────────────┬── user_roles            (customer|rider|admin|support)
                    ├── user_auth_providers   (google|apple)
                    ├── addresses
                    ├── device_tokens
                    ├── carts, favorites, favorite_items
                    ├── orders
                    ├── vouchers.created_by
                    └── wallet / ledger (via owner_id, polymorphic)
```

| Table | Role | Notable |
|---|---|---|
| `users` | profile | `profile_completed_at IS NULL` ⇒ may browse, may not order |
| `user_roles` | roles | soft revocation via `revoked_at`; a partial index serves the live check |
| `user_auth_providers` | provider links | `CHECK provider_type IN ('google','apple')`. No password, no email login, no phone OTP |
| `addresses` | saved addresses | `geohash` + `geohash_prefix` + denormalised `area_id` so fee lookup skips geo resolution |
| `device_tokens` | push registration | `UNIQUE(token)` — a reinstall moves the row, it does not duplicate it |

`users.id` has no default. It is a mirror of `auth.users.id`, not a generated key — the profile cannot exist without an auth identity, and `handle_new_user()` creates it.

### The profile gate

`profile_phone_required` CHECK: `profile_completed_at IS NULL OR phone_number IS NOT NULL`. A profile cannot be marked complete without a phone number. And `place_order_v1()` independently re-checks the gate before doing anything:

```sql
if not exists (select 1 from public.users u
                where u.id = v_user and u.profile_completed_at is not null) then
  perform private.err('PROFILE_INCOMPLETE', 'complete your profile before ordering');
end if;
```

Enforced in the database, not only in the app.

### Riders have an optional account

`riders.user_id` is nullable. A rider can exist, be dispatched to, and be paid out before they ever install the app. The cascade on `users` is `SET NULL` rather than `CASCADE` for the same reason: deleting a login must not destroy a payout history.

Contact details are synchronised in **both directions** by two triggers, because the customer has to be able to call the rider at the door:

- `users` updated → `push_user_contact_to_rider()` copies name/phone/country to the rider row, guarded by `IS DISTINCT FROM` so an unrelated profile edit does not bump `riders.updated_at`.
- `riders` written → `sync_rider_contact_from_user()` pulls from the profile.

`riders.phone_number` is `UNIQUE`. Two riders cannot share one number; the second insert raises rather than silently reassigning.

---

## 6. Vendors and catalogue

```
cities ──┬── areas ──┬── vendors ──┬── vendor_cuisines ── cuisines
         │           │             ├── vendor_areas
         │           │             ├── vendor_schedules      (weekly windows)
         │           │             ├── vendor_holidays       (closures)
         │           │             └── vendor_staff ──────── users
         │           └── delivery_zones
         │
         └── brands ── vendors

vendors ── menu_categories ── menu_items ──┬── menu_item_sizes   (price variants)
                                            └── item_options ── option_choices
```

| Table | Role | Notable |
|---|---|---|
| `vendors` | the merchant | 38 columns. `menu_version` is the cache key. `vertical_type` covers food, grocery, pharmacy, flowers, bakery, others |
| `brands` | optional parent brand | several storefronts, one brand |
| `cuisines` | global taxonomy | `*_normalized` columns feed the trigram indexes |
| `vendor_cuisines` / `vendor_areas` / `vendor_staff` | the vendor's edges | all cascade on vendor delete |
| `vendor_areas` | where it delivers | per-area `eta_minutes`, `eta_maxutes` and `delivery_fee_override` |
| `vendor_schedules` | opening hours | `(vendor_id, day_of_week, slot)` — `slot` allows two windows a day |
| `vendor_holidays` | closures | one row per `(vendor_id, date)` |
| `menu_categories` | menu sections | |
| `menu_items` | sellable line | `pricing_mode IN ('fixed','sized')` |
| `menu_item_sizes` | price variants | exactly one default, index-enforced |
| `item_options` | customisation group | `min_selections` / `max_selections` |
| `option_choices` | the selectable values | `price_modifier` may be negative |

### Two pricing modes

`pricing_mode = 'fixed'` → the price is `menu_items.base_price`.
`pricing_mode = 'sized'` → the customer must pick a `menu_item_sizes` row; the price is that row's `price`.

Both paths add `SUM(option_choices.price_modifier)`. Two CHECKs keep this honest:

```sql
fixed_item_has_price   -- pricing_mode <> 'fixed' OR base_price IS NOT NULL
menu_items_pricing_mode_check -- pricing_mode IN ('fixed','sized')
```

And two triggers keep the sized path from becoming unsellable:

- `assert_item_has_sizes()` — a `sized` item must have at least one size row.
- `assert_item_still_sized()` — the **last** size row of a sized item cannot be deleted.

### `stock_count IS NULL` means unlimited

This is the single most easily-misread column in the schema. `NULL` is unlimited; only an explicit `0` or below is out of stock. `compute_quote()` is explicit about it:

```sql
when p.stock_count is not null and p.stock_count <= 0 then 'OUT_OF_STOCK'
```

Counting `stock_count = 0` instead would reject every item that never had stock configured.

### `menu_version` — the cache key

Clients cache a vendor's menu keyed on `vendors.menu_version`. Any write anywhere in that vendor's menu tree must bump it, or a stale client keeps showing a deleted dish.

The triggers walk the tree at the right depth:

| Table | Function | Hops to `vendor_id` |
|---|---|---|
| `menu_items` | `bump_version_for_direct_vendor()` | `vendor_id` on the row |
| `menu_categories` | `bump_version_for_direct_vendor()` | `vendor_id` on the row |
| `menu_item_sizes` | `bump_version_for_items_of()` | `item_id` → 1 |
| `item_options` | `bump_version_for_items_of()` | `item_id` → 1 |
| `option_choices` | `bump_version_for_choices()` | `option_id` → `item_id` → 2 |

They are `FOR EACH STATEMENT`, so a bulk edit of 200 items bumps the version once rather than 200 times.

### Bilingual search

`normalize_text_v1()` is unaccent + lowercase + whitespace collapse. It is applied as a **column DEFAULT**, so the normalized value is maintained by the database and cannot drift from the source:

```sql
name_normalized text default normalize_text_v1(name)
```

That makes a `GENERATED ALWAYS AS ... STORED` equivalent that works with a non-immutable-enough function and stays indexable. The trigram indexes sit on the normalized column, so `فينجز` and `finges` both match `فinger`.

Both languages get their own GIN trigram index on every searchable table, each carrying the storefront-visibility predicate so the index only holds rows a customer may see.

---

## 7. Cart

The cart is the **input to quoting**. It is not authoritative about money.

| Table | Role | Notable |
|---|---|---|
| `carts` | one live cart per user | `UNIQUE (user_id) WHERE is_active` |
| `cart_items` | the lines | `UNIQUE (cart_id, menu_item_id, md5(selected_options::text))` |
| `favorites` / `favorite_items` | two separate lists | saved merchants vs saved dishes |

`cart_items.cached_price` is display-only. It exists so the cart screen does not re-price on every render. `place_order_v1()` never reads it — it re-derives every price from the engine.

The line-identity unique index means the same item with the same options is one line whose quantity is bumped, not two rows. That is why `md5(selected_options::text)` is in the key: same pizza without olives and the same pizza with olives are different lines.

`assert_cart_item_orderable()` fires on insert and update, so a cart cannot hold an item that is already unavailable.

---

## 8. Orders — the centre of the model

### The two money views

This is the part that most often gets confused.

**`orders` holds the customer-facing view.** What the customer is charged.

```
total = (subtotal + delivery_fee + service_fee + rider_tip) − discount_amount
```

That identity is a CHECK constraint on the table, not a line in application code:

```sql
constraint orders_total_consistent check CHECK (
  (total = ((((subtotal + delivery_fee) + service_fee) + rider_tip) - discount_amount)))
```

**`sub_orders` holds the settlement view.** What each vendor is owed.

| Column | Meaning |
|---|---|
| `subtotal` | that vendor's items |
| `delivery_fee_share` | its proportional slice of the order's single delivery fee |
| `service_fee_share` | its proportional slice of the service fee |
| `discount_share` | its proportional slice of the voucher discount |
| `commission_amount` | the platform's cut from that vendor |
| `platform_fee_amount` | fee lines attributed to the platform |
| `vendor_net_payout` | `max(0, subtotal − commission)` |
| `settlement_status` | `payable` → `in_payout` → `settled`, or `void` |
| `payout_id` | which payout settled it |

The delivery fee is **one number on the order**, split proportionally to each vendor's subtotal **for reporting only**. Rider pay and platform revenue are computed per order, not per vendor — otherwise a two-vendor order would pay the rider twice.

`sub_orders_payout_only_when_settled` CHECK is the money gate:

```sql
(payout_id IS NULL OR settlement_status IN ('settled','in_payout'))
```

A sub-order cannot carry a payout id until it is actually in one.

### Order items are frozen at placement

`order_items` copies the name, both language names, the image, the unit price, the total, the selected options and the selected size. A later menu edit **must not** rewrite history.

```sql
menu_item_id references menu_items(id) ON DELETE SET NULL
```

`SET NULL`, not `CASCADE`: the line must outlive the dish it names. `item_name` and `unit_price` stay exactly as they were charged.

`total_price = quantity * unit_price` is a CHECK, not a trigger.

### The state machine

**`sub_orders.status`** — what a vendor and a rider act on:

```
pending ──▶ accepted ──▶ preparing ──▶ ready ──▶ picked_up ──▶ delivering ──▶ delivered
   │            │            │           │            │
   └────────────┴────────────┴───────────┴────────────┴──▶ cancelled
                └────────────────────────────────────────▶ rejected
```

Nine states. `rejected` and `cancelled` are distinct: a vendor declining is not the same as a customer cancelling, and the analytics read the difference.

**`orders.status`** — what the customer sees. **Derived, never written by a client.**

```
all cancelled/rejected   → cancelled
all delivered            → delivered
all terminal             → partially_cancelled
all picked_up/delivering → picked_up
all ready                → ready
all preparing/ready      → preparing
any past pending         → partially_confirmed
else                     → pending
```

Most-terminal-wins. `private.recompute_order_aggregates()` is the only writer, called by the `sync_order_status()` statement trigger on `sub_orders`. This is why the order can be `partially_cancelled` — one vendor refused, two delivered — a state that has no direct writer at all.

`confirmed_at` and `completed_at` are stamped on the same pass, each with its own `bool_and` condition.

### History, modifications, ETA

| Table | Role |
|---|---|
| `order_status_history` | append-only. `actor_role` records **who** moved the state |
| `order_modifications` | post-placement edits. `difference_amount = new_total − original_total` is CHECK-enforced |
| `order_eta_snapshots` | promised vs predicted ETA over time |

`order_status_history` rejects a no-op transition: `from_status <> to_status` is CHECK-enforced, so the log cannot contain a row that did not change anything. `assert_history_scope()` requires the row to name an order **or** a sub_order, never both and never neither.

`order_eta_snapshots` exists so lateness is measured rather than reconstructed: each row is a (promised, predicted) pair at a moment in time, and the sweep deletes anything older than 24 hours.

---

## 9. Delivery

| Table | Role | Notable |
|---|---|---|
| `riders` | the courier | `user_id` nullable. `cash_held` and `max_cash_held` |
| `driver_shifts` | on-duty windows | `area_ids uuid[]`. GiST exclusion on overlap |
| `rider_location_pings` | position history | `recorded_at` may be 5 min future (device skew) |
| `delivery_assignments` | the trip | the dispatch leg, and the cash the rider moved |
| `rider_pay_rules` | pay configuration | `rider_id IS NULL` = city default |

### `is_online` is a derived column, CHECK-enforced

```sql
constraint riders_is_online_consistent check CHECK ((is_online = (status <> 'offline')))
```

No trigger, no application discipline — the column cannot disagree with `status`.

### Location comes as a set or not at all

```sql
constraint riders_location_has_time check CHECK (
  (current_latitude IS NULL AND current_longitude IS NULL AND last_location_at IS NULL)
  OR
  (current_latitude IS NOT NULL AND current_longitude IS NOT NULL AND last_location_at IS NOT NULL))
```

A half-present position with no timestamp would be a stale fix presented as a live one.

### Five invariants are deferred to COMMIT

Five of the guards in this schema are triggers rather than CHECKs, and all five are `DEFERRABLE INITIALLY DEFERRED`:

| Trigger | Table |
|---|---|
| `trg_fee_tiers_monotonic` | `delivery_fee_tiers` |
| `trg_cart_item_orderable` | `cart_items` |
| `trg_item_has_sizes` | `menu_items` |
| `trg_item_still_sized` | `menu_item_sizes` |
| `trg_history_scope` | `order_status_history` |

This is load-bearing, and it is the only reason they work. Each checks a property of the row's **siblings**, so an immediate check fires against a half-built state:

- `trg_fee_tiers_monotonic` compares the new tier against the tiers for *lower* vendor counts. Lowering tier 2 below tier 1 must fail — but only once the whole set is visible.
- `trg_item_still_sized` asks whether the item has any size row *left*. On a `BEFORE DELETE` the row is still present, so an immediate check would pass every time and the guard would do nothing at all.
- `trg_item_has_sizes` asks whether size rows *exist*. Creating a `sized` item and its first size in one transaction fails immediately unless deferred.

Deferring moves the check to COMMIT. The violation still aborts the transaction — it just aborts once the write is coherent, instead of rejecting a legitimate multi-statement operation.

These appear as 5 rows of `contype = 't'` in `pg_constraint`, which is why the constraint total (373) exceeds 62 PK + 22 UNIQUE + 176 CHECK + 107 FK.

### One active trip per order

```sql
CREATE UNIQUE INDEX delivery_assignments_one_active ON delivery_assignments (order_id)
  WHERE status <> ALL (ARRAY['delivered','failed','cancelled']);
```

One trip in flight per order. Terminal states are excluded from the index, so a redelivery of the same order is allowed once the first trip is closed.

### One trip at a time, per rider

```sql
CREATE INDEX delivery_assignments_open ON delivery_assignments (rider_id, status)
  WHERE status = ANY (ARRAY['assigned','at_first_vendor','picking_up','picked_up','delivering','arrived']);
```

### `stop_sequence` is jsonb, and that is correct

A multi-vendor order has several vendor stops before one customer stop. The exact sequence is a property of that one order and depends on which vendors are in it — a `delivery_stops` table would be a join with no independent lifecycle and no query that needs it. It is stored as an ordered jsonb array and walked by `private.trip_distance_km()`.

### The rider-pay breakdown is frozen on the assignment

`delivery_assignments` carries the resolved pay at claim time, not a rule reference:

```sql
rider_pay_sums check CHECK (
  rider_pay_total IS NULL OR rider_pay_base IS NULL
  OR rider_pay_total = (rider_pay_base + COALESCE(rider_pay_distance,0) + COALESCE(rider_pay_bonus,0)))
```

`private.resolve_pay()` computes it once. Editing the pay rule afterwards must not retroactively change what a rider already earned.

### Cash collection is tri-state

```sql
constraint delivery_assignments_collection_pair check CHECK (
  (collection_method IS NULL AND collection_channel IS NULL AND collected_amount IS NULL)
  OR
  (collection_method IS NOT NULL AND collection_channel IS NOT NULL))
```

Plus `collection_none_is_zero`: if the method is `none`, the amount must be zero. All three payer columns (`base`, `distance`, `bonus`) must be present or all absent.

### Riders cannot have overlapping shifts

```sql
ALTER TABLE driver_shifts ADD CONSTRAINT driver_shifts_no_overlap
  EXCLUDE USING gist (rider_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)
  WHERE (is_active);
```

This is an **`EXCLUDE` constraint, not a unique index** — the distinction matters. `EXCLUDE ... WITH &&` is what actually forbids overlapping ranges; a unique index over the same columns would only forbid byte-identical rows and would happily permit a rider being double-booked. It is the one object in the schema that needs `btree_gist`, so that `uuid` becomes gist-comparable. A rider roster with two overlapping shifts produces double-booked dispatch, and a CHECK constraint cannot express "no overlap" at all.

### Pay resolution order

`private.pay_rule_for()`:
1. a rule with `rider_id = this rider`, active, inside its window — most recent `effective_from` wins;
2. otherwise the city-wide rule (`rider_id IS NULL`);
3. otherwise **nothing matches**, and then:

```sql
rider pay = 0,  platform revenue = 100% of the delivery fee
```

That third branch is the launch posture, not an oversight. There is no default rider pay in code because the absence of a rule *is* the configuration.

`UNIQUE (city_id) WHERE rider_id IS NULL AND is_active` guarantees at most one city default at a time.

---

## 10. Money

```
                    ledger_entries          payouts ── payout_lines
                   (append-only,          (batch settlement,
                    UNIQUE idempotency)     UNIQUE idempotency)
                        ▲                         ▲
                        │                         │
   wallets ─────────────┘                    sub_orders.payout_id
   (cached balance,       payout_lines.sub_order_id
    optimistic version)

   platform_float ──── one row per business date, variance CHECK-enforced
```

| Table | Role | Notable |
|---|---|---|
| `wallets` | cached balance per vendor or rider | `version` for optimistic locking. `owner_type IN ('vendor','rider')` |
| `ledger_entries` | the journal | `UNIQUE(idempotency_key)`. The money cannot be double-posted |
| `payouts` | batch settlement | `UNIQUE(idempotency_key)`. approval required before paid |
| `payout_lines` | composition | the shape CHECK ties each line to its source |
| `platform_float` | daily cash reconciliation | `variance = cash_expected − cash_remitted`, CHECK |
| `commission_rules` | configurable commission | all rows ship INACTIVE |

### `wallets` is a cache, and the schema admits it

`wallets.balance` is denormalised from `ledger_entries`. That is why:

- `wallets.version` exists — optimistic locking on the cached row;
- `get_wallet_balance_v1()` returns **`drift`** alongside the balance: the difference between the wallet row and `SUM(signed_amount)` of its ledger entries.

That `drift` column should always be zero. It is the single most valuable number in the money layer: a non-zero value means the cache and the journal disagree, which is exactly the class of bug that is otherwise invisible until an audit.

### `platform_float` is a derived variance

```sql
constraint platform_float_variance_consistent check CHECK ((variance = (cash_expected - cash_remitted)))
```

A discrepancy between what riders should have collected and what they remitted cannot be stored without being visible. `reconcile_day_v1()` may **explain** a variance; it can never close one. An audit trail that silently balances itself is not an audit trail.

### `payout_lines_shape` — the shape CHECK worth reading

```sql
constraint payout_lines_shape check CHECK (
     (payout_line_type = 'vendor_earning' AND sub_order_id IS NOT NULL AND assignment_id IS NULL)
  OR (payout_line_type = 'rider_trip'     AND sub_order_id IS NULL     AND assignment_id IS NOT NULL)
  OR (payout_line_type IN ('tip','bonus') AND sub_order_id IS NULL     AND assignment_id IS NOT NULL)
  OR (payout_line_type = 'adjustment'     AND sub_order_id IS NULL     AND assignment_id IS NULL))
```

Each line type must reference exactly the right source row. A vendor earning cannot be attributed to a trip; a tip cannot be orphaned. And two partial unique indexes enforce the same thing at the storage layer:

```sql
CREATE UNIQUE INDEX payout_lines_sub_order_unique  ON payout_lines (sub_order_id) WHERE sub_order_id IS NOT NULL;
CREATE UNIQUE INDEX payout_lines_assignment_unique ON payout_lines (assignment_id, payout_line_type) WHERE assignment_id IS NOT NULL;
```

So a concurrent payout run cannot produce a duplicate even if the CHECK somehow passed. One earning per sub_order; one trip line per assignment.

### No payout without an approver

```sql
constraint payouts_paid_is_approved check CHECK (
  status <> ALL (ARRAY['paid','processing'])
  OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
```

`draft → approved → processing → paid`, with `failed` requiring a reason. A payment cannot leave without a named human.

### Polymorphic money columns have triggers instead of foreign keys

`wallets.owner_id`, `payouts.account_id`, `ledger_entries.account_id`, `commission_rules.target_id` each point at either `vendors` or `riders`. A real FK cannot express that. What exists instead:

- a CHECK on the shape (`ledger_entries_account_required`: vendor/rider ⇒ `account_id` NOT NULL; platform/platform_earnings ⇒ NULL);
- and a trigger that verifies the target actually exists — `assert_wallet_owner()`, `assert_ledger_account()`, `assert_payout_account()`, `assert_commission_target()` — each raising `23503` with a `FOREIGN_KEY_VIOLATE` prefix.

So the guarantee is the same as an FK's, spelled out in plpgsql.

---

## 11. Engagement, events and operations

| Table | Role | Notable |
|---|---|---|
| `reviews` | one per `(order, vendor)` | `UNIQUE`. Vendor and rider ratings independent |
| `vouchers` | discount rules | `UNIQUE (upper(code))` — matched case-insensitively |
| `voucher_redemptions` | actual uses | `UNIQUE (voucher_id, order_id)` |
| `promo_slots` | home banners | `title`/`subtitle` are jsonb per-language objects |
| `events` | **the transactional outbox** | the most important ops table |
| `notifications` | partitioned, 30-day retention | `title`/`body` jsonb, rendered from templates |
| `notification_templates` | 38 rows = 19 keys × 2 langs | `UNIQUE (key, channel, lang)` |
| `audit_log` | partitioned, never pruned | `before`/`after` jsonb |
| `*_daily_stats` | rollups | 3 tables: `event_`, `auth_`, `search_` |

### `events` is the transactional outbox

Every state-changing RPC writes one row in the **same transaction** as the state change. That gives two guarantees that a separate queue cannot:

1. An event cannot exist for a change that rolled back.
2. A change cannot happen without an event.

```
events
  id            bigint, nextval
  id_uuid       uuid, unique          ← external reference, since bigint leaks volume
  type          text                  ← order.placed, order.claimed, …
  aggregate_type, aggregate_id        ← what it is about
  payload       jsonb                 ← carries the actor; there is no actor column
  attempts      smallint              ← Worker retry state
  last_error    text
  delivered_at  timestamptz           ← set by mark_events_delivered_v1
```

There is deliberately **no actor column**. The actor lives in the payload, which is what the `handle_new_user` trigger does too.

The drain is `claim_events_v1(limit)` — `FOR UPDATE SKIP LOCKED`, so two Workers never claim the same event. It joins `private.push_routing()` to resolve the template and the recipient, and returns `variables` plus the recipient's `language`.

```
event type          → who        → template key
order.placed        → customer   → order.placed
order.placed        → vendor     → vendor.new_order
order.claimed       → rider      → rider.order_assigned
order.status_changed→ customer   → order.vendor_rejected / order.picked_up
order.delivered     → customer   → order.delivered
order.cancelled     → customer   → order.cancelled
```

That table is a `VALUES` list inside `private.push_routing()`. Adding a notification type is a row, not a code change.

`claim_events_v1` and `mark_events_delivered_v1` are **`service_role` only**. A client must not be able to claim or mark events, or it could suppress a notification or replay history.

### Notifications render from templates, not inline

`notification_templates` is `UNIQUE (key, channel, lang)` — 38 rows, 19 keys × 2 languages. Arabic and English are separate **rows**, not columns, so adding a language is an insert and editing the Arabic copy never touches the English row.

`notifications.title` and `notifications.body` are jsonb objects carrying per-language strings. They are rendered from a template at write time, not composed at read time, so a push already on the device is unaffected by a later copy change.

### Search stats never store the query

```sql
search_daily_stats.query_hash ~ '^[0-9a-f]{32}$'
```

An MD5 hex, never the raw text. The query is user input and it is not retained. Two CHECKs keep the funnel from contradicting itself: `zero_result = (results_count = 0)` and `clicks <= results_count`.

### Reviews cannot be double-submitted

`UNIQUE (order_id, vendor_id)` — one review per merchant per checkout. `rider_rating IS NULL OR rider_id IS NOT NULL` prevents a rider rating with no rider attached.

---

## 12. The money path end to end

One order, two vendors, cash on delivery, 3 vendors in the basket.

**Quote**
```
delivery_zones      base 2500, free_radius 5.0, per_km 200, max_vendors 3
delivery_fee_tiers  3 vendors → 10000 bps
                    ⇒ delivery_fee = round(2500 × 10000/10000) = 2500
                      + max(0, furthest_km − 5.0) × 200

commission_rules    vendor_commission_enabled = false ⇒ commission 0 per vendor
vouchers            code, window, cap, min_order — all read from the row
```

**Place** — `place_order_v1` re-runs the whole thing. Same inputs, same fingerprint ⇒ proceeds.

```
INSERT orders       total = subtotal + 2500 + 0 + tip − discount   (CHECK enforces)
                   address_snapshot frozen, price_fingerprint stored
INSERT sub_orders   one per vendor, UNIQUE (order_id, vendor_id)
                   delivery_fee_share proportional, commission 0
                   settlement_status = 'payable'
INSERT order_items  name and price copied, never re-read from the catalogue
UPDATE carts        is_active = false, quote cleared
INSERT events       'order.placed', same transaction
```

**Deliver**

```
claim_order_v1      private.resolve_pay →
                      rider rule: none
                      city rule:  none
                      ⇒ rider pay 0, platform = 20% of delivery_fee   (ADR 3)
                    frozen onto the assignment

begin_collection_v1 amount_due, can_collect_cash (checked against max_cash_held)

collect_cash_v1     riders.cash_held += amount
                    ledger_entries ← 'cash_collected', UNIQUE idempotency_key

complete_delivery_v1  sub_orders.settlement_status → payable
                      delivery_assignments.status → delivered
```

**Reconcile and pay**

```
run_payout_v1        builds payout_lines from settled sub_orders
                     UNIQUE (sub_order_id) means no earning is paid twice
                     draft → approved (named approver) → paid

platform_float       cash_expected vs cash_remitted
                     variance is a CHECK, reconcile_day_v1 explains it
```

Every money movement passes through `ledger_entries` with a UNIQUE idempotency key, so a retried RPC is a no-op rather than a double charge.

---

## 13. How money is protected

Four independent layers. Any one of them alone would be sufficient; together they mean a bug has to defeat all four.

| # | Mechanism | What it prevents |
|---|---|---|
| 1 | **No write grants.** `authenticated` has SELECT and EXECUTE, nothing else | a client cannot issue an INSERT/UPDATE at all |
| 2 | **Arithmetic is CHECK-enforced** on the table | `total`, `payout_lines.net`, `platform_float.variance`, `delivery_assignments.rider_pay_total` cannot be written wrong |
| 3 | **Re-pricing inside the transaction** | a stale client price is never charged |
| 4 | **`UNIQUE` idempotency keys** on `orders`, `ledger_entries`, `payouts` | a retry cannot double-charge, double-post or double-pay |

Plus the invariants that make layer 2 meaningful:

- `sub_orders_payout_only_when_settled` — no payout id before settlement
- `payouts_paid_is_approved` — no payment without a named approver
- `vouchers_within_usage_limit` — `usage_count <= usage_limit_total`, in the database
- `riders_cash_held_nonneg` — a rider's cash float cannot go negative
- `ledger_entries_signed_amount_check` — `signed_amount <> 0`, no zero-value noise in the journal

---

## 14. Indexes: what the design leans on

249 indexes. Almost all fall into one of four patterns.

### Partial indexes carrying the live-row predicate

Soft-deleted rows stay in the table but stay out of the hot index.

```sql
CREATE INDEX vendors_name_trgm ON vendors USING gin (name_normalized gin_trgm_ops)
  WHERE is_active AND is_approved AND (deleted_at IS NULL);

CREATE INDEX sub_orders_payable_vendor ON sub_orders USING btree (vendor_id)
  WHERE settlement_status = 'payable';
```

The payout scan never touches a settled row. The catalogue search never touches a deleted menu.

### GIN trigram over normalized text

```sql
CREATE INDEX cuisines_name_ar_trgm ON cuisines USING gin (name_ar_normalized gin_trgm_ops);
CREATE INDEX menu_items_ingredients_trgm ON menu_items USING gin (ingredients_normalized gin_trgm_ops)
  WHERE is_available AND (deleted_at IS NULL);
```

This is why `normalize_text_v1()` exists as a column default rather than a query-time `ILIKE`. A functional index would work but could not also carry the visibility predicate.

### UNIQUE partial indexes encoding a business rule

The rule is in the storage layer, so concurrent inserts cannot violate it.

| Index | Rule |
|---|---|
| `cities_one_primary` | at most one primary city |
| `addresses_one_default` | one default address per user |
| `carts_one_active` | one live cart per user |
| `menu_item_sizes_one_default` | one default size per item |
| `vendors_slug_live` | slug reusable after soft delete |
| `user_auth_providers_provider_active` | provider relinkable after soft delete |
| `vouchers_code_upper` | codes unique case-insensitively |
| `orders_idempotency_key_key` | idempotent checkout |
| `driver_shifts_no_overlap` | no overlapping shifts (EXCLUDE constraint, not an index) |

### Composite indexes ordered for the real access path

```sql
CREATE INDEX orders_status_placed ON orders USING btree (status, placed_at DESC);
CREATE INDEX sub_orders_vendor_open ON sub_orders USING btree (vendor_id, status)
  WHERE status = ANY (ARRAY['pending','accepted','preparing','ready']);
CREATE INDEX rider_location_pings_order ON rider_location_pings USING btree (order_id, recorded_at DESC);
```

Leading column for the filter, then `recorded_at DESC` for the "last N" limit — so the index serves both the filter and the sort without a separate sort step.

---

## 15. Partitioning and retention

### Two RANGE-partitioned tables, both by `created_at`

```
notifications   PARTITION BY RANGE (created_at)
  ├── notifications_2026_10
  └── notifications_2026_11

audit_log       PARTITION BY RANGE (created_at)
  ├── audit_log_2026_10
  └── audit_log_2026_11
```

Two consequences that are easy to get wrong:

1. **The primary key must include the partition key.** `PRIMARY KEY (id, created_at)`, not `(id)`.
2. **RLS is per-relation, not inherited.** A policy on `notifications` does not cover `notifications_2026_11`. Every partition carries its own pair of policies — and `private.ensure_month_partition()` creates the partition, enables RLS and creates the policy in **one call**, so a partition can never be born open.

That last point is the whole reason partition creation is a function and not a migration step.

### Retention

| Table | Window | Job |
|---|---|---|
| `events` | 7 days **after delivered** | `prune-events-hourly` |
| `order_eta_snapshots` | 24 hours | `prune-eta-hourly` |
| `notifications` | 30 days | `prune-notifications-daily` |
| `rider_location_pings` | 30 days | `prune-pings-daily` |
| `audit_log` | **never** | — |
| `orders` and everything below | **never** | — |

Every sweeper deletes in 1000-row batches with `pg_sleep(0.05)` between them. A sweep on a large table cannot monopolise the database — that is a real failure mode for a naive `DELETE ... WHERE created_at < now() - interval '30 days'`.

`audit_log` is not pruned automatically. An audit trail that deletes itself is not an audit trail.

Cron minute offsets are staggered (`7`, `13`, `23`, `41`, `37`) so four sweeps never stack on the same connection pool at `:00`.

---

## 16. Security model

### Reads: RLS. Writes: `security definer` functions. Nothing else.

**All 115 policies are `FOR SELECT`.** There is not one `INSERT`, `UPDATE` or `DELETE` policy in the entire application schema. That is the design in one line:

- reads go through PostgREST, filtered by RLS;
- writes go exclusively through functions that re-check authorisation themselves, and write the audit or event row in the same transaction.

Every policy is `to authenticated`. Even public catalogue reads require a signed-in user — a user with no `profile_completed_at` can browse but is still authenticated.

### Identity resolution inside policies

Seven `private` functions, all `STABLE SECURITY DEFINER SET search_path TO ''`:

```
private.is_admin()                              role check, no table scan
private.vendor_ids_for(uid)                     vendor_staff where user_id = uid
private.rider_ids_for(uid)                      riders where user_id = uid
private.account_ids_for(uid)                    vendor + rider ids via wallets
private.visible_order_ids(uid)                  customer ∪ vendor ∪ rider
private.owned_or_assigned_order_ids(uid)        customer ∪ rider (stricter)
private.rider_order_ids(uid)                    rider only
```

`SECURITY DEFINER` is required, not optional: a policy on `users` cannot query `user_roles` as the calling role without recursing. `search_path TO ''` with every object schema-qualified closes the search-path hijack.

### The `riders` table has no policy and no grant

This is the sharpest detail in the schema:

```
GRANT SELECT ON riders_public TO authenticated;   ← the view
-- (no grant on `riders` at all)
```

`riders` holds `user_id`, live coordinates, `cash_held` and `max_cash_held`. A customer must be able to see the name and phone number of the person bringing their food, and nothing else. So the base table is unreachable and `riders_public` exposes exactly eight columns:

```
id, first_name, last_name, phone_number, vehicle_type, vehicle_plate,
rating_avg, rating_count
```

Phone is included deliberately — the customer pays at the door and must be able to call.

### Order visibility is three-way

```
orders_read  using ( id IN (SELECT private.visible_order_ids(auth.uid())) OR is_admin() )
```

A customer sees their own orders. A rider sees orders they are assigned. A vendor sees orders containing one of its sub_orders.

But **`sub_orders_read` is stricter for vendors** — it requires `vendor_id IN vendor_ids_for(uid)`, not merely "you have a sub_order here". A vendor sees only its own sub_orders, never a competitor's on the same order.

### `users_read` has a deliberate exception

```sql
id = auth.uid()
OR id IN (SELECT o.user_id FROM orders o
           WHERE o.id IN (SELECT private.rider_order_ids(auth.uid())))
OR is_admin()
```

A rider may read the profile of a customer on an order they are delivering — and only those. That is the minimum needed for a rider to call the customer at the door, and `rider_order_ids()` bounds it exactly.

### Money tables

Every one is scoped to the owning vendor or rider. `platform_float` has **no non-admin path at all** — its `_read` policy is identical to its `_admin_read`.

---

## 17. Known rough edges in the live schema

Observed while reading, not fixed. Recorded so nobody rediscovers them as a surprise.

1. **Two identical checks on `delivery_zones`.**
   `delivery_zones_max_vendors_per_order_check` and `max_vendors_per_order_range` have the same predicate. Harmless, but one is redundant. Likely a rename that left the old name behind.

2. **Twenty-two rows in `events`, but zero `ledger_entries`.**
   Orders were placed and events were written, but no money ever moved. Consistent with the launch posture (no service fee, no vendor commission) and with the counts below — but it means the settlement path has not been exercised by real traffic.

3. **`events` is not partitioned**, although `private.ensure_month_partition()` accepts `'events'` as a valid target and is named in the cron job. The mechanism exists and the table has not been converted. `ensure_partitions()` only loops over `notifications` and `audit_log`.

4. **13 tables carry `updated_at` but no `created_at`.** `feature_flags` is one of them, as are `wallets`, `delivery_fee_tiers`, `carts` and the rollup tables. On a mutable row that is a deliberate simplification, but on `feature_flags` it means an audit cannot answer "when was this flag first added" — only when it was last touched.

5. **`GRANT EXECUTE ... TO anon` on eleven trigger functions** (`set_updated_at`, `sync_order_status`, `sync_cart_item_vendor`, `sync_order_item_parent`, the three `sync_order_item_aggregates_*`, `touch_cart_from_new_rows`, `assert_cart_item_orderable`, `assert_history_scope`, `bump_version_for_direct_vendor`). These are PostgREST defaults and are harmless — a client cannot do anything useful with a `trigger`-returning function, and `anon` has no table grants at all — but `anon` has no business executing anything. Worth revoking as defence in depth.

6. **`normalize_text_v1` is overloaded on `text` and `jsonb`.** Both are granted, which is correct, but the `jsonb` variant is not `IMMUTABLE`-marked in a way that would let it be used in a generated column. It is only used as a column default, which works.

7. **`private.ensure_partitions()` returns a counter it never increments** (`v_made` stays 0). The return value is meaningless; callers should not branch on it.

---

## 18. File map

| File | Contents |
|---|---|
| `schema/00_extensions.sql` | 11 extensions |
| `schema/01_tables_geo_and_platform.sql` | cities, areas, delivery_zones, delivery_fee_tiers, settings, feature_flags |
| `schema/02_tables_identity.sql` | users, user_roles, user_auth_providers, addresses, device_tokens |
| `schema/03_tables_vendors_and_catalog.sql` | vendors, brands, cuisines, vendor edges, menu tree |
| `schema/04_tables_cart.sql` | carts, cart_items, favorites, favorite_items |
| `schema/05_tables_orders.sql` | orders, sub_orders, order_items, history, modifications, eta |
| `schema/06_tables_delivery.sql` | riders, driver_shifts, pings, assignments, pay rules |
| `schema/07_tables_money.sql` | wallets, ledger, payouts, float, commission rules |
| `schema/08_tables_engagement_and_ops.sql` | reviews, vouchers, promo, events, notifications, audit, rollups |
| `schema/09_foreign_keys.sql` | all 107 FKs, grouped and annotated by delete policy |
| `schema/10_indexes_geo_identity_vendors.sql` | indexes for those domains |
| `schema/11_indexes_orders_delivery_money_ops.sql` | indexes for those domains |
| `schema/12_views.sql` | `riders_public` |
| `schema/13_triggers.sql` | all 72, grouped by job; the 5 deferred invariant triggers are marked |
| `schema/14_rls_policies.sql` | all 115 policies, grouped by audience |
| `schema/15_functions_private.sql` | the `private` schema, source |
| `schema/16_functions_checkout.sql` | `compute_quote`, `quote_order_v1`, `place_order_v1` — full source |
| `schema/17_grants_and_cron.sql` | table/function grants, 6 cron jobs |
| `schema/18_seed_data.sql` | 13 settings, 3 fee tiers, 2 commission rules, 38 templates |
| `schema/19_functions_public_index.sql` | the public RPC surface (105 functions incl. trigger functions), catalogued by role |

### Live row counts at the time of writing

| Table | Rows |
|---|---|
| `notification_templates` | 38 |
| `events` | 21 |
| `users` | 4 |
| `delivery_fee_tiers` | 3 |
| `vendors`, `menu_items`, `sub_orders`, `order_items`, `commission_rules` | 2 each |
| `cities`, `areas`, `delivery_zones`, `riders`, `orders` | 1 each |
| `brands`, `cuisines`, `feature_flags`, `vouchers`, `promo_slots` | 0 |
| `wallets`, `ledger_entries` | 0 |

Structurally complete, operationally empty. No demo data, no fixtures, no seeded accounts.