# Contracts — Spec 001

Postgres RPC, edge endpoints, event contract, push catalogue. All RPC names are versioned.
All money columns are integer piastres.

---

## 1. RPC catalogue

### 1.1 Catalog and browsing

| Function | Returns | Notes |
|---|---|---|
| `get_areas_v1(p_city_code text)` | `areas[]` | Thin: id, slug, names, geohash prefix |
| `get_feed_manifest_v1(p_city_code text)` | `{ feed_version int, cdn_url text, updated_at, item_count }` | **~250 bytes. The feed itself comes from R2** |
| `get_vendor_feed_v1(p_area_id uuid, p_vertical text, p_open_only bool, p_query text, p_offset int, p_limit int, p_sort text)` | `vendors[]` + cursor | Cache-miss path only. Max 40 per page |
| `get_vendor_detail_v1(p_vendor_id uuid, p_lat, p_lng)` | vendor, areas, `menu_version`, `menu_cdn_url`, is_open_now, eta range | `menu_cdn_url` is the R2 path |
| `get_menu_v1(p_vendor_id uuid, p_version int)` | categories, items, options, choices | Only if the snapshot is unavailable. ~60 KB, prefer R2 |
| `search_catalog_v1(p_query text, p_area_id uuid, p_filters jsonb, p_limit int)` | ranked merchants + items | Trigram similarity; open-now and distance as tie-breakers |

### 1.3 Profile

| Function | Returns | Notes |
|---|---|---|
| `get_profile_status_v1()` | `{ profile_completed_at, has_phone, has_address, can_browse, can_order, missing text[] }` | Called at app launch. `missing` drives which fields the completion screen asks for. Tokens are `first_name`, `last_name`, `phone_number`, `address` — **column names, in that order**, so the app binds a label to a token without a lookup table that can drift |
| `complete_profile_v1(p_first_name, p_last_name, p_phone)` | the new profile state | The only way to set `profile_completed_at`. Validates E.164 and phone uniqueness. **Idempotent on identical retry**: same values after completion returns the current state and writes **no** second event, because a client re-sending after a timeout must not be shown an error for a request that succeeded. Differing values after completion raise `PROFILE_ALREADY_COMPLETE` rather than silently no-op'ing, because a silent no-op leaves a user believing a changed name was stored |
| `update_profile_v1(p_patch jsonb)` | the new profile | Cannot set `profile_completed_at` — rejected **twice over**: by key, and structurally by its absence from the `SET` list. Accepts exactly `first_name`, `last_name`, `phone_number`, `avatar_path`, `preferred_language`, `country_code`. A key that is forbidden and a key that does not exist are **different** client bugs, so they raise different messages (`INVALID_PATCH`) rather than one silent union hiding a typo |

All three `SECURITY DEFINER`, `search_path` pinned to `''`, `EXECUTE` granted to `authenticated` and
**not** to `anon`. Shipped in `016`.

**Both mutators write exactly one `events` row in the same transaction** (constitution III.21), with
**id-only payloads** — the changed field *names* for an edit, never their values, because the values
include the phone number.

### 1.4 Cart

| Function | Returns | Notes |
|---|---|---|
| `get_or_create_cart_v1()` | `cart_id, items[], groups[]` | One active cart per user |
| `upsert_cart_item_v1(p_menu_item_id uuid, p_vendor_id uuid, p_quantity int, p_options jsonb, p_notes text)` | cart item | Last-write-wins on `updated_at`. Raises `TOO_MANY_VENDORS` past the cap |
| `remove_cart_item_v1(p_cart_item_id uuid)` | void | |
| `clear_cart_v1()` | void | |
| `cart_summary_v1(p_cart_id uuid)` | per-vendor subtotals, cached totals, `vendor_count`, `max_vendors` | **Display only. Not authoritative** |

### 1.5 Checkout and orders

| Function | Returns | Notes |
|---|---|---|
| `quote_order_v1(p_cart_id uuid, p_address_id uuid, p_voucher_code text, p_rider_tip int, p_delivery_type text, p_grouping text)` | `quote_id, expires_at, fingerprint, fee_breakdown, totals, per_vendor[], limits, rejections[], warnings[]` | 5-minute TTL. The only source of price truth |
| `apply_voucher_v1(p_quote_id uuid, p_code text)` | new quote or a rejection reason | |
| `place_order_v1(p_quote_id uuid, p_payment_method text, p_idempotency_key text)` | `order_id, order_number, sub_orders[], totals` | Checks the profile gate first, then re-prices inside the transaction. Aborts with `PRICE_CHANGED` |
| `cancel_order_v1(p_order_id uuid, p_sub_order_id uuid, p_reason text)` | outcome, refund amount | Policy-gated by status |
| `reorder_v1(p_order_id uuid)` | new `cart_id` | Re-adds available items, flags the rest |
| `get_order_v1(p_order_id uuid)` | order, sub_orders, items, timeline, `fee_breakdown` | Slim-row aware: fetches archived detail from R2 via signed URL |
| `list_orders_v1(p_status, p_offset, p_limit)` | order summaries | Cursor-paginated |
| `confirm_modification_v1(p_modification_id uuid, p_approved bool)` | updated totals | Customer consent for price changes |
| `rate_order_v1(p_order_id uuid, p_vendor_ratings jsonb, p_comment text)` | void | Separate vendor and rider ratings |

**`quote_order_v1` response shape:**

```jsonc
{
  "quote_id": "uuid",
  "expires_at": "2026-10-04T12:05:00Z",
  "fingerprint": "md5:c41a...",
  "fee_breakdown": {
    "delivery_base_fee": 2500,
    "vendor_count": 2,
    "vendor_multiplier_bps": 11000,      // ×1.10
    "distance_km": 3.4,
    "free_radius_km": 5.0,
    "distance_charge": 0,                 // 3.4 km is inside the free radius
    "delivery_fee": 2750,                 // round(2500 × 1.10)
    "service_fee": 0,
    "service_fee_enabled": false,
    "rider_tip": 2000,
    "currency": "EGP"
  },
  "totals": {
    "subtotal": 48500, "discount_amount": 5000, "voucher_discount": 5000,
    "delivery_fee": 2750, "service_fee": 0, "rider_tip": 2000, "total": 48250
  },
  "per_vendor": [{
    "vendor_id": "uuid", "name": "مطعم", "name_ar": "مطعم",
    "subtotal": 20000, "delivery_fee_share": 1134, "service_fee_share": 0,
    "discount_share": 5000, "commission_amount": 0, "vendor_net_payout": 15000,
    "prep_estimate_minutes": 20, "ready_estimate_minutes": 12,
    "meets_minimum": true, "in_delivery_range": true
  }],
  "limits": { "vendor_count": 2, "max_vendors_per_order": 3 },
  "rejections": [{
    "vendor_id": "uuid", "code": "OUT_OF_RANGE",
    "message_ar": "المحل خارج نطاق التوصيل لمنطقتك"
  }],
  "warnings": [{ "code": "VENDOR_BUSY", "vendor_id": "uuid", "extra_minutes": 15 }]
}
```

