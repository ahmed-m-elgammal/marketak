# Marketak Mobile — Screen & Component Inventory (Customer + Driver, one RN/Expo app)

**Derived from `DATA-MODEL.md` (live Supabase `erxxsebcqqcpkipzcdhg`, 62 tables, 115 SELECT-only RLS policies).**

Every route and component below is traced to a table, a column, a constraint or an RPC in that model. Nothing here is speculative product padding.

**Every count and constraint claim in this file was re-verified against the live database on 2026-10-08.** Six claims did not survive it — the number of assignment states, the uniqueness of the rider's trip index, the `platform_float` read path, the name of the language column, the count of derived order statuses, and the RPC total — plus three arithmetic slips in this table. They are corrected in place and marked. One structural finding is new and large: **eight table groups have no write path at all.** See §8 rule 1 before trusting any P0–P7 phase in §10.

---

## 0. Headline numbers

| Layer | Count | Notes |
|---|---:|---|
| **Public functions** | **105** | 18 trigger, 49 `admin_*` CRUD, **19 client-callable** — "105 RPCs" is wrong |
| **Customer routes** | **37** | auth/onboarding 7, discovery 9, cart+checkout 7, orders 9, account 5 |
| **Driver routes** | **18** | onboarding 1, availability+shifts 4, trips 7, money 5, vehicle 1 |
| **Shared routes** | **5** | notifications, push prefs, language, support, about |
| **Total routes** | **60** | all real screens in the navigator |
| **Modals / bottom sheets** | **23** | 18 in the original inventory + 5 the re-verification exposed; `CashCollectionSheet` is counted here and again in §6.3 |
| **Tier 0 — UI primitives** | **34** | `base/ui/*` |
| **Tier 1 — customer domain components** | **30** | the list in §6.2 holds 30, not 31 |
| **Tier 1 — driver domain components** | **25** | |
| **Tier 2 — feature composites** | **26** | screen-level assemblies |
| **Total components** | **115** | |
| **Hooks** | **35** | 32 in the original inventory + 3 for the newly-found surfaces |
| **Services / API modules** | **22** | Supabase + device + domain |
| **Store slices (Zustand)** | **9** | |
| **Type definition modules** | **17** | one per schema domain, mirrors `schema/*.sql` |

**Build-size read:** ~76 screens-or-sheets, 115 components, ~80 non-component modules. For a two-role app on one codebase that is a normal-to-heavy build — roughly 9–13 weeks for a small team, and the driver half (16 routes) is only ~28% of the routes but the majority of the *risk*, because it owns cash.

**Read §8 rule 1 before the phases in §10.** Twelve routes and three sheets have no write path at all — not a restricted one. That is a schema gap, not a UI gap, and it puts three of the nine build phases out of reach until it is closed.

---

## 1. How one app becomes two apps

The backend already decides this. You do not build a role picker; you read roles.

```
auth.users → users → user_roles (customer|rider|admin|support, soft-revoked via revoked_at)
                     └── riders.user_id  (NULLABLE)
```

Three facts drive the whole shell:

1. **`riders.user_id` is nullable.** A rider can exist, be dispatched, and be paid before they install the app. So the driver side has an **onboarding/claim flow** — the rider identifies themselves by phone (`riders.phone_number` is `UNIQUE`) and links it to a `user_id`. This is a real screen, not an edge case.
2. **A user can hold both roles.** Role switch is a *view* change, not a re-login. The tab bar, the route tree and the token scope all change under a live session.
3. **RLS resolves visibility, not the client.** The same JWT returns a different world depending on the role rows. Never cache a "role" in AsyncStorage as truth — re-read `user_roles` on app resume, because `revoked_at` can flip while the app is backgrounded.

**Navigator structure**

```
RootNavigator
├── BootGate                     (session restore, flags, city, role resolution)
├── AuthStack                    (customer ∪ driver sign-in — identical, Supabase Auth)
├── CustomerStack
│   └── CustomerTabs  [Home · Search · Orders · Account]
├── DriverStack
│   └── DriverTabs    [Home · Trips · Earnings · Account]
└── SharedStack                  (modals + full-screen pushes reachable from both)
```

Role switching unmounts one stack and mounts the other. Do **not** keep both mounted — the two tabs have contradictory caches (customer cart vs driver trip).

**Language / RTL is shell-level, not screen-level.** `ar` and `en` are separate rows in `notification_templates` (19 keys × 2 langs), `promo_slots.title` is jsonb per language, and search is trigram over `*_normalized` columns maintained by the DB. So: one `I18nProvider` at root, `I18nManager.forceRTL` on switch, and **numbers stay LTR inside RTL containers** (piastre amounts, phone numbers, order numbers).

---

## 2. Customer routes (37)

### 2.1 Auth & onboarding — 7

| # | Route | Screen | Binds to |
|---:|---|---|---|
| 1 | `/splash` | Boot | `settings`, `feature_flags`, `cities` (`is_primary`), session restore |
| 2 | `/welcome` | Welcome | `promo_slots`; brand + language choice |
| 3 | `/auth/sign-in` | Sign in | `user_auth_providers` — **Google + Apple only** |
| 4 | `/auth/callback` | OAuth deep-link handler | Supabase Auth redirect |
| 5 | `/auth/complete-profile` | Profile gate | `update_profile_v1(p_patch jsonb)` → `{profile_completed_at, has_phone, has_address, can_browse, can_order, missing[]}` |
| 6 | `/onboarding/area` | Pick home area | `areas.geohash_prefix` → `delivery_zones` |
| 7 | `/role` | Role switcher | `user_roles` ∪ `riders.user_id` — **only if both** |

**Note on #3.** The model has no password, no email+password, no phone OTP — `user_auth_providers` is `CHECK provider_type IN ('google','apple')`. So this screen is two buttons. Do not build a form you will delete. Do build the *failure* states (cancelled OAuth, provider returns an existing linked account, offline).

**Note on #5.** `profile_phone_required` CHECK means a profile cannot be marked complete without a phone number, and `place_order_v1` re-checks the gate independently. So the gate is a route interceptor on `/checkout`, not a validation toast. The verdict arrives as *data*: `update_profile_v1` and `get_profile_status_v1` return `can_order`, `can_browse`, `has_address` and `missing[]`, so render the database's answer rather than a second client-side rule that can disagree with it.

### 2.2 Discovery — 9

| # | Route | Screen | Binds to |
|---:|---|---|---|
| 8 | `/home` | Home | `get_vendor_feed_v1(p_area_id, p_vertical, p_open_only, p_query, p_offset, p_limit, p_sort)`, `promo_slots`, `cuisines` |
| 9 | `/home/promo/:slotId` | Promo landing | `promo_slots` (jsonb title/subtitle per lang) |
| 10 | `/search` | Search entry | `search_catalog_v1(p_query, p_area_id, p_filters, p_limit)` |
| 11 | `/search/:query` | Results (Stores / Dishes tabs) | `search_catalog_v1` `p_filters` jsonb |
| 12 | `/browse/cuisines` | Cuisine index | `cuisines` |
| 13 | `/browse/cuisines/:cuisineId` | Cuisine → vendors | `vendor_cuisines` |
| 14 | `/browse/vendors` | All vendors, sorted/filterable | `get_vendor_feed_v1(p_sort, p_open_only, p_vertical)` |
| 15 | `/vendor/:vendorId` | Storefront | `vendors.menu_version`, `vendor_schedules`, `vendor_holidays`, `menu_categories`, `menu_items` |
| 16 | `/vendor/:vendorId/item/:itemId` | Item detail | `menu_items`, `menu_item_sizes`, `item_options`, `option_choices` |

**#15 is the screen that most needs care.** The storefront visibility predicate (`is_active AND is_approved AND deleted_at IS NULL`) and the ETAs live behind `get_vendor_feed_v1`, but open/closed is **five** state sources, not two:

- `vendors.is_open` + `vendors.auto_open` — the authoritative pair. `auto_open` decides whether the schedule drives `is_open` or a human does, so `is_open = false` can mean either "shut for the day" or "someone overrode it". `is_busy` is a third, independent manual flag.
- `vendor_schedules` — weekly windows, `time without time zone`, `slot` allows **two windows a day** (lunch + dinner). Not a single open/close pair.
- `vendor_holidays` — one row per `(vendor_id, date)`, overrides the schedule.
- `vendor_areas` — per-area `eta_minutes`, `eta_maxutes`, `delivery_fee_override`, and it decides whether this vendor even appears for the selected address.

Three further `vendors` columns have no screen anywhere in this document: **`minimum_order_value`** (a per-vendor floor — see §6.2), **`capacity_per_slot`** (a limit with its own rejection), and **`delivery_fee_override`** (a *second* override, on the vendor row as well as on `vendor_areas`; the quote must say which one won).

