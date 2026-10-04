# Changelog

All notable changes to Marketak. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is not yet meaningful — there
is no released version, and the schema is still pre-review.

## [Unreleased]

Nothing shipped. This project is specification-only.

### Added

- **Platform specification** for a one-city, lunch-first delivery platform on Supabase +
  Cloudflare + Firebase. Eight documents: constitution, spec, decisions, data-model, contracts,
  plan, free-tier-plan, tasks, open-questions.
- **Multi-vendor checkout model.** One `orders` row plus N `sub_orders`. Order items belong to a
  sub-order, never to an order. This is the requirement the whole schema is shaped around.
- **Configurable delivery fee.** `base × multiplier(vendor_count)` plus a distance component.
  Tiers seed at ×1.00 / ×1.10 / ×1.20 for 1 / 2 / 3 vendors, stored in basis points. Maximum
  vendors per cart is 3, from `settings`. No fee constant appears in code or in a function body.
- **Phased revenue model.** Launch revenue is a cut of the delivery fee taken from the rider.
  Vendor commission on items and a customer service fee exist as inactive rows, activated by an
  `update` around month 3–4. `effective_from` prevents retroactive application.
- **No customer wallet.** The customer pays the rider directly in cash or by Vodafone Cash /
  Instapay. Wallets exist for vendors and riders only. Chosen for money integrity: it removes the
  entire top-up fraud surface and all customer float.
- **Two-phase checkout.** `quote_order_v1` reprices and returns a 5-minute fingerprint;
  `place_order_v1` reprices inside the transaction and aborts with `PRICE_CHANGED` plus an
  itemised diff. The offline cache is display-only and can never produce a wrong charge.
- **Append-only ledger** with Postgres rules forbidding `UPDATE` and `DELETE`. Corrections are
  reversing entries. Money is integer piastres.
- **Free-tier longevity plan.** Byte-level model of every cap, three retention scenarios, a ranked
  list of 14 levers, and a named upgrade trigger: Postgres over 350 MB, or cumulative orders over
  ~40,000, or the first real cash in the system.
- **Agent skills** — 16 Cloudflare, 13 Firebase, 2 Supabase. Relevance recorded in
  `ENVIRONMENT.md` §5.
- **MCP servers** — Cloudflare (API, docs, bindings, builds, observability), Supabase, Firebase.
  All connected and authenticated.

### Infrastructure

- **Supabase project `marketak`** created — ref `erxxsebcqqcpkipzcdhg`, region `eu-central-1`
  (Frankfurt), Postgres 17.11, free plan, `ACTIVE_HEALTHY`. Extensions verified available
  including `pg_tap`, so the RLS policy tests are runnable rather than theoretical.
- **Firebase project `marketak-eg`** created (number `283007295790`) and set active. `marketak`
  was already taken as a global Firebase project id.
- **Firebase apps registered** for Android and iOS under bundle/package `com.jaylak.mobile`.
- **R2 enabled.** Buckets `marketak-public` and `marketak-private` created in `EEUR`.

### Database

Migrations 001–014b written **and applied** to the live project `erxxsebcqqcpkipzcdhg`. 62 tables and
partitions, 229 indexes, 115 RLS policies, 0 tables without RLS, 0 unindexed foreign keys, 0 client
write grants, 0 grants to `anon`.

### Fixed

**`014b` — `riders` and `users` could hold different phone numbers for the same person.** Each table has
its **own independent** `UNIQUE (phone_number)`, so the same rider could be `+201000000001` in one and
`+201000000999` in the other with nothing objecting. Verified before writing: the only trigger on
`riders` was `updated_at`. ADR 20 exposes `riders.phone_number` through `riders_public` as the number
the customer calls, so on divergence the customer calls a number the rider's own account does not
show, and dispatch calls another — the customer eats the failed delivery.

The columns cannot be dropped: `riders.user_id` is nullable **by design** so a rider can be onboarded
before ever signing in. Two triggers instead, because one is not enough — a trigger only on `riders`
closes the gap at insert time and reopens it the moment an admin edits the auth profile.

**The null guard is the load-bearing detail.** Constitution 18 makes the phone "a profile field
collected after sign-in", so `users.phone_number` is NULL until the profile is completed. A plain
`SELECT … INTO new.phone_number` would have assigned NULL and **wiped a working contact number an
admin entered during onboarding**. Every field is only overwritten when the source is non-null.
Verified: a linked rider whose auth profile has no phone keeps `+202222222222` and the name
`Onboarded`; a linked rider with a complete profile inherits both.

Both triggers are `SECURITY DEFINER` — clients hold no write on `riders` at all, so without it a rider
editing their own phone would get a permission error. A collision with another rider's number **fails
loudly** on `riders_phone_number_key` rather than silently reassigning. 12 assertions, all passing,
including no-op edits leaving `updated_at` alone.

### Changed

- **Open question 3.13** resolved as option (a), confirmed by a human reviewer.
- **Open question 3.17** resolved: `search_daily_stats` stays admin-only. `012`'s `CHECK` had already
  closed the storage path; the read-side residual risk of unsalted md5 is now accepted knowingly
  rather than left dangling, and `014` makes the admin-only posture structural — the table is absent
  from the 51-table grant list.
