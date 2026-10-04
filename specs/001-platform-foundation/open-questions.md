# Open Questions — Spec 001

Unresolved items. This file exists so that undecided decisions stay visible instead of becoming
silent assumptions in code. **Adding a table, a fee rule or a payment path that is not answered here
is a bug in the spec, not initiative.**

Status: ⬜ open · 🟡 in progress · ✅ resolved (move to `decisions.md`)

---

## 1. Infrastructure

| # | Item | Status | Note |
|---|---|---|---|
| 1.1 | Supabase project `marketak` | ✅ | ref `erxxsebcqqcpkipzcdhg`, region `eu-central-1`, ACTIVE_HEALTHY, Postgres 17.11 |
| 1.2 | Supabase project_ref | ✅ | `erxxsebcqqcpkipzcdhg`. **Not yet written into the MCP URL** — see §1.7 |
| 1.3 | Firebase project | ✅ | `marketak-eg` (`marketak` was taken globally), number `283007295790` |
| 1.4 | R2 buckets | ✅ | `marketak-public` + `marketak-private`, `EEUR`. R2 enabled with a payment method |
| 1.5 | Cloudflare custom domain | ⬜ | Required for `cdn.`, `track.`, `admin.` and `vendor.` hosts. **Blocked on a domain purchase** — see §2.1 |
| 1.6 | ~~Does R2 require a payment method?~~ | ✅ | Yes. Set at enablement. ~$0/month at our volume |
| 1.7 | Scope the Supabase MCP | ⬜ | Unscoped it can touch every project in the account. Add `?project_ref=erxxsebcqqcpkipzcdhg` plus a read-only variant — recipe in `ENVIRONMENT.md` §4.3 |
| 1.8 | Android app package name | ✅ | `com.jaylak.mobile`. Note the root is `jaylak`, **not** the brand — the store listing is under your personal developer account |
| 1.9 | Register Android + iOS apps | ✅ | Android `…:android:e74edad733ca1550a55abf`, iOS `…:ios:6861ceffc5b2d0e3a55abf` |
| 1.10 | Android SHA-1 / SHA-256 | ⬜ | Add once the release signing cert exists. Not needed for FCM; needed for App Check |
| 1.11 | APNs key | ⬜ | **Blocked on an Apple Developer account.** Without it iOS gets no push at all |

---

## 2. Blocked on external accounts or purchases

| # | Item | Status | Note |
|---|---|---|---|
| 2.1 | Domain name | ⬜ | Needed for the CDN and the tracking host. A domain is the only unavoidable cash cost |
| 2.2 | Apple Developer account | ⬜ | iOS push through FCM requires an APNs authentication key uploaded to the Firebase console. Without it, iOS gets **no push notifications** |
| 2.3 | Production billing | ⬜ | Firebase is on the free Spark plan with no payment method. Adding one is optional |
| 2.4 | Mapping / geocoding provider | ⬜ | Location currently needs only latitude and longitude, so no provider is required yet. A free tier will not have a commercial SLA — acceptable while live tracking is off |

---

## 3. Product decisions not yet made