**#15 cache rule.** `vendors.menu_version` is the cache key and five `FOR EACH STATEMENT` triggers bump it from anywhere in the menu tree (including 2 hops deep via `option_choices → item_options → menu_items`). A `sized` item whose last `menu_item_sizes` row is deleted is *rejected by a trigger*, and `menu_items` survives it with `deleted_at`. So: cache the menu by `menu_version`, and re-fetch when the version changes — otherwise you keep rendering a dish that was taken off the board.

### 2.3 Cart & checkout — 7

| # | Route | Screen | Binds to |
|---:|---|---|---|
| 17 | `/cart` | Cart | `carts` (one active per user), `cart_items` — **no write RPC exists**, see §8 rule 1 |
| 18 | `/checkout` | Checkout | `quote_order_v1` → `quote_id`, `expires_at` (+5 min) |
| 19 | `/checkout/address` | Address picker | `addresses`, `areas` — **read-only**, no writer RPC |
| 20 | `/checkout/address/new` | Address form | `addresses.geohash`, `geohash_prefix`, denormalised `area_id` — **blocked**, see §8 rule 1 |
| 21 | `/checkout/review` | Quote review / confirm | `place_order_v1(quote_id, payment_method, payment_channel, idempotency_key)` |
| 22 | `/checkout/price-changed` | **Itemised price diff** | `PRICE_CHANGED` error payload |
| 23 | `/order/placed/:orderId` | Placement success | `orders`, `sub_orders`, `order_items` |

**#17 — the singleton cart.** `UNIQUE (user_id) WHERE is_active` means there is exactly one live cart per user. No cart switcher, no "my other cart". The interesting part is line identity:

```
UNIQUE (cart_id, menu_item_id, md5(selected_options::text))
```

The same pizza without olives and the same pizza with olives are **two lines**; two identical lines are **one line with a bumped quantity**. Your cart UI must reflect that literally or increment/decrement will look broken to users.

Also: `cart_items.cached_price` is **display-only**. It exists so the cart doesn't re-price on every render. Never submit it, never total from it, never show a "total" that pretends to be authoritative — the cart has no total in the model at all.

**#17/#18 — and the cart has no writer at all.** No function in the database inserts or updates `carts` or `cart_items`; `quote_order_v1` only `UPDATE`s an existing `carts` row, and `touch_cart_from_new_rows` is a trigger waiting for an insert that never comes. So `/cart`, `ItemCustomizationSheet`, `OptionGroupSheet` and `CartLineEditSheet` are read-only as the schema stands. This is not a hardening item — it is P2.

**Two inputs the model requires and this document did not render.** `quote_order_v1(p_cart_id, p_address_id, p_voucher_code, p_rider_tip, p_delivery_type, p_grouping)`:

- **`p_delivery_type`** — `'delivery' | 'pickup'`, stored as `orders.delivery_type`. Pickup means no rider, no delivery fee and no tracking screen, so it is a different checkout, not a toggle. `vendors` carries **no pickup capability flag** — no `supports_pickup`, no pickup fee — so how a vendor opts in is unresolved (§11.9).
- **`p_grouping`** — `'together' | 'separate'`, stored as `orders.delivery_grouping`: one bag from every vendor, or one bag per vendor. A customer-facing choice with no component in §5 and no row in the quote review.

And the response is wider than "totals": `quote_id, expires_at, fingerprint, fee_breakdown, totals, per_vendor, `**`limits, rejections, warnings`**. `limits` carries `max_vendors_per_order` (3), `rejections` the item-level refusals (`OUT_OF_STOCK`, out-of-area, below `minimum_order_value`), `warnings` the soft ones. §5 has a surface for none of the three.

**#21 — the countdown.** The quote lives 5 minutes. Render a live countdown, and on expiry re-quote silently. `PRICE_CHANGED` is *not* expiry — it's the fingerprint moving.

**#22 — do not cheapen this.** `place_order_v1` re-runs `private.compute_quote()` inside the write transaction and aborts with a payload containing *which item moved, old price, new price, and both totals*. The model's own line: "a 'prices changed' screen with no numbers in it is not consent." Build a two-column diff table with the per-item delta and both order totals, plus a "review changes" action that re-quotes and returns to #21.

**#21 idempotency.** The place button must mint one `idempotency_key` per checkout attempt and **reuse it on retry**. Disable double-tap in the UI, but understand the DB is the real protection — a retried RPC is a no-op, not a double charge. That means a failed-but-actually-succeeded request must be retryable without fear.

### 2.4 Orders — 9

| # | Route | Screen | Binds to |
|---:|---|---|---|
| 24 | `/orders` | Order list + status tabs | `orders.status` (8 derived branches; the CHECK also allows `delivering`, which the derivation never emits), `orders_status_placed` index |
| 25 | `/orders/:orderId` | Order detail | `sub_orders` (grouping unit), `order_items` |
| 26 | `/orders/:orderId/track` | Live tracking | `delivery_assignments`, `riders_public`, `order_eta_snapshots` — **no position source**, see §8 rule 1 |
| 27 | `/orders/:orderId/timeline` | Status history | `order_status_history` (`actor_role`) |
| 28 | `/orders/:orderId/cancel` | Cancel flow | `cancel_order_v1(p_order_id, p_sub_order_id, p_reason)` |
| 29 | `/orders/:orderId/review` | Review | `reviews` `UNIQUE(order_id, vendor_id)` — **no submit RPC exists**, see §8 rule 1 |
| 30 | `/orders/:orderId/receipt` | Receipt | frozen `order_items` snapshot |
| 31 | `/orders/:orderId/changes` | Modification log | `order_modifications.difference_amount` |
| 32 | `/orders/:orderId/repeat` | **Repeat order** | `order_items` → rebuild cart → `quote_order_v1` |

**#24 — the status tabs are the derived states, and two of them are unusual:**

```
all cancelled/rejected   → cancelled
all delivered            → delivered
all terminal             → partially_cancelled     ← no direct writer, ever
all picked_up/delivering → picked_up
all ready                → ready
all preparing/ready      → preparing
any past pending         → partially_confirmed
else                     → pending
```

Tab set: **Active** (pending / partially_confirmed / preparing / ready / picked_up), **Delivered**, **Cancelled** (includes `partially_cancelled`). A "partially_cancelled" order is *not* a cancelled order and must not be filed with them — one vendor refused, two delivered, and the customer still gets a normal-looking order with a removed line.

**Do not compute status on the device.** `private.recompute_order_aggregates()` is the only writer of `orders.status`, and `sync_order_status()` is a statement trigger on `sub_orders`. If you render an optimistic status you will eventually disagree with the only authority that matters. The one exception worth optimising: `picked_up` can be reflected from the assignment's own state since the rider is the actor.

**#25 — `sub_order` is the layout unit, not the order.** There is no `vendor_id` on `orders`, ever. A three-restaurant checkout is three `sub_orders` with independent status, prep estimate and payout figure. The detail screen is a list of vendor cards, each with its own progress rail, each individually cancellable. Rendering it as one flat item list throws away the entire point of the schema.

**#26 — what you may show about the rider.** `riders` grants nothing to `authenticated` (its one policy is `riders_admin_read`); the customer reads the view `riders_public`, which exposes exactly eight columns:

```
id, first_name, last_name, phone_number, vehicle_type, vehicle_plate, rating_avg, rating_count
```

So: name, photo initials, **call button** (deliberate — cash at the door), vehicle, plate, rating. And **nothing else**. No live coordinates from `riders.current_latitude` — the table is unreachable. Live movement has to come from the assignment/trip progress, and freshness from `order_eta_snapshots` (promised vs predicted, swept after 24h). A customer watching a dot that is 4 minutes stale and not knowing it is a support ticket waiting to happen. And note that this is not merely a restriction: `rider_location_pings` has no writer RPC either, so there is no live position to show even through an RPC — the trip-progress fallback is the *only* option at launch, not the safer one.

**#28 — a cancel is not just a status flip.** `cancel_order_v1` writes an `order_modifications` row and stamps `sub_orders.cancellation_actor IN ('customer','vendor','admin','system')`, which makes `difference_amount` non-zero and **changes `orders.total`** — because `total = subtotal + delivery_fee + service_fee + rider_tip − discount` is recomputed. A partial cancel therefore changes what the customer is owed back. So the cancel screen must show the new total and the delta, and the timeline (#27) must name the actor: a vendor `rejected` and a customer `cancelled` are different stories and this is where the customer reads them. `transition_order_v1` is the other writer to that table, and it is the vendor/admin one.

**#29 — one review per vendor per checkout.** `UNIQUE (order_id, vendor_id)`, and `rider_rating IS NULL OR rider_id IS NOT NULL` prevents a rider rating with no rider attached. The composer is therefore per-sub-order, with an optional independent rider rating — and once submitted, that vendor's card shows "reviewed", not a form. **There is no submit path**: no function writes `reviews`, so the composer has nothing to call (§8 rule 1).

