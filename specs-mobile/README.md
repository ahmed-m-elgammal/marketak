# specs-mobile — the database contract for the mobile app

The mobile app serves **two roles from one binary**: customer and rider, role-switched. Every fact
below applies to both. Nothing here is customer-only unless a section says so.

Read from the **live database** through `pg_proc`, `pg_constraint`, `pg_policies`, `pg_class`,
`pg_indexes` and `information_schema`. Nothing transcribed from a spec file. Where this disagrees
with `specs/001-platform-foundation/`, the database is right.

**Survey** — 2026-10-09, project `erxxsebcqqcpkipzcdhg` (`marketak`, `eu-central-1`, Postgres 17.11).

## The rows are mock. The contract is not.

The database currently holds **mock data**, not production data. That distinction is load-bearing, so
read it before anything else.

**Trust completely — this is schema, and it is real:**

- Table and column names, types, nullability, defaults
- Primary keys, unique constraints, foreign keys, CHECK constraints
- RLS policies — exactly what each role may read
- RPC signatures, return shapes, and error codes
- Indexes, triggers, and what the triggers do
- The `settings` keys and the fee formula

**Never build against — this is mock, and it will change:**

- Specific rows: vendor names, areas, cities, cuisines, menus, users, riders, orders
- Row counts, or "there is only one city"
- A row being present or absent — including `feature_flags` being empty today
- Any `geohash_prefix` value, or any coordinate in the data
- The specific values of `delivery_base_fee`, `per_km_fee`, or the fee tiers — read them, never hardcode

Where this file quotes a concrete row, it is quoted **as an example of the shape**, never as a value to
depend on. A screen that works only when there is exactly one city, one order, or zero flags will pass
against the mock data and fail the day real data lands. If a number appears below, ask whether your
code would still be right if it changed — if not, you are reading the wrong column.

**How to use this file.** You will not be given the migrations or database access. Everything below is
the live contract, transcribed. Treat it as complete and current:

- **§3** tells you what you may read and write. If it is not in §3, you cannot do it directly.
- **§4–5** are the only legal string values. There are no enums, so a typo fails at runtime.
- **§15** is the RPC catalogue — signature, what comes back, what can fail. This is your data layer.
- **§16** is the quote object, field by field. Your checkout screen is a rendering of it.
- **§17** is the table catalogue — the columns you will read, and why you would touch each.
- **§18** is what the platform does to you: cron, settings, storage gaps, realtime gaps.
- **§19** is the index and trigger contract — what your queries will actually hit.
- **§13** lists what does not exist yet. Do not design a screen around a row there.

Sections 1–12 are the rules you must not break. Sections 15–20 are the reference you build from.

---

## 1. The rule everything else follows

**The client is never trusted.**

Every write runs inside a `SECURITY DEFINER` Postgres function, in one transaction, which decides
everything. No client-side price, no client-side eligibility check, no client-side state machine.

| The app may | The app may never |
|---|---|
| Send intent: item id, options, quantity | Send a price |
| Read the price the server returns | Send a price it calculated |
| Branch on an error code | Decide whether an action is allowed |
| Show the server's message | Invent its own business copy |

`upsert_cart_item_v1` takes `(menu_item_id, selected_options, selected_size_id, quantity)`.
There is deliberately no price parameter.

---

## 2. Connection

| | |
|---|---|
| URL | `https://erxxsebcqqcpkipzcdhg.supabase.co` |
| Key | `sb_publishable_…` — RLS-scoped, safe in the app binary |
| Auth | Google + Apple only |

`service_role` bypasses RLS on every table. Worker only, never a phone.

---

## 3. What the app may touch — verified, not assumed

`has_table_privilege('authenticated', …)` was checked directly. This is the authority.

| Table | SELECT | INSERT / UPDATE | How the app writes it |
|---|:--:|---|---|
| `carts`, `cart_items` | ✅ | ❌ | `upsert_cart_item_v1`, `remove_cart_item_v1` |
| `notifications` | ✅ own rows | ❌ | **nothing exists** — see §8 |
| `device_tokens` | ✅ own rows | ❌ | `register_device_token_v1` |
| `addresses` | ✅ own rows | ❌ | `upsert_my_address_v1`, `set_default_address_v1`, `delete_address_v1` |
| `favorites` | ✅ own rows | ❌ | **nothing exists** |
| `reviews` | ✅ non-hidden | ❌ | **nothing exists** |
| **`riders`** | ❌ **even SELECT** | ❌ | **`get_my_rider_profile_v1` only** — see §7 |
| `orders`, `sub_orders`, `delivery_assignments` | ✅ | ❌ | RPCs only |

**Tables you cannot read at all** (`authenticated` has no SELECT): `riders`, `events`, `audit_log`
and its partitions, `notification_templates`, `platform_float`, `auth_daily_stats`,
`event_daily_stats`, `search_daily_stats`. Do not plan a screen around any of them.

Direct table writes stay denied after migration 041. The address RPCs are `SECURITY DEFINER`, so
`authenticated` still holds **no** `INSERT`/`UPDATE`/`DELETE` on `addresses` — verified
`false` on all three after it applied.

**`riders` is the table that looks broken and is not.** A rider cannot `SELECT` their own row —
but `get_my_rider_profile_v1()` (§15) returns the whole profile plus a computed
`effective_cash_limit`. Read it through the RPC and never write to the table. What remains missing
is the *write* side: online toggle, location pings, shifts. See §7 and §13.

`riders_public` is the one readable rider surface, and it is a **view**, not a table:
`id, first_name, last_name, phone_number, vehicle_type, vehicle_plate, rating_avg, rating_count`
where `is_active`. That is what a customer sees on the tracking screen — it deliberately excludes
`user_id`, live coordinates, `cash_held` and `max_cash_held`, so do not try to map a live rider
from it.

`reviews_read` is `NOT is_hidden OR is_admin` — it is **not** scoped to the reader. Every
non-hidden review is world-readable. Do not assume a review row is private to its author.

---

## 4. Status vocabularies

From `CHECK` constraints, which are the authority. Note `orders` and `sub_orders` do **not** share
a status set.

### `orders.status` — 9
```
pending  partially_confirmed  preparing  ready
picked_up  delivering  delivered  partially_cancelled  cancelled
```

### `sub_orders.status` — 9
```
pending  accepted  preparing  ready
picked_up  delivering  delivered  rejected  cancelled
```

### `delivery_assignments.status` — 10
```
unassigned  assigned  at_first_vendor  picking_up  picked_up
delivering  arrived  delivered  failed  cancelled
```

`at_first_vendor`, `picking_up` and `arrived` exist **only** on assignments. There is no `accepted`
on an order — vendor acceptance is a `sub_orders` transition.

### `orders.payment_status` — 4
```
unpaid  collected  failed  refunded
```

### `sub_orders.settlement_status` — 4
```
payable  in_payout  settled  void
```
Plus a second constraint: once `payout_id` is set, only `in_payout` or `settled` is legal.

### `riders.status` — 4
```
offline  available  assigned  on_break
```

### `riders.vehicle_type` — 4
```
car  bicycle  motorcycle  scooter
```

**A trigger enforces the pairing:** `CHECK (is_online = (status <> 'offline'))`. Setting online
and setting `status` are the same act. A UI with two separate toggles will fail on one of them.

---

## 5. There are no Postgres enums

Every status and category is `text` + `CHECK`. A wrong string fails **at runtime, not compile
time**, and there is no type to catch it.

Verified values for `quote_order_v1`, from `private.compute_quote`:

| Parameter | Allowed | Default |
|---|---|---|
| `p_delivery_type` | `'delivery'`, `'pickup'` | `'delivery'` |
| `p_grouping` | `'together'`, `'separate'` | `'together'` |
| `p_rider_tip` | `integer >= 0` | `0` |

Anything else raises `DELIVERY_TYPE_INVALID`, `GROUPING_INVALID` or `TIP_INVALID`.

**`place_order_v1` accepts only `p_payment_method = 'cash'` in v1.** No customer wallet, no
top-up flow. The platform holds no customer money.

Other string arguments validated inside a function body, not by a type:
`register_device_token_v1(p_platform, p_app_role)`, `get_flags_v1(p_app_role)`,
`get_vendor_feed_v1(p_vertical, p_sort)`, `run_payout_v1(p_payout_type, p_action, p_method)`,
`begin_collection_v1(p_channel)`. **Read the raise clauses in `pg_proc` before sending any.**

---

## 6. Checkout

```
upsert_cart_item_v1     build    → cart_item_id, cart_id, unit_price
      ↓
quote_order_v1         price    → quote_id, expires_at (5 min), fingerprint, totals
      ↓
   ... shopper confirms ...
      ↓
place_order_v1         commit   → order_id, order_number, sub_orders
```

**`p_idempotency_key` is required.** A retry must not create a second order. Generate once per
attempt, reuse across retries. A reused key raises `IDEMPOTENCY_KEY_TAKEN`.

`place_order_v1` re-prices inside its transaction and aborts with `PRICE_CHANGED` if anything
moved. The quote is a snapshot with a fingerprint, not a commitment.

`p_payment_channel` is separate from `p_payment_method`, and
`PAYMENT_CHANNEL_MISMATCH` / `PAYMENT_CHANNEL_REQUIRED` exist. They must agree.

### `selected_options`
```json
[{ "choice_id": "<uuid>" }]
```
The quote engine reads `choice_id` and does **not** validate ownership.
`upsert_cart_item_v1` validates it: `OPTION_UNAVAILABLE`, `OPTION_SELECTION_INVALID`.

### Proofs are paths, not URLs
`complete_delivery_v1(p_order_id, p_proof_path, p_lat, p_lng)` and
`collect_cash_v1(p_order_id, p_amount, p_reference, p_proof_path)` take a **path**. A Worker
signs it. You cannot render a proof image directly from the response.

### Address — required before any quote

`quote_order_v1` cannot run without an `addresses` row. Migration 041 added the write path:

```sql
upsert_my_address_v1(p_patch jsonb, p_id uuid default null)  -- returns the full row
list_my_addresses_v1()                                       -- default first, then last_used_at desc
set_default_address_v1(p_id uuid)
delete_address_v1(p_id uuid)                                 -- soft delete
```

`p_patch` is JSON, not a column list, matching `admin_upsert_area_v1`. Allowed keys:

`label` (`home`|`work`|`other`), `area_id`, `latitude`, `longitude`, `building`, `floor`,
`apartment`, `landmark`, `delivery_instructions`. Anything else raises `UNKNOWN_KEY`.

| The app sends | The server decides |
|---|---|
| `area_id`, `latitude`, `longitude` | `geohash` (7 chars) and `geohash_prefix` (4) |
| nothing | `area_name`, copied from `areas.name` |
| nothing | `user_id`, always `auth.uid()` |
| `p_id = null` vs an id | insert vs update |
| nothing | `is_default`, true on the first address |

**The first address a shopper saves is the default automatically.** `addresses_one_default` is
`unique (user_id) where is_default and deleted_at is null`, and a shopper with an address book but
no default has nothing for checkout to pre-select. `set_default_address_v1` demotes the incumbent
in the same statement; `delete_address_v1` promotes a survivor rather than leaving none.

`area_id` must name a **live** area with an **active delivery zone**. A shopper outside the launch
city gets `AREA_UNAVAILABLE` or `NO_DELIVERY_ZONE` at entry time, not a failed checkout.

**The pin is not checked against the area's radius, on purpose.** The area decides which fee table
applies; the pin decides where the rider goes. Rejecting an out-of-radius pin would refuse valid
addresses with no way for the shopper to correct it.

### The map is a picker, and it must resolve an `area_id` itself

**The server will not work out which area a pin is in.** `upsert_my_address_v1` takes `area_id` as
required input and validates only that the area is active and has an active zone. It never compares
the pin to the area's centre or radius. So the app must answer "which area is this pin in?" before it
calls the RPC — that is the one piece of geo logic that lives in the client.

Do it from data you can already read, in this order:

1. **Read `areas`** (`areas_read` = `is_active OR is_admin`). Columns you need: `id`, `name`,
   `name_ar`, `center_lat`, `center_lng`, `radius_km`, `is_active`.