`delivery_fee_share` is a proportional reporting split only. The fee itself is one number for the
order, because the rider's pay and the platform's revenue are computed once per order, not per
vendor.

**`PRICE_CHANGED` error shape** — the app must render this as an itemised diff and require explicit
re-confirmation:

```jsonc
{
  "code": "PRICE_CHANGED",
  "message_ar": "تغيرت الأسعار",
  "diff": [
    { "menu_item_id": "uuid", "item_name_ar": "برجر", "old_unit_price": 12000, "new_unit_price": 15000 },
    { "type": "DELIVERY_FEE_CHANGED", "old_delivery_fee": 2500, "new_delivery_fee": 2750,
      "reason_ar": "تغير عدد المطاعم في الطلب" },
    { "type": "VOUCHER_EXPIRED", "voucher_code": "WELCOME10", "message_ar": "انتهت صلاحية الكود" }
  ],
  "new_quote": { "...": "a fresh quote_order_v1 response" }
}
```

### 1.5.1 Checkout implementation notes (shipped in `017`)

Four points where `017` had to decide something neither this file nor `data-model.md` covered. All
four are open questions 3.23–3.26, not settled doctrine.

- **`quote_id` is a row on `carts`** — not a stateless token, and not a new table. The quote needs
  the inputs it was priced against *and* the old per-line prices, because `place_order_v1` must
  re-price inside its own transaction and `PRICE_CHANGED` must carry an itemised diff. A
  fingerprint alone says *that* something moved, not *what*, and a "prices changed" sheet with no
  numbers in it is not consent. Cost is bounded by the number of active users, not by order volume,
  which is why this beat a per-order quote table. Consequence accepted: one live quote per cart.
- **`place_order_v1` takes a fourth argument `p_payment_channel`, defaulted to null.** The table
  `CHECK` ties `payment_method` to `payment_channel`, and `wallet` means `vodafone_cash` or
  `instapay` (spec 3.4) with no way to infer which. `cash` derives `cod`; `wallet` with a null
  channel is **refused, not guessed**. Defaulted, so existing three-argument calls stay valid.
- **The size is carried in three real columns**, not inside `selected_options`. Measured with
  `pg_column_size` at one size plus two choices per item: 342 B in columns versus 498 B in JSONB —
  468 B/order at 3.0 items/order, about 6% of Scenario B runway. A nested-object shape was rejected
  outright because both tables `CHECK (jsonb_typeof(selected_options) = 'array')`. It also makes
  `order_items` internally consistent: `item_name` and `unit_price` were already frozen as columns
  for constitution II.14, and "Large at 15000" belongs to that same frozen identity.
- **`rider_pay_total` and `platform_revenue` are 0 at placement.** No rider exists yet, so
  `pct_of_delivery_fee_bps` cannot be resolved, and spec 3.3 freezes the resolved amounts onto
  `delivery_assignments` at assignment instead. Zero means *not yet determined*, and is
  distinguishable because no `delivery_assignments` row exists yet. `018` writes the authoritative
  figures at claim.

`transition_order_v1(p_order_id, p_sub_order_id, p_to_status, p_reason)` was **absent from this
section** while `data-model.md` §15.2 assigned it to `017`. Its signature is derived from spec 5.

### 1.6 Vendor

| Function | Returns | Notes |
|---|---|---|
| `list_vendor_orders_v1(p_status text)` | open sub-orders for the caller's vendor | The source behind `BranchInbox` |
| `transition_sub_order_v1(p_sub_order_id, p_status, p_reason)` | new status | Validates against the state machine |
| `bulk_prepare_v1(p_sub_order_ids uuid[])` | count | Accept many at once from a queue |
| `upsert_menu_item_v1(...)` | item id, new `menu_version` | Bumps the version in the same transaction |
| `delete_menu_item_v1(p_menu_item_id uuid)` | void | Soft delete. Order history is unaffected |
| `set_availability_v1(p_vendor_id, p_is_open, p_is_busy)` | effective open state | Manual override beats the schedule |
| `set_schedules_v1(p_schedules jsonb)` | schedules | Supports split shifts |
| `add_holiday_v1(p_date date, p_reason text)` | void | |
| `get_vendor_earnings_v1(p_from date, p_to date)` | daily rows + totals | `vendor_earnings_daily` |
| `request_payout_v1(p_period_start, p_period_end)` | `payout_id` | Moves `payable → in_payout` |
| `get_menu_version_v1(p_vendor_id)` | `menu_version` | Cheap poll for snapshot freshness |

### 1.7 Rider