**#32 — repeat is a partial-failure screen, not a shortcut.** `order_items` are frozen at placement: `menu_item_id references menu_items(id) ON DELETE SET NULL`. The line outlives the dish it names, so a repeat from six months ago can contain rows whose `menu_item_id` is `NULL` (dish deleted) or whose vendor is now closed / holidaying / out of the delivery area. So: rebuild the cart from the frozen snapshot, then mark each line *re-orderable / dish gone / vendor closed / now out of stock* before letting the user proceed — and then send them through the normal quote flow, because the prices in the old order are history, not a quote.

### 2.5 Account — 5

| # | Route | Screen | Binds to |
|---:|---|---|---|
| 33 | `/account` | Account hub | `users` |
| 34 | `/account/profile` | Edit profile | `update_profile_v1(p_patch jsonb)` (patch-guarded; also writes `users.avatar_path`) |
| 35 | `/account/addresses` | Address book | `addresses` (`addresses_one_default` partial unique) — **no writer RPC**, see §8 rule 1 |
| 36 | `/account/favorites` | Favorites — **two tabs** | `favorites` (stores) + `favorite_items` (dishes) — **no toggle RPC**, read-only |
| 37 | `/account/settings` | Preferences | `users.preferred_language`, push toggle → `register_device_token_v1` |

Note #36: `favorites` and `favorite_items` are **two separate tables**, not one polymorphic list. Two tabs, two endpoints, two empty states. This is the kind of thing that gets built as one list with a type column and then breaks. With no add/remove RPC (see §8 rule 1), both tabs are read-only at launch, so the empty state is the only state that can be reached — a strong hint that this is a schema gap rather than a design choice.

---

## 3. Driver routes (18)

The driver is the smaller half by route count and the larger half by consequence — this is the surface that moves real cash.

### 3.1 Onboarding — 1

| # | Route | Screen | Binds to |
|---:|---|---|---|
| D1 | `/driver/onboarding` | Link or claim rider profile | `riders.user_id` (nullable), `riders.phone_number` UNIQUE |

Because `riders.user_id` is nullable and the delete behaviour is `ON DELETE SET NULL` (deleting a login must not destroy payout history), a rider may sign in and find *no* rider row. This screen: enter phone → match against `riders` (via an RPC, since the base table has no customer-facing policy) → claim it, or get routed to admin for provisioning. Handle the "phone already claimed by someone else" case explicitly; the UNIQUE constraint will raise.

Also: two triggers sync contact **both directions** (`users` → `riders` and `riders` → `users`), guarded by `IS DISTINCT FROM`. So the profile screen and the rider profile screen are the same fields — do not let them drift.

### 3.2 Availability & shifts — 4

| # | Route | Screen | Binds to |
|---:|---|---|---|
| D2 | `/driver` | Driver home | `riders.status`, `is_online`, `cash_held`, available queue |
| D3 | `/driver/status` | Go online / offline | `status` — **`is_online` is CHECK-derived**; no status-writer RPC exists, see §8 rule 1 |
| D4 | `/driver/shifts` | Shift list | `driver_shifts` |
| D5 | `/driver/shifts/new` | Shift editor | `driver_shifts.area_ids[]`, no-overlap EXCLUDE — **no writer RPC**, see §8 rule 1 |

**D3 — never write `is_online`.** `CHECK (is_online = (status <> 'offline'))` — the column physically cannot disagree with `status`. Write `status` only; the CHECK does the rest. The UI copy should say what status does (visible to dispatch? affects job offers?), not just flip a switch. **Caveat this whole section:** as the schema stands there is nothing to write `status` with (§8 rule 1), so D3 is a design waiting on a call.

**D5 — the EXCLUDE constraint.** This is a `GIST EXCLUDE ... WITH &&`, **not** a unique index:

```sql
EXCLUDE USING gist (rider_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&) WHERE (is_active)
```

A unique index over the same columns would only reject byte-identical rows and would happily permit a double-booked rider. It also needs `btree_gist` to make `uuid` gist-comparable. The client cannot express this in SQL, so **pre-check overlap against the rider's existing active shifts in the editor** and render the conflicting shift inline. Note also that the constraint is `DEFERRABLE INITIALLY DEFERRED`, so the failure surfaces at COMMIT, not at insert — which means a submit that "succeeded" from PostgREST's perspective can still abort the transaction.

**The caveat that swallows the paragraph above:** `driver_shifts` has no writer RPC either (§8 rule 1). So the overlap pre-check is a real design for a write path that does not exist yet — build it as the client half of a `set_shift_v1` you also have to write, and do not treat the EXCLUDE analysis as the reason D5 is blocked. It is not; the missing function is.

Two smaller notes on this table. `driver_shifts` has a plain `driver_shifts_active_window` index on `(starts_at, ends_at) WHERE is_active` that serves the agenda, and `driver_shifts_rider_starts` on `(rider_id, starts_at DESC)` for history — both are access paths, neither is a constraint.

### 3.3 Trips — 7

| # | Route | Screen | Binds to |
|---:|---|---|---|
| D6 | `/driver/trips` | Available + active | `get_available_orders_v1(p_lat, p_lng, p_radius_km)`; the pool is `rider_id IS NULL AND status = 'unassigned'` |
| D7 | `/driver/trips/:assignmentId` | Trip detail — the core screen | `stop_sequence` jsonb, `sub_orders`, `rider_pay_*`, `distance_km`, `eta_minutes` |
| D8 | `/driver/trips/:id/navigate` | Navigate to stop | external maps; coords from stop_sequence |
| D9 | `/driver/trips/:id/customer` | Customer contact | `users` — the **rider→customer profile read exception** |
| D10 | `/driver/trips/:id/cash` | Cash collection | `begin_collection_v1` → `collect_cash_v1` **or** `collect_wallet_v1` |
| D11 | `/driver/trips/:id/complete` | Complete delivery | `complete_delivery_v1(p_order_id, p_proof_path, p_lat, p_lng)` |
| D12 | `/driver/trips/:id/failed` | Failed delivery | `delivery_assignments.status = 'failed'` |

**D6 — the queue is a single-item interface by design. One partial unique index does the work, and it is not the one you would guess:**

```sql
-- one trip in flight per order  (UNIQUE — this is the guard)
CREATE UNIQUE INDEX delivery_assignments_one_active ON delivery_assignments (order_id)
  WHERE status <> ALL (ARRAY['delivered','failed','cancelled']);

-- an access path for the open-trip query  (NOT unique)
CREATE INDEX delivery_assignments_open ON delivery_assignments (rider_id, status)
  WHERE status = ANY (ARRAY['assigned','at_first_vendor','picking_up','picked_up','delivering','arrived']);

-- the offer pool  (NOT unique)
CREATE INDEX delivery_assignments_offer_pool ON delivery_assignments (assigned_at)
  WHERE rider_id IS NULL AND status = 'unassigned';
```

**Correction to an earlier draft of this file: only the first index is unique.** An earlier version claimed "two partial unique indexes do the work" and concluded a rider can hold at most one active trip. That is wrong — `delivery_assignments_open` and `delivery_assignments_offer_pool` are plain btree indexes, and `delivery_assignments_one_active` constrains `order_id`, not `rider_id`. The database permits a rider with two live trips. So the single-active-trip surface is a **product decision you enforce in the client**, not a guarantee you inherit: build the active trip as a persistent full-screen surface *and* refuse a second `claim_order_v1` while one is open, because a rider who quietly holds two looks exactly like a dispatch bug.

**D7 — ten assignment states, and the button set is status-gated:**

```
unassigned ──▶ assigned ──▶ at_first_vendor ──▶ picking_up ──▶ picked_up ──▶ delivering ──▶ arrived
                                                       ↘ delivered | failed | cancelled
```

An earlier version of this file listed nine. The missing one is **`unassigned`** (`rider_id IS NULL`) — the state a trip is in *before* any rider exists, which is precisely the pool D6 lists. A claim must also satisfy `delivery_assignments_claimed_has_time`: `assigned_by = 'rider_claim'` requires both `rider_id` and `claimed_at`, and `claim_order_v1(p_assignment_id, p_rider_id)` needs the caller's own `rider_id` to already be known — which loops straight back into §3.6.

The trip detail must render a **different primary action per state**, and the action list is not uniform — a multi-vendor trip has an action per vendor stop, not one action for the whole trip. `sub_orders.status` (nine values, vendor/rider-facing) and `delivery_assignments.status` (ten values, the dispatch leg) are *different state machines* that move in parallel. Ship one indicator that shows both without pretending they're one. `sub_orders.cancellation_actor IN ('customer','vendor','admin','system')` is what distinguishes a vendor's `rejected` from a customer's `cancelled` on this screen.

**D7 — `stop_sequence` is jsonb and that is correct.** A multi-vendor order is N vendor pickups then 1 dropoff, and the sequence is a property of that single order — a `delivery_stops` table would be a join with no independent lifecycle. Walk the array; render a stop list. The trip's distance comes from `private.trip_distance_km()` over the same array, so the map and the list must be rendered from one source of truth or they will disagree.