- **Open question 3.18** resolved earlier: `rider_pay_rules` readable by admin, the named rider, and
  the city-wide default rows.
- **Open question 3.19** accepted for v1: the assigned rider can read the whole `users` row for their
  customer, `email` included. RLS cannot mask a column on an allowed row. Accepted **conditional on
  `users.email` not acquiring a use** that would make it sensitive — marketing consent or a breach list.
  The trigger to revisit is recorded, because that is the thing that would change the answer.
- **All open questions raised by `012`–`014` are now closed.**

- `001_extensions` — `pgcrypto`, `pg_trgm`, `btree_gist`, `unaccent`, `pg_partman`. PostGIS is
  available and deliberately **not** installed: area matching is geohash-prefix plus a haversine
  distance, so nothing in the schema depends on a spatial extension.
- `002_geo_and_config` — `cities`, `areas`, `delivery_zones`, `delivery_fee_tiers`, `settings`
- `002s_seed_fee_tiers` — the ×1.00 / ×1.10 / ×1.20 vendor-count tiers, as data, in a separate file
- `003_identity` — `users`, `user_roles`, `user_auth_providers`, `addresses`, `device_tokens`,
  `feature_flags`, plus the `on_auth_user_created` trigger
- `004_vendors` — `brands`, `vendors`, `vendor_areas`, `vendor_schedules`, `vendor_holidays`,
  `cuisines`, `vendor_cuisines`, `vendor_staff`, `vendor_earnings_daily`
- `005_catalog` — `menu_categories`, `menu_items`, `menu_item_sizes`, `item_options`, `option_choices`
- `005a` – `005e` — forward fixes from auditing the applied migrations: a `bump_menu_version` column
  list, seven integrity defects, a `zone_id` column corrected in the fee-tier monotonicity guard, the
  revoke pass that closed the anon read leak, and the `private` schema
- `006_cart` — `carts`, `cart_items`
- `007_orders` — `orders`, `sub_orders`, `order_items`, `order_status_history`,
  `order_modifications`
- `007a` — `sync_order_status` joined the transition table on a column that does not exist
- `007b` — `orders.item_count` could never become non-zero (see **Fixed**)
- `007c` — `order_eta_snapshots`. Declared in `data-model.md` §6 and assigned to `007` by §15.2, but
  **007 shipped without it.** Adds no constraints beyond the spec — see below
- `008_riders` — `riders`, `driver_shifts`, `delivery_assignments`, `rider_location_pings`, plus
  `effective_cash_limit_v1`
- `009_money` — `commission_rules`, `wallets`, `ledger_entries`, `payouts`, `payout_lines`,
  `platform_float`, `rider_pay_rules`, plus the `sub_orders.payout_id` foreign key that `007` had to
  leave out because `payouts` did not exist yet
- `009s_seed_revenue_config` **S** · `009t_seed_settings` **S** — data only, per §15.1 rule 1
- `010_engagement` — `reviews`, `favorites`, `favorite_items`, `notifications` (**partitioned by
  month**), `notification_templates`
- `010a` — closed a demonstrated cross-tenant read; `vendor_staff.deleted_at` (see **Security**)
- `011_growth` — `vouchers`, `voucher_redemptions`, `promo_slots`
- `011a_polymorphic_integrity` — `BEFORE` triggers so `wallets.owner_id`, `payouts.account_id`,
  `ledger_entries.account_id` and `commission_rules.target_id` cannot name a row that does not exist.
  A polymorphic column cannot carry a foreign key, so `011a` supplies the guarantee a FK would. Also
  made `ledger_entries.account_id` nullable, replacing a `CHECK` that had been vacuous.
- `011b_fix_trigger_return_value` — **fixed silent row loss.** `011a`'s `BEFORE` triggers ended
  without a `RETURN`, which in PL/pgSQL means `RETURN NULL`, which for a `BEFORE` trigger means *skip
  this row*. Every insert into those four tables was being discarded without error. Caught by testing
  rather than by reading, and recorded here because the failure mode — a write that reports success
  and stores nothing — is the kind that survives review.
- `011s_seed_notification_templates` — 19 keys from `contracts.md` §4.1–4.3 × `ar`/`en` = 38 rows.
  The table had been **empty since `010` created it** and nothing in §15.2 would ever have populated
  it, so nothing could render a notification at all. **The Arabic is a first draft and wants review**
  by someone who writes Arabic customer-facing copy; it is correct MSA, and every row is correctable
  with an `UPDATE` and no code change.
- `011t_notification_type_lookup` — `private.notification_type_exists(text)`, resolving open question
  3.12 as option (a′): the RPC validates `notifications.type` against this table rather than against
  a list frozen into a `CHECK`. A `CHECK` would make the 20th notification type cost a migration and
  turn a copy change into a deployment; against `notification_templates` adding a key is an `INSERT`.
  Deliberately not a foreign key — templates are unique per `(key, channel, lang)`, so there is no
  single row for `notifications.type` to reference.
- `012_aggregates` — `rider_earnings_daily`, `event_daily_stats`, `search_daily_stats`,
  `auth_daily_stats`, `audit_log`