| Function | Returns | Notes |
|---|---|---|
| `set_rider_status_v1(p_status, p_lat, p_lng)` | new status, `cash_held`, `effective_cash_limit` | |
| `open_shift_v1(p_starts_at, p_ends_at, p_area_ids uuid[])` | shift id | |
| `get_available_orders_v1(p_lat, p_lng, p_radius_km)` | up to 10 minimal summaries | Feasibility-filtered. Never includes menus |
| `get_my_pay_rule_v1()` | the rider's active `rider_pay_rules` row | So the rider can see what a trip pays before claiming it |
| `claim_order_v1(p_assignment_id, p_rider_id)` | `order_id`, resolved `rider_pay_total`, `platform_revenue` | Atomic. Raises `ORDER_ALREADY_CLAIMED`. Freezes rider pay onto the assignment |
| `get_active_trip_v1()` | assignment, stop sequence, order, customer address, `rider_pay_total` | One call per trip update |
| `arrive_vendor_v1(p_sub_order_id)` | next stop | Advances the stop sequence |
| `confirm_pickup_v1(p_sub_order_id)` | next stop or drop-off | |
| `begin_collection_v1(p_order_id, p_payment_method, p_channel)` | `{ amount_due, can_collect_cash, cash_held, effective_cash_limit }` | Raises `CASH_LIMIT_EXCEEDED` when `cash_held + amount_due` would exceed the limit |
| `collect_cash_v1(p_order_id, p_amount, p_reference, p_proof_path)` | receipt, new `cash_held` | Writes `cash_collected` against the platform, increments `cash_expected` |
| `collect_wallet_v1(p_order_id, p_channel, p_reference)` | receipt | The customer already transferred to the rider. **Writes no platform cash movement** — records `payment_channel` and a reference |
| `complete_delivery_v1(p_order_id, p_proof_path, p_lat, p_lng)` | delivery confirmation, payout summary | Writes `actual_delivery_time` and the `rider_cut` ledger entry |
| `get_rider_earnings_v1(p_from date, p_to date)` | daily rows + totals | |
| `report_issue_v1(p_order_id, p_type, p_note, p_photos uuid[])` | issue id | |

`p_channel` on both collection calls is one of `cod`, `vodafone_cash`, `instapay`. It is recorded, not
processed: the platform never moves the money in either case.

### 1.7.1 Rider delivery notes (shipped in `018`)

Four decisions `018` had to make where this section and `data-model.md` were silent or in conflict.
All four are open questions 3.27–3.29.

- **`get_available_orders_v1` materializes the offer pool.** `claim_order_v1` takes an
  `assignment_id` and raises `ORDER_ALREADY_CLAIMED`, which means assignment rows must already exist —
  but **no function in any migration creates them** and there is no offers table. The availability call
  inserts them with `ON CONFLICT DO NOTHING`, relying on `delivery_assignments_one_active`
  (`UNIQUE (order_id)` where the status is not terminal). The cost is real and accepted: **a function
  whose name says "get" writes**, and every call takes row locks on `delivery_assignments`, so callers
  must treat it as a poll rather than a free read. `021` owning cron does not help, because a rider
  would see an empty pool until `021` ships.
- **`platform_revenue` is a commission ON the delivery fee**, read from
  `commission_rules(scope='rider', applies_to='delivery_fee')`, **not** `delivery_fee − rider_pay_total`.
  §3.2 line 278 states the latter and it is arithmetically impossible: with the shipped seeds a 2500
  fee against a 2000 `per_trip` and a 500 leg bonus gives **−2000** of revenue. `per_trip` and
  `bonus_per_leg` are additive rider costs the platform bears from its own margin; the delivery fee is
  split between rider and platform. `rider_pay_rules` pays the rider, `commission_rules` books the
  revenue line — each table for its own concern, matching constitution 9.
- **Collection writes the `rider_cut` ledger entry; `complete_delivery_v1` backstops it
  idempotently.** §3.2 places both ledger writes under COLLECTION while this section credits
  `rider_cut` to `complete_delivery_v1`. Both cannot own it: `ledger_entries.idempotency_key` is
  UNIQUE, so the second write would raise. Revenue is recognised on collection regardless of payment
  method, because the platform earned the cut whether the customer handed over cash or transferred to
  the rider directly.
- **`ON CONFLICT` cannot be used against `ledger_entries` at all.** Constitution 4 gives the table
  `DO INSTEAD NOTHING` rules on `UPDATE` and `DELETE`, and **Postgres refuses any
  `INSERT ... ON CONFLICT` against a table that has rules**, whatever the conflict target. The
  idempotency guard is therefore `INSERT ... SELECT ... WHERE NOT EXISTS (idempotency_key = ...)`.
  The UNIQUE index remains the real guarantee; this is the guarded form of it. Worth knowing before
  anyone writes the settlement migrations.

Also decided here, and not obvious from the schema:

- **One assignment row per ORDER**, not per `sub_order_id`. `delivery_assignments_one_active` is
  `UNIQUE (order_id)` for any non-terminal status, which permits exactly one active trip, and spec 25
  is "one rider, one trip, N vendor pickups, one drop-off". The per-leg sequence lives in
  `stop_sequence` jsonb, so a three-vendor order is one trip with three stops and
  `bonus_per_leg × 3`.
- **Availability is judged on distance to the FURTHEST vendor**, not to the customer. A rider can
  stand next to the customer and still be an hour from the kitchen.
- **`payment_collected_by` references `users(id)`, not `riders(id)`.** Writing the rider id there is
  an FK violation, which is the kind of thing the schema check should have made obvious.
- **`riders` has no `deleted_at`** — `is_active` is the soft-delete flag, unlike the `vendors` family.
- **A collected amount must equal the order total exactly.** A short collection is a dispute, not a
  partial success, and silently accepting one would leave `platform_float.variance` permanently out
  by the difference.

Error codes added: `NOT_A_RIDER`, `RIDER_NOT_VERIFIED`, `RIDER_LOCATION_REQUIRED`, `RADIUS_INVALID`,
`ASSIGNMENT_NOT_FOUND`, `RIDER_REQUIRED`, `RIDER_NOT_FOUND`, `RIDER_NOT_ELIGIBLE`,
`ORDER_ALREADY_CLAIMED`, `ORDER_NOT_CLAIMABLE`, `ORDER_NOT_ASSIGNED`, `NOT_YOUR_TRIP` style
`NOT_AUTHORIZED`, `ALREADY_COLLECTED`, `AMOUNT_INVALID`, `AMOUNT_MISMATCH`, `CASH_LIMIT_EXCEEDED`,
`PAYMENT_CHANNEL_MISMATCH`, `ALREADY_DELIVERED`, `SUB_ORDERS_INCOMPLETE`.

### 1.8 Wallet and money

Wallets exist for **vendors and riders only**. There is no customer wallet and no top-up flow.