2. **Read `delivery_zones`** (`delivery_zones_read` = `is_active OR is_admin`). Its `area_id` values
   are the areas that can actually accept an address. In the current mock data only 2 of 4 areas
   qualify, and one of those has an inactive zone — **so roughly half the areas in the table will
   reject an address with `NO_DELIVERY_ZONE`**. Do not hardcode which ones. Read both tables at
   runtime, intersect them, and show the shopper only the areas that survive.
3. **Pick the nearest active, zone-covered area** by distance from the pin to `center_lat/lng`.
   `haversine_km(p_lat1, p_lng1, p_lat2, p_lng2)` is a public SQL function and `authenticated` holds
   EXECUTE on it — use it if you would rather not carry the formula. The formula is deterministic, so
   computing client-side is equally correct.
4. **Show the shopper what you resolved, and let them override it.** Because the server does not
   check the radius, a wrong guess produces a silently wrong fee table, not an error. An area chooser
   next to the pin is the honest UI; the pin alone is not enough information.

Never compute or send `geohash` / `geohash_prefix` — `upsert_my_address_v1` derives both from the pin
with `private.geohash_encode`, at precision 7 and 4. And never reverse the flow: `area_id` is an
input, not something you can back out of the pin later.

> **Mock-data warning.** Some `geohash_prefix` values in the current data are not hashes of their own
> coordinates — one area is centred on Cairo but carries a European geohash. This is a seeding
> artifact and may well be gone when real data lands. It is inert either way, because area-to-zone
> matching goes through `area_id`, never the hash. **Do not resolve an area from `geohash_prefix`** —
> use the centre and radius. If anything ever must filter on the prefix, recompute it with
> `private.geohash_encode` first.

Codes: `PATCH_EMPTY`, `UNKNOWN_KEY`, `ADDRESS_REQUIRED`, `ADDRESS_NOT_FOUND`, `ADDRESS_COORDS_REQUIRED`,
`ADDRESS_COORDS_INVALID`, `ADDRESS_LABEL_INVALID`, `AREA_REQUIRED`, `AREA_UNAVAILABLE`, `NO_DELIVERY_ZONE`.

### Cart
One checkout is **one `orders` row plus N `sub_orders` rows**. Never one order with a nullable
`vendor_id`.

`cart_items_line_identity` =
`(cart_id, menu_item_id, md5(selected_options), coalesce(selected_size_id, zero-uuid))`.
Two sizes are distinct lines; identical lines merge. `is_new` distinguishes insert from merge.

A spent cart is deleted 7 days after checkout by `private.prune_spent_carts` (cron 03:17). After
`place_order_v1` the cart has **no remaining reader**.

---

## 7. Rider — what exists and what does not

### Read this first

You cannot `SELECT` from `riders`. **Use `get_my_rider_profile_v1()`.** It is `SECURITY DEFINER`,
takes no arguments, resolves the rider from `auth.uid()`, and returns one row:

```
rider_id uuid · first_name · last_name · phone_number · country_code char(2)
vehicle_type · vehicle_plate · home_area_id · status · is_online · is_active · is_verified
rating_avg numeric · rating_count int · completed_deliveries int · cancelled_deliveries int
cash_held int · effective_cash_limit int
current_latitude numeric · current_longitude numeric · last_location_at timestamptz
created_at timestamptz
```

Errors: `AUTH_REQUIRED`, `NOT_A_RIDER`. A customer-role user calling this gets `NOT_A_RIDER`, not an
empty row — so it doubles as the "is this user a rider?" check at app start.

`effective_cash_limit` is resolved for you. It already folds in `riders.max_cash_held` (nullable,
per-rider override) and the `rider_max_cash_held_default` setting. **Do not re-derive it.** Passing
`0` means cash collection is disabled for that rider.

### The rider write set that works

| RPC | What it does |
|---|---|
| `get_available_orders_v1(p_lat, p_lng, p_radius_km)` | the offer pool near the rider |
| `claim_order_v1(p_assignment_id, p_rider_id)` | take an offer |
| `transition_order_v1(p_order_id, p_sub_order_id, p_to_status, p_reason)` | advance the trip |
| `begin_collection_v1(p_order_id, p_payment_method, p_channel)` | pre-flight before collecting |
| `collect_cash_v1(p_order_id, p_amount, p_reference, p_proof_path)` | record cash taken |
| `collect_wallet_v1(p_order_id, p_channel, p_reference)` | record a wallet/Vodafone/InstaPay payment |
| `complete_delivery_v1(p_order_id, p_proof_path, p_lat, p_lng)` | close the trip, settle the money |

### Does not exist — do not design a screen around these

| Missing | Consequence for the app |
|---|---|
| **self-registration as a rider** | There is no `apply_as_rider_v1`. A rider row is created **only** by `admin_upsert_rider_v1`, admin-gated. A signed-in user with no `riders` row is not a rider — build "become a rider" as a support/request screen, not a form that writes |
| **go online / offline** | `is_online` and `status` have no setter. There is no availability toggle |
| **write a location ping** | `rider_location_pings` has no client write RPC. **Out of scope for v1** — there is no live map. GPS passed *into* `get_available_orders_v1` and `complete_delivery_v1` works fine, see §15 |
| **shifts** | `driver_shifts` is readable by the rider, but has no write RPC |
| **vehicle update** | `vehicle_type` / `vehicle_plate` have no setter |
| **device token for the rider role** | `device_tokens.app_role` accepts `'rider'`, and `register_device_token_v1` accepts it — but no rider-side push template is routed to a rider except `order.claimed`. See §8 |

`admin_upsert_rider_v1(p_patch jsonb, p_id uuid)` accepts `email | user_id | first_name | last_name |
phone_number | country_code | vehicle_type | vehicle_plate | home_area_id | is_verified | is_active |
max_cash_held`. It resolves `email` → `users.id`, writes `riders.user_id` (nullable by design — a rider can
be onboarded **before** their first sign-in), grants the `rider` role in `user_roles`, and is idempotent on
email. **`is_verified` defaults to `false`**, so an admin-created rider exists but cannot claim until an
admin flips it — that is the gate, not a bug. From the phone it raises `NOT_AUTHORIZED`.

`is_online` is a **derived** column: `CHECK (is_online = (status <> 'offline'))`. It is not a second
toggle. Any UI with separate "online" and "status" controls will fail on one of them.

### One governed trip

The rider's trip is one `delivery_assignments` row. `assignment.status` has 10 values, three of which
exist nowhere else in the schema: `at_first_vendor`, `picking_up`, `arrived`. `claim_order_v1` sets
`assigned_by = 'rider_claim'` and stamps `claimed_at`.

`begin_collection_v1` returns `can_collect_cash`, `can_collect_wallet`, `cash_held`,
`effective_cash_limit`, `already_collected`. Call it **before** `collect_cash_v1` — it is the only way
to know whether the rider is about to be blocked, and `CASH_LIMIT_EXCEEDED` fires at collection time,
after the rider is standing at the door.

### Do not build these screens yet

Rider earnings, availability and live-location screens have no write path. The rider profile screen
**does** work — `get_my_rider_profile_v1` covers it. Build the missing RPCs first if you need the
rest; §13 ranks them by what they block.

---

## 8. Notifications — how the app actually receives them

This is the part with the most wrong assumptions. There are **two independent systems**, and they
are not connected.

### 8a. Push — fired by a Worker, never by the database

The database writes an `events` row. A Cloudflare Worker polls, renders, and sends to FCM/APNs.
**The app never reads `events` and never renders a template.**

`private.push_routing()` is the routing table. At survey time:

| Event type | Recipient | Template key |
|---|---|---|
| `order.placed` | customer | `order.placed` |
| `order.placed` | vendor | `vendor.new_order` |
| `order.claimed` | rider | `rider.order_assigned` |
| `order.delivered` | customer | `order.delivered` |
| `order.cancelled` | customer | `order.cancelled` |
| `order.status_changed` → `picked_up` | customer | `order.picked_up` |
| `order.status_changed` → `rejected` | customer | `order.vendor_rejected` |

Note `order.status_changed` routes on `v_payload_to` — the same event produces different templates
per target status. **A new status needs a new routing row or the shopper gets nothing.**

`claim_events_v1(p_limit)` is the Worker's side. It is **not the app's** — see §15. It returns eight
columns: `event_ids bigint[]`, `template_key`, `recipient` (`customer|vendor|rider`), `recipient_id`,
`order_id`, `order_number`, `variables jsonb`, `language`, `oldest_event`. `p_limit` defaults to 50
and is clamped to 1–200. It collapses many event rows into one push per (recipient, template, order)
and locks the rows with `for update … skip locked`, so two Worker instances cannot both send the same
notification. Idempotent by event id — constitution 32.

`variables` is built with `jsonb_strip_nulls`, so an absent key is simply absent — never `null`.
These keys appear when they apply:

| Key | Present when |
|---|---|
| `order_number`, `vendor_count`, `total`, `item_count`, `payment_method`, `currency` | always, except a null `vendor_count` |
| `vendor_name` | the vendor's name, resolved for a vendor recipient or a rejection |
| `reason` | a cancellation or rejection reason, from the event payload or `sub_orders.rejection_reason` |
| `refund_amount` | a cancellation |
| `rider_pay_total` | an assignment |
| `affected_items` | `order.vendor_rejected` only |
| `rider_name` | an assigned rider — trimmed, and absent when blank |
| `stops` | an assigned rider with a route — the length of `stop_sequence` |
| `eta` | an ETA could be computed, from the assignment or the promised time, in the city's timezone as `HH24:MI` |

`currency` is read from the **order row**, never from `settings`, because `cities.currency` is
per-row and an admin can change it. It is `btrim`'d because the column is `bpchar` and SQLite-style
padding turns `'EGP'` into `'EGP '`, which `Intl.NumberFormat` rejects. Render the currency from this
string; do not hardcode `EGP`.

Separately, `notification_templates.variables` (§8b) is the list of placeholders a **template**
declares. The two lists overlap but are not the same thing, and neither one is the `data` column a
`notifications` row would carry.

### 8b. Notification centre — a `notifications` table the app reads directly

`notifications(id, user_id, order_id, sub_order_id, type, title, body, data, read_at, created_at)`.

**`title` and `body` are `jsonb` objects, not strings.** Both are CHECK-constrained to
`jsonb_typeof = 'object'`. A stored notification looks like:

```json
{ "ar": "تم إلغاء طلبك", "en": "Your order was cancelled" }
```

So the app must pick its own language key and fall back. **Never render `notification.title`
directly as a string** — it will print `[object Object]`.

`notification_templates` is keyed by `(key, channel, lang)` and every key exists in **both `ar` and
`en`**. The `title`/`body` objects on a notification are resolved from these, not written fresh.

| Key | Variables |
|---|---|
| `order.placed` | `order_number, vendor_count, total` |
| `order.vendor_accepted` | `vendor_name, eta` |
| `order.vendor_rejected` | `vendor_name, affected_items, action_required` |
| `order.preparing` / `.ready` / `.arriving` | `eta` |
| `order.picked_up` | `rider_name, eta` |
| `order.delivered` | `total, payment_method, review_prompt` |
| `order.cancelled` | `reason, refund_amount` |
| `rider.order_assigned` | `order_number, stops, rider_pay_total` |
| `rider.new_offer` | `pickup_area, delivery_area, rider_pay_total` |
| `rider.customer_cancelled` | `order_number, stops_remaining` |
| `rider.cash_limit_warning` | `cash_held, effective_cash_limit` |
| `rider.payout_paid` | `amount, cash_remitted` |
| `voucher.available` | `code, expires_at` |
| `vendor.new_order` | `order_number, item_count, total, prep_deadline` |
| `vendor.order_modified` | `item_name, old, new` |
| `vendor.order_cancelled` | `reason, items` |
| `vendor.payout_paid` | `amount, period` |

Every template exists in both `ar` and `en`. `device_tokens.language` also exists — **a device
registers its language, so push can be sent in the reader's language rather than the account's.**

### 8c. What is missing

| Missing | Consequence |
|---|---|
| **no INSERT** | nothing creates a `notifications` row. The centre would always be empty |
| **no UPDATE** | `read_at` can never be set. Unread badges are impossible |
| **no realtime publication** | nothing pushes new rows to a listening client |
| `notifications.type` | **no CHECK constraint.** Read the values from `events` before relying on it |