| # | Question | Status | Why it matters |
|---|---|---|---|
| 3.1 | What is the domain? | ⬜ | `cdn.<domain>`, `track.<domain>`, `admin.<domain>`, `merchant.<domain>` |
| 3.2 | Will `delivery_grouping = 'separate'` ever ship? | ⬜ | Modelled but not built. Deciding it now affects whether the fee formula needs a per-vendor branch |
| 3.3 | Vendor cancellation compensation rule | ⬜ | ADR 1 allows vendor rejection. Who absorbs the cost when a vendor cancels after `preparing`? Currently unspecified |
| 3.4 | Is `free_radius_km` measured from the vendor or the zone centroid? | ⬜ | Changes the fee for the same address depending on which vendor is ordered from. Zone centroid is simpler and fairer; vendor radius is more realistic |
| 3.5 | Does the rider `bonus_per_leg` exist at launch? | ⬜ | Rewards multi-vendor trips, which are harder. Costs margin on exactly the baskets the platform wants to encourage |
| 3.6 | Lunch capacity: what happens when a vendor is over `capacity_per_slot`? | ⬜ | Hide the vendor, or accept with a longer ETA? Affects revenue and customer trust differently |
| 3.7 | Should a partially-rejected order auto-remove the vendor, or always ask? | ⬜ | Auto-removing loses basket value silently. Always asking adds friction at the worst moment |
| 3.8 | Minimum order across the whole cart, or per vendor only? | ⬜ | Per-vendor only is implemented. A cart-wide minimum would raise the average basket but add a failure mode |
| 3.9 | **Styling: plain `StyleSheet` + a `src/theme/` token module, or NativeWind?** | ✅ **Plain `StyleSheet` + `src/theme/` tokens.** One fewer dependency, no Babel step, and a token module satisfies "zero inline styling" on its own. The `design-system` skill's token-extraction discipline and 10-dimension audit apply; its CSS-custom-property output does not, because this is React Native. Task T0.1d |
| 3.10 | **Is `rider_location_pings` partitioned from the start, or only once volume justifies it?** | ✅ **Keep the table in migration `008`, plain and unpartitioned.** Resolved by decision, not by the spec being consistent — it was not. `data-model.md` §8 said "partitioned by month **when volume justifies it**"; §14.1 and task T0.2c said it partitions by month so retention is `DROP TABLE`. The mechanical consequence is real: a partitioned table's unique constraint must include the partition key, so the specced `bigserial primary key` **fails outright** on a partitioned table and would have to become `(recorded_at, id)`.<br><br>**Why plain wins.** Nothing writes to this table until Phase 8 — ADR 9 defers the ping loop, and `contracts.md` defines no RPC that inserts a location row; the writer is the Durable Object. Volume is therefore zero, which is exactly the condition §8 named. And the choice is asymmetric: adding partitioning later to an **empty** table is a cheap migration, while removing it from a populated partitioned table is not.<br><br>**The table is kept deliberately, for future work.** Traced to ADR 9 ("described as optional"), `spec.md` FR-C-11 ("driver location **when live tracking is enabled**"), and `free-tier-plan.md` §7's explicit "keep `rider_location_pings` and the DO schema so activation is configuration". Worth recording what that last claim is and is not: the flag and the app-side ping loop *are* configuration, but a Postgres table is not — it is a migration. That is the only reason it sits in `008` rather than the Phase 8 migration.<br><br>**Scope it deliberately, so it is not built by accident.** `riders` already carries `current_latitude`, `current_longitude`, `current_geohash` and `last_location_at`, which is sufficient for "where is my rider right now". `rider_location_pings` exists only for the **breadcrumb trail** — `data-model.md` §14 gives its purpose as "rider trip replay", `spec.md` §9 gives it 30-day retention. So Phase 8 can ship a live map with `riders` alone if the trail is not wanted. At 4.0 KB/order it is the single largest line in the free-tier budget (`free-tier-plan.md` §3.2) and §8 itself calls it "the first candidate for removal if the database ever gets tight" |
| 3.11 | **What does `orders.item_count` count — dishes or order lines? And where does the per-sub-order count come from?** | ✅ **Hole 1: `item_count` means DISHES — `sum(quantity)`, which is what `007b` already applies and verifies.** Chosen on meaning, not on speed: the one stated consumer is a kitchen, and a prep line reads "3" off a ticket listing three dishes, not "2". It also matches how customers count. Worth being straight about the reasoning, because the stated criterion was minimum compute and compute does **not** decide this one: `sum(quantity)` and `count(*)` are both aggregates over the same handful of rows, and `count(*)` is marginally cheaper since it can be served index-only. The difference is one column fetch and is not a performance argument. The two *scopes* differ — a customer sees the whole order, a vendor sees their sub-order — while the *unit* agrees, which is what makes one definition serve both.<br><br>**Hole 2: no column added — the count is computed on demand.** This reverses the recommendation made when the question was raised. A cached `sub_orders.item_count` costs a permanent write on every order line forever, to save an aggregate that `order_items_sub_order_id` already serves as an index range scan over a few rows. On minimum total compute, on-demand wins, and it adds no column that could drift out of step with `order_items`. `contracts.md`'s `vendor.new_order` push is generated by an RPC, so the RPC computes it. **Hole 2 therefore needs no migration at all** — the "no column to read from" problem dissolves once the count is derived at read time rather than stored |
| 3.12 | **Should `notifications.type` be constrained to the push catalogue?** | ✅ **Resolved as option (a') — the RPC validates against `notification_templates`, and the templates are now seeded.** Shipping `011s` and `011t`. A `CHECK` listing the 19 keys was rejected on maintenance cost rather than principle: it freezes 19 keys into the schema, so the 20th notification type costs a migration and turns a copy change into a deployment. Checking against `notification_templates` keeps the catalogue in the database where the templates already live, so adding a key is an `INSERT` — which is exactly what `011s` did for all 19. `private.notification_type_exists(text)` is the lookup `016`–`020` will call; it honours `is_active`, so deactivating a template for one language leaves the notification valid through the other and only invalid once every language is off. Deliberately **not** a foreign key: templates are unique per `(key, channel, lang)`, so there is no single row for `notifications.type` to reference — that would be option (c) and is more schema than a stable catalogue is worth.<br><br>**A prerequisite was missing and is now fixed.** `notification_templates` had been **empty since `010` created it**, and nothing in §15.2 would ever have populated it — so nothing could render a notification at all. `011s` seeds all 19 keys × ar/en = 38 rows, with `contracts.md`'s placeholders exactly. **The Arabic is a first draft and wants review** by someone who writes Arabic customer-facing copy; it is correct MSA and every row is correctable with an `UPDATE` and no code change, which is the point of rows over constants |
| 3.13 | **`riders` duplicates the user's name and phone — should it?** | ⬜ Found by a normalization audit of 001–010. `riders.first_name`, `last_name` and `phone_number` restate what `users` already holds, and `users.phone_number` is UNIQUE while `riders.phone_number` is a *separate* UNIQUE — so the same number can exist in both, and the two can drift. Nothing keeps them equal. The columns cannot simply be dropped, because `riders.user_id` is nullable by design (a rider can be onboarded by an admin before ever signing in). Options: **(a)** keep both and add a trigger that copies `users.phone_number` into `riders` when `user_id` is set, so drift is impossible but admin-onboarded riders still work; **(b)** make `phone_number` live only on `users` and require linking before a rider can be created, dropping the admin-onboarded path; **(c)** leave it. (a) is the smallest change that removes the drift risk |
| 3.14 | **Four polymorphic columns have no referential integrity at all** | ✅ **Resolved in `011a` — option (a), a trigger per table.** A `BEFORE INSERT OR UPDATE` trigger on `wallets`, `payouts`, `ledger_entries` and `commission_rules` resolves the discriminator and verifies the target row exists, raising `23503 FOREIGN_KEY_VIOLATE`. This is the pattern already proven by `cart_items.vendor_id` in `006` and `order_items.order_id` in `007`, and it closes the same class of hole that `effective_cash_limit_v1` was. Four small static-`EXISTS` functions rather than one parameterised helper, because a helper would need dynamic SQL to map the discriminator to a table name and that puts an interpolated identifier into `EXECUTE`. Cost is one primary-key lookup per insert, which is not measurable against the write path. The error message is deliberately generic so it cannot be used to enumerate ids. See **Fixed** for a silent-data-loss bug in the first attempt |
| 3.15 | **`notifications` and `rider_location_pings` use `bigserial` — keep it or move to UUID?** | ✅ **Keep `bigserial` — reversing the recommendation I made when raising this.** Neither half of the original reasoning survived contact with the schema. The *security* half is worth nothing here: nothing has a foreign key to either table, both are reached by `(user_id, created_at)` or an age sweep, and an RLS policy filters on `user_id` regardless of which id a caller supplies. A sequential id in a URL grants nothing a uuid would not, unless some future RPC exposes a row by id *without* a user filter — which is an RPC bug, not an id-scheme problem, and migration `014`'s policies are the control that actually matters. The *performance* half is real and points the other way: uuid is 128 bits against bigint's 64, so every index roughly doubles, and these are the highest-volume prune targets in the database (6 rows/order and 20 rows/order). Paying that forever to defend against an attack that does not apply is the wrong trade. `rider_location_pings` also receives zero rows until Phase 8 |
| 3.16 | **`vouchers.applies_to_vendor_ids` is a `uuid[]` — convert to a join table?** | ✅ **Keep the array.** The measurement in `011` stands: GIN on `uuid[]` is accepted by Postgres 17 and is used — `EXPLAIN (FORMAT JSON)` shows `Bitmap Index Scan` for both `&&` and `@>` — so `data-model.md` §16's stated reason, "JSON arrays cannot be indexed", does not hold here the way it did for `vendors`. What remains unindexable is the `= '{}'` branch meaning *all vendors*, and a join table would fix the half that already works while needing a sentinel convention for the half that does not. A wrong sentinel silently hides a voucher from every vendor or shows it to every vendor, which is worse than a scan. With tens of vouchers rather than millions, that scan is free forever, so the trade is a permanent index-size cost against a cost that will never be paid. `vouchers.applies_to_vendor_ids` and `driver_shifts.area_ids` both stay as arrays |

---

## 4. Unverified assumptions

Each of these is modelled, not measured. Re-check before trusting any of them for a quarter.

| # | Assumption | Verify by |
|---|---|---|
| 4.1 | Row and index sizes within 2× of the model | `pg_total_relation_size` after 1,000 real orders |
| 4.2 | Free-plan CPU survives a lunch peak | Load test 100 concurrent `place_order_v1` through the peak window |
| 4.3 | 2.9 KB/order after archiving holds | Same as 4.1 |
| 4.4 | PostGIS availability on `eu-central-1` | ✅ **Resolved.** Available, 3.3.7. The design still uses geohash and does not need it |
| 4.5 | DO memory bills at 128 MB for SQLite-backed objects | Dashboard, before enabling tracking |
| 4.6 | Frankfurt latency acceptable against a 900 ms p95 | Measure. **If it fails, migrate regions early — it is not a toggle** |

---

## 5. Explicitly deferred, not decided

Recorded so they are not mistaken for oversights.

| # | Item | When it returns |
|---|---|---|
| 5.1 | Live rider tracking | Phase 8, flag default off. Affordable at ~500 orders/day, unaffordable at 2,000 |
| 5.2 | Payment gateway integration | Extension point in `plan.md` §8. Adds a third `payment_channel`; does not replace cash or direct transfer |
| 5.3 | Loyalty / subscriptions | Not specced |
| 5.4 | Scheduled / recurring delivery | Not specced |
| 5.5 | Split delivery to multiple addresses | Explicitly rejected; one checkout is one address |
| 5.6 | Multi-branch vendors | Rejected for v1. A chain is N vendors sharing a `brand_id` |
| 5.7 | Ads / banner revenue | Slots modelled, unsold |
| 5.8 | Push funding | Not an option in v1. Notifications are transactional only |

---

## 6. Known gaps in this spec

| # | Gap | Impact |
|---|---|---|
| 6.1 | **Migration `.sql` files exist for 001–007b only.** 005, 006 and 007 were extracted from this document and applied; 005a–005e, 007a and 007b are forward fixes written after auditing what ran. The DDL is **still** the source of truth in `data-model.md`, and it has drifted from the applied migrations in at least four places — `orders.status` is documented as "derived, never set directly" when nothing derived it until `007`, `sub_orders.sequence` is documented with a `default 1` that `007` deliberately removed, none of `007`'s money CHECK constraints appear in this document, and `order_eta_snapshots` is specified in §6 and §15.2 but has never been created. Task **T0.1a** closes the remaining 008–022. `scripts/check_schema_drift.py` detects this class mechanically |
| 6.2 | No seed data script | T0.9 |
| 6.3 | No `.gitignore` | Must exist before the first commit |
| 6.4 | No CI | pgTAP policy tests in migration 022 are meant to fail the build; nothing runs them yet. `scripts/check_schema_drift.py` reports spec-vs-database drift but is **not yet wired to fail a build** — no baseline has been agreed, so it is advisory |
| 6.5 | No human review of this spec | It is authored, not approved. Treat every number as a proposal |
| 6.6 | RLS policies are described, not written | Migration 014 |
| 6.7 | RPC bodies are not written | Migrations 016–020 |
| 6.8 | `vendors.reject_rate` and `audit_log` are in the schema with no stated use | Remove or specify |