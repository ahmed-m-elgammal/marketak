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
| `get_profile_status_v1()` | `{ profile_completed_at, has_phone, has_address, can_browse, can_order, missing[] }` | Called at app launch. `missing` drives which fields the completion screen asks for |
| `complete_profile_v1(p_first_name, p_last_name, p_phone)` | the new profile state | The only way to set `profile_completed_at`. Validates E.164 and phone uniqueness |
| `update_profile_v1(p_patch jsonb)` | the new profile | Cannot set `profile_completed_at` |

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

### 1.8 Wallet and money

Wallets exist for **vendors and riders only**. There is no customer wallet and no top-up flow.

| Function | Returns | Notes |
|---|---|---|
| `get_wallet_v1(p_owner_type text, p_owner_id uuid)` | balance, status, recent entries | Vendor or rider. RLS limits the caller to their own |
| `adjust_wallet_v1(p_owner_type, p_owner_id, p_amount, p_reason, p_reference, p_idempotency_key)` | new balance, ledger entry id | Admin only. `p_reason` is mandatory. Writes a signed `adjustment` entry |
| `freeze_wallet_v1(p_owner_type, p_owner_id, p_reason)` | void | Blocks further payouts pending investigation |
| `list_frozen_v1()` | frozen wallets with reasons | Admin |
| `get_platform_float_v1(p_from date, p_to date)` | daily float with `variance` | The only cash exposure |
| `reconcile_day_v1(p_date date)` | expected vs banked vs owed, per account | **Must return zero unexplained variance** |
| `run_vendor_payout_v1(p_vendor_id, p_period)` | `payout_id` | `payable → in_payout` in one transaction |
| `run_rider_payout_v1(p_rider_id, p_period)` | `payout_id` | Includes cash remittance, zeroes `cash_held` |
| `approve_payout_v1(p_payout_id, p_approve, p_method, p_reference)` | new status | |
| `get_commission_v1(p_scope, p_target_id)` | effective rules | Read-only. Returns the **active rider cut** and the **inactive vendor row** |
| `set_commission_rule_v1(p_rule_id, p_value, p_is_active)` | the rule | Admin. Sets `effective_from = now()`, so activation is never retroactive |
| `get_fee_rules_v1(p_zone_id uuid)` | base fee, free radius, per-km, `max_vendors`, all tiers | Read-only, for the admin console and for support |
| `set_fee_tier_v1(p_zone_id, p_vendor_count, p_multiplier_bps)` | the tier | Admin. Basis points, so no float ever enters the fee |

### 1.9 Platform

| Function | Returns | Notes |
|---|---|---|
| `get_flags_v1(p_app_role, p_app_version)` | resolved flags | The Remote Config replacement |
| `get_setting_v1(p_key)` | value | |
| `set_setting_v1(p_key, p_value)` | void | Admin |
| `record_event_v1(p_event, p_properties jsonb)` | void | Analytics → daily rollups, not raw rows |
| `get_admin_metrics_v1(p_date)` | funnel, orders, revenue by line, cancellation, ETA accuracy | |
| `get_eta_accuracy_v1(p_from date, p_to date)` | promised vs actual percentiles | |
| `claim_events_v1(p_limit int)` | event batch | The `pg_cron` drain. `FOR UPDATE SKIP LOCKED` |
| `mark_events_delivered_v1(p_ids uuid[])` | void | One call per batch, never per event |
| `claim_undelivered_events_v1(p_limit int)` | event batch | Retry path |
| `archive_orders_v1(p_before date, p_limit int)` | archived count | Moves items and history to R2 |

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
| `voucher.created` | voucher_id | Batched 15 s | None in v1 |
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
| `TOO_MANY_VENDORS` | Cart exceeds `max_vendors_per_order` | Name the vendors to remove |
| `PRICE_CHANGED` | Quote fingerprint mismatch | Show the diff, require re-confirmation |
| `ITEM_UNAVAILABLE` | Item disabled, deleted or out of stock | Remove it, show what changed |
| `OUT_OF_STOCK` | `stock_count` exhausted | Offer a replacement or removal |
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

Every message carries Arabic and English. The customer app shows Arabic by default; the vendor app
defaults to Arabic and switches with the user's device language.