**D7 — pay is frozen at claim time.** `delivery_assignments` carries resolved `rider_pay_base` / `rider_pay_distance` / `rider_pay_bonus` / `rider_pay_total`, computed once by `private.resolve_pay()`:

```
rider pay = 0, platform revenue = 100% of the delivery fee   ← when no rule matches
```

That third branch in `private.pay_rule_for()` is the **launch posture**, not a bug. A rider with no matching rule earns 0 and the platform takes the whole fee. Your UI must render a zero total gracefully and legibly — "no pay rule configured for this city" is a support-worthy screen, not a crash and not a silent blank.

**You do not have to detect that state by arithmetic.** `claim_order_v1` returns `has_pay_rule boolean` alongside the frozen pay, so `PayRuleMissingNotice` binds to a flag rather than to `rider_pay_total = 0` — which is also the legitimate value of a real zero-rate rule. The full claim response is `order_id, assignment_id, rider_id, rider_pay_base, rider_pay_distance, rider_pay_bonus, rider_pay_total, platform_revenue, distance_km, eta_minutes, has_pay_rule`: everything the trip detail needs arrives in one call, which is why D7 should be rendered from the claim result rather than re-read.

**D9 — the deliberate read exception.** `users_read` allows a rider to read the profile of a customer on an order they are delivering, *and only those*, bounded by `private.rider_order_ids(uid)`. This is the minimum needed to call the customer at the door. The contact sheet is therefore allowed — but it must read through RLS, not be populated with a broader profile fetch that would simply come back empty and look broken.

### 3.4 Money — 5

| # | Route | Screen | Binds to |
|---:|---|---|---|
| D13 | `/driver/earnings` | Wallet balance | `wallets`, `get_wallet_balance_v1(p_owner_type, p_owner_id)`, `get_rider_earnings_v1(p_from, p_to)` |
| D14 | `/driver/ledger` | Ledger history | `ledger_entries` |
| D15 | `/driver/cash` | Cash float & limit | `riders.cash_held`, `max_cash_held`, `effective_cash_limit_v1` |
| D17 | `/driver/payouts` | **Payout history — missing** | `payouts`, `payout_lines` (rider-readable via `account_ids_for`) |
| D18 | `/driver/payouts/:payoutId` | Payout detail — missing | `payout_lines.shape` CHECK, `payouts.status`, `approved_by`, `paid_at` |

**D13 — `wallets` is a cache and the API admits it.** `wallets.balance` is denormalised, `wallets.version` exists for optimistic locking, and `get_wallet_balance_v1()` returns **`drift` alongside the balance** — the gap between the wallet row and `SUM(signed_amount)` of its journal entries. There is also `get_rider_earnings_v1(p_from, p_to)` for a dated range, which is what an earnings screen actually wants; D13 should show both, not the wallet alone.

Render the balance normally. Render `drift` **only when non-zero**, as a conspicuous ops banner. A non-zero drift is the single most valuable number in the money layer — it means the cache and the journal disagree, which is exactly the class of bug that otherwise stays invisible until an audit. Do not hide it, and do not let a rider "fix" it.

**D17/D18 — the payout half of driver money is missing entirely.** `payouts` and `payout_lines` are rider-readable (`account_id IN (SELECT private.account_ids_for(auth.uid()))`), and `payouts.status` runs `draft → approved → processing → paid` with `failed` requiring a reason, plus `approved_by`, `approved_at`, `paid_at` and `failure_reason`. So a rider can be told *when they get paid and whether it failed* — and no route in this document does. Note also that there is **no cash-out RPC**: `collect_wallet_v1` collects a wallet payment at the door, it does not withdraw. Payouts are created by `run_payout_v1` (admin), so the rider's money screen ends in a read-only status timeline.

**D15 — the float bar is the rider's most important widget.** `riders.cash_held` is not a balance to top up; it is a **liability to reconcile**. `riders_cash_held_nonneg` stops it going negative, and `effective_cash_limit_v1` bounds it. So the driver home must show cash held against max cash held as a fill bar, because it changes what work the rider can accept. The warning threshold is not a design choice: `settings.rider_cash_limit_warning_pct = 80`, read through the same RPC.

### 3.5 Vehicle — 1

| # | Route | Screen | Binds to |
|---:|---|---|---|
| D16 | `/driver/vehicle` | Vehicle details | `riders.vehicle_type`, `vehicle_plate` |

`vehicle_type` and `vehicle_plate` are on `riders` and surfaced publicly through `riders_public` — a customer can read the plate of the person at their door, so it is customer-visible data that the rider must be able to correct. Route it through an RPC (`authenticated` has no `UPDATE` grant anywhere) and mirror it onto the customer-facing card, which is a good end-to-end test of the two-way contact sync on `users ↔ riders`.

**D11 — completion is a two-part proof, not a button.** `complete_delivery_v1(p_order_id, p_proof_path, p_lat, p_lng)` takes an uploaded object path *and* the rider's GPS at the door, which is almost certainly validated against the address geohash. `delivery_assignments` also carries `signature_path` — a second capture with no component in §5 or §6. This means D11 needs, in front of the RPC call: an R2 signer round trip, a capture surface, a signature surface, and an "upload failed, retry" path that does not look like a delivery failure. An earlier version of this file bound D11 to a bare `complete_delivery_v1` and would have shipped a two-argument-away screen.

### 3.6 ⚠️ Unresolved: there is no read *or write* path for the rider's own row

This is the one place where the model as written does not obviously support the app, and it should be settled before P6, not during it.

`riders` carries the fields the driver home needs — `status`, `is_online`, `cash_held`, `max_cash_held`, `vehicle_type`, `vehicle_plate`, `current_latitude`/`current_longitude`/`last_location_at`, `rating_avg` — and the live policy set is admin-only. **Correction:** `DATA-MODEL.md` says the table has "no policy and no grant"; it in fact has one policy, `riders_admin_read` (`is_admin()`). Substance unchanged, precision fixed.

```
GRANT SELECT ON riders_public TO authenticated;   ← the view: what the customer may read
-- (no grant on `riders` to authenticated at all)
policy riders_admin_read  on riders  →  is_admin()   -- the only way in
```

`riders_public` exposes eight columns: `id, first_name, last_name, phone_number, vehicle_type, vehicle_plate, rating_avg, rating_count`. That is enough for a customer at the door and **not enough for a rider on shift** — `status`, `cash_held`, `max_cash_held` and live position are all outside it. `private.rider_ids_for(uid)` exists and is used inside other policies, so the identity resolution is already there; what is missing is a surface the rider's own client can call.

**And the write side is worse than the read side.** Beyond §8 rule 1, there is no function anywhere that writes `riders.status` — so `/driver/status` (D3) has no call to make — and none that writes `driver_shifts`, so D5's overlap editor targets a table the client cannot touch. The rider's own state is read-blocked **and** write-blocked; `claim_order_v1`, `begin_collection_v1`, `collect_cash_v1` and `complete_delivery_v1` are the only rider-side writes that exist at all.

Three ways to close it, cheapest first:

1. **A `private.get_my_rider_v1()` RPC** that returns the caller's own `riders` row (plus a `private.set_my_status_v1()` writer to pair with it, since `authenticated` cannot `UPDATE`). Mirrors the existing `get_wallet_balance_v1()` pattern and is the smallest change.
2. **A second view**, `rider_self`, with an RLS policy of `user_id = auth.uid()`. Cleaner as a read model, but it re-exports live coordinates, which is a wider blast radius than an RPC.
3. **Fold the fields the app needs into an existing RPC response** — the precedent already exists: `claim_order_v1` returns `has_pay_rule` and `get_wallet_balance_v1` takes explicit owner args. Least new surface, but couples the rider's own state to trip calls and makes offline driver home awkward.

Whichever you pick, the driver app cannot be built against `riders_public`, and any plan that assumes it can will stall at P6 with a rider who cannot see their own cash float.

**D10 — cash collection is tri-state, pre-flighted, and not the only path:**

```sql
CHECK ( (collection_method IS NULL AND collection_channel IS NULL AND collected_amount IS NULL)
     OR (collection_method IS NOT NULL AND collection_channel IS NOT NULL) )
-- plus: if method = 'none', amount must be 0
```

`begin_collection_v1` returns `amount_due` **and** `can_collect_cash` (checked against `max_cash_held`) *before* anything moves. So the collection screen is: read `amount_due` → show `can_collect_cash` as a hard gate with a reason → only then enable `collect_cash_v1`. Never optimistically show cash collected; `riders.cash_held += amount` plus a `ledger_entries` row with `UNIQUE(idempotency_key)` happen server-side or not at all.

**A second path this document omitted:** `collect_wallet_v1(p_order_id, p_channel, p_reference)` handles `collection_channel IN ('vodafone_cash','instapay')`, where `collection_reference` is the transaction id the rider has to type. `collection_method IN ('cash','wallet','none')` × `collection_channel IN ('cod','vodafone_cash','instapay')` is six combinations, not one — so `CashCollectionSheet` is a method + channel + reference form, and only `cash`/`cod` moves `cash_held` at all. The other four land as `payment_status` on the order, not on the rider's float.