- `013_events` — `events`, the outbox, **shipped unpartitioned on measured evidence**
- `014_rls` — row-level security on all 62 tables and partitions
- `014a_fix_vendor_sub_order_leak` — closes a cross-vendor leak found by testing `014`
- `014b_sync_rider_contact` — `riders` and `users` contact fields can no longer drift (open Q 3.13)

### Security

**`014` enables RLS everywhere and hands `authenticated` exactly one privilege: `SELECT` on 51 read
tables.** No `INSERT`, `UPDATE` or `DELETE` on any table for any client role — every mutation is a
`security definer` RPC, which is what makes the RPC the single place a permission decision is written
(constitution III.21). `anon` holds nothing. `service_role` has `BYPASSRLS` and is unaffected.
115 policies. Recorded as **ADR 17–20**.

**Three defects in the spec were found by testing, not by reading.** Each is reproduced in
`CHANGELOG` and asserted in the migration so it cannot be reintroduced.

**1. §13.2's helper-function pattern does not work.** The spec says to `revoke execute … from
public, anon, authenticated` on a `private` helper, then call it from a policy. That fails at runtime
with `permission denied for function f`, because a policy expression is evaluated as the role running
the query. Measured on this database:

| | Result |
|---|---|
| `REVOKE EXECUTE FROM authenticated`, policy calls it | `permission denied for function f` |
| `GRANT EXECUTE TO authenticated`, **no** `USAGE` on the schema | policy works |
| direct call to `authenticated` | `permission denied for schema` |

The control that actually blocks direct access is that `private` holds **no schema `USAGE`** for
`anon`, `authenticated` *or* `service_role` — verified false for all three. A role with `EXECUTE` but
no `USAGE` cannot name the function, cannot call it through a wrapper, and cannot reach it through
PostgREST. So `EXECUTE` **is** granted to `authenticated`, because policies need it, and the schema
stays shut. **Stronger than what §13.2 describes.**

**2. RLS does not propagate to partitions — a live leak.** Enabling RLS and a deny-all policy on the
`notifications` **parent** left every partition with `relrowsecurity = false` and **zero policies**,
verified with a throwaway partitioned table. The partitions live in `public`, which `authenticated`
may `USAGE`, so `select * from notifications_2026_10` would have returned **every notification in the
system**. Today's blanket zero-grant posture hid this, but §13.3's own
`alter default privileges` line would have exposed every partition the moment anyone added one grant.
RLS is now enabled on every partition, parent policies are mirrored onto each, and
`private.ensure_month_partition` was rewritten so partitions created by `021`'s cron job are born with
RLS and the right policy. **Verified by temporarily granting on a partition and confirming the policy
still filters** — proving the defence under the exact condition that would have exposed it. **ADR 18.**

**3. `014` leaked a co-vendor's sub-orders, and its comment claimed it hadn't.** `014` applied one rule
to the whole order subtree — `order_id ∈ visible_order_ids` — and the comment asserted this enforced
§13.1 invariant 2, "a vendor can read only its own sub-orders". It did not. `visible_order_ids`
deliberately unions "an order containing one of my vendors' sub-orders", which is right for the
`orders` row (a vendor needs the total and the delivery address) and wrong for `sub_orders`.

Measured on a two-vendor fixture where one order carries a sub-order per vendor:

```
vendor 1 staff, SELECT count(*) FROM sub_orders   ->  3   (expected 2)
  of which belonging to vendor 2                  ->  1   (expected 0)