| Function | Returns | Notes |
|---|---|---|
| `get_wallet_v1(p_owner_type text, p_owner_id uuid)` | balance, status, recent entries | Vendor or rider. RLS limits the caller to their own |
| `adjust_wallet_v1(p_owner_type, p_owner_id, p_amount, p_reason, p_reference, p_idempotency_key)` | new balance, ledger entry id | Admin only. `p_reason` is mandatory. Writes a signed `adjustment` entry |
| `freeze_wallet_v1(p_owner_type, p_owner_id, p_reason, p_idempotency_key)` | wallet row + `frozen` flag | Blocks further payouts pending investigation. **Shipped by `025`**, which added the fourth `p_idempotency_key` argument: a retry is the one case where a replayed call could otherwise produce a second freeze-shaped effect |
| `list_frozen_v1()` | frozen and under-review wallets with reasons and balances | Admin. **Shipped by `025`** |
| `get_platform_float_v1(p_from date, p_to date)` | daily float with `variance` | The only cash exposure |
| `reconcile_day_v1(p_date date)` | expected vs banked vs owed, per account | **Must return zero unexplained variance** |
| `run_vendor_payout_v1(p_vendor_id, p_period)` | `payout_id` | `payable → in_payout` in one transaction |
| `run_rider_payout_v1(p_rider_id, p_period)` | `payout_id` | Includes cash remittance, zeroes `cash_held` |
| `approve_payout_v1(p_payout_id, p_approve, p_method, p_reference)` | new status | |
| `get_commission_v1(p_scope, p_target_id)` | effective rules | Read-only. Returns the **active rider cut** and the **inactive vendor row**. **Shipped by `025`** |
| `set_commission_rule_v1(p_scope, p_applies_to, p_value_bps, p_effective_from, p_target_id, p_commission_type)` | the new rule + the id it superseded | Admin. **Shipped by `025`, and this signature REPLACES the one in the table above it**, which said `(p_rule_id, p_value, p_is_active)`. See the note below |
| `get_fee_rules_v1(p_zone_id uuid)` | base fee, free radius, per-km, `max_vendors`, all tiers | Read-only, for the admin console and for support. **Shipped by `025`** |
| `set_fee_tier_v1(p_zone_id, p_vendor_count, p_multiplier_bps)` | the tier, + `created` | Admin. Basis points, so no float ever enters the fee. **Shipped by `025`**, as an upsert on `delivery_fee_tiers_pkey` |

**`025` also introduces the two `events` types this catalogue was missing: `fee_tier.set` and
`wallet.frozen`**, both admin audit events. `wallet.frozen` deliberately carries the reason in its
payload: a freeze notification without its reason is not actionable, and §3 forbids secrets and PII
beyond ids, neither of which an investigation note is.

**`set_commission_rule_v1` — why the signature changed, and it is not a rename.** The row this table
originally carried, `(p_rule_id, p_value, p_is_active)`, edits an existing rule in place.
`admin-crud-plan.md` §5 specifies `(p_scope, p_applies_to, p_value_bps, p_effective_from)` and inserts a
new dated rule, closing the previous one with `effective_until`. **Decided, asked rather than assumed:
the plan wins**, even though this file outranks the plan under `data-model.md` §16, because in-place
editing cannot satisfy constitution I.9's auditability — overwriting the row makes "what was the rate
last month" unanswerable, and I.9 exists precisely so a retroactive commission is a *detectable* bug
rather than a silent one. `commission_rules` already carries `effective_from`, `effective_until`,
`commission_type`, `applies_to`, `min_amount` and `max_amount`: it is a versioned rule, not a mutable
preference, and `admin-crud-plan.md` §4a independently reaches the same conclusion by refusing
`deleted_at` on this table for the same reason.

Two date rules, and the second was found by executing rather than by reading:

- A `p_effective_from` **before today** is refused with `EFFECTIVE_FROM_IN_PAST`. Not clamped —
  clamping would report success for a request the caller did not make.
- A `p_effective_from` **at or before the rule it would supersede** is refused with
  `EFFECTIVE_FROM_INVALID`. `current_date` is midnight and the rule being superseded was inserted
  during the day, so "same-day" is not the same instant; without this check the caller gets a raw
  `commission_rules_window_valid` violation on a row they never wrote.

Omitting `p_effective_from` takes `now()` and is the correct way to say "activate this immediately".

### 1.8.1 What `019` actually shipped, and what it did not

`data-model.md` §15.2 row 019 names five functions and that row is the migration inventory. `019`
implements those five. **Six of the thirteen above are unbuilt** — the eight-name gap is a naming
artefact, not eight missing behaviours: `run_payout_v1` absorbs `run_vendor_payout_v1`,
`run_rider_payout_v1` and `approve_payout_v1` as its `p_action` of `create | approve | reject`, and
`get_wallet_v1` ships as `get_wallet_balance_v1`. The six with no writer at all:

| Not built | Consequence today |
|---|---|
| ~~`freeze_wallet_v1`, `list_frozen_v1`~~ | **Shipped by `025`.** `wallets.status` accepts `'frozen'` and `'review'` and `wallets_status_reason_required` already demands a reason, but nothing could set one — a wallet could only be frozen by editing the row directly, bypassing the audit trail the constraint exists to create. Both now exist, admin-only, and both write an `events` row |
| ~~`get_commission_v1`, `set_commission_rule_v1`~~ | **Shipped by `025`.** constitution I.9 requires vendor commission to be switchable by an `update`, never a migration; it no longer needs raw SQL. Note the signature change recorded above |
| ~~`get_fee_rules_v1`, `set_fee_tier_v1`~~ | **Shipped by `025`.** Same for constitution I.7's other configurable constants |
| `get_wallet_v1` | implemented as `get_wallet_balance_v1`, per §15.2. The naming split is unresolved |

`025` also introduces the two `events` types this catalogue was missing: `fee_tier.set` and
`wallet.frozen`.

Three decisions `019` had to make where this section and `data-model.md` were silent:

- **The approval gate is `p_action` on `run_payout_v1`**, not a separate `approve_payout_v1`, because
  §15.2 assigns no such function while `payouts_paid_is_approved` makes approval structurally
  mandatory. Values are `create` \| `approve` \| `reject`, and create and approve stay in **separate
  transactions** — `plan.md` §4 requires it, so a crash mid-payout leaves a visible recoverable batch.
- **A bank reference is mandatory to approve.** `run_payout_v1` is the only function in the repository
  that can write `platform_float.cash_remitted`, and constitution I.10 requires variance to be zero or
  explained in writing. Without a required reference, variance could be closed by assertion.
- **One rider payout batch mixes cash and earnings**, with cash flagged per `payout_lines.source`, so a
  single approval covers a single net transfer.