---

## 4. Shared routes (5)

| # | Route | Screen | Binds to |
|---:|---|---|---|
| S1 | `/notifications` | Notification centre | `notifications` (partitioned, jsonb title/body per lang) — `read_at` has **no writer**, so there is no unread state |
| S2 | `/notifications/preferences` | Push preferences | `register_device_token_v1(p_token, p_platform, p_app_role, p_app_version)`, `get_flags_v1(p_app_role, p_app_version)` |
| S3 | `/language` | Language / direction | `users.preferred_language`; forces RTL |
| S4 | `/support` | Help & contact | static + `settings` |
| S5 | `/about` | Version, terms, privacy | static |

**S1 — 30-day retention means the list has a hard floor.** `notifications` is `PARTITION BY created_at` and swept after 30 days. A rider who was offline for a month gets an empty screen, and that is correct, not a bug — but the empty state should say so. Titles and bodies are jsonb per language, **rendered from templates at write time**, so a push already on the device is unaffected by later copy edits. Don't try to re-localise stored notifications client-side; store the delivered shape as-is and render the current language's string if present, falling back to the other.

Three further S1 facts. `notifications.read_at` exists but **no function writes it** — `authenticated` has SELECT only and there is no `mark_notification_read_v1` — so the centre is all-unread, forever (see §8 rule 1). `notifications.data` is the jsonb that pairs with a push tap, and the table carries `order_id` and `sub_order_id`, so tap→route resolution is schema-supported (`order.placed` → `/orders/:id/track`); **no route in §2 or §3 is registered for it, and nothing here handles a cold start from a push**. And `S1` must never call `claim_events_v1` or `mark_events_delivered_v1` — those are `service_role` only and are the Worker's, not the client's.

**S2 — push registration is version- and role-scoped.** `register_device_token_v1(p_token, p_platform, p_app_role, p_app_version)` and `get_flags_v1(p_app_role, p_app_version)` both take the role and the semantic version, so the app must ship both from a single source (Expo constants), not per-screen. `feature_flags.targeting_rules` is jsonb and is what makes those two args mean anything — see §11.8, because a force-update gate has no settings row behind it.

---

## 5. Modals & bottom sheets (23)

Not routes — overlays with their own component. Counted separately because they is where most of the app's interaction actually lives. The original inventory counted 18; re-verification against the live schema added five that the model supports and the list omitted.

**Customer (10)**
1. `ItemCustomizationSheet` — sizes + options + qty, live price
2. `OptionGroupSheet` — `min_selections` / `max_selections` enforcement
3. `CartLineEditSheet` — qty, options, remove
4. `AddNoteToVendorSheet` — special instructions per sub_order
5. `AddressPickerSheet` — quick switch on checkout
6. `VoucherInputSheet` — code entry, uppercase-normalized
7. `TipSelectorSheet` — pre-set amounts + custom
8. `VendorSortFilterSheet` — sort/filter vendor list
9. `CancelReasonSheet` — per-sub_order cancellation → `cancel_order_v1(p_reason)`
10. `PaymentMethodSheet` — `place_order_v1` takes `p_payment_method` + `p_payment_channel`; the schema allows `cash|wallet` × `cod|vodafone_cash|instapay|gateway`, but only `cash`/`cod` has a collection RPC at launch (§11.10)

**Driver (6)**
11. `StopActionSheet` — status-gated actions for one stop
12. `CashCollectionSheet` — amount + `collection_method` + `collection_channel` + `collection_reference`
13. `FareBreakdownSheet` — base / distance / bonus / total
14. `CustomerCallSheet` — confirm-then-call
15. `ShiftConflictSheet` — the overlapping shift from the EXCLUDE violation
16. `TripFailureSheet` — reason capture → `delivery_assignments.failure_reason`

**Missing from this list (5)** — these exist in the schema and have no overlay:
19. `DeliveryProofSheet` — capture/upload before `complete_delivery_v1(p_proof_path)`
20. `QuoteLimitsSheet` — `limits` / `rejections` / `warnings` from a *successful* quote
21. `PayoutStatusSheet` — `payouts.status` + `failure_reason` (D17/D18)
22. `PickupPickerSheet` — `p_delivery_type = 'pickup'` (§11.9)
23. `SuspendedAccountSheet` — `users.is_active = false` / `deleted_at` (§11.11)

**Shared (2)**
17. `LanguageSheet` — from anywhere in the tree
18. `RateAppSheet` — post-delivery prompt