```

So vendor 1 could read vendor 2's line items, prices and commission share for an order they were both
cooking — exactly the leak invariant 2 exists to prevent. **A comment that claims a guarantee the code
does not provide is worse than no comment, because the next reviewer trusts it.** `014a` splits the two
entitlements: `sub_orders` and `order_items` filter on `vendor_id` **or**
`private.owned_or_assigned_order_ids`, and `014a` asserts the policy shape. `order_items` was fixed in
the same migration because it carries `vendor_id` and had the identical shape — fixing one and not
the other would have kept the same leak one table over. **ADR 19.**

**4. `riders` "Public fields only" is not expressible in RLS, and the requirement was sharper than
the spec.** RLS filters rows, never columns. `riders` holds `phone_number`, `current_latitude`,
`current_longitude`, `vehicle_plate`, `cash_held`, `max_cash_held` and `user_id`; a table grant
exposes all of them and no row policy can prevent it. The specified behaviour: a **customer** sees
each rider's name, vehicle, rating and **phone number** — they pay at the door and have to be able to
call. A **rider** sees the customer's name, phone and location, but only for an order they have
accepted.

`riders` now gets **no client grant at all**, and `public.riders_public` carries the projection. The
excluded columns are unreachable rather than filtered, and `user_id` never leaves the database —
which matters because it is the key `010a`'s cash-limit leak walked. The rider→customer direction
rides on `users_read` plus the order subtree, so it ends automatically when the assignment ends.
**ADR 20.**

**Verified by switching to the `authenticated` role with real JWT claims** — 17 assertions across
customer, rider, vendor-1, vendor-2 and admin, each in a rolled-back transaction. A customer sees
1 of 2 orders, 2 of 3 sub-orders on their own order, 0 ledger rows, 0 wallets, 0 earnings rows, and the
rider's phone via `riders_public`. A rider sees the assigned order only, plus that order's customer.
Vendor 1 sees 2 sub-orders and **0** belonging to vendor 2, and vice versa. `anon` is denied
everything. `platform_float` is denied even to admin, by design — it is reachable only through an
admin RPC.

The migration also asserts its own invariants and raises rather than completing: RLS disabled
anywhere in `public`, any non-`SELECT` client grant, any grant to `anon`, a direct grant on `riders`,
or `authenticated` holding `USAGE` on `private`. **A policy set that silently omits a table is the
exact failure RLS exists to prevent, so it is checked rather than trusted.**

After `014a`: **62 tables and partitions, 229 indexes, 115 policies, 0 tables without RLS, 0 anon
grants, 0 client write grants, 0 bare `auth.uid()` in a policy.**

§15.2 assigns six tables to `012`; **five were created and one already existed.**
`vendor_earnings_daily` was built by `004`, so the list overstated the work. Worse,
`rider_earnings_daily` had **never been created at all** — `008` made `riders` and the delivery tables
but omitted it — so `012` is its first appearance and the only chance to get it right.

Six defects in §12's DDL were corrected. Three would have shipped bugs rather than annoyances:

| # | Defect | Consequence had it shipped |
|---|---|---|
| 1 | `rider_earnings_daily` had no `deleted_at` and no non-negativity `CHECK`s | A financial record that could be hard-deleted, contradicting constitution III.17 and §13 error 13, which had already ruled on this exact table shape for `vendor_earnings_daily` |
| 2 | `event_daily_stats` declared `city_id`/`app_role` nullable, then put them in the `PRIMARY KEY` | Silent `NOT NULL` promotion, so platform-wide events are impossible and the failure looks like a bug |
| 3 | `search_daily_stats.query_hash` had **no format constraint** | The column's whole stated privacy property — "the raw text is not stored" — was enforced by nothing. A rollup under time pressure could persist raw customer searches into a column called `query_hash`. Now `^[0-9a-f]{32}$`, verified to reject both Latin and Arabic raw text |
| 4 | `auth_daily_stats` listed `otp_requested` and `password_reset` | **Constitution III.18 breach.** "No email, no password, no phone OTP" — and a constraint advertising those flows invites an engineer to build the counter. Reduced to the four events Google/Apple sign-in can actually emit |
| 5 | `audit_log` used `id bigserial primary key` while §14.1 requires it partitioned | **Not suboptimal — a syntax error.** Every `UNIQUE` constraint on a partitioned table must include the partition key, the same failure `010` had to correct for `notifications`. Now `primary key (id, created_at)` |
| 6 | `audit_log.actor_user_id references users(id)` with no `ON DELETE` | Defaults to `NO ACTION`, which makes a user **permanently undeletable** once any audit row names them, including via the `auth.users` cascade. Reproduced to confirm before fixing. Now `on delete set null`: the record outlives its actor, which is the correct audit semantic |

Two performance findings, both in `audit_log`:

- **The `actor_user_id` index is not optional.** Nulling that reference on delete means finding every
  row naming the user; with no index it is a sequential scan of *every partition* on a table retained
  365 days. Added partial (`where actor_user_id is not null`, since system rows carry no actor), and
  it doubles as the admin "what did this user do" query.
- **`entity_id` deliberately gets no integrity trigger**, unlike `011a`. An audit row must outlive the
  thing it describes; a trigger rejecting a dangling `entity_id` would make deletion fail on its own
  audit trail. `before`/`after` make each row self-contained instead.

`event_daily_stats.unique_users` gained `unique_users <= count`, and carries a warning that matters
more than the constraint: an exact distinct count is **not incrementally upsertable**, so `021`'s
rollup must recompute it over the affected window rather than add to it, or it drifts upward forever.

**19 assertions, all passing**, each in a rolled-back transaction: user deletion is no longer wedged
by the audit FK; the audit row survives with its actor nulled and its snapshot intact; raw Latin and
Arabic query text are both rejected while a real md5 is accepted; `otp_requested` and
`password_reset` are both unissuable while `login_failed` works; `support` is accepted and `wizard`
rejected; `clicks > results` and `zero_result = false` with `results_count = 0` are both rejected;
`net_payout` remains unconstrained so a clawback can go negative; and all 10 rider-earnings
non-negativity checks are present.

After `012`: **61 tables and partitions, 224 indexes, 0 unindexed foreign keys, 0 unpinned
`security definer` functions, 0 client table grants.**

Open question **3.17** is new and unresolved: the md5 in `query_hash` is still brute-forceable by
anyone who can read the table. `012`'s `CHECK` closes the storage path, not the read path.

`013_events` ships `events` **unpartitioned**, amending §14.1, which lists it among the four
monthly-partitioned prune targets.

**The benchmark contradicted the recommendation.** Both designs were built on this database with
16,000 rows of realistic payload:

| | Unpartitioned | Partitioned monthly |
|---|---|---|
| Hot path — claim 50 × 200 | 6.3 ms | 6.6 ms |
| Prune one day (~1,800 rows) | 3.52 ms | **1.77 ms** |
| Reinsert 2,000 into pruned space | 32.4 ms | **22.7 ms** |
| Size incl. indexes | 7,552 kB | **7,080 kB** |
| **Peak disk at 2,000 orders/day** | **45.2 MB — 11%** | **238.8 MB — 60%** |

Partitioning was faster on three of four measures, and the hot path was a tie (31 µs vs 33 µs per
claim) — the earlier claim that unpartitioned would win the hot path was simply wrong. Partitioning
still loses because **the failure mode is cumulative disk, not per-statement latency**, and the
benchmark's 9 days of data fitted inside a single partition, hiding the thing that matters.

§14.1's rationale — "a monthly partition range turns retention into `DROP TABLE`" — **cannot hold for a
7-day retention window.** A September partition still holds deliverable rows on 1 October, so it
survives until roughly 7 October: 37 days in practice, not 7. At 2,000 orders/day × 7 events ×
483 bytes, that is 238.8 MB against a 400 MB working ceiling that `free-tier-plan.md` calls "the wall".
The `DELETE` costs ~3.5 ms/day and `events_delivered_at` makes it a **bitmap index scan** —
verified by `EXPLAIN ANALYZE` at 9 index buffer hits to locate 6,859 of 20,000 rows — so autovacuum
reuses the dead space and steady state does not creep.

**The uniqueness guarantee is the second reason.** §14.1 reprints the `events` DDL to add the
partition key to the primary key — and then leaves `unique id_uuid` on the line above, a second
instance of the same rule. Correcting it is not free: `unique (id_uuid, created_at)` satisfies
Postgres while **not** making `id_uuid` unique, making only the *pair* unique, so the same key could
land in two months unnoticed. `contracts.md` depends on the strong form in three places (§6 calls it
the "downstream idempotency key", `webhooks/events` keys on it, clients ignore a repeat). Staying
plain keeps §11 exactly as written. Verified: a duplicate `id_uuid` is rejected **even with a
different `created_at`**, which is precisely the case partitioning would have allowed.

Three checks added: `attempts >= 0`, and `delivered_at >= created_at` — the second catches a
dispatcher bug that would otherwise make undelivered work look prunable and delete it. `attempts` has
no ceiling on purpose; a permanently failing event must trip T7.6's dead-letter alert, not a
constraint. `aggregate_id` gets no foreign key, for the same reason `audit_log.entity_id` gets none:
an outbox row must outlive what it describes, and R2 archival of order detail would cascade.

The measurement also corrected an error in the budget model: `events` is **483 bytes/row measured,
not the 400 assumed**, so 7 rows/order is 3.4 KB rather than 2.8 KB. `free-tier-plan.md` §3.1 and
§3.5 are corrected upward by ~20%, which makes the §5 pruning jobs load-bearing rather than merely
worthwhile. A new §3.7 records the generalisation: **monthly is the right default for 30-day and
longer windows and actively harmful below about 14 days.**

`vouchers.discount_value` was `numeric(12,2)`, the **same constitution III.3 violation** `009`
corrected in `commission_rules.value`: a float where none is allowed, and a percentage that is not
basis points. Now `integer`, so `2000` is 20%. A percentage above 10000 bps is rejected, while a
`fixed_amount` of 250000 — a legitimate 2,500 EGP off a large order — is still accepted, because the
bound belongs to the type rather than to the column.

Three integrity gaps closed that `data-model.md` §9 left to application code:
- **`usage_limit_total` is now enforced by a `CHECK`.** Previously nothing stopped `usage_count`
  passing the cap except whichever RPC remembered to check.
- **Voucher codes are now case-insensitively unique** via a second unique index on `upper(code)`.
  `save20` and `SAVE20` would both have been redeemable, and codes are typed by hand from a poster.
- **`promo_slots` cannot name a target type without a target id**, or the reverse — a slot in the
  first state cannot be navigated to and one in the second cannot be interpreted.

Also added FK indexes §9 omits for `vouchers.created_by`, `voucher_redemptions.user_id` and
`voucher_redemptions.order_id` — `voucher_id` leads the existing two, so those three led none.

**Measured, not assumed, on the `uuid[]` question.** §16 removed arrays from `vendors` because
"JSON arrays cannot be indexed". A GIN index on `uuid[]` **is** accepted by Postgres 17 and **is**
used — `EXPLAIN (FORMAT JSON)` shows `Bitmap Index Scan` for both `&&` and `@>`. What GIN cannot
serve is the other branch of the predicate, `applies_to_vendor_ids = '{}'` meaning *all vendors*.
So the array is fine for vendor membership and unindexable for "applies to everything", and a join
table would fix the first while needing a sentinel convention for the second. Recorded as open
question 3.16 rather than converted, with `driver_shifts.area_ids` noted as the same shape.

`notifications` is the first partitioned table in the schema, and the reason is the opposite of
`rider_location_pings`: pings are empty until Phase 8 so its partitioning was deferred, whereas
notifications are written from the first order. §14.1 already documents the constraint that forces
the shape — on a partitioned table a `UNIQUE` constraint must include the partition key, so §10's
`id bigserial primary key` is illegal. Applied §14.1's own form,
`primary key (id, created_at)`. The cost is that `notifications.id` is unique only within a month,
which is acceptable because nothing references it and both access paths are already time-scoped.

Partition management uses §14.1's documented fallback rather than `pg_partman`:
`private.ensure_month_partition(text, date)` creates the month if missing, is idempotent, and carries
a **whitelist of the four prune targets** — the table name is interpolated into DDL, so without it the
function would partition anything a caller named. Current and next month exist now, because a
partitioned table with no matching partition rejects every insert.

⚠️ **`013` will hit the same wall.** §11's `events` declares `id bigserial primary key` **and**
`id_uuid uuid not null … unique`. Neither includes `created_at`, so both become illegal the moment
`events` is partitioned. §14.1 shows the corrected form; `013` must use it.

Recorded as open question 3.12: `contracts.md` §4 enumerates 19 notification keys and
`notifications.type` constrains none of them, so a typo yields an inbox row matching no template.
Deliberately unconstrained here — a hardcoded `CHECK` would be a second source of truth drifting from
`contracts.md`, and an FK is impossible while templates are unique per `(key, channel, lang)`.

`ledger_entries` is now append-only by two independent mechanisms, because constitution III.4 words
it as Postgres **rules** — which hold against a privileged mistake, not only the client roles — and
`TRUNCATE` is revoked as well, since no `ON UPDATE`/`ON DELETE` rule covers it. Both are used on
purpose: with only the rules a buggy application `UPDATE` succeeds and changes nothing, which is the
hardest failure to notice, while the revoke makes it a loud permission error.

Seeded and verified live: the rider revenue line is **active at 2000 bps (20%)** of the delivery fee
and the vendor commission row exists **inactive**, so month 3–4 is an `UPDATE`. `rider_max_cash_held_default`
is seeded at 250000, which is what makes `008`'s `effective_cash_limit_v1` return 2,500 EGP instead of
falling through to 0 — and 0 would have silently disabled cash collection for every rider.

`order_eta_snapshots` exists so "were we late?" is a query rather than an argument: `promised_at` is
what the customer was shown, `predicted_at` is what the system believed at `computed_at`, and the gap
between them is the ETA error. `sub_order_id` is nullable — null is an order-level snapshot, set is a
per-vendor one — which is how §6's three-rows-per-order budget resolves.

`007c` is deliberately a plain DDL translation, unlike `006`, `007` and `008`: no money columns to
guard, **no append-only revoke**, and no `computed_at`-not-in-the-future `CHECK` even though `008`
added the equivalent guard on `rider_location_pings.recorded_at`. That constraint protects a
trip-duration calculation; this table feeds a diagnostic query, where minutes of clock skew cost
nothing and a constraint that blocks an analytics write costs debugging. A revoke would also collide
with the policies migration `014` has yet to write. The omissions are recorded in the migration so
they read as decisions rather than oversights.

`rider_location_pings` is created **empty and stays empty until Phase 8**. ADR 9 defers live
tracking, `contracts.md` defines no RPC that writes to it, and the writer is the Durable Object.
Kept deliberately, for when the tracking API exists. It is created **plain and unpartitioned** —
see open question 3.10. It is also the highest-volume table in the database, budgeted at 4.0 KB per
order, which is why `riders.current_latitude` / `current_longitude` / `last_location_at` exist
alongside it: those three columns are enough to ship "where is my rider", and only the trip trail
needs the pings table.

`order_eta_snapshots` is specified in `data-model.md` §6 and §15.2 but **does not exist yet**, in the
repository or in the database. Not yet migrated.

Verified against the live database rather than assumed: **0 unindexed foreign keys**, every
`security definer` function pinned to `search_path = ''`, and the profile gate proven across six
cases — the trigger fires on sign-in, grants the base `customer` role, leaves the profile
incomplete, rejects a completion with no phone, accepts a valid one, and rejects a duplicate phone.

`order_eta_snapshots` was proven to answer its question rather than merely exist: a two-vendor order
with one envelope snapshot predicted 4 minutes late and two vendor snapshots at −6 and +9 minutes
returns a mean error of 2.3 minutes across 3 rows — 1 order-level, 2 vendor-level — which is exactly
the arithmetic inserted.

**Defect found by applying rather than reading:** `users.id uuid primary key default
auth.users(id)` is illegal — Postgres rejects a column reference in a `DEFAULT` expression
(`ERROR 0A000`). `data-model.md` carried the same bug and was corrected in the same change, so the
spec and the database do not disagree.

### Changed

- **`008` adds constraints that are not in `data-model.md` §8.** Flagged in the migration and
  reversible by dropping the constraint. Each was verified to reject the bad case:
  - Money and domain `CHECK`s on `riders` and `delivery_assignments`, following the rule `007`
    established. Includes `delivery_assignments_rider_pay_sums`, so a frozen pay breakdown cannot
    disagree with its own total.
  - `riders_is_online_consistent` — §8 declares **both** `status` and `is_online` without saying how
    they relate, which is the same desync shape that let `menu_items.vendor_id` drift in `005b`. The
    constraint enforces `is_online = (status <> 'offline')`. **This assumes the two are the same
    fact.** If `is_online` instead means "the app is open" while `status` means "delivery state",
    the constraint is wrong and should be dropped.
  - `driver_shifts_no_overlap` — an `EXCLUDE USING gist` constraint preventing one rider from
    holding two overlapping active shifts, which would let a single rider be matched to two
    concurrent orders. This is what migration `001` installs `btree_gist` for.
  - `riders_location_has_time` — a position with no timestamp reads as current and is not.
  - `effective_cash_limit_v1` does **not** check `p_rider_id` against the caller, so any
    authenticated user can read any rider's cash limit. Minor, but the guard belongs with the
    caller-identity rules in migration `018`.
- **`vendor_staff` gained `deleted_at`** (`010a`). Constitution III.17 asks for soft delete plus
  `updated_at` on every business table, and this was the one table with neither a `deleted_at` nor an
  `is_active` — no lifecycle mechanism at all, so a staff member who leaves could only be deleted,
  losing the record that they ever had access. Every other table lacking `deleted_at` has a competing
  mechanism (`is_active`, `effective_until`, a status enum, or append-only semantics) and was left
  alone. Nullable, so instant, and the table is empty.
- **Audit of 001–010 against the data-integrity standard.** Findings recorded rather than silently
  fixed, because each needs a decision:
  - **Four polymorphic columns have no referential integrity** — `wallets.owner_id`,
    `payouts.account_id`, `ledger_entries.account_id`, `commission_rules.target_id` are bare `uuid`
    with no FK, because each resolves against a different table via a sibling discriminator. The
    database currently permits a wallet for a vendor who does not exist. Open question 3.14.
  - **`riders` restates the user's name and phone**, and `users.phone_number` and
    `riders.phone_number` are *separate* unique constraints, so the two can drift. Open question
    3.13.
  - **43 of 50 tables have no `deleted_at`.** Reviewed individually: the large majority are correct
    — append-only (`ledger_entries`, `order_status_history`), immutable snapshots (`orders`,
    `order_items`), config with its own lifecycle (`cities`, `commission_rules`, `payouts`), pure
    join tables (`vendor_areas`), or pruned rather than deleted (`notifications`). Only
    `vendor_staff` was a genuine gap, fixed above.
  - **`notifications` and `rider_location_pings` use `bigserial`**, so their ids are guessable and a
    single sequence would serialize writes if the app ever writes from more than one region. Both are
    empty, so converting is free now and expensive after launch. Open question 3.15.
- **Three rules have no surface to audit yet, and saying otherwise would be false.** There is no
  `package.json`, no `apps/` and no application code of any kind, so `SELECT *`, N+1 queries and
  slow-query tuning cannot be assessed in the application — there is none. What *can* be reported:
  - No `SELECT *` against any table in any migration. The single textual match, `005b:150`, is
    `select * from (values …)` — a projection of a literal `VALUES` list, not a table.
  - `pg_stat_statements` is installed and has **1,205 real statements** recorded. Every one of the
    eight slowest is Supabase/PostgREST schema introspection — `pg_timezone_names`,
    `pg_extension`, `information_schema`, domain-type recursion. There is not one application query,
    and nothing to optimise against zero rows. Their 300–400 ms means are catalog scans on an empty
    database and are not a signal about production.
  - What will enforce the remaining rules, and where: `014`'s policies replace the table-wide grants
    so every read is column-scoped rather than `SELECT *`; `016`–`020`'s RPCs return projections
    instead of rows, which is also the structural answer to N+1; `free-tier-plan.md` §11 already lists
    the weekly query checks, and its monitoring table names the slow-query alert.
- **`driver_shifts.area_ids` stays a `uuid[]`, as specced.** §16 removed JSON arrays from `vendors`
  for exactly this reason — "JSON arrays cannot be indexed; forces a scan on every availability
  check" — and then used an array here. A join table would be consistent with `vendor_areas` and
  would make the shift-area lookup indexable. Not changed unilaterally: that means adding a table
  nobody approved. Recorded for a decision.
- **Three places `data-model.md` §7 conflicts with the constitution.** The constitution wins, because
  `AGENTS.md` makes it non-negotiable and `data-model.md` a proposal:
  - `commission_rules.value` was `numeric(12,4)` seeded with `20` for 20%. Rule III.3 says *no
    numeric* and that *percentages are basis points*, so this broke the rule twice. Now `integer`
    basis points — `2000` is 20%.
  - `payouts` had no `idempotency_key`. Rule III.5 names a payout as one of the cases that must
    carry one, so a retried payout run would have paid twice, and `run_payout_v1` in `019` had
    nowhere to put it. Added `NOT NULL UNIQUE`; the table was empty so nothing needed backfilling.
  - `platform_float.variance` had nothing tying it to `cash_expected - cash_remitted`, which is how
    §7 defines it and what rule III.10 makes the daily health check. Now constrained.
- **`wallets.balance` deliberately has NO non-negativity check.** A wallet is a liability the platform
  owes, so a negative balance is a real state — that party owes the platform, e.g. a rider who took
  more cash than the order was for. `balance >= 0` would make it unrepresentable. Verified by
  inserting `-25000` and confirming acceptance. It is the one money column in this migration where the
  reflexive constraint is wrong.

### Fixed

- **`orders.item_count` could never become non-zero.** `sync_order_status()` derives `item_count`
  from `order_items`, but it was only ever attached to `sub_orders`. `order_items.sub_order_id` is a
  `NOT NULL` foreign key, so an order line cannot exist until after its sub-order does — the
  aggregate was therefore always recomputed *before* any line was counted, and nothing recomputed it
  afterwards. Every order would have carried `item_count = 0` while holding real items.

  Proven by execution, not inference, on a two-vendor order:

  | step | before | after | actual |
  |---|---|---|---|
  | after inserting lines | 0 | 5 | 5 |
  | one of two sub-orders accepted | 0 | 5 | 5 |
  | a line's quantity 2 → 4 | 0 | 7 | 7 |
  | a line deleted | 0 | 4 | 4 |
  | both sub-orders delivered | 0 | 4 | 4 |

  `vendor_count` was always correct, because it reads `sub_orders` — the table that actually fired the
  trigger. That asymmetry is what identified the cause.

  Fixed in `007b`. The aggregate `UPDATE` moved into `private.recompute_order_aggregates(uuid)` so
  `sub_orders` and `order_items` share one definition instead of two copies that can drift, and
  `order_items` gained statement-level triggers for insert, update and delete. The UPDATE trigger
  reads both transition tables, because `order_items.order_id` is derived from `sub_order_id` — so
  moving a line to a different sub-order moves it to a different order, and the order it left would
  otherwise keep counting a line it no longer has. The helper lives in `private` because it takes an
  argument, which would otherwise make it a callable PostgREST RPC — the problem `005e` moved
  `private.is_admin()` out of `public` to solve.

### Security

- **A demonstrated cross-tenant read, closed.** `public.effective_cash_limit_v1` is
  `SECURITY DEFINER` and accepts a `rider_id`, but never checked the caller was that rider. `008`
  revoked `EXECUTE` from `public, anon` — insufficient, because `authenticated` is a member of
  `PUBLIC` and so still held `EXECUTE`, leaving the function reachable at
  `POST /rest/v1/rpc/effective_cash_limit_v1`.

  Proven by execution, not inference. With `request.jwt.claims` set to a customer identity and the
  session switched to the `authenticated` role:

  | check | result |
  |---|---|
  | `current_user` after switch | `authenticated` / session `postgres` |
  | control — `select from public.riders` | **CONTROL OK: privileges genuinely reduced** |
  | `effective_cash_limit_v1(<other rider>)` | **LEAKED 777777** |

  The control is what makes this trustworthy: it proves the role switch actually reduced privileges,
  so the leak is the function bypassing the table lockdown rather than an artefact of testing as the
  owner. A locked-down table is worthless if a definer function hands its rows to anyone who asks —
  the same shape as `005b` and `007b`, where the write path was guarded and a read path around it
  was not.

  Fixed in `010a`: split into `private.effective_cash_limit` (unguarded, unreachable from PostgREST
  because it is not in an exposed schema — settlement and reconciliation use it) and a guarded public
  entry point. Re-verified live: own rider still reads `55555`, another rider is now **blocked 42501**,
  and the private helper is **not callable** from the client role. A rejected read *raises* rather
  than returning null, because a null would read as "limit 0" and per §8 a limit of 0 disables cash
  collection — turning an information leak into an outage.
- **Audited 001–010 for leakage.** `anon` and `authenticated` hold **zero** table grants; no views
  exist in `public`; all 3 `SECURITY DEFINER` functions are pinned to `search_path = ''`; and the only
  function in an exposed schema that takes arguments was the one above. RLS is still off on every
  table — deliberate, since `005d` revoked the grants and the policies land in `014`.
- Purged an Apple App Store Connect private key (`*.p8`) and an iOS distribution certificate
  (`*.cer`) from git history after they were committed by a `git add -A`. `.gitignore` extended
  to cover `*.p8 *.cer *.p12 *.pfx *.jks *.mobileprovision` and the `appstore/` directory.
  `git add -A` is now forbidden by the commit protocol in `AGENTS.md`.
- The App Store Connect key should still be revoked and regenerated. It was never pushed to a
  remote, but an App Store Connect key can read sales data and manage builds, and it does not
  expire on its own.

### Deprecated

- `architecture-spec-supabase-cloudflare-firebase.md` — the original v1 architecture spec.
  Superseded. Marked with a contradiction table so it is not implemented from by mistake. Retained
  only as a historical artifact.

## Known gaps

Recorded in `open-questions.md` §6. The significant ones:

- Migrations 010–022 have **not** been written. `010` (`engagement`) is next.
- No application code. No `apps/`. No `package.json`.
- `npm run typecheck`, `npm run lint`, `npm test`, `npm run verify` do not exist, so **no
  engineering checklist can currently be signed off.** See `AGENTS.md` §Verification commands.
  Migration assertions to date have been run by hand against the live database.
- `scripts/check-test-integrity.mjs` does not exist, so rule 4 is unenforced.
- `scripts/check_schema_drift.py` exists and compares the live database against `data-model.md`, but
  it reports rather than gates: no baseline has been agreed, so its findings are not yet a build
  failure.
- RLS is disabled on all 32 tables. Grants are revoked, so `anon` and `authenticated` can read
  nothing; the policies land in `014`.
- The spec has never been reviewed by a human. Every number in it is a proposal.