New error codes: `OWNER_TYPE_INVALID`, `OWNER_REQUIRED`, `WALLET_NOT_FOUND`, `WALLET_NOT_ACTIVE`,
`WALLET_CONFLICT`, `LEDGER_CONFLICT`, `REASON_REQUIRED`, `REFERENCE_INVALID`, `PAYOUT_TYPE_INVALID`,
`ACCOUNT_REQUIRED`, `ACTION_INVALID`, `PERIOD_REQUIRED`, `PERIOD_INVALID`, `PERIOD_TOO_LONG`,
`PAYOUT_ID_REQUIRED`, `PAYOUT_NOT_FOUND`, `PAYOUT_NOT_DRAFT`, `METHOD_REQUIRED`, `REFERENCE_REQUIRED`,
`NOTHING_DUE`, `DATE_REQUIRED`, `DATE_IN_FUTURE`, `RANGE_INVALID`, `VARIANCE_UNEXPLAINED`,
`VENDOR_NOT_FOUND`, `RIDER_NOT_FOUND`.

**`service_role` holds `EXECUTE` on the mutations and still cannot use them.** All three money
mutations begin `if v_user is null then raise AUTH_REQUIRED`, and `private.is_admin()` is false with no
JWT, so a service-role call writes nothing. Verified by execution, not by inspection.

### 1.9 Platform

| Function | Returns | Notes |
|---|---|---|
| `get_flags_v1(p_app_role, p_app_version)` | resolved flags | The Remote Config replacement |
| `get_setting_v1(p_key)` | value | |
| `set_setting_v1(p_key, p_value)` | void | Admin |
| `record_event_v1(p_event, p_properties jsonb)` | void | Analytics → daily rollups, not raw rows |
| `get_admin_metrics_v1(p_date)` | funnel, orders, revenue by line, cancellation, ETA accuracy | |
| `get_eta_accuracy_v1(p_from date, p_to date)` | promised vs actual percentiles | |
| `claim_events_v1(p_limit int)` | collapsed notification rows | The drain. **Shipped in `038b`/`038e`/`038f`**, signature below |
| `mark_events_delivered_v1(p_ids bigint[], p_result jsonb)` | `(marked bigint, still_open bigint)` | One call per batch. **Shipped in `038`** |
| `claim_undelivered_events_v1(p_limit int)` | event batch | Retry path. **Still does not exist** |

#### 1.9.0 Push drain (shipped in `038`–`038f`)

Three functions, all `security definer` with `set search_path = ''`.

`claim_events_v1(p_limit int default 50)` returns
`(event_ids bigint[], template_key text, recipient text, recipient_id uuid, order_id uuid,
order_number text, variables jsonb, language text, oldest_event timestamptz)` — **collapsed**, one row
per `(recipient, recipient_id, template_key, order_id)`, not one row per event.

| Argument | Actual type | Why it differs from the draft |
|---|---|---|
| `mark_events_delivered_v1(p_ids uuid[])` | **`bigint[]`** | `events.id` is `bigserial`, not `uuid`. `events` carries both `id bigint` and `id_uuid uuid`; the writer paths and the claim return `id`, so the mark takes `bigint[]` |
| `mark_events_delivered_v1` returns `void` | **`(marked, still_open)`** | A partial failure must be visible to the Worker. Void gave it no way to learn that some sends failed |
| `register_device_token_v1` returns nothing | **`setof public.device_tokens`** | See below |

`register_device_token_v1(p_token text, p_platform text, p_app_role text, p_app_version text default null)`
upserts on **`(token)` alone** — `device_tokens_token_key` is `UNIQUE (token)` **globally**, there is no
`(user_id, token)` index, and the constraint forbids what that key would imply since one token cannot
belong to two users. `language` is read from `users.preferred_language` and **never accepted from the
client**, so a caller cannot choose the language its own notifications arrive in.

It returns `setof public.device_tokens` rather than a `returns table` list. The first version declared
`returns table (id uuid, token text, ...)`; those OUT parameters share their names with the columns, so
plpgsql resolved the unqualified `token` in `on conflict (token)` to the OUT PARAMETER and every call
raised `42702 column reference "token" is ambiguous`. A conflict target cannot be schema-qualified, and
renaming the OUT parameters would push odd names onto every client of an RPC whose signature is still
being decided. Returning the row type gives the client the table's own column names with no collision.

**Error codes added:** `AUTH_REQUIRED`, `TOKEN_REQUIRED`, `TOKEN_TOO_LONG`, `PLATFORM_INVALID`,
`APP_ROLE_INVALID`, `TOKEN_ALREADY_REGISTERED`, `PROFILE_INCOMPLETE`, `IDS_REQUIRED`.

#### 1.9.0.1 Grants — the first two exceptions in the repository

| Function | `anon` | `authenticated` | `service_role` |
|---|---|---|---|
| `register_device_token_v1` | **no** | yes | yes |
| `claim_events_v1` | **no** | **no** | yes |
| `mark_events_delivered_v1` | **no** | **no** | yes |

All 82 pre-existing `_v1` functions are `authenticated`-callable, and each is correct — a client asking for
its own order to be placed is what they are for. The drain pair is different: `events` has exactly one
policy, `events_admin_read`, a `SELECT` policy gated on `private.is_admin()`, and **no INSERT or UPDATE
policy at all**. A client holding EXECUTE on `mark_events_delivered_v1` could mark arbitrary events
delivered, suppressing notifications permanently, and could do it with `attempts` never rising — so the
§11 item 8 backlog alarm could never fire. An alarm that cannot ring is worse than no alarm, because it
reads as healthy. `anon` is revoked everywhere: `register_device_token_v1` reads `auth.uid()` and would
raise anyway, but a function that only fails when called is one more trap for the next author.

The pattern a future author will copy from the other 82 is
`grant execute ... to authenticated, service_role`, which is why the revoke is asserted **after** every
`create or replace`, in every one of these migrations.

#### 1.9.0.2 `variables` — every placeholder a routed template needs

`order_number`, `vendor_count`, `total`, `vendor_name`, `reason`, `refund_amount`, `rider_pay_total`,
`affected_items`, `rider_name`, `stops`, `eta`, `payment_method`, `item_count`.