*(Numbering 1–18 is the original inventory; 19–23 are the gaps. `CashCollectionSheet` appears here and again in §6.3, which is why §0's component total and this overlay total are not additive.)*

**#1 is the most complex sheet in the app.** It must handle `pricing_mode`:
- `'fixed'` → price is `menu_items.base_price`, no size step
- `'sized'` → **a `menu_item_sizes` row must be selected**; one is index-enforced as default

Both paths then add `SUM(option_choices.price_modifier)`, and `price_modifier` **may be negative** (a "no onions" discount). Render it as `−15.00 EGP`, not a parenthesised number, and never assume a modifier is additive-positive. A `sized` item with no size selected must block add-to-cart — `assert_item_has_sizes` guarantees at least one exists, and `assert_item_still_sized` guarantees the last one cannot be deleted, so "no sizes available" is unreachable and should not be a state you design for.

**#6 — voucher codes are `UNIQUE (upper(code))`.** Normalize to uppercase on input (and trim), because matching is case-insensitive but the stored value is whatever was typed. And the sheet needs more states than "valid/invalid": `usage_limit_per_user` (has *this* user already used it — a `voucher_redemptions` read), `first_order_only` (has this user ever ordered), `applies_to_vendor_ids` (is this vendor in the basket), `valid_from`/`valid_until`, `min_order_value`, `max_discount_cap`, and `discount_type` (`fixed` vs `percentage`). A single "code not recognised" string cannot cover eight eligibility rules.

---

## 6. Component inventory (115)

### 6.1 Tier 0 — UI primitives (34) → `src/base/ui/`

**Text (5)**
`AppText` (role prop: h1–h6/label/body/caption) · `LocalizedText` (lang + RTL-aware) · `PriceText` (piastres → EGP, LTR-locked) · `BidiText` (mixed ar/en runs) · `Link`

**Buttons (5)**
`Button` (primary/secondary/ghost/danger) · `IconButton` · `FAB` (cart) · `SegmentedControl` (role switch, favorites tabs, order status) · `SubmitButton` (holds idempotency key + in-flight lock)

**Inputs (7)**
`TextField` · `PhoneField` (country code) · `CodeField` (voucher) · `SearchField` (debounced, trigram-safe) · `TextArea` (cancel reason, review body) · `Select` (area picker) · `Toggle`

**Overlays (5)**
`Sheet` · `Modal` · `ConfirmDialog` · `Toast` · `ActionSheet`

**Feedback (5)**
`Loader` · `Skeleton` · `EmptyState` · `ErrorState` (carries a PG `code`, not just a message) · `ConnectionBanner`

**Layout (5)**
`Screen` (safe area + header + scroll) · `AppHeader` · `Section` (title + action) · `ListSeparator` · `Stack` (spacing primitive)

**Media (2)**
`RemoteImage` (`expo-image`, disk cache) · `Avatar` (initials fallback — `riders` has no image column, though `users.avatar_path` does and `update_profile_v1` patches it)

A note on that caveat, because it changes the account section: `users.avatar_path` is patchable through `update_profile_v1`, so profile-photo upload is in scope and needs the same R2 signer round trip as delivery proof (§5.19). `riders` still has no image, so the customer's `RiderCard` is initials forever — that part of the original note stands. `vendors.logo_path` and `brands.logo_path` exist too, but those are vendor-web uploads, not mobile.

**#ErrorState matters more than it looks.** Every failure in this system arrives as a Postgres error with a code, and several are *user-actionable* rather than generic: `PRICE_CHANGED`, `PROFILE_INCOMPLETE`, `OUT_OF_STOCK`, `AUTH_REQUIRED`, `RIDER_REQUIRED`, plus the cash-limit rejections. Map code → specific copy and a specific CTA. A generic "something went wrong" on `PRICE_CHANGED` throws away the single most important product moment in the checkout.

Not every refusal is an error, though: `quote_order_v1` returns `rejections`, `warnings` and `limits` inside a **successful** response, and those need their own surfaces. A basket over `max_vendors_per_order` (3) is a limit; an item below `vendors.minimum_order_value` is a rejection; both arrive with HTTP 200. An `ErrorState`-only design silently swallows them.

### 6.2 Tier 1 — customer domain components (30)

`VendorCard` · `VendorRow` · `VendorBanner` · `CuisineChip` · `MenuCategoryNav` · `MenuItemRow` · `MenuItemImage` · `MenuItemCustomizationPicker` · `SizeSelector` · `OptionGroup` · `OptionChoice` (± modifier) · `QuantityStepper` · `StockBadge` · `CartLine` · `CartSummaryBar` · `EmptyCart` · `StickyCartFooter` · `AddressCard` · `VoucherBadge` · `TipSelector` · `PaymentMethodCard` (cash, locked) · `MoneyBreakdown` · `PriceDiffRow` · `OrderStatusPill` · `SubOrderCard` · `OrderCard` · `OrderTimeline` · `RiderCard` (`riders_public` only) · `RatingStars` · `ReviewComposer`

`MoneyBreakdown` and `PriceDiffRow` ship as one file with two exports — they share a row layout and the same piastre formatting.

**`StockBadge` — the one that will bite you.** `stock_count IS NULL` means **unlimited**. Only an explicit `0` or below is out of stock:

```sql
when p.stock_count is not null and p.stock_count <= 0 then 'OUT_OF_STOCK'
```

Testing `stock_count === 0` marks every item that never had stock configured as sold out. In a schema with no demo data, that is *most of the catalogue*. Get this predicate right and put it in one shared helper, because it will be needed in the menu list, the item sheet, the cart, and again inside `compute_quote`.

`vendors.minimum_order_value` is the other predicate with no component. It is per-vendor, so the cart needs one "add X to reach the minimum" row **per sub_order**, not one global total — and it lands in the quote's `rejections`, not in a client-side rule, so the cart can look fine and the quote still refuse.

### 6.3 Tier 1 — driver domain components (25)

`OnlineToggle` · `ShiftCard` · `ShiftEditor` · `TripCard` · `ActiveTripBar` · `TripStopList` · `TripStopRow` (vendor pickup / customer dropoff) · `TripActionBar` · `TripStatusTimeline` · `AvailableJobQueue` · `CustomerContactCard` · `CallButton` · `NavigationLauncher` · `CashCollectionSheet` · `CashHeldCard` (fill bar vs `max_cash_held`) · `CashRemittanceCard` (`platform_float.variance`) · `RiderPayBreakdown` · `RiderEarningsCard` (+ `drift` banner) · `RiderLedgerRow` · `PerformanceStat` · `TripHistoryRow` · `VehicleCard` · `LocationPingIndicator` · `StaleLocationWarning` · `RiderRatingBadge`

`CashRemittanceCard` **cannot be built as a driver component as the schema stands.** Both `platform_float` policies — `platform_float_read` *and* `platform_float_admin_read` — are `is_admin()`. A rider reading `platform_float` gets zero rows, always. Either this card moves to `admin-web` alongside `reconcile_day_v1` and `get_platform_float_v1`, or it needs a new RPC; what it cannot be is a rider widget bound to a table the rider cannot read. This is the sharpest correction in the file: earlier drafts had the driver reading daily platform reconciliation, which is exactly the data an admin dashboard owns.

**`StaleLocationWarning` is not cosmetic — and it is currently unreachable.** `riders_location_has_time` is all-or-nothing — a half-present position is a CHECK violation — but the *value* can still be arbitrarily old, and `rider_location_pings.recorded_at` may legitimately be **5 minutes in the future** (device clock skew). So the location UI must show a recency badge, must not treat a future timestamp as an error, and must not present a stale fix as live.

The catch: **no function writes `rider_location_pings`** (§8 rule 1). There is nothing to render stale, because there is nothing to write. `LocationPingIndicator`, this component, and the customer's live tracking all presuppose a `report_location_v1` that does not exist — and until it does, #26's "live movement has to come from the assignment/trip progress" is the *only* option, not the preferred one.

### 6.4 Tier 2 — feature composites (26)

**Customer (14)**
`HomeHeroCarousel` (promo_slots) · `CuisineStrip` · `NearbyVendorsRail` · `ClosedVendorNotice` (schedule-derived) · `HolidayNotice` · `StorefrontHeader` · `DeliveryEtaBadge` · `VendorCountBadge` (vs `max_vendors_per_order`) · `QuoteCountdown` · `CheckoutSummary` · `OrderStatusTabBar` · `TrackMapView` · `RiderArrivalCard` · `PartialCancelNotice`

**Driver (8)**
`DriverStatusHeader` · `ShiftAgenda` · `JobOfferCard` · `StopProgressMap` · `TripCountdown` · `PayRuleMissingNotice` (the zero-pay launch branch) · `FloatWarningBanner` (approaching `max_cash_held`) · `DriftWarningBanner`

**Shared (4)**
`AppTabBar` (role-aware) · `ScreenTitle` · `PullToRefresh` · `OfflineState` (all writes go through RPCs — and for eight table groups there is no RPC at all, so there is nothing to queue *and* nothing to retry)

`OfflineState` deserves a sharper gloss than it had: the usual React Native offline story is a queue plus an optimistic patch. Here the queue is empty by design — every mutation is a call to a `security definer` function that re-prices and re-authorises — so offline is a **read-only degraded mode with a ConnectionBanner**, never a write buffer. The one exception worth designing for is the quote itself: a 5-minute TTL can expire during a tunnel, and re-quoting on reconnect is the only correct move.

**`QuoteCountdown` and `PayRuleMissingNotice` are the two components a normal build would skip and a real one cannot.** The first is a 5-minute TTL with a fingerprint contract behind it; the second is the documented launch posture where a rider with no pay rule earns zero — and it does **not** need to be inferred from `rider_pay_total = 0`, which is also the legitimate value of a real zero-rate rule: `claim_order_v1` returns **`has_pay_rule`**, so bind the notice to the flag. `FloatWarningBanner`'s threshold is likewise not a design choice — `settings.rider_cash_limit_warning_pct = 80`, read through `effective_cash_limit_v1`.

---

## 7. Component → data binding matrix

The high-signal rows. If a screen or component is not in this table, it is either pure chrome or speculative.

| Surface | Table(s) | RPC / function | Constraint that shapes the UI |
|---|---|---|---|
| Sign in | `user_auth_providers` | Supabase Auth | `provider IN ('google','apple')` — 2 buttons only |
| Profile gate | `users` | `update_profile_v1`, `get_profile_status_v1`, `place_order_v1` | `profile_phone_required` CHECK; verdict arrives as `can_order`/`missing[]` |
| Role switch | `user_roles`, `riders` | — | `revoked_at` soft revoke; `riders.user_id` nullable |
| Area picker | `areas`, `delivery_zones` | `private.setting_*` | `geohash_prefix` join key; one primary city |
| Vendor card ETA | `vendor_areas` | `get_vendor_feed_v1` | per-area `eta_minutes/eta_maxutes`, `delivery_fee_override`; the vendor row has a second override |
| Open/closed | `vendors`, `vendor_schedules`, `vendor_holidays` | `get_vendor_feed_v1(p_open_only)` | **five** inputs: `is_open` + `auto_open` + `is_busy` + `slot` (two windows/day) + holidays |
| Menu cache | `vendors.menu_version` | `bump_version_for_*` triggers | 5 triggers, 2 hops deep, `FOR EACH STATEMENT` |
| Item sheet | `menu_items`, `menu_item_sizes`, `item_options`, `option_choices` | — | `pricing_mode` fixed\|sized; `min/max_selections`; negative modifiers |
| Sold-out badge | `menu_items.stock_count` | `private.compute_quote` | `NULL` = unlimited, `0` = out of stock |
| Vendor minimum | `vendors.minimum_order_value` | `quote_order_v1` → `rejections` | per-vendor floor; no component in §6 |
| Cart line | `carts`, `cart_items` | — | one active cart; `md5(selected_options::text)` line identity; **no writer RPC** |
| Cart price | `cart_items.cached_price` | — | display-only, never submitted |
| Quote | `delivery_zones`, `delivery_fee_tiers`, `vouchers` | `quote_order_v1` | 5-min TTL + fingerprint; takes `p_delivery_type` and `p_grouping`; returns `limits`/`rejections`/`warnings` |
| Delivery type / grouping | `orders.delivery_type`, `orders.delivery_grouping` | `quote_order_v1(p_delivery_type, p_grouping)` | `delivery|pickup` and `together|separate` — two checkout controls with **no screen in §5**, and no vendor pickup flag (§11.9) |
| Delivery fee display | `delivery_zones` | `private.compute_quote` | distance to **furthest** vendor; multiplier by vendor count |
| Place order | `orders`, `sub_orders`, `order_items` | `place_order_v1` | `UNIQUE (order_id, vendor_id)`; `orders_total_consistent` CHECK; payment_method **+ payment_channel** |
| Price-changed | — | `place_order_v1` → `PRICE_CHANGED` | itemised diff payload; consent moment |
| Order list tabs | `orders.status` | `private.recompute_order_aggregates` | most-terminal-wins; 8 derived branches, CHECK allows a 9th (`delivering`) that is never emitted |
| Order detail | `sub_orders`, `order_items` | — | sub_order is the grouping unit; items frozen, `ON DELETE SET NULL` |
| Tracking | `delivery_assignments`, `riders_public`, `order_eta_snapshots` | — | view exposes 8 columns only; ETA swept at 24h; **no live-position source** |
| Cancel | `sub_orders` | `cancel_order_v1` | `cancellation_actor` distinguishes vendor `rejected` from customer `cancelled`; rewrites `orders.total` |
| Review | `reviews` | — | `UNIQUE (order_id, vendor_id)`; rider rating needs a rider; **no submit RPC** |
| Voucher | `vouchers`, `voucher_redemptions` | `quote_order_v1(p_voucher_code)` | `UNIQUE (upper(code))`; `UNIQUE (voucher_id, order_id)`; **`usage_limit_per_user` + `first_order_only` need a client-visible eligibility read** |
| Favorites | `favorites`, `favorite_items` | — | two tables, two lists; **no toggle RPC** |
| Notifications | `notifications`, `notification_templates` | `claim_events_v1`, `mark_events_delivered_v1` | partitioned by `created_at`; 30-day sweep; jsonb per lang; drain is `service_role` only; `read_at` unwritten |
| Driver online | `riders.status` | — | `is_online = (status <> 'offline')` CHECK — never write it; **and nothing can write `status` either** |
| Rider link | `riders.user_id`, `riders.phone_number` | — | nullable FK, `ON DELETE SET NULL`, phone UNIQUE |
| Shifts | `driver_shifts` | — | GIST **EXCLUDE** overlap, `DEFERRABLE … DEFERRED` → fails at COMMIT; **no writer RPC** |
| Location | `rider_location_pings` | — | `recorded_at` may be +5 min; location is all-or-nothing; **no writer RPC** |
| Trip queue | `delivery_assignments` | `claim_order_v1` | one active trip per **order** (unique); nothing constrains a rider to one |
| Trip stops | `delivery_assignments.stop_sequence` | `private.trip_distance_km` | ordered jsonb array; distance walked from it |
| Pay display | `delivery_assignments.rider_pay_*` | `claim_order_v1` → `has_pay_rule` | frozen at claim; no rule ⇒ pay 0, platform takes 100% |
| Cash collection | `riders.cash_held`, `ledger_entries` | `begin_collection_v1`, `collect_cash_v1`, `collect_wallet_v1` | tri-state CHECK; `max_cash_held` gate; 6 method×channel combinations; `UNIQUE` idempotency |
| Complete | `delivery_assignments`, `sub_orders` | `complete_delivery_v1(p_proof_path, p_lat, p_lng)` | proof upload + GPS, then → `delivered` / `settlement_status = payable` |
| Rider earnings | `wallets`, `ledger_entries` | `get_wallet_balance_v1`, `get_rider_earnings_v1` | balance is a cache; **`drift` must surface** |
| Payouts | `payouts`, `payout_lines` | `run_payout_v1` (admin) | rider-readable; `draft→approved→processing→paid`; **no route in this document** |
| Float | `riders.cash_held` | `effective_cash_limit_v1` | warning at `rider_cash_limit_warning_pct = 80` |
| Platform float | `platform_float` | `get_platform_float_v1`, `reconcile_day_v1` | both policies `is_admin()` — **admin-web only, not a rider widget** |
| Settings | `settings`, `feature_flags` | `get_flags_v1(p_app_role, p_app_version)` | `feature_flags.value_type` + `targeting_rules`; typed parsing |
| Push | `device_tokens` | `register_device_token_v1(p_token, p_platform, p_app_role, p_app_version)` | `UNIQUE(token)` — reinstall moves, not duplicates; **collides for a dual-role user** |

---

## 8. The constraints that force specific UI

This is the section worth arguing about in design review. Each row is a place where the obvious implementation is wrong.

1. **No optimistic writes anywhere — and for eight table groups, no writes at all.** All 115 policies are `FOR SELECT` and `authenticated` holds SELECT + EXECUTE and nothing else, verified across all 52 tables. But SELECT-only is not the same as *reachable*: for the tables below, **no function in the database writes them**, so the client has no path, not a restricted one.

   | Table group | No RPC exists to… | Blocked |
   |---|---|---|
   | `carts` / `cart_items` | create a cart, add, change qty on, or remove a line | route 17, sheets 1–3, **all of P2** |
   | `addresses` | create, edit or delete an address | routes 19, 20, 35 — and `quote_order_v1(p_address_id)` needs one to exist |
   | `reviews` | submit a review | route 29, `ReviewComposer`, `useReviews` |
   | `favorites` / `favorite_items` | add or remove a favourite | route 36 reads fine, but nothing can be favourited |
   | `driver_shifts` | create or edit a shift | D4, D5 — so D5's EXCLUDE analysis is about an unreachable write |
   | `rider_location_pings` | report a position | D7, D8, `useLocationPing`, `LocationPingIndicator`, `StaleLocationWarning` — **and customer live tracking has no source** |
   | `riders.status` | go online or offline | D3 |
   | `notifications.read_at` | mark a notification read | S1 |

       `quote_order_v1` only `UPDATE`s an existing `carts` row, and `touch_cart_from_new_rows` is a trigger waiting for an insert that never arrives. Treat each of these as a **schema gap that needs a `security definer` RPC**, not a UI problem — `add_to_cart_v1`, `upsert_address_v1`, `submit_review_v1`, `toggle_favorite_v1`, `set_shift_v1`, `report_location_v1`, `set_my_status_v1`, `mark_notification_read_v1`. Everything else in this document assumes they exist.

2. **Every failure is a Postgres code.** `PRICE_CHANGED`, `PROFILE_INCOMPLETE`, `OUT_OF_STOCK`, `AUTH_REQUIRED`, `RIDER_REQUIRED`, `FOREIGN_KEY_VIOLATE` (from the trigger-based polymorphic checks), and the cash-limit rejections. Build a code→copy→CTA map as a first-class module, not ad-hoc `if`s in screens. And remember that `quote_order_v1` refuses in a **200 response** through `rejections`/`limits`/`warnings` (§5.18).
3. **Retry is safe.** `UNIQUE` idempotency keys on `orders`, `ledger_entries`, `payouts`. A retried RPC is a no-op. So a request that failed *after* the DB committed must be retryable with the same key and must not double-apply. The submit button's idempotency key lifetime is a product decision, not just an implementation detail.
4. **Deferred constraints fail late.** Five triggers are `DEFERRABLE INITIALLY DEFERRED` and fire at COMMIT. Two of them (`trg_item_still_sized`, `trg_item_has_sizes`) would be *provably useless* if checked immediately. For the client this means: an RPC can return success and the transaction still aborts. Treat "no error returned" as provisional for these paths, and reconcile on the next read.
5. **Roles are live, not cached.** `user_roles.revoked_at` means a role can disappear while the app is backgrounded. Re-resolve roles on resume; don't gate the UI on a cached role array.
6. **Bilingual is layout, not copy.** Arabic is RTL, the catalogue is trigram-searched over normalized columns maintained by the DB, promo copy and notification bodies are jsonb per language, and templates are rows not columns. One provider at root, `forceRTL` on switch, and a lint rule that hard-fails a hardcoded direction anywhere in the tree.
7. **The customer never sees the `riders` table.** Eight columns, through a view. If a design mock shows a customer's live map pinning the rider's device GPS, that data does not exist for them. Live tracking must be built from assignment progress + ETA snapshots, with an explicit staleness affordance.
8. **Zero-pay is a real, documented state.** `private.pay_rule_for()` has three branches and the third is "no rule → rider earns 0, platform takes 100% of the delivery fee". Build the screen; it is the launch configuration.
9. **`partially_cancelled` has no writer.** It is computed. No optimistic client logic will ever produce it correctly, because it depends on every sub_order reaching a terminal state. Render what the DB says, always.
10. **The cart has no total.** `carts`/`cart_items` carry `cached_price` for display only. If the cart screen shows a "Total", it must be labelled as an estimate — the authoritative number first appears at `quote_order_v1`.
11. **A dual-role user cannot register one push token.** `device_tokens` is `UNIQUE(token)`, but `register_device_token_v1` takes `p_app_role`, and a single install has a single FCM/APNs token. A device that has been both customer and rider collides on its second registration. Decide whether the token row is per-role or per-user before P0 freezes the boot sequence — this is the one place where "role switch is a view change" (§1) is not free.
12. **The rider's own state has no write path at all.** See §3.6. `status`, shifts and position are read-blocked *and* write-blocked, so the driver half of this document is a specification waiting on six functions.

---

## 9. Non-UI modules

### Hooks (35)
`useAuth` · `useSession` · `useRoles` · `useProfileGate` · `useLanguage` · `useIsRTL` · `useVendorMenu` (`menu_version` cache) · `useVendorAvailability` (schedules + holidays **+ `is_open`/`auto_open`/`is_busy`** merged) · `useStockState` (the `NULL` rule) · `useVendorMinimum` (`minimum_order_value` per sub_order) · `useCart` · `useCartLineIdentity` (`md5` of selected options) · `useQuote` (TTL + countdown **+ `limits`/`rejections`/`warnings`**) · `usePlaceOrder` (idempotency key holder) · `useOrders` · `useOrderDetail` · `useOrderStatusTabs` (the 8 derived branches) · `useLiveTracking` · `useReviews` · `useVoucherValidation` (`usage_limit_per_user`, `first_order_only`, `applies_to_vendor_ids`) · `useAddresses` · `useFavorites` (two lists) · `useNotifications` · `usePushToken` · `useDriverProfile` · `useRiderStatus` · `useShifts` (overlap pre-check) · `useLocationPing` (staleness-aware) · `useActiveTrip` · `useTripStops` (walks jsonb) · `useCashCollection` (`can_collect_cash`, method × channel) · `useWalletBalance` (balance + drift) · `usePayouts` (D17/D18) · `useDeliveryProof` (R2 sign + upload) · `useFeatureFlags` (`get_flags_v1(p_app_role, p_app_version)`)

The last three are for surfaces this re-verification added. `useCart`, `useReviews`, `useAddresses` and `useFavorites` are all **write-blocked** (§8 rule 1) and should be built as thin read wrappers until the RPCs exist.

### Services (22)
`supabase/client` · `supabase/auth` · `rpc/quote` · `rpc/orders` · `rpc/delivery` · `rpc/cash` · `rpc/money` · `rpc/notifications` · `queries/vendors` · `queries/menu` · `queries/orders` · `queries/rider` · `mapper/errors` (code→copy) · `format/money` (piastres) · `format/bidi` · `format/eta` · `format/distance` · `device/push` · `device/location` · `device/geo` (geohash + area resolve) · `device/calls` (tel: to customer & rider) · `cache/menu` (`menu_version` keyed)

Three services this list now needs and does not have: **`rpc/feed`** (`get_vendor_feed_v1` + `search_catalog_v1`, which replace the raw table reads above), **`rpc/flags`** (`get_flags_v1(p_app_role, p_app_version)`), and **`storage/sign`** (the R2 signer round trip that `p_proof_path`, `signature_path` and `users.avatar_path` all require). `device/location` is currently write-blocked (§8 rule 1) and should be built against the missing `report_location_v1` signature rather than left out.

### Store slices (9)
`session` · `roles` · `language` · `address` (selected) · `cart` (server-mirrored) · `quote` (transient) · `rider` (status, float) · `trip` (active assignment) · `flags`

### Type modules (17)
Mirroring `schema/00…19` — one per domain: `geo` · `platform` · `identity` · `vendors` · `catalog` · `cart` · `orders` · `delivery` · `money` · `engagement` · `ops` · plus `rpc` (**19 client-callable signatures**, not 105 — the other 86 are trigger or `admin_*` internals), `enums` (the `text` + CHECK closed sets, hand-written — the schema has **no enums**, so these types are the app's only guard), `navigation` · `i18n` · `theme` · `api`.

`types/enums.ts` now has to carry **ten** assignment states, not nine — `unassigned` was the omission, and a missing `'unassigned'` in a `switch` is a blank button on the queue screen.

**On the missing enums.** The schema uses `text` with `CHECK (col = ANY (ARRAY[...]))` throughout, deliberately, so that adding a vertical or a channel is a migration rather than an `ALTER TYPE` that can invalidate a running client. The cost lands on the app: nothing stops a typo'd status string at compile time. Hand-write the closed sets in `types/enums.ts` and derive them from the CHECK lists — that is where the database's flexibility becomes your type safety, and it's the only place.

---

## 10. Suggested build order

| Phase | Scope | Routes | Why here |
|---|---|---:|---|
| **P0** Foundation | Boot, sign-in, profile gate, i18n/RTL, role split, primitives, push token, **the 8 missing write RPCs** | 1–7, S3 | Nothing else is testable without role resolution, RTL, **and a cart you can write to** |
| **P1** Browse | Home, search, cuisines, storefront, item detail | 8–16 | Read-only, low risk, validates the `menu_version` cache |
| **P2** Cart | Cart, customization sheets, sold-out rules | 17 + sheets 1–3 | **Blocked** — no cart write RPC. Write `add_to_cart_v1`/`update_cart_item_v1`/`remove_cart_item_v1` first, or move the phase behind P0 |
| **P3** Checkout | Quote, countdown, review, place, price-changed | 18–23 | The fingerprint contract is the highest-risk logic in the app |
| **P4** Orders | List, detail, tracking, cancel, review, receipt, repeat | 24–32 | Derived status and sub_order grouping; needs address + review writers |
| **P5** Account | Addresses, favorites, notifications, settings | 33–37, S1–S2 | **Blocked** — no address or favourite writer. The two-lists trap and the 30-day floor stand, but the writes need RPCs |
| **P6** Driver core | Onboarding, online toggle, shifts, job queue, claim | D1–D6 | EXCLUDE constraint, nullable `riders.user_id`, **and three missing writers** (status, shifts, rider self-read) |
| **P7** Driver trips | Stop list, navigate, status actions, complete/fail | D7–D12, D9 | The core operational loop — plus proof upload and GPS, which `complete_delivery_v1` requires |
| **P8** Driver money | Cash collection, float, earnings, ledger, vehicle, **payouts** | D10, D13–D18 | **Ship last** — highest consequence, needs P7 telemetry; D17/D18 are new in this version |
| **P9** Harden | Offline states, permission denial, RTL QA, error-code sweep | all | 115 policies, 19 client RPCs, 2 languages |

**A third opinion, and it gates everything above: eight table groups have no writer at all (§8 rule 1).** P0 should include the missing RPCs, not just the shell. Until they exist, P2, P5 and P6 are building screens against tables the client cannot write, which is the most expensive possible way to discover a schema gap — and it will not be discovered by a typecheck, only by a rider tapping "add to cart" and nothing happening.

---

## 11. Open questions this inventory assumes an answer to

1. **Language default and whether it follows the device.** The column is `users.preferred_language`, not `users.language`. Half the answer is already in the model: `settings.platform_name_ar` is described as "the default everywhere, because Arabic is the primary market language" — so Arabic-first is the documented posture, and what is left is whether a device locale may override it on first run.
2. **Does the driver have to be a customer too?** If yes, the role switcher ships in P0 rather than P5. If no, `user_roles` still permits both rows and the app must handle the user who acquires the second role later. See §11.7, because the answer is no longer free.
3. **Is `stop_sequence` ever edited after dispatch?** The model says no writer, but a vendor rejecting a sub_order changes the optimal route. If dispatch re-sequences, the trip screen and the map need a re-render contract.
4. **Which collection paths are live?** `collection_method IN ('cash','wallet','none')` × `collection_channel IN ('cod','vodafone_cash','instapay')` is six combinations, and `collect_wallet_v1` already exists for the wallet ones. So the collection sheet is a form either way; what is undecided is which channels ship at launch and who supplies the `collection_reference`.
5. **Is there a vendor app in scope later?** `vendor_staff` links users to vendors and RLS already scopes reads for them — and `get_vendor_dashboard_v1`, `get_vendor_earnings_v1` and `transition_order_v1` confirm a vendor client is designed for. If a vendor tablet is coming, the customer screen set is a subset of a three-role app and some primitives will be reused — worth knowing before P0 freezes the component API.
6. **How is the rider's own row exposed?** See §3.6. `riders` has exactly one policy, `riders_admin_read`, so a rider has no read path for `status`, `cash_held`, `max_cash_held` or live position — and no write path for `status` either. This blocks P6 and needs a decision, not an implementation.
7. **Can a dual-role user register one push token?** `device_tokens` is `UNIQUE(token)` while `register_device_token_v1` takes `p_app_role`, and one install has one FCM/APNs token. On a device that has used both roles the second registration collides. P0 question, not a P9 one.
8. **What gates a force-update?** `get_flags_v1(p_app_role, p_app_version)` is version-scoped and `feature_flags.targeting_rules` is jsonb, but there is no `min_app_version` settings row and `semver_gte(a,b)` has nothing to compare against. Either add the key or drop the gate from the design — right now "you must update to continue" has no configuration behind it.
9. **How does a vendor opt into pickup?** `orders.delivery_type IN ('delivery','pickup')` and `quote_order_v1(p_delivery_type)` exist, but `vendors` has no pickup flag — no `supports_pickup`, no pickup fee, no pickup ETA. The order side of pickup is designed; the vendor side is not.
10. **What is `payment_method = 'wallet'` on an order?** `orders.payment_method IN ('cash','wallet')` and `payment_channel` allows `vodafone_cash`/`instapay`/`gateway`, while `wallets.owner_type` is limited to `('vendor','rider')` and there is no customer wallet anywhere. Either it is dead schema, or there is a payment path this inventory has no screen for and no way to reconcile.
11. **What happens to a deactivated account?** `users.is_active` and `users.deleted_at` exist, and a signed-in user whose row goes inactive or soft-deleted has no screen in §2 — no "account suspended", no delete-account flow, no forced sign-out on next resume. §8 rule 5 covers role revocation; this is the same problem one layer down.