`authenticated` has SELECT on own rows only. That is the entire permission set.

**Building the centre needs three new RPCs:** create-or-append, mark-read, and mark-all-read — plus
a realtime publication on `notifications`. Until then, build only the list, from data you create
by hand.

### 8d. Push registration

```sql
register_device_token_v1(p_token text, p_platform text, p_app_role text, p_app_version text)
```
Writes `device_tokens(id, user_id, token, platform, app_role, app_version, language, last_seen_at)`.
It returns `SETOF device_tokens` — **the whole row, including other tokens the user registered.**
Treat it as server data, not something to echo back.

Call it on launch **and on every sign-in**, because `language` and `app_version` are per-registration
and change. `last_seen_at` drives liveness, so skipping the call makes a live device look dead.

---

## 9. Errors

Every failure is a Postgres exception whose **message starts with a SCREAMING_SNAKE code**:

```
ITEM_RETIRED: الصنف غير متاح
```

The Arabic text after the colon is written for the shopper. **Show it verbatim.**

**The code is at the start of the message, not in PostgREST's `code` field** — that field is always
the generic SQLSTATE `P0001`. Reading `error.code` returns `P0001` for every business failure. This
is the single most common mistake against this database.

| Kind | Codes | The app should |
|---|---|---|
| `unauthenticated` | `NOT_AUTHORIZED`, `AUTH_REQUIRED`, `OWNER_REQUIRED`, `RIDER_REQUIRED`, `ACCOUNT_REQUIRED` | return to sign-in |
| `invalid-input` | `INVALID_QUANTITY`, `INVALID_OPTIONS`, `OPTION_SELECTION_INVALID`, `SIZE_REQUIRED`, `PHONE_INVALID`, `PHONE_IN_USE`, `NAME_INVALID`, `INVALID_PATCH`, `TIP_INVALID`, `DELIVERY_TYPE_INVALID`, `GROUPING_INVALID` | retry with different input |
| `conflict` | `PRICE_CHANGED`, `QUOTE_EXPIRED`, `IDEMPOTENCY_KEY_TAKEN`, `LEDGER_CONFLICT`, `WALLET_CONFLICT`, `INVALID_TRANSITION` | re-read and retry silently |

Also present: `CASH_LIMIT_EXCEEDED`, `RIDER_NOT_VERIFIED`, `NOT_A_RIDER`,
`RIDER_LOCATION_REQUIRED`, `VOUCHER_EXPIRED`, `CANCEL_WINDOW_CLOSED`, `ORDER_NOT_ASSIGNED`,
`SUB_ORDERS_INCOMPLETE`, `CART_ITEM_REQUIRED`, `ITEM_SIZED_BUT_NO_SIZES`, `PHONE_IN_USE_BY_RIDER`,
`PROFILE_ALREADY_COMPLETE`.

**`ITEM_PRICE_CHANGED` and `DELIVERY_FEE_CHANGED` do not exist.** No function body raises either, so a
screen branching on them can never fire. The real conflicts are `PRICE_CHANGED`, `QUOTE_EXPIRED` and
`IDEMPOTENCY_KEY_TAKEN`.

**Two raising styles, one code format.** Most of the schema calls `private.err('CODE', 'message')`. The
profile functions and the trigger asserts instead use a raw
`raise exception 'CODE: %' using errcode = 'P0001'` — `NAME_INVALID`, `PHONE_INVALID`, `PHONE_IN_USE`,
`PHONE_IN_USE_BY_RIDER`, `PROFILE_ALREADY_COMPLETE`, `INVALID_PATCH`, `CART_ITEM_RETIRED`,
`CART_ITEM_UNAVAILABLE`, `ITEM_SIZED_BUT_NO_SIZES`, `HISTORY_UNKNOWN_SUB_ORDER`. The wire format is
identical; only the source differs. A code search that greps for `err(` alone will report these as
missing.

`GROUPING_INVALID` and `TIP_INVALID` surface as `quote_order_v1` failures even though the `public`
wrapper raises only `AUTH_REQUIRED` and `CART_NOT_FOUND`. They are raised inside
`private.compute_quote`, and so are every `VOUCHER_*` rejection. They are real; map them.

### The mapper already exists — do not write a second one

`src/services/errors/app-error.ts` holds `AppError`, `parseServerError` and `BEHAVIOUR_CODES`. It
parses the code out of the message with `/^([A-Z][A-Z0-9_]+):\s*(.*)$/s` and keeps the Arabic text as
`serverMessage`. **Extend it; do not add a second error layer.**

Only codes the app *behaves* differently on belong in `BEHAVIOUR_CODES`. Everything else is `business`
and renders `serverMessage` unchanged.

---

## 10. The profile gate

```
sign in → profile_completed_at IS NULL → can browse, CANNOT order
        → can_order === true           → full access
```

`get_profile_status_v1()` returns `can_browse`, `can_order`, `missing[]`. `missing` names what is
required, so onboarding renders a checklist instead of guessing.

Enforced by `place_order_v1`, not the client. Phone is a profile field, not a credential — no OTP.

`addresses` is writable as of migration 041 — see §6. **Checkout is now unblocked**: an address can
be created, quoted, and placed in one flow, verified end-to-end against the live database.

> `complete_profile_v1(p_first_name, p_last_name, p_phone)` and `get_profile_status_v1()` both
> return `has_address`, but **neither can set it** — they read `addresses` and cannot write it.
> Only `upsert_my_address_v1` creates one. If the onboarding checklist reads `missing` and sees an
> address requirement, the app must call the address RPC; no profile RPC will clear it.

---

## 11. Money

Always `Piastres` from `@marketak/shared`, never a float. Postgres stores `integer`.

Formatting lives in `@marketak/shared`: `formatMoney`, `formatCount`, `formatRateBps`,
`formatWhen`, `formatRelativeInZone`, `multiplierFromBps`. **Do not create `lib/money` in the app.**
Two money formatters is how one screen shows `29.50` and another shows `٢٩٫٥٠`.

`get_wallet_balance_v1` returns `drift` — ledger balance minus wallet balance. A non-zero value is
a reconciliation failure, not a display detail.

---

## 12. RLS — what it means for you

Every table has RLS on, and `authenticated` holds **SELECT only** — no INSERT, UPDATE or DELETE
anywhere. That is the whole design: all writes go through `SECURITY DEFINER` RPCs (§15), so your app
never issues a mutation.

The policies are not all the same shape. Three families exist, and you must know which one guards a
table before you assume what a query returns:

| Family | Example tables | What it means |
|---|---|---|
| **owner-scoped** | `carts`, `cart_items`, `addresses`, `device_tokens`, `favorites`, `favorite_items`, `notifications`, `user_roles`, `user_auth_providers`, `voucher_redemptions` | `(select auth.uid()) = user_id` — you see your own rows |
| **public-if-live** | `cities`, `areas`, `brands`, `cuisines`, `vendors`, `promo_slots`, `vouchers`, `commission_rules`, `settings`, `delivery_fee_tiers`, `vendor_areas`, `vendor_cuisines`, `vendor_schedules`, `vendor_holidays`, `feature_flags` | `is_active OR is_admin` — everyone sees live rows |
| **resolved-relationship** | `orders`, `sub_orders`, `delivery_assignments`, `order_items`, `order_status_history`, `order_modifications`, `order_eta_snapshots`, `rider_location_pings`, `rider_earnings_daily`, `driver_shifts`, `wallets`, `payouts`, `payout_lines`, `ledger_entries` | a `private.*` helper decides — see below |

The `(select …)` wrapper is a per-statement cache, not a per-row call. A bare `auth.uid()` in a
policy is a performance bug, and `scripts/check-policies.mjs` fails on it.

### The `private` resolvers — know these exist

Every relationship-scoped policy calls one of these `SECURITY DEFINER` SQL helpers. They are not
callable from the app; they exist so you understand what a query will return:

| Helper | Returns | Used by |
|---|---|---|
| `private.visible_order_ids(uid)` | orders the user may see as **customer** | `orders`, `delivery_assignments`, `order_eta_snapshots`, `rider_location_pings`, `order_modifications`, `order_status_history` |
| `private.owned_or_assigned_order_ids(uid)` | customer-owned **or** rider-assigned orders | `order_items`, `sub_orders` |
| `private.rider_order_ids(uid)` | orders where the user is the rider | `users_read` (so a customer's name is visible to their rider) |
| `private.rider_ids_for(uid)` | rider ids linked to the user | `driver_shifts`, `rider_earnings_daily` |
| `private.vendor_ids_for(uid)` | vendor ids the user staffs | `vendor_earnings_daily`, `vendor_staff`, and the menu write-escape on `menu_items` / `menu_categories` / `item_options` / `menu_item_sizes` / `option_choices` |
| `private.account_ids_for(uid)` | vendor + rider ids the user owns | `wallets`, `payouts`, `payout_lines`, `ledger_entries` |
| `private.is_admin()` | boolean, no args | every `*_admin_read` policy — the bypass on all of them |

Two consequences you will hit:

1. **`order_items` and `sub_orders` are visible to the vendor too.** A customer reading their order
   items and a vendor reading the same rows are the same query. Do not build a vendor-only view of
   them and expect the customer not to see it.
2. **`users_read` exposes a customer's row to their rider.** A rider can read the name of the person
   whose order they hold. It is the one deliberate cross-role read, because the rider has to call them.

### `reviews_read` is not scoped to the author

`NOT is_hidden OR is_admin`. Every non-hidden review is world-readable. Do not assume a review row
is private to whoever wrote it.

---

## 13. Blockers, ranked

Build order follows the database, not the screen list.

### v1 scope: no real-time map

**The map in this version is a location picker, nothing else.** It exists to drop a pin for an address
(§6) and to hand GPS to the two RPCs that take coordinates as arguments. There is no live rider
tracking screen, no customer ETA map, and no moving marker. So:

| Gap | v1 impact |
|---|---|
| No `rider_location_pings` write | **Not a v1 blocker.** Nothing needs it |
| No way to persist `riders.current_latitude` | **Not a v1 blocker.** `get_available_orders_v1` takes GPS as an argument |
| No realtime publication | **Not a v1 blocker.** Poll instead |

That removes three gaps from the critical path. The customer tracking screen becomes a **status
timeline** built from `order_status_history` — which works today, and needs no location at all. If a
real-time map is ever added, it needs a ping RPC first; until then, do not design for it.

### Remaining gaps, ranked by what they block

| # | Gap | Blocks | Status |
|---|---|---|---|
| ~~1~~ | No address write RPC | checkout | **shipped** — §6 |
| ~~2~~ | No rider read RPC | rider profile | **shipped** — `get_my_rider_profile_v1`, §7 |
| 1 | **No online/offline setter** | every rider availability screen | gap |
| 2 | **No notifications INSERT / UPDATE / realtime** | notification centre, unread badges | gap |
| 3 | **No shift RPC** (`driver_shifts` is real and readable) | rider scheduling | gap |
| 4 | **No vehicle update** | rider vehicle editing | gap |
| 5 | **No review write RPC** | the rate-my-order screen | gap |
| 6 | **No favourites write RPC** | saved vendors / saved items | gap |
| 7 | **No rider self-registration** | a rider who is not already in `riders` can never become one from the app | gap — §7 |
| — | No `rider_location_pings` write | live tracking | **out of scope for v1** |

**The customer flow is complete end-to-end.** Browse → cart → address → quote → place → track →
cancel all work today. The rider flow is **read-and-claim only**: a rider can see the offer pool,
claim it, advance it, collect money and deliver — but cannot go online or manage shifts.

`driver_shifts` also has an EXCLUDE constraint (`gist (rider_id, tstzrange(starts_at, ends_at))`)
preventing overlapping active shifts plus `CHECK (ends_at > starts_at)`. The schema is sound; only
the write path is missing. `admin_upsert_rider_v1` exists but is admin-gated and will reject a
non-admin with `NOT_AUTHORIZED`.

---

## 14. Verify against the live database

> You will not have database access. These are here so a reviewer with `SUPABASE_DB_URL` can
> re-check the claims above via `npm run verify`. Do not write app code that depends on them.

```sql
-- what a role may actually do, the authority for §3
select has_table_privilege('authenticated', 'public.riders', 'SELECT');
select has_table_privilege('authenticated', 'public.notifications', 'UPDATE');

-- exact signatures
select proname, pg_get_function_identity_arguments(oid), pg_get_function_result(oid)
from pg_proc join pg_namespace on pg_namespace.oid = pronamespace
where nspname = 'public' and proname like '%_v1';

-- allowed string values
select conrelid::regclass::text, attname, pg_get_constraintdef(oid)
from pg_constraint join unnest(conkey) k(attnum) on true
     join pg_attribute a on a.attrelid = conrelid and a.attnum = k.attnum
where contype = 'c' and attname in ('status','payment_status','settlement_status','title','body');

-- every error code, both ways they are raised:
--   private.err('CODE', ...)                             — most of the schema
--   raise exception 'CODE: %' using errcode = 'P0001'    — the profile functions, the trigger asserts
-- Both produce the same wire format. Either pattern alone returns a partial list.
select proname, array_agg(distinct m[1]) as codes
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
cross join lateral regexp_matches(pg_get_functiondef(p.oid), $$(?:err\(\s*|raise exception ')([A-Z][A-Z0-9_]+)$$, 'g') as m
where n.nspname in ('public','private') and p.prokind = 'f'
group by proname order by proname;

-- notification templates
select key, lang, variables from public.notification_templates order by key, lang;

-- push routing
select * from private.push_routing();

-- the geohash seed-data bug (§6): rows whose hash is not a hash of their coordinates
select 'areas'     as t, count(*) filter (where geohash_prefix is distinct from private.geohash_encode(center_lat, center_lng, 4)) as bad from public.areas
union all select 'vendors',   count(*) filter (where geohash_prefix is distinct from private.geohash_encode(latitude, longitude, 4)) from public.vendors
union all select 'addresses', count(*) filter (where geohash_prefix is distinct from private.geohash_encode(latitude, longitude, 4)) from public.addresses;

-- the encoder itself
select private.geohash_encode(57.64911, 10.40744, 7) = 'u4pruyd' as matches_published_vector,
       private.geohash_encode(0, 0, 7) = 's000000'              as handles_midpoint;
```

`SUPABASE_DB_URL` in `.env` lets `npm run verify` run these as a gate.

---

## 15. The RPC catalogue

Every function below is `SECURITY DEFINER`, takes named `p_*` parameters, and is callable by
`authenticated` (unless marked). Call them with `supabase.rpc('name', { p_arg: value })`.

`pg_get_function_result()` is the authority on what comes back — it is reproduced here verbatim.
Where a return column is `jsonb`, its shape is spelled out in §16.

**The DTOs already exist.** `src/services/rpc/dto.ts` holds `UpsertCartItemResult`,
`RemoveCartItemResult`, `QuoteResult`, `PlaceOrderResult`, `ProfileStatus`, `SelectedOption`, and the
`PaymentMethod` / `DeliveryType` / `Grouping` / `Language` unions. `src/services/rpc/api.ts` is the
only place `supabase.rpc()` is allowed. **Extend those; never add a second DTO or a direct `rpc()`
call** (AGENTS.md rule 11).

`QuoteResult` types `fee_breakdown`, `per_vendor`, `limits`, `rejections` and `warnings` as `unknown`
on purpose — the server does not promise a shape to a caller that has not validated it. §16 tells you
the real shape so you can decode it once, with Zod, at the boundary. Do not loosen those to `any`.

### Profile and onboarding

```
get_profile_status_v1()                          → (profile_completed_at, has_phone, has_address,
                                                     can_browse, can_order, missing text[])
```
Call this at app start, after every sign-in, and after onboarding. `missing` is an array of strings
naming what is absent, so render a checklist rather than guessing. It lists, in this fixed order:
`phone_number`, `first_name`, `last_name`, `address` — a blank-but-present field counts as missing.
`can_browse` is always `true` for a live session and `can_order` is `profile_completed_at is not null`.
Errors: **`NOT_AUTHORIZED`** — no session, no `public.users` row for the account, or the row is soft
deleted. It does **not** always return a row: a caller whose `users` row was deleted gets an error, not
an empty profile.

```
complete_profile_v1(p_first_name text, p_last_name text, p_phone text)
                                                  → (profile_completed_at, has_phone, has_address,
                                                     can_browse, can_order, missing text[])
```
Sets the profile and stamps `profile_completed_at`, which is the gate `place_order_v1` enforces.
**It cannot create an address** — see §10. The phone must match `^\+[1-9][0-9]{7,14}$` and is trimmed, not
normalised. Errors: `NOT_AUTHORIZED`, `NAME_INVALID`, `PHONE_INVALID`, `PHONE_IN_USE`,
`PHONE_IN_USE_BY_RIDER`, `PROFILE_ALREADY_COMPLETE`.

It is **idempotent**: re-sending the same three values returns the status row without an event. Re-sending
*different* values after completion raises `PROFILE_ALREADY_COMPLETE` — send the user to
`update_profile_v1`, do not retry this one. `PHONE_IN_USE` means another `users` row holds the number
(field-level error, pick another). `PHONE_IN_USE_BY_RIDER` means a `riders` row holds it — possibly a
rider with no account at all — and the user **cannot fix that by trying another number**, so route it to
support, not back to the field.

```
update_profile_v1(p_patch jsonb)                 → same shape as complete_profile_v1
```
Partial update. Allowed keys, exactly six: `first_name`, `last_name`, `phone_number`, `avatar_path`,
`preferred_language`, `country_code`. `profile_completed_at`, `id`, `is_active`, `deleted_at`,
`created_at`, `updated_at`, `last_seen_at` and `email` are named and **rejected**, never silently
dropped. Errors: **`INVALID_PATCH`** (not `UNKNOWN_KEY` — that is the address RPC's code), plus
`NOT_AUTHORIZED`, `NAME_INVALID`, `PHONE_INVALID`, `PHONE_IN_USE`, `PHONE_IN_USE_BY_RIDER`.
`avatar_path` must be a storage path: any URI scheme, `..`, or a backslash is rejected. An empty patch
writes nothing and emits no event.

### Addresses

```
upsert_my_address_v1(p_patch jsonb, p_id uuid)   → addresses   (the full row)
list_my_addresses_v1()                           → SETOF addresses
set_default_address_v1(p_id uuid)                → addresses
delete_address_v1(p_id uuid)                     → boolean
```
`p_id = null` inserts, an id updates. Full rules in §6.

### Cart

```
upsert_cart_item_v1(p_menu_item_id uuid, p_selected_options jsonb,
                    p_selected_size_id uuid, p_quantity integer,
                    p_special_instructions text)
                                                 → (cart_item_id, cart_id, quantity,
                                                    unit_price, is_new boolean)
```
Creates the cart if the user has none. `is_new` distinguishes an insert from a merge into an existing
line. **`unit_price` is server-computed — never send a price.** Errors: `AUTH_REQUIRED`,
`ITEM_REQUIRED`, `ITEM_RETIRED`, `ITEM_UNAVAILABLE`, `SIZE_REQUIRED`, `SIZE_UNAVAILABLE`,
`SIZE_NOT_APPLICABLE`, `OPTION_UNAVAILABLE`, `OPTION_SELECTION_INVALID`, `INVALID_OPTIONS`,
`INVALID_QUANTITY`.

```
remove_cart_item_v1(p_cart_item_id uuid)         → (cart_id uuid, remaining integer)
```
Errors: `AUTH_REQUIRED`, `CART_ITEM_REQUIRED`, `CART_ITEM_NOT_FOUND`. `remaining` is the line count left
in that cart after the delete — `0` means the cart is now empty, which is not the same as no cart.

### Checkout

```
quote_order_v1(p_cart_id uuid, p_address_id uuid, p_voucher_code text,
               p_rider_tip integer, p_delivery_type text, p_grouping text)
                                                 → (quote_id uuid, expires_at timestamptz,
                                                    fingerprint text, fee_breakdown jsonb,
                                                    totals jsonb, per_vendor jsonb,
                                                    limits jsonb, rejections jsonb,
                                                    warnings jsonb)
```
The whole price contract is in §16. `expires_at` is 5 minutes out. Errors: `AUTH_REQUIRED`,
`CART_NOT_FOUND`, `CART_EMPTY`, `ADDRESS_NOT_FOUND`, `NO_DELIVERY_ZONE`, `MISSING_FEE_TIER`,
`TIP_INVALID`, `DELIVERY_TYPE_INVALID`, `GROUPING_INVALID` — the last six all come from
`private.compute_quote`.

```
place_order_v1(p_quote_id uuid, p_payment_method text, p_idempotency_key text,
               p_payment_channel text)
                                                 → (order_id uuid, order_number text,
                                                    sub_orders jsonb, totals jsonb)
```
Re-prices inside the transaction. Errors: `AUTH_REQUIRED`, `PROFILE_INCOMPLETE`,
`QUOTE_NOT_FOUND`, `QUOTE_EXPIRED`, `CART_NOT_PLACABLE`, `PRICE_CHANGED`,
`IDEMPOTENCY_KEY_REQUIRED`, `IDEMPOTENCY_KEY_TAKEN`, `PAYMENT_METHOD_INVALID`,
`PAYMENT_CHANNEL_INVALID`, `PAYMENT_CHANNEL_REQUIRED`.

```
cancel_order_v1(p_order_id uuid, p_sub_order_id uuid, p_reason text)
                                                 → (outcome text, cancelled_count integer,
                                                    refund_amount integer, refund_currency char(3))
```
`p_sub_order_id = null` cancels the whole order; an id cancels one vendor's part. `outcome` tells you
which happened. Errors: `AUTH_REQUIRED`, `ORDER_NOT_FOUND`, `NOT_AUTHORIZED`,
`ORDER_NOT_CANCELLABLE`, `NOTHING_TO_CANCEL`, `CANCEL_WINDOW_CLOSED`.

### Discovery

```
get_vendor_feed_v1(p_area_id uuid, p_vertical text, p_open_only boolean, p_query text,
                   p_offset integer, p_limit integer, p_sort text)      → (payload jsonb)
```
Returns `{ items: [...], next_offset, has_more }`. Each item:
`id, slug, name, name_ar, vertical_type, logo_path, rating_avg, rating_count,
minimum_order_value, prep_time_minutes, availability, menu_version`.

**`availability` is one string, not two booleans.** `'open' | 'paused' | 'closed'` — `paused` means
the vendor set `is_busy` themselves; `closed` means not open. A UI switching on `is_open`/`is_busy`
separately will render one of the three states wrongly.

`p_sort` accepts `rating | name | prep_time | min_order` and **silently falls back to `rating`** for
anything else. `p_limit` is clamped to 1–40 (default 12). `p_offset` is clamped to 0–2000. `p_query`
is normalised (lowercased, unaccented) before matching against `name_normalized` /
`name_ar_normalized`.

```
search_catalog_v1(p_query text, p_area_id uuid default null, p_filters jsonb default '{}',
                  p_limit integer default 20)
                                                 → (kind text, vendor_id, vendor_name, vendor_name_ar,
                                                    item_id, item_category_id, item_name, item_name_ar,
                                                    item_image_path, item_price, score numeric,
                                                    is_open boolean, distance_km numeric,
                                                    rating_avg, rating_count,
                                                    minimum_order_value, prep_time_minutes)
```
`kind` is `'vendor'` or `'item'` — one result set, two shapes, discriminated by `kind`. A vendor hit
has null item fields and vice versa, so check `kind` before reading `item_*`.

`p_limit` is clamped to 1–50, default 20. An empty `p_query` returns a plain vendor list ranked
`is_open desc, rating desc` — it is not a search. `p_filters` accepts `open_now`, `vertical_type`,
`cuisine_ids` and `max_price`. Search runs on `name_normalized`, `name_ar_normalized` and
`description_normalized` / `ingredients_normalized`, trigram-ranked at 3+ characters and substring-ranked
below that. It never errors on a bad filter key — it ignores it.

### Orders and tracking

```
get_flags_v1(p_app_role text default null, p_app_version text default null)
                                                 → (flag_key text, value jsonb)
```
Pass the device's role and semver. Targeting is resolved server-side from
`feature_flags.targeting_rules`, which supports four keys: `roles` (array), `vendor_ids` (array,
resolved through `private.vendor_ids_for` — so a vendor-staffed user gets vendor-targeted flags),
`min_app_version` (a string, or an object of platform → minimum, compared with `semver_gte`), and
`percentage` (deterministic bucketing on `md5(uid)` — the same device always lands in the same
bucket, so a flag does not flicker between calls).

`feature_flags` holds **no rows in the current mock data** — so `get_flags_v1` returns zero rows
today. That is a property of the data, not of the API. Build the call anyway; it is the kill switch
for every rollout, and it must work on the day someone inserts the first flag.

### Rider

`get_my_rider_profile_v1()` is in §7 with its full column list. The rest:

```
get_available_orders_v1(p_lat numeric, p_lng numeric, p_radius_km numeric default null)
     → (assignment_id, order_id, order_number, vendor_count, area_id,
        pickup_km, dropoff_km, est_pickup_minutes, total, currency, placed_at)
```
Errors: `AUTH_REQUIRED`, `NOT_A_RIDER`, `RIDER_NOT_VERIFIED`, `RIDER_LOCATION_REQUIRED`,
`RADIUS_INVALID`.

`p_radius_km` is nullable and defaults to **25 km** when null. `p_lat`/`p_lng` are required in practice:
the rider's stored `current_latitude`/`current_longitude` is only the fallback, and nothing in v1 writes
it back.

The gates fire in this order, and the first two are the real ones:

```
auth.uid() null                                      → AUTH_REQUIRED
no active riders row for that user                   → NOT_A_RIDER
riders.is_verified = false                           → RIDER_NOT_VERIFIED
coalesce(p_lat, riders.current_latitude) is null     → RIDER_LOCATION_REQUIRED
p_radius_km <= 0                                     → RADIUS_INVALID
```

**Location is not the blocker it looks like.** The signature is
`get_available_orders_v1(p_lat, p_lng, p_radius_km)` and the caller's GPS wins:

```sql
v_lat := coalesce(p_lat, v_rider.current_latitude);
v_lng := coalesce(p_lng, v_rider.current_longitude);
```

So the app passes the device's position and it works. `RIDER_LOCATION_REQUIRED` only fires when the
rider passes null **and** has no stored location — i.e. a caller who neither sends GPS nor has ever
had a location recorded. In the mock data every rider row has a location, but **do not count on that**:
a real rider who has never been located hits this, and the app must prompt for permission rather than
show an error.

What has no RPC is **persisting** the location back to `riders.current_latitude`. That matters for the
fallback path and for dispatch, not for opening the offer pool.

### This function writes — it is not a read

Before selecting, it **INSERTs into `delivery_assignments`** to backfill the pool:

```sql
insert into public.delivery_assignments (order_id, status, assigned_by, stop_sequence, distance_km)
select o.id, 'unassigned', 'system', <stop_sequence jsonb>, o.distance_km
  from public.orders o
 where o.status in ('pending','partially_confirmed','preparing','ready')
   and o.delivery_type = 'delivery'
   and o.cancelled_at is null
   and exists (select 1 from public.sub_orders so
                where so.order_id = o.id
                  and so.status in ('pending','accepted','preparing','ready'))
   and not exists (select 1 from public.sub_orders so join public.vendors v on v.id = so.vendor_id
                    where so.order_id = o.id
                      and not (v.is_active and v.is_approved)
                      and so.status not in ('delivered','cancelled','rejected'))
on conflict do nothing;
```

Three consequences:

1. **Every poll writes.** Idempotent via `on conflict do nothing` against the partial unique index
   `delivery_assignments_one_active (order_id) WHERE status <> delivered/failed/cancelled` — but it is
   still an INSERT attempt on every call, so a 5-second poll is 5-second write traffic. Poll at a sane
   interval, not on a timer you forgot to clear.
2. **`assigned_at` is never set by the backfill** — it stays null. Do not use it to sort the pool.
3. **The pool is empty whenever no order is ready.** An order enters the pool only while its status is
   `pending`, `partially_confirmed`, `preparing` or `ready`, it is a delivery, and it has at least one
   live sub-order still open. In the mock data the single order is already `picked_up`, so the pool is
   empty — but that is just the current state of the data, not a defect. **An empty offer list is a
   normal, expected state**, and the app must render it as "no orders near you", never as an error.

The `stop_sequence` it builds — `[{sub_order_id, vendor_id, latitude, longitude, sequence}]` ordered by
`sub_orders.sequence` — is the multi-vendor route. It is written once, here, and is what the rider
screen must render. Do not recompute the route client-side.

Returns `limit 10`, ordered by pickup distance ascending.

```
claim_order_v1(p_assignment_id uuid, p_rider_id uuid)
     → (order_id, assignment_id, rider_id, rider_pay_base, rider_pay_distance,
        rider_pay_bonus, rider_pay_total, platform_revenue, distance_km,
        eta_minutes, has_pay_rule boolean)
```
Errors: `AUTH_REQUIRED`, `RIDER_REQUIRED`, `NOT_AUTHORIZED`, `RIDER_NOT_FOUND`, `RIDER_NOT_ELIGIBLE`,
`ASSIGNMENT_NOT_FOUND`, `ORDER_NOT_FOUND`, `ORDER_ALREADY_CLAIMED`, `ORDER_NOT_CLAIMABLE`.
`p_rider_id` is validated against `private.rider_ids_for(auth.uid())`, so passing any rider id but your
own raises `NOT_AUTHORIZED` — learn your id from `get_my_rider_profile_v1` and send that.
`has_pay_rule = false` means the city has no default `rider_pay_rules` row — the pay figures are then
zero, which is a configuration gap, not a bug in your call. Claiming also writes `riders.status` and
`riders.is_online` together, because the pair is under one CHECK.

```
transition_order_v1(p_order_id uuid, p_sub_order_id uuid, p_to_status text, p_reason text)
     → (sub_order_id uuid, from_status text, to_status text, order_status text)
```
The single rider state machine. `p_sub_order_id = null` transitions the whole order; an id
transitions one vendor's part. `order_status` is the re-derived parent status, so you do not have to
re-read `orders` after a transition. Errors: `AUTH_REQUIRED`, `ORDER_NOT_FOUND`,
`SUB_ORDER_NOT_FOUND`, `NOT_AUTHORIZED`, `INVALID_TRANSITION`.

```
begin_collection_v1(p_order_id uuid, p_payment_method text, p_channel text)
     → (amount_due int, can_collect_cash bool, can_collect_wallet bool, cash_held int,
        effective_cash_limit int, currency char(3), already_collected bool)
```
Call before collecting. Errors: `AUTH_REQUIRED`, `NOT_AUTHORIZED`, `ORDER_NOT_FOUND`,
`ORDER_NOT_ASSIGNED`, `PAYMENT_METHOD_INVALID`, `PAYMENT_CHANNEL_INVALID`,
`PAYMENT_CHANNEL_MISMATCH`.

```
collect_cash_v1(p_order_id uuid, p_amount integer, p_reference text, p_proof_path text)
     → (order_id, collected_amount, cash_held, ledger_entry_id, reference, currency)
collect_wallet_v1(p_order_id uuid, p_channel text, p_reference text)
     → (order_id, collected_amount, cash_held, channel, reference, currency, platform_cash_moved)
complete_delivery_v1(p_order_id uuid, p_proof_path text, p_lat numeric, p_lng numeric)
     → (order_id, delivered_at, rider_pay_total, platform_revenue, tips,
        rider_gross_total, vendor_payable, currency)
```
`collect_cash_v1` errors: `ALREADY_COLLECTED`, `AMOUNT_INVALID`, `AMOUNT_MISMATCH`,
`CASH_LIMIT_EXCEEDED`, `ORDER_NOT_ASSIGNED`, `ORDER_NOT_FOUND`, `NOT_AUTHORIZED`.
`complete_delivery_v1` errors: `ALREADY_DELIVERED`, `SUB_ORDERS_INCOMPLETE`, `ORDER_NOT_ASSIGNED`,
`ORDER_NOT_FOUND`, `NOT_AUTHORIZED`. It settles rider pay, platform revenue and vendor payable in the
same transaction — the returned figures are the ledger, not an estimate.

```
effective_cash_limit_v1(p_rider_id uuid)                  → integer
get_rider_earnings_v1(p_from date default null, p_to date default null)
                                                         → (payload jsonb)
```
`effective_cash_limit_v1` answers only for an admin or the caller's own rider; any other rider id raises
`FORBIDDEN` with SQLSTATE `42501`, not a `P0001` business code. There is no need to call it — 
`get_my_rider_profile_v1` already returns the resolved limit. `get_rider_earnings_v1` defaults both
dates to the server's 30-day window and clamps it, returns a single JSON object rather than a row set,
and carries a `range_clamped` flag when it narrowed what you asked for. Parse it, do not `.map()` it.

### Device tokens

```
register_device_token_v1(p_token text, p_platform text, p_app_role text, p_app_version text)
                                                 → SETOF device_tokens
```
Call on launch **and on every sign-in**. Returns every token the user has registered, not just this
one — treat it as server state. Errors: `AUTH_REQUIRED`, `PROFILE_INCOMPLETE`, `TOKEN_REQUIRED`,
`TOKEN_TOO_LONG`, `PLATFORM_INVALID`, `APP_ROLE_INVALID`, `TOKEN_ALREADY_REGISTERED`.

### Admin — do not call from the app

`admin_upsert_*_v1`, `admin_delete_*_v1`, `admin_restore_*_v1` (~50 functions), plus
`run_payout_v1`, `reconcile_day_v1`, `set_commission_rule_v1`, `set_fee_tier_v1`, `get_admin_metrics_v1`,
`get_platform_float_v1`, `get_vendor_dashboard_v1`, `get_vendor_earnings_v1`, `adjust_wallet_v1`,
`freeze_wallet_v1`, `list_frozen_v1`, `get_wallet_balance_v1`, `get_commission_v1`, `get_fee_rules_v1`.
All are gated by `private.is_admin()` and will raise `NOT_AUTHORIZED` from a phone. The admin console
is `apps/admin-web`, not this app.

`claim_events_v1` and `mark_events_delivered_v1` are **service_role only** — `authenticated` has no
EXECUTE at all. They belong to the outbox Worker.

---

## 16. The quote object, field by field

`quote_order_v1` returns nine columns. Two are scalars you act on; five are JSON objects you render;
two are arrays you branch on. This is the entire shape, from `private.compute_quote`.

### Scalars

| Column | Type | Use |
|---|---|---|
| `quote_id` | uuid | pass to `place_order_v1` as `p_quote_id` |
| `expires_at` | timestamptz | 5 minutes. Start a countdown; on expiry, re-quote |
| `fingerprint` | text | `'md5:…'`. Log it, never display it |

### `totals` — the money block

```
subtotal            int   sum of priceable lines only
discount_amount     int   the voucher discount actually applied
voucher_discount    int   the same number, named for the receipt
voucher_code        text  normalised, or null
delivery_fee        int   base × multiplier + distance charge
service_fee         int   0 unless the service-fee setting is on
rider_tip           int   what the shopper chose
total               int   subtotal + delivery_fee + service_fee + rider_tip − discount_amount
```

`discount_amount` equals `voucher_discount` — there is no other discount source in v1. Render one of
them, not both.

### `fee_breakdown` — the "why is delivery this much" panel

```
delivery_base_fee     int     from the zone row
vendor_count          int     distinct priceable vendors
vendor_multiplier_bps int     from delivery_fee_tiers for that count
distance_km           numeric rounded to 3dp — the FURTHEST vendor, not the average
free_radius_km        numeric from the zone
per_km_fee            int     from the zone
distance_charge       int     max(0, distance_km − free_radius_km) × per_km_fee
delivery_fee          int     round(base × bps / 10000) + distance_charge
service_fee           int
service_fee_enabled   bool
rider_tip             int
currency              char(3)
```

The formula, verbatim: `round(base × multiplier_bps / 10000) + max(0, km − free_radius) × per_km_fee`.
The **furthest** vendor sets the distance. If a shopper asks why delivery is expensive, this block is
the whole answer — do not invent one.

### `per_vendor` — the per-restaurant split

```
vendor_id             uuid
subtotal              int
delivery_fee_share    int   proportional to this vendor's subtotal, for reporting only
service_fee_share     int
discount_share        int
commission_amount     int   0 at launch — vendor commission is off
`vendor_net_payout     int   subtotal − commission_amount, floored at 0
prep_estimate_minutes int
ready_estimate_minutes int  prep − 2, floored at 0
meets_minimum         bool  always true — see the note below
in_delivery_range     bool  always true — see the note below
```

**`meets_minimum` and `in_delivery_range` are hardcoded `true`.** The real checks are `rejections`
below. Do not build a "this vendor is below its minimum" banner off them — it will never fire.

### `limits`

```
vendor_count            int    how many vendors are in the basket
max_vendors_per_order   int    from the zone, falling back to the setting
```

If `vendor_count > max_vendors_per_order`, `rejections` gains a `VENDOR_LIMIT_EXCEEDED` entry and the
quote is not placeable.

### `rejections` — the array you must handle

```
[{ vendor_id: uuid | null, code: text, message_ar: text }]
```

One entry per **vendor**, not per line. `vendor_id` is `null` for order-wide rejections (voucher
problems, the vendor limit). **`message_ar` is Arabic only** — there is no `message_en`. You must
supply the English string from `code` yourself; the server does not.

| `code` | Meaning |
|---|---|
| `ITEM_RETIRED` | the item was deleted |
| `VENDOR_UNAVAILABLE` | vendor inactive or unapproved |
| `ITEM_UNAVAILABLE` | `is_available = false` |
| `OUT_OF_STOCK` | `stock_count` is not null and `<= 0` |
| `SIZE_REQUIRED` | `pricing_mode = 'sized'` and no size chosen |
| `SIZE_UNAVAILABLE` | chosen size is not available |
| `OPTION_UNAVAILABLE` | a `choice_id` did not resolve |
| `OUT_OF_RANGE` | vendor further than the zone's `max_distance_km` |
| `VENDOR_LIMIT_EXCEEDED` | too many vendors in one order |
| `VOUCHER_UNKNOWN` | code not found |
| `VOUCHER_EXPIRED` | inactive, or outside its window |
| `VOUCHER_EXHAUSTED` | `usage_count >= usage_limit_total` |
| `VOUCHER_MINIMUM_NOT_MET` | subtotal below `min_order_value` |
| `VOUCHER_FIRST_ORDER_ONLY` | flagged first-order-only, user has a non-cancelled order |
| `VOUCHER_NOT_APPLICABLE` | `applies_to_vendor_ids` set and disjoint from the basket |

`warnings` is always `[]` today. `ok` is **not** a returned column on `quote_order_v1` — it lives
inside the internal `compute_quote` payload and is not exposed. Derive placeability from
`rejections.length === 0`.

### `lines` — not returned by `quote_order_v1`

`lines` exists inside the internal payload but is not one of the nine returned columns. For line-level
detail, re-read `cart_items` (§17) — you can `SELECT` your own cart. Each `cart_items` row carries
`cached_price` and `display_snapshot` for exactly this purpose, and `display_snapshot` is the render
payload.

### What the fingerprint covers

Every input that changes what the shopper is charged: zone id, base fee, multiplier bps, free radius,
per-km fee, distance, vendor count, subtotal, delivery fee, service fee, tip, discount, voucher code
and its type/value/cap, and every line's key + unit price + size + options. It is order-independent
(sorted), so re-adding the same items in a different order produces the same fingerprint.

`place_order_v1` recomputes it. A mismatch raises `PRICE_CHANGED`. **The quote is a snapshot, not a
commitment** — a price can move between quote and place, and the shopper must see the new total.

---

## 17. Table catalogue

62 tables and partitions in `public`, plus one view. Grouped by what they are for. Money is
**integer piastres** everywhere. Every timestamp is `timestamptz`. `deleted_at` means a soft delete —
**filter it out in every query**, the RLS policy will not do it for you on most tables.

Read-access column below is what `authenticated` gets under RLS, not what exists.

### 17.1 Identity

**`users`** — the account row, 1:1 with `auth.users`.
Read: own row, plus the rows of customers whose orders you hold as a rider.
`id` uuid PK → `auth.users(id)` ON DELETE CASCADE · `phone_number` unique · `email` · `first_name` ·
`last_name` · `avatar_path` · `preferred_language` `'ar'|'en'` default `'ar'` ·
`country_code` char(2) default `'EG'` · `profile_completed_at` (the gate, §10) · `is_active` ·
`last_seen_at` · `created_at` · `updated_at` · `deleted_at`.
Only writable through `complete_profile_v1` / `update_profile_v1`.

**`riders`** — the rider row. **Readable only through `get_my_rider_profile_v1`** (§7).
`user_id` → `users(id)` · `phone_number` unique · `country_code` · `first_name` · `last_name` ·
`vehicle_type` `car|bicycle|motorcycle|scooter` · `vehicle_plate` · `status`
`offline|available|assigned|on_break` default `offline` · `is_online` **derived, see §7** ·
`is_verified` · `is_active` · `current_latitude` / `current_longitude` / `current_geohash` /
`last_location_at` (all four null together or all four set — a CHECK enforces it) · `home_area_id` ·
`rating_avg` numeric(3,2) 0–5 · `rating_count` · `max_cash_held` nullable, 0 disables cash ·
`cash_held` · `completed_deliveries` · `cancelled_deliveries`.

**`riders_public`** (view) — the only readable rider surface:
`id, first_name, last_name, phone_number, vehicle_type, vehicle_plate, rating_avg, rating_count`
where `is_active`. This is what the customer sees on the tracking screen. Phone is exposed because
the customer pays at the door and must be able to call.

**`user_roles`** — `user_id` + `role` `customer|rider|admin|support`, PK on both. `revoked_at` nulls
mean live. This is how you decide which app shell to render. Read: own rows + admin.

**`user_auth_providers`** — `provider_type` `google|apple` + `provider_id`. Read: own rows. Useful for
"how did I sign in" in account settings.

**`device_tokens`** — `token` unique, `platform` `android|ios`, `app_role` `customer|rider|admin`,
`app_version`, `language` `ar|en`, `last_seen_at`. Read: own rows. Writable only via
`register_device_token_v1`. `language` is **per registration**, so it changes when the device
language changes — re-register on language change, not just on sign-in.

### 17.2 Geography and catalogue

**`cities`** — `code` unique, `name`, `name_ar`, `country_code` char(2), `timezone`, `center_lat`,
`center_lng`, `currency` char(3) default `EGP`, `is_active`, `is_primary`. Exactly one primary city
(partial unique index). Read: active + admin.

**`areas`** — the neighbourhood, the unit everything else is scoped to. `city_id`, `slug`,
`name`, `name_ar`, `geohash_prefix` (4 chars), `center_lat`, `center_lng`, `radius_km` default 3,
`is_active`. Unique on `(city_id, slug)`. Read: active + admin.

**`delivery_zones`** — **the fee table**. One row per area. `city_id`, `area_id`, `name`, `name_ar`,
`currency`, `delivery_base_fee` int default 2500, `free_radius_km` default 5, `per_km_fee` int
default 200, `max_vendors_per_order` smallint 1–10 default 3, `min_order_value`,
`max_distance_km` default 12, `peak_hours` `int4range`, `is_active`. **These are configuration, not
constants.** Never hardcode a fee in the app — read it or let `quote_order_v1` do it. Read: active +
admin.

**`delivery_fee_tiers`** — PK `(zone_id, vendor_count)`, `multiplier_bps` 0–100000. One row per
vendor count per zone. `quote_order_v1` raises `MISSING_FEE_TIER` if the count is absent — so a zone
with no tier for 3 vendors cannot serve a 3-vendor basket. Read: all rows (`true` policy).

**`brands`** — chains. `name`, `name_ar`, `logo_path`, `is_active`. A vendor may belong to one.

**`cuisines`** — `code` unique, `name`, `name_ar`, `sort_order`, plus generated `name_normalized` /
`name_ar_normalized` (lowercased, unaccented) which the trigram indexes live on. Read: all.

**`vendors`** — the restaurant. Read: active + approved + not deleted, or admin.
`slug` unique-where-live · `name`, `name_ar` · `legal_name` · `brand_id` · `vertical_type`
`food|grocery|pharmacy|flowers|bakery|others` · `city_id`, `area_id` · `latitude`, `longitude`,
`geohash_prefix` · `delivery_radius_km` default 8 · `is_open`, `is_busy`, `auto_open` · `is_approved`,
`is_active` · `capacity_per_slot` · `reject_rate` · `delivery_fee_override` · `minimum_order_value` ·
`prep_time_minutes` default 15 · `prep_time_max_minutes` default 30 · `rating_avg`, `rating_count` ·
`menu_version` (bumped by triggers on every menu write — cache-buster) · `logo_path` · `description`,
`description_ar` · `contact_phone`, `contact_landline`.

`menu_version` is the field to poll or cache on. Any menu mutation increments it via a trigger, so a
client that stores the menu with its version can tell whether it is stale without re-fetching.

**`vendor_areas`** — PK `(vendor_id, area_id)`. `delivery_fee_override`, `eta_minutes` default 20,
`eta_maxutes` default 40, `is_active`. **A vendor serving several areas has several rows** — use
`EXISTS`, not a join, or the vendor row multiplies.

**`vendor_cuisines`** — PK `(vendor_id, cuisine_id)`. Filter chips.

**`vendor_schedules`** — unique on `(vendor_id, day_of_week, slot)` (the PK is a surrogate `id`).
`day_of_week` 0–6, `slot` default 0, `opens_at`/`closes_at` time, `is_closed`. Two slots per day (lunch
and dinner) is the intent. Check `closes_at > opens_at` is enforced — no overnight windows.

**`vendor_holidays`** — unique `(vendor_id, holiday_date)`. Read: all.

**`vendor_staff`** — `user_id`, `vendor_id`, `staff_role` `owner|manager|staff|cashier`,
`can_edit_menu`, `can_manage_orders`. Not used by the customer or rider app.

**`menu_categories`** — `vendor_id`, `name`, `name_ar`, `description`, `display_order`,
`is_available`. Read: live rows where the vendor is live.

**`menu_items`** — `category_id`, `vendor_id`, `name`, `name_ar`, `description`, `description_ar`,
`pricing_mode` `fixed|sized`, `base_price` (required when fixed), `is_available`, `stock_count` null =
unlimited, `preparation_time_minutes`, `image_path`, `display_order`, `nutritional_info` jsonb,
`allergens` jsonb, `ingredients` jsonb, `tags` text[], `calories`, `is_spicy`, `is_vegetarian`,
`is_featured`, `is_new`, plus generated `*_normalized` columns for search.

`pricing_mode = 'sized'` means **the price comes from `menu_item_sizes`, not `base_price`**. A size
is mandatory — `assert_item_has_sizes` blocks a sized item with no sizes.

**`menu_item_sizes`** — `item_id`, `name`, `name_ar`, `price`, `is_default`, `is_available`,
`calories`, `display_order`. Only one default per item (partial unique index). Deleting the last size
is blocked (`trg_item_still_sized`).

**`item_options`** — `item_id`, `name`, `name_ar`, `is_required`, `min_selections`, `max_selections`
default 1, `display_order`, `is_available`. `max_selections >= min_selections` is enforced, and a
required option must be satisfiable.

**`option_choices`** — `option_id`, `name`, `name_ar`, `price_modifier` int (can be **negative**,
floor −100000), `is_default`, `is_available`, `stock_count`, `calories`, `display_order`. A negative
modifier is a discount, not an error.

### 17.3 Cart and addresses

**`carts`** — one active cart per user (partial unique index `carts_one_active`).
`user_id`, `is_active`, `last_seen_at`, plus the **quote cache**: `quote_id`, `quote_fingerprint`,
`quote_expires_at`, `quote_address_id`, `quote_voucher_code`, `quote_rider_tip`,
`quote_delivery_type`, `quote_grouping`, `quote_snapshot` jsonb.

The `quote_*` columns are the server's memo of the last quote for this cart. You may read them to
restore a checkout screen after the app is killed; you may never write them. Re-quote if
`quote_expires_at` has passed.

**`cart_items`** — `cart_id`, `vendor_id` (auto-synced from the item by a trigger), `menu_item_id`,
`quantity` 1–99, `selected_options` jsonb array, `special_instructions`, `display_snapshot` jsonb,
`cached_price` int, `cached_at`, `selected_size_id`, `selected_size_name`, `selected_size_price`.

`display_snapshot` is the render payload — name, image, price as they were when added. Render from
it, not from a join to `menu_items`, because the menu can change under an open cart.
`cart_items_line_identity` = unique on
`(cart_id, menu_item_id, md5(selected_options), coalesce(selected_size_id, '000…0'))` — identical
lines merge, different sizes stay separate.

**`addresses`** — see §6. `user_id`, `label` `home|work|other`, `area_id`, `geohash` (7 chars),
`geohash_prefix` (4), `latitude`, `longitude`, `area_name`, `building`, `floor`, `apartment`,
`landmark`, `delivery_instructions`, `is_default`, `last_used_at`. Exactly one default per user
(partial unique index). Only writable through the address RPCs.

### 17.4 Orders

**`orders`** — one checkout = one order row + N `sub_orders`. Read: own + rider-visible + admin.
`currency` char(3) `EGP` is on the row — render it, do not read `settings.currency`.
Money (all int): `subtotal`, `delivery_base_fee`, `delivery_multiplier_bps` default 10000,
`distance_km`, `delivery_fee`, `service_fee`, `discount_amount`, `voucher_code`,
`voucher_discount`, `rider_tip`, `rider_pay_total`, `platform_revenue`, `total`.
Identity/state: `order_number` unique, `user_id`, `status`, `pricing_version`, `price_fingerprint`,
`payment_method` `cash|wallet`, `payment_channel` `cod|vodafone_cash|instapay|gateway`,
`payment_status` `unpaid|collected|failed|refunded`, `payment_collected_at/by/reference/proof_path`.
Delivery: `delivery_type` `delivery|pickup`, `delivery_grouping` `together|separate`,
`vendor_limit_applied`, `address_id`, `address_snapshot` jsonb, `delivery_latitude/longitude`,
`delivery_geohash_prefix`, `area_id`, `is_contactless`, `access_note`,
`scheduled_delivery_time`, `promised_delivery_at`, `eta_minutes`, `eta_maxutes`.
Counts and stamps: `vendor_count`, `item_count`, `placed_at`, `confirmed_at`, `first_picked_up_at`,
`completed_at`, `cancelled_at`, `cancellation_reason`, `cancellation_actor_id`, `idempotency_key`
unique-when-set.

**`address_snapshot` is the receipt.** It is written at placement and never updated, so an edited
address never rewrites history. Render the delivery address on an order from the snapshot, not from
`addresses` — the shopper may have deleted that address since.

`total` is enforced: `greatest(0, subtotal + delivery_fee + service_fee + rider_tip − discount_amount)`,
and `voucher_discount <= discount_amount`. If your client arithmetic disagrees with `orders.total`,
your client is wrong.

**`sub_orders`** — one per vendor per order. `order_id`, `vendor_id`, `sequence`, `status`,
`subtotal`, `delivery_fee_share`, `service_fee_share`, `discount_share`, `commission_amount`,
`platform_fee_amount`, `vendor_net_payout`, `menu_version_snapshot`, `prep_estimate_minutes`
default 20, `prep_actual_minutes`, `ready_at`, `accepted_at`, `preparing_at`, `picked_up_at`,
`delivered_at`, `cancelled_at`, `cancellation_reason`, `cancellation_actor`
`customer|vendor|admin|system`, `rejection_reason`, `settlement_status`
`payable|in_payout|settled|void`, `payout_id`. Unique on `(order_id, vendor_id)` and on
`(order_id, sequence)`.

**`orders.status` is derived from `sub_orders.status` by a trigger.** Never write it. One
`sub_orders` INSERT or UPDATE re-computes the parent, which is how `partially_confirmed` and
`partially_cancelled` exist at all.

**`order_items`** — `sub_order_id`, `order_id`, `vendor_id` (all three synced by a trigger),
`menu_item_id` nullable ON DELETE SET NULL, `item_name`, `item_name_ar`, `image_path`, `quantity`,
`unit_price`, `total_price` (= quantity × unit_price, enforced), `selected_options` jsonb,
`special_instructions`, `item_status`
`confirmed|out_of_stock|price_updated|limited_stock|replacement`, `selected_size_id/name/price`.

Name and image are **denormalised on purpose**. If the vendor renames an item tomorrow, this order
keeps the name it was placed with. Render order history from these columns, never from `menu_items`.

**`order_status_history`** — `order_id`, `sub_order_id`, `from_status`, `to_status`, `actor_user_id`,
`actor_role` `customer|rider|vendor|admin|system`, `reason`, `metadata` jsonb, `created_at`.
`from_status <> to_status` when set. This is the audit trail behind the customer's order timeline —
query it, do not synthesise a timeline from `orders.status`.

**`order_modifications`** — `modification_type` `item_removed|item_added|price_updated|stock_limited`,
`original_total`, `new_total`, `difference_amount` (= new − original, enforced), `reason`,
`customer_approved`, `actor_user_id`. This is the "your order changed" screen.

**`order_eta_snapshots`** — `order_id`, `sub_order_id`, `promised_at`, `predicted_at`,
`computed_at`. An append-only history of ETA promises. Query the latest by `computed_at` if you need
to show "we said 30 minutes, here is where it moved to".

### 17.5 Delivery

**`delivery_assignments`** — the rider's trip. `order_id`, `sub_order_id` nullable, `rider_id`
nullable, `status` (10 values, §4), `stop_sequence` jsonb, `assigned_by`
`system|rider_claim|admin`, `assigned_at`, `claimed_at`, `arrived_vendor_at`, `picked_up_at`,
`arrived_at`, `delivered_at`, `distance_km`, `eta_minutes`, `rider_pay_base/distance/bonus/total`,
`platform_revenue`, `collected_amount`, `collection_method` `cash|wallet|none`,
`collection_channel` `cod|vodafone_cash|instapay`, `collection_reference`, `proof_path`,
`signature_path`, `failure_reason`.

`rider_pay_total = rider_pay_base + rider_pay_distance + rider_pay_bonus` is a CHECK. Only one
active assignment per order (partial unique index). `stop_sequence` is the multi-vendor route order —
render it, do not guess it.

**`rider_location_pings`** — `order_id`, `rider_id`, `latitude`, `longitude`, `heading` 0–360,
`speed_kmh`, `accuracy_m`, `recorded_at` (never more than 5 minutes in the future — a CHECK enforces
it). Read: own orders + admin. **No client write RPC**, and it is out of scope for v1 (§13), so
nothing fills it. It is the table a future live map would need; ignore it for now.

**`driver_shifts`** — `rider_id`, `starts_at`, `ends_at`, `area_ids` uuid[], `is_active`.
`ends_at > starts_at` enforced; a GiST EXCLUDE index blocks overlapping active shifts for one rider.
Readable by the rider, not writable.

### 17.6 Money and settlement — mostly out of app scope

Read these to render; never write them. There is no customer wallet and no top-up flow — the customer
pays the rider at the door.

**`wallets`** — vendor and rider only (`owner_type` `vendor|rider`). `owner_id`, `balance`,
`currency`, `status` `active|frozen|review`, `status_reason`, `version` (optimistic concurrency).
Unique on `(owner_type, owner_id)`.

**`ledger_entries`** — append-only double-entry. `account_type` `vendor|rider|platform|platform_earnings`,
`account_id`, `entry_type` `rider_cut|cash_collected|cash_remitted|delivery_fee|service_fee|
commission|refund|reversal|vendor_payout|rider_payout|adjustment|float_sweep`, `signed_amount`
(non-zero), `idempotency_key` NOT NULL and unique, `order_id`, `sub_order_id`, `payout_id`, `note`,
`metadata`, `currency`.
`account_id` is required for vendor/rider and forbidden for platform types (a CHECK constraint,
`ledger_entries_account_required`).

**`rider_earnings_daily`** — PK `(rider_id, business_date)`. `deliveries`, `legs`, `online_minutes`,
`base_fees`, `distance_fees`, `tips`, `bonuses`, `deductions`, `net_payout`, `cash_held`,
`cash_remitted`. Readable by the rider — this is the earnings screen, and it is a **row per day**, so
group client-side for a range.

**`vendor_earnings_daily`** — same shape for vendors. Not used by this app.

**`payouts` / `payout_lines`** — admin settlement. `payouts(payout_type vendor|rider, account_id,
period_start, period_end, gross, fee, net, currency, method, status draft|approved|processing|paid|failed|
cancelled, reference, approved_by/at, paid_at, failure_reason, idempotency_key not null)`.
`payout_lines(payout_line_type vendor_earning|rider_trip|tip|bonus|adjustment, source
cash_collected|wallet_payment|adjustment, sub_order_id, assignment_id, gross, fee, net)` with a shape
CHECK tying line type to which id is set.

**`commission_rules`** — `scope` `vendor|rider|platform`, `target_id`, `vertical_type`,
`commission_type` `percentage|fixed_amount|free_delivery|negative`, `value` int, `min_amount`,
`max_amount`, `applies_to` `subtotal|delivery_fee|service_fee|payout_total`, `effective_from`,
`effective_until`, `is_active`. Readable, but `vendor_commission_enabled` is `false` at launch, so
vendor commission is 0 regardless of what these rows say.

**`rider_pay_rules`** — `city_id`, `rider_id` nullable (null = the city default),
`per_trip_amount`, `per_km_amount`, `pct_of_delivery_fee_bps` 0–10000, `bonus_per_leg`,
`effective_from/until`, `is_active`. One active default per city (partial unique index).

**`platform_float`** — admin cash reconciliation. Not readable by `authenticated`.

### 17.7 Growth and engagement

**`vouchers`** — `code` unique (also unique on `upper(code)`), `name`, `discount_type`
`percentage|fixed_amount|free_delivery`, `discount_value` (>0, and ≤10000 for percentage),
`min_order_value`, `max_discount_cap`, `usage_limit_total`, `usage_limit_per_user`, `usage_count`,
`applies_to_vendor_ids` uuid[] (GIN-indexed), `vertical_type`, `first_order_only`, `valid_from`,
`valid_until`, `is_active`. Read: active and in-window. Enforced: `usage_count <= usage_limit_total`.

**`voucher_redemptions`** — `voucher_id`, `user_id`, `order_id`, `sub_order_id`, `discount_amount`
(>0). Read: own rows. This is the "my vouchers" history.

**`promo_slots`** — `city_id`, `slot_key`, `title` jsonb, `subtitle` jsonb, `image_path`,
`target_type` `vendor|vertical|area|url`, `target_id` text, `starts_at`, `ends_at`, `sort_order`,
`is_active`. Unique on `(city_id, slot_key)`. `title`/`subtitle` are **jsonb language objects**, same
rule as `notifications` (§8b).

**`feature_flags`** — `flag_key` unique, `value_type` `bool|string|number|json`, `value` jsonb,
`targeting_rules` jsonb, `description`, `is_active`. Read them via `get_flags_v1`, not directly — the
RPC applies role, vendor, version and percentage targeting that a raw `select` does not.

**`settings`** — PK `key`, `value` jsonb, `description`, `updated_at`, `updated_by`, `deleted_at`.
13 rows, all readable. These are the money constants (§18).

**`reviews`** — `order_id`, `sub_order_id`, `user_id`, `vendor_id`, `rider_id`, `vendor_rating`
1–5, `rider_rating` 1–5 (requires a rider), `comment`, `is_hidden`. Unique on `(order_id, vendor_id)`
— one review per vendor per order. **No write RPC** (§13).

**`favorites`** — PK `(user_id, vendor_id)`. **`favorite_items`** — PK `(user_id, menu_item_id)`.
Both readable by the owner, neither writable.

### 17.8 Platform internals — read nothing here

`events` (the outbox, service_role only), `notifications` and its monthly partitions (`read` only —
see §8), `audit_log` and its partitions (service_role only), `notification_templates` (service_role
only), `auth_daily_stats`, `event_daily_stats`, `search_daily_stats` (all service_role only). They
exist so a reviewer knows they are not accidentally reachable. Do not build on them.

---

## 18. Platform facts the app depends on

### Settings — the money constants

These are rows in `public.settings`, readable by `authenticated`. **They are configuration. None of
them may appear as a literal in app code.** The `value` column shows the current value, which will
change; read the row at boot and again when you need it, never capture it into a constant.

| key | value | meaning |
|---|---|---|
| `currency` | `EGP` | 1 EGP = 100 piastres; every money column is integer piastres |
| `default_country_code` | `EG` | |
| `max_vendors_per_order` | `3` | global ceiling; a zone may be lower, never higher |
| `order_number_prefix` | `MK` | order numbers read `MK-261004-7F3K9` |
| `platform_name` / `platform_name_ar` | `Marketak` / `ماركتك` | Arabic is the default everywhere |
| `service_fee_enabled` | `false` | inactive at launch |
| `service_fee_type` | `fixed` | or `percentage` |
| `service_fee_default` | `0` | amount or bps per the type |
| `vendor_commission_enabled` | `false` | flipped in month 3–4 |
| `rider_commission_enabled` | `true` | the launch revenue line: a cut of the delivery fee |
| `rider_max_cash_held_default` | `250000` | 2,500 EGP; per-rider row overrides; 0 disables cash |
| `rider_cash_limit_warning_pct` | `80` | warn at 80% of the limit |

### Images and proof paths — there is no storage yet

`logo_path`, `image_path`, `avatar_path`, `proof_path`, `signature_path`, `promo_slots.image_path`
are all **paths, not URLs**. And:

- `storage.buckets` is **empty** (0 rows).
- No file-access Worker exists in `functions/` — only `outbox-dispatcher`.

So today **no image is renderable**. Treat every path as opaque until a signing Worker exists. Do not
`supabase.storage.from(...)` against a bucket you invented, and do not concatenate a base URL onto a
path. When the Worker lands, it will hand you a signed URL; until then, render a placeholder.

### Realtime

The `supabase_realtime` publication exists but has **zero tables**. Nothing pushes to a listening
client. The customer tracking screen must **poll**, and the notification centre does not exist (§8c).

### Row counts at survey time — mock, ignore them

`cities` 2 · `areas` 4 · `vendors` 6 · `menu_items` 12 · `users` 14 · `riders` 4 · `orders` 1 ·
`sub_orders` 2 · `order_items` 2 · `carts` 1 · `cart_items` 2 · `delivery_zones` 3 · `events` 35 ·
`vouchers` 3 · `delivery_assignments` 1 · `cuisines` 0 · `feature_flags` 0 · `notifications` 0 ·
`notification_templates` 38 · `addresses` 5 · `rider_pay_rules` 1 · `reviews`, `favorites`,
`favorite_items`, `promo_slots`, `device_tokens`, `driver_shifts`, `wallets`, `brands` all 0.

**These are not constraints.** They tell you the shape was exercised, nothing more. The trap they set:
a screen that only works with one city, one order, or zero flags passes against this data and breaks
the day real data arrives. Test with several cities, several vendors per order, and an empty basket.

### The geohash seed artifact

Some `geohash_prefix` values in the current data are not hashes of their own coordinates. See the
warning in §6. It is inert, because area-to-zone matching goes through `area_id`, never the hash.

---

## 19. Indexes and triggers you must know

### Triggers

**72** triggers in `public` (non-internal; Postgres's own `RI_FKey_*` and constraint triggers are
excluded). **41** of them are `set_updated_at()`, which only maintains `updated_at` — ignore those. The
31 that change what your app should do:

**Columns the server fills for you** (BEFORE INSERT/UPDATE — never send them):

| Table | Trigger | What it sets |
|---|---|---|
| `cart_items` | `sync_cart_item_vendor` | `vendor_id`, from `menu_item_id` |
| `menu_items` | `sync_menu_item_vendor` | `vendor_id`, from `category_id` |
| `order_items` | `sync_order_item_parent` | `order_id`, `vendor_id`, `sub_order_id` |

**`vendors.menu_version` is bumped automatically.** Any write to `menu_items`, `menu_categories`,
`item_options`, `menu_item_sizes` or `option_choices` increments the parent vendor's version. Cache a
menu against `menu_version` and you never re-fetch a menu that has not changed.

**Aggregates are maintained by triggers, not by your reads:**

- `order_items` → `sync_order_item_aggregates_ins/upd/del` recompute order and sub-order totals.
- `sub_orders` → `sync_order_status` **derives `orders.status`**. One sub-order change re-computes the
  parent. This is where `partially_confirmed` and `partially_cancelled` come from.
- `cart_items` → `touch_cart_from_new_rows` bumps `carts.last_seen_at`.

**Guards that raise instead of letting bad data in:** `assert_cart_item_orderable`,
`assert_item_has_sizes`, `assert_item_still_sized`, `assert_fee_tiers_monotonic`,
`assert_history_scope`, plus `private.assert_commission_target`, `private.assert_ledger_account`,
`private.assert_payout_account`, `private.assert_wallet_owner`. They surface as business error codes,
not Postgres errors.

**Auth:** `on_auth_user_created` on `auth.users` AFTER INSERT calls `public.handle_new_user()`, which
mirrors the new identity into `public.users`. So a Google or Apple sign-in produces a `public.users`
row with `profile_completed_at = null` — the §10 gate starts closed, by design.

**Partitions are created by a monthly cron** (`ensure-partitions-monthly`, `cron.job` 5) and it
creates the table, enables RLS and adds one policy — **but no secondary indexes**. A brand-new month
partition of `notifications` will do sequential scans until indexes are added. Relevant because §8c
already flags that the notification centre is not usable; if you build it, this is the next problem.

### Indexes — the ones that back your queries

**252** index entries in `pg_indexes` for `public`: 243 leaf indexes (`btree`, `gin`, `gist`) plus 9
partitioned-index parents on `notifications` and `audit_log`. These are the ones your queries will use;
if your filter does not match the predicate, the index is not used.

**Partial indexes are the rule here, and the predicate is part of the contract.** Every index below
marked `WHERE` only serves queries that include the same condition.

| You are doing | Index | Predicate you must include |
|---|---|---|
| Vendor list for an area | `vendors_area_id_vertical_type_idx (area_id, vertical_type)` | `is_active AND is_approved` |
| Vendor list by city, open only | `vendors_city_id_is_open_deleted_at_idx (city_id, is_open, deleted_at)` | — |
| Top-rated vendors | `vendors_rating_avg_idx (rating_avg DESC)` | `is_active AND is_approved` |
| Name search (vendor, item, category, cuisine) | `*_name_trgm`, `*_name_ar_trgm`, `vendors_description_trgm`, `menu_items_ingredients_trgm` — all **GIN trigram** | `is_active AND is_approved AND deleted_at IS NULL` |
| Tag filter on menu items | `menu_items_tags_idx` — **GIN on `tags` array** | `deleted_at IS NULL` |
| Full menu for a vendor | `menu_items_vendor_id_is_available_display_order_idx`, `menu_categories_vendor_id_display_order_idx`, `menu_item_sizes_item_id_display_order_idx`, `item_options_item_id_display_order_idx`, `option_choices_option_id_display_order_idx` | `deleted_at IS NULL` |
| My cart lines | `cart_items_line_identity` (unique), `cart_items_cart_vendor (cart_id, vendor_id)` | — |
| My active cart | `carts_one_active (user_id)` | `is_active` |
| Rider offer pool | `delivery_assignments_offer_pool (assigned_at)` | `rider_id IS NULL AND status = 'unassigned'` |
| Rider's open trips | `delivery_assignments_open (rider_id, status)` | `status IN (assigned, at_first_vendor, picking_up, picked_up, delivering, arrived)` |
| Rider history | `delivery_assignments_rider_history (rider_id, assigned_at DESC)` | — |
| Riders available in an area | `riders_active_verified (home_area_id, status)` | `is_active AND is_verified` |
| Vendor's incoming orders | `sub_orders_vendor_open (vendor_id, status)` | `status IN (pending, accepted, preparing, ready)` |
| Vendor's new orders by time | `sub_orders_status_created (status, created_at)` | `status IN (pending, accepted)` |
| My order history | `orders_user_placed (user_id, placed_at DESC)` | — |
| Orders by status | `orders_status_placed (status, placed_at DESC)` | — |
| Order lines | `order_items_sub_order_id`, `order_items_order_id` | — |
| Order timeline | `order_status_history_order (order_id, created_at)`, `order_status_history_sub_order` | — |
| My notification list | `notifications_user_created (user_id, created_at DESC)` | see the partition note below |
| My addresses | `addresses_user_id_last_used_at_idx (user_id, last_used_at DESC)` | `deleted_at IS NULL` |
| Active vouchers | `vouchers_active_window (is_active, valid_from, valid_until)` | — |
| Voucher applies to my vendors | `vouchers_applies_to_vendor_ids` — **GIN on the uuid array** | — |
| Vendor reviews | `reviews_vendor_created (vendor_id, created_at DESC)` | `NOT is_hidden` |
| Promo shelf | `promo_slots_active_sort (city_id, sort_order)` | `is_active` |
| Rider pings for an order | `rider_location_pings_order (order_id, recorded_at DESC)` | — |

Three traps:

1. **Trigram indexes need 3+ characters.** A 1–2 character query falls back to a sequential scan.
   Debounce search input and do not fire on every keystroke.
2. **The `ONLY` indexes on `notifications` and `audit_log` are inert.** `notifications_user_created`
   and its siblings are declared `ON ONLY public.notifications`, which attaches them to the empty
   parent of a partitioned table. The real indexes live on `notifications_2026_10`,
   `notifications_2026_11`, and so on. Queries still hit those — but a future partition starts with
   none, per the cron note above.
3. **Unique constraints that are partial are easy to bypass by accident.** `orders_idempotency_key_key`
   is unique `WHERE idempotency_key IS NOT NULL`. Two rows with a null key are legal. The RPC always
   sets it, so this is fine server-side; it only bites if you ever insert directly.

---

## 20. Where to start

Build in this order. It follows the write paths that exist, so nothing blocks.

1. **Sign-in and the profile gate.** Google + Apple only. Call `get_profile_status_v1()` and render
   `missing[]`. A user with no `profile_completed_at` can browse and cannot order (§10).
2. **Register the device token** on launch and on every sign-in — `register_device_token_v1` with the
   device's real `language` and `app_version`.
3. **Discovery.** `get_vendor_feed_v1` for the list, `search_catalog_v1` for search. Render
   `availability` as one string, never two booleans.
4. **Vendor detail.** `vendors`, `menu_categories`, `menu_items`, `menu_item_sizes`, `item_options`,
   `option_choices` — all directly readable. Cache against `vendors.menu_version`.
5. **Cart.** `upsert_cart_item_v1` and `remove_cart_item_v1`. Never send a price.
6. **Address.** `upsert_my_address_v1`. Without one there is no quote.
7. **Checkout.** `quote_order_v1` → confirm → `place_order_v1` with a fresh idempotency key. Build the
   `rejections` array as a real screen, not a toast.
8. **Order tracking — a status timeline, not a map.** `order_status_history` is the spine; add
   `orders.status`, `sub_orders.status` and `promised_delivery_at`. Poll. Render the address from
   `address_snapshot`, item names from `order_items`, the rider's name and phone from `riders_public`.
   There is no real-time map in v1 (§13).
9. **Cancellation.** `cancel_order_v1`, with `CANCEL_WINDOW_CLOSED` handled.
10. **Rider shell.** `get_my_rider_profile_v1` decides whether the user is a rider at all. Then
    `get_available_orders_v1` — **pass the device GPS as `p_lat`/`p_lng`**, it does not need a stored
    location (and it backfills the pool itself, §15) — → `claim_order_v1` → `transition_order_v1` →
    `begin_collection_v1` → `collect_cash_v1` / `collect_wallet_v1` → `complete_delivery_v1`
    (which takes the rider's delivery coordinates as an argument). **Stop there.** Online toggle,
    shifts and vehicle editing do not exist (§13).

Everything not in that list — favourites, reviews, notifications, earnings dashboards, admin, live
tracking — has either no write path or is out of scope for v1. Do not build a screen for it until §13
shrinks.