`jsonb_strip_nulls` is applied, so a variable the join could not supply is **absent** rather than
present-and-null. A missing key is a renderer error you can catch; a null is a silent empty string, which
is how an Arabic message ends up with a hole in it.

Three are Worker-owned **static** strings, deliberately not supplied here, because they have no per-order
content and duplicating them into the database would give an admin one more place to edit a notification
by mistake: `review_prompt`, `action_required`, `prep_deadline`.

`eta` is `delivery_assignments.assigned_at + eta_minutes`, formatted in `cities.timezone`. **Not**
`orders.promised_delivery_at`: that column has no writer anywhere in the schema, so it was permanently
null and `{eta}` was permanently absent from `order.picked_up`. See ADR 24 and `038g`.

`money is passed raw, never formatted` — `total` and `rider_pay_total` are both piastres. Formatting in SQL
would put currency formatting in two places that must then agree, and the constitution makes every money
constant configuration rather than a literal. The Worker formats both through one helper in
`packages/shared`.

`038e` adds a migration-time assertion that every placeholder named by a **routed** template is supplied
by one of the two sides above, read from `notification_templates` rather than from frozen template bodies.
Scoped by joining `private.push_routing()`: the 12 active push templates the MVP does not route want
`{amount}`, `{period}` and similar that no emitter produces yet, which is Phase 4 work.

#### 1.9.0.3 Known limitation: no claim lease

`claim_events_v1` uses `FOR UPDATE SKIP LOCKED`, whose lock **ends when the claim transaction commits** —
but the Worker sends *after* that. Two concurrent drains would therefore claim the same events.

Accepted for MVP, with the trigger condition recorded rather than left implicit: MVP has exactly **one**
drain consumer and a 50-event drain completes in well under a second, so overlap requires a run longer
than the 15 s cron period. A crashed run is already safe — events stay undelivered and are reclaimed next
tick, which is at-least-once delivery and the correct trade for push, where a retry beats a lost
notification.

**A lease becomes mandatory the moment there is a second concurrent consumer, or the drain is scaled
horizontally.** It would be `claimed_at timestamptz` + `claim_token uuid` on `events`, with the claim
writing both and refusing rows whose lease is live, and the mark clearing the lease. That contradicts the
plan's `Schema changes: 0` and would require an ADR amendment under rule 6.
| `archive_orders_v1(p_before date, p_limit int)` | archived count | Moves items and history to R2 |

#### 1.9.1 Voucher admin surface (shipped in `037`)

Before this there were **zero** voucher functions in `public`: `count(*) from pg_proc where proname
ilike '%voucher%'` was 0. Every other admin entity has an upsert, a soft delete and a restore.

| Function | Returns | Notes |
|---|---|---|
| `admin_upsert_voucher_v1(p_patch jsonb, p_id uuid)` | uuid | Create or update. Admin only |
| `admin_delete_voucher_v1(p_id uuid, p_reason text)` | void | Soft delete. Reason mandatory |
| `admin_restore_voucher_v1(p_id uuid, p_reason text)` | void | Clears `deleted_at`. Does **not** change `is_active` |

Accepted keys: `code`, `name`, `discount_type`, `discount_value`, `min_order_value`,
`max_discount_cap`, `usage_limit_total`, `usage_limit_per_user`, `applies_to_vendor_ids`,
`vertical_type`, `first_order_only`, `valid_from`, `valid_until`, `is_active`.

`usage_count` is **not** accepted. It is system state; a writable usage limit is a limit that can be
reset.

Three conventions a caller must know, none of which the type signature carries:

| Thing | Rule |
|---|---|
| `discount_value` for `percentage` | **Basis points**, so `1000` = 10.0%. Range 1..10000 |
| `applies_to_vendor_ids` | A uuid array, **or** the literal string `"ALL_VENDORS"`, stored as the empty array |
| `max_discount_cap`, `valid_until` | An **absent** key means leave alone. An explicit jsonb `null` means clear |

The absent-vs-null rule is not cosmetic. `p_patch ? 'k'` is true for both, and
`jsonb_typeof('{}'->'k')` is SQL NULL rather than the string `'null'`, so the obvious
`case when p_patch ? 'k' and jsonb_typeof(...) <> 'null'` conflates them and an explicit null
silently keeps the old value. Only a three-way test separates absent from null.

Since `036` an empty `applies_to_vendor_ids` means **every vendor**, not none. Before that a voucher
created with schema defaults was rejected on every cart.

Error codes: `AUTH_REQUIRED`, `NOT_AUTHORIZED`, `PATCH_EMPTY`, `UNKNOWN_KEY`, `KEY_REQUIRED`,
`PATCH_INVALID`, `VENDOR_NOT_FOUND`, `DISCOUNT_TYPE_INVALID`, `DISCOUNT_PERCENTAGE_INVALID`,
`DISCOUNT_VALUE_INVALID`, `VOUCHER_CODE_TAKEN` (case-insensitive, matches `compute_quote`),
`VOUCHER_WINDOW_INVALID`, `VOUCHER_LIMIT_INVALID`, `VOUCHER_CAP_INVALID`, `VERTICAL_TYPE_INVALID`,
`NOT_FOUND`, `ALREADY_DELETED`, `NOT_DELETED`, `REASON_REQUIRED`.

### 1.10 Sync

| Function | Returns | Notes |
|---|---|---|
| `sync_changes_v1(p_since timestamptz)` | `{ cursor, areas[], vendor_ids[], menu_versions[], cart[] }` | Small by construction. Catalog is R2 |
---

## 2. Edge endpoints

| Endpoint | Method | Purpose | Auth |
|---|---|---|---|
| `cdn/*` | GET | R2 public bucket via Cloudflare CDN | Public |
| `files/private/*` | GET | R2 private via signed URL | Signed |
| `upload/sign` | POST | Signed R2 upload URL after a role check | Supabase JWT |
| `files/access` | POST | Short-lived signed URL for a private object | Supabase JWT + role check |
| `track/{order_id}` | WS | OrderRoom, Phase 3 | JWT + `can_track_order_v1` |
| `ws/vendor/{vendor_id}` | WS | BranchInbox | JWT + `vendor_staff` check |
| `webhooks/events` | POST | Database webhook for critical events | Shared secret |
| `webhooks/jobs` | POST | Cron Trigger entry | Cloudflare secret |
| `admin/*`, `merchant/*` | — | Cloudflare Pages static apps | Supabase Auth |

Every endpoint is idempotent. `webhooks/events` keys on `events.id_uuid`.

---

## 3. Event contract

`events` is the only channel from Supabase to the outside world.

| Field | Type | Meaning |
|---|---|---|
| `id` | `bigserial` | Local ordering |
| `id_uuid` | `uuid` | **Downstream idempotency key** |
| `type` | `text` | `order.placed`, `order.status_changed`, … |
| `aggregate_type` | `text` | `order`, `vendor`, `voucher` |
| `aggregate_id` | `uuid` | |
| `payload` | `jsonb` | Ids and minimum data. **Never secrets, never PII beyond ids** |
| `attempts` | `smallint` | Alert above 5 |
| `last_error` | `text` | |
| `created_at` | `timestamptz` | |
| `delivered_at` | `timestamptz` | Null until confirmed |

### 3.1 Types and their urgency

| Type | Payload | Path | Effect |
|---|---|---|---|
| `order.placed` | order_id, vendor_ids, totals | **Webhook** | FCM to vendor staff + `BranchInbox` push |
| `vendor.rejected_sub_order` | order_id, sub_order_id, vendor_id, reason | **Webhook** | FCM to customer, update order aggregate |
| `driver.assigned` | order_id, rider_id, rider_pay_total | **Webhook** | FCM to rider and customer, `OrderRoom` push |
| `order.status_changed` | order_id, sub_order_id, from, to, eta | Batched 15 s | FCM to customer, `OrderRoom` push |
| `order.delivered` | order_id, delivered_at, sub_order_ids | Batched 15 s | FCM, review prompt |
| `order.cancelled` | order_id, reason, refund | Batched 15 s | FCM to all parties |
| `payment.collected` | order_id, method, channel, collected_amount | Batched 15 s | FCM to customer, `platform_float` update |
| `menu.updated` | vendor_id, menu_version | Batched 15 s | Rebuild the R2 snapshot |
| `driver.arrived` | order_id | Batched 15 s | `OrderRoom` push only, no push notification |
| `payout.paid` | payout_id, owner_type, owner_id, amount | Batched 15 s | FCM to vendor or rider |
| `rider.cash_limit_warning` | rider_id, cash_held, effective_cash_limit | Batched 15 s | FCM to the rider only |
| `commission.activated` | scope, value, effective_from | Batched 15 s | Admin audit notification |
| `fee_tier.set` | actor, vendor_count, multiplier_bps, created | Batched 15 s | Added by `025`. The catalogue had no fee-tier event, so a fee change was invisible to the outbox |
| `wallet.frozen` | actor, owner_type, owner_id, reason, idempotency_key | Batched 15 s | Added by `025`. The reason is an admin audit note, not a customer push, so it travels in the payload |
| `voucher.created` | voucher_id | Batched 15 s | None in v1 |
| `user.profile_completed` | user_id | Batched 15 s | None in v1 — `auth_daily_stats` is the obvious future reader |
| `user.profile_updated` | user_id, changed field **names** | Batched 15 s | None in v1 |

**These two were missing from this table and were added by `016`.** The catalogue has no profile event
at all, which was a real gap: constitution 18 makes the profile gate load-bearing, and nothing recorded
that completing it happened. They follow the catalogue's own shape — singular aggregate, dot, past-tense
verb — and carry **id-only payloads**, so neither leaks the phone number into the outbox.
| `vendor.earnings_rolled` | vendor_id, business_date | Batched 15 s | None |
### 3.2 Guarantees

- **At-least-once.** Every consumer is idempotent: FCM uses a collapse key of `event_id`, snapshot
  rebuilds are content-addressed, clients ignore a repeated `id_uuid`.
- **Order guaranteed before notification**, because the `events` insert is in the same transaction
  as the state change.
- **A Worker outage delays notifications and loses nothing.** The cron drain retries every minute.
- **Pruned 7 days after delivery.** Anything older is a bug, not a backlog.

---

## 4. Push notification catalogue

Templates live in `notification_templates`, rendered server-side in the user's `preferred_language`.

### 4.1 Customer

| Key | Trigger | Variables |
|---|---|---|
| `order.placed` | Order placed | order_number, vendor_count, total |
| `order.vendor_accepted` | First vendor accepts | vendor_name, eta |
| `order.vendor_rejected` | A vendor rejects | vendor_name, affected_items, action_required |
| `order.preparing` | All vendors preparing | eta |
| `order.ready` | All vendors ready | eta |
| `order.picked_up` | Rider collected | rider_name, eta |
| `order.arriving` | Rider within 2 km | eta |
| `order.delivered` | Delivered | total, payment_method, review_prompt |
| `order.cancelled` | Cancelled | reason, refund_amount |
| `voucher.available` | Promotion | code, expires_at |

There is no wallet notification, because there is no customer wallet.

### 4.2 Vendor

| Key | Trigger | Variables |
|---|---|---|
| `vendor.new_order` | Sub-order received | order_number, item_count, total, prep_deadline |
| `vendor.order_cancelled` | Customer cancelled | reason, items |
| `vendor.order_modified` | Price or stock change | item_name, old, new |
| `vendor.payout_paid` | Payout processed | amount, period |

### 4.3 Rider

| Key | Trigger | Variables |
|---|---|---|
| `rider.new_offer` | Nearby order | pickup_area, delivery_area, rider_pay_total |
| `rider.order_assigned` | Claim succeeded | order_number, stops, rider_pay_total |
| `rider.customer_cancelled` | Order dropped | order_number, stops_remaining |
| `rider.payout_paid` | Settlement done | amount, cash_remitted |
| `rider.cash_limit_warning` | `cash_held` at 80% of the effective limit | cash_held, effective_cash_limit |
### 4.4 Rules

- **`rider.new_offer` is a batch, not a blast.** One push listing up to 3 offers, or a local
  notification that is a hint to open the app. Pushing every nearby order individually burns the
  rider's battery and gets the app killed.
- **Never push PII to a lock screen.** Customer address and name go in the payload, not the title
  and body.
- **`order.vendor_rejected` requires an action**, so it is high priority and carries a deep link to
  the resolution screen. This is the notification that decides whether a customer comes back.
- **Every push has an in-app fallback.** If FCM delivery fails, the in-app `notifications` row is
  already there.

---

## 5. Error contract

All RPC errors are raised as Postgres exceptions with a stable `code`, mapped to a typed app error.
Never surface a raw Postgres message to a user.

| Code | Meaning | App behaviour |
|---|---|---|
| `PROFILE_INCOMPLETE` | `profile_completed_at is null` | Route to the completion screen. Never a dead end |
| `PHONE_IN_USE` | Another account already has this number | Inline message on the phone field |
| `PHONE_INVALID` | Not a well-formed E.164 number | Inline message on the phone field |
| `NAME_INVALID` | First or last name empty after trim, or over 80 characters | Inline message on the name field |
| `PHONE_IN_USE_BY_RIDER` | The number is registered to a **rider** profile | **Not** an inline field error — see below |
| `PROFILE_ALREADY_COMPLETE` | `complete_profile_v1` called with different values after completion | Route to settings; `update_profile_v1` is the save path |
| `INVALID_PATCH` | `update_profile_v1` given a forbidden key, or a key that does not exist | Developer error, not a user error |

**`PHONE_IN_USE_BY_RIDER` is deliberately distinct from `PHONE_IN_USE`, and that distinction is the
whole point.** Migration `014b` keeps `riders.phone_number` in step with `users.phone_number`, so a
profile completion can be aborted by a collision with a rider row — possibly one who never signed in
(their `riders.user_id` is `null`, admin-onboarded), possibly a colleague, possibly the user themself
with a stale second number on file. `PHONE_IN_USE`'s documented behaviour is "inline message on the
phone field", which is a **dead end**: the user cannot resolve it by typing a different number, because
retrying is precisely what loops them. A distinct code lets the app route to support instead of to the
field. It is also reachable from `update_profile_v1` for a reason that is easy to miss — `014b`'s trigger
is `after update of first_name, last_name, phone_number, country_code`, so it fires for a **name-only
edit** on a linked rider whose numbers have drifted.
| `TOO_MANY_VENDORS` | Cart exceeds `max_vendors_per_order` | Name the vendors to remove |
| `PRICE_CHANGED` | Quote fingerprint mismatch | Show the diff, require re-confirmation |
| `ITEM_UNAVAILABLE` | Item disabled, deleted or out of stock | Remove it, show what changed |
| `OUT_OF_STOCK` | `stock_count` is zero or below. `null` still means unlimited | Offer a replacement or removal. **Shipped in `017a`**; until then no function raised it and a sold-out item could be bought |
| `VENDOR_CLOSED` | Outside schedule, on holiday, or paused | Block that vendor's items |
| `OUT_OF_RANGE` | Address outside `delivery_radius_km` | Block, suggest an area |
| `BELOW_MINIMUM` | Below `minimum_order_value` | Show the shortfall |
| `INVALID_OPTIONS` | Required option missing or `max_selections` exceeded | Inline field errors |
| `VOUCHER_INVALID` | Unknown code | Inline message |
| `VOUCHER_EXPIRED` | Past `valid_until` | Inline message |
| `VOUCHER_EXHAUSTED` | Total or per-user limit reached | Inline message |
| `VOUCHER_MINIMUM` | Below `min_order_value` | Show the shortfall |
| `CASH_LIMIT_EXCEEDED` | `cash_held + amount_due` would exceed the rider's effective limit | Rider must settle or refuse the order. Offers wallet collection instead |
| `NO_PAY_RULE` | No active `rider_pay_rules` row for this rider or city | **Rider cannot claim.** An admin error, surfaced loudly, never a free delivery |
| `CART_STALE` | Cart changed since quote | Re-quote and re-confirm |
| `INVALID_TRANSITION` | Illegal state change | Refresh and retry |
| `CART_NOT_PLACABLE` | Cart has lines that cannot be priced (retired, out of range, size required, out of stock) | Return to the cart and drop the named vendor. **Reachable only since `017b`** — the raise itself was unreachable, because `\|\|` binds tighter than `->` in the message expression and the error became `22P02` before `private.err` was called |
| `QUOTE_NOT_FOUND` | `quote_id` unknown, or already spent by a completed order | Re-quote |
| `QUOTE_EXPIRED` | Quote older than its 5-minute TTL | Re-quote |
| `CANCEL_WINDOW_CLOSED` | Customer tried to cancel after preparation started | Offer support; only admin may cancel |
| `ORDER_NOT_CANCELLABLE` | Order already delivered or cancelled | — |
| `NOTHING_TO_CANCEL` | No cancellable parts remain | — |
| `PAYMENT_METHOD_INVALID` / `PAYMENT_CHANNEL_REQUIRED` / `PAYMENT_CHANNEL_INVALID` | Method not `cash`/`wallet`, or `wallet` without a channel | See §1.5.1 |
| `IDEMPOTENCY_KEY_REQUIRED` | Empty `p_idempotency_key` | Developer error |
| `IDEMPOTENCY_KEY_TAKEN` | Key already used by another user's order | Developer error |
| `CART_NOT_FOUND` / `ADDRESS_NOT_FOUND` / `CART_EMPTY` / `AUTH_REQUIRED` | Ownership or input precondition failed | — |
| `NO_DELIVERY_ZONE` / `MISSING_FEE_TIER` | Zone or fee tier not configured for this address or vendor count | **Admin error** — refuse rather than guess a fee |
| `TIP_INVALID` / `DELIVERY_TYPE_INVALID` / `GROUPING_INVALID` | Bad enum argument | — |
| `PROFILE_INCOMPLETE` | `profile_completed_at` is null | Route to the completion screen (constitution 18) |
| `ORDER_ALREADY_CLAIMED` | Another rider won | Refresh the list |
| `COLLECTION_ALREADY_DONE` | Order already collected | Show the existing receipt |
| `NOT_AUTHORIZED` | RLS or role check failed | Sign out and re-authenticate |
| `RATE_LIMITED` | Too many calls | Back off; never retry in a tight loop |

`sql
create or replace function public.raise_app_error(p_code text, p_message_ar text, p_detail jsonb default '{}'::jsonb)
returns void language plpgsql as $$
begin
  raise exception '%: %: %', p_code, p_message_ar, p_detail::text using errcode = 'P0001';
end $$;
```

Every message carries Arabic and English. The mobile app shows Arabic by default; the vendor dashboard
defaults to Arabic and switches with the user's device language.
