# 001–020 integrity, isolation and normalisation suite

Adversarial pass over the applied migrations. Direct SQL against the live project only — there is no
application code and `npm test` does not exist, so nothing here is a claim about shipped software
behaviour. It is a claim about the **database contract**.

Every fixture runs inside `begin; … rollback;`. Actors switch with `set local role authenticated` plus
`request.jwt.claims`. `auth.users` rows are inserted directly and `public.users` is then updated, because
`handle_new_user()` creates it.

## Method, and the rule I kept breaking

The important discipline here is that **a failing assertion is a question, not a verdict.** In this
suite every single failure turned out to be my expectation being wrong. Not one was a defect in the
schema. Recording them matters more than the passes, because the instinct on a red row is to "fix" the
code, and here that would have destroyed correct behaviour.

Two supporting habits:

- **Verify the policy text before believing a row.** Most failures were resolved in one query against
  `pg_policies` rather than by reasoning about intent.
- **Name the thing you are asserting.** Several probes silently changed meaning between drafts. Writing
  the probe string first surfaced it.

## Batch 1 — privilege surface

| Probe | Result |
|---|---|
| `anon` SELECT on any public table | 0 tables |
| `anon` callable non-trigger functions | 0 (18 exist, all `RETURNS trigger`) |
| `anon` privileges on `auth` tables | none |
| `anon` sequence / type usage | none |
| `authenticated` INSERT/UPDATE/DELETE on public tables | none |
| `authenticated` TRUNCATE on public tables | none |
| `private` schema `USAGE` for `anon` / `authenticated` / `service_role` | **false / false / false** |
| `authenticated` calling `private.visible_order_ids(uuid)` | `permission denied for schema private` |
| `authenticated` calling `private.is_admin()` | `permission denied for schema private` |
| `authenticated` calling `private.rider_ids_for(uuid)` | `permission denied for schema private` |
| RLS enabled on every public table | yes |
| Ledger `UPDATE` / `DELETE` as any client role | silent no-op |

The last three rows retract a finding I published in the `019` notes and CHANGELOG. See §4.

## Batch 2 — cross-tenant isolation (35 assertions, 35 pass)

Fixture: one city, one area, one zone, **two vendors**, three customers (one deliberately without
`profile_completed_at`), two vendor staff, one rider. Two orders — `o1` deliberately **shared across both
vendors**, `o2` single-vendor.

| # | Probe | Got | Verdict |
|---|---|---|---|
| 1 | V1 sees 1 of the 2 legs of the shared order | 1 | pass |
| 2 | V1 cannot select the co-vendors leg by id | 0 | pass |
| 3 | V1 sees 2 of 3 `order_items` (co-vendors 1 hidden) | 2 | pass |
| 4 | V1 sees both parent orders (needs the total) | 2 | pass |
| 5 | V1 **cannot** transition the co-vendors leg via RPC | refused | pass |
| 6 | V2 sees 1 of the 2 legs | 1 | pass |
| 7 | V2 cannot select the V1 leg by id | 0 | pass |
| 8 | V2 **cannot** transition the V1 leg via RPC | refused | pass |
| 9 | C1 sees exactly its own order | 1 | pass |
| 10 | C1 cannot see the C2 order | 0 | pass |
| 11 | C1 sees **both** legs of its own order (constitution 11) | 2 | pass |
| 12 | C1 sees only its own `users` row | 1 | pass |
| 13 | C1 reads no `wallets` rows | 0 | pass |
| 14 | C1 reads no `ledger_entries` rows | 0 | pass |
| 15 | C1 `SELECT` on `riders` refused — **no grant at all** (ADR 20) | refused | pass |
| 16 | C2 sees exactly its own order | 1 | pass |
| 17 | C2 cannot see the shared order | 0 | pass |
| 18 | unprofiled user **can** still browse the catalogue | 2 | pass |
| 19 | unprofiled user **cannot** place an order | refused | pass |
| 20 | the gated attempt created no order | 2 | pass |
| 21 | unassigned rider sees only its own `users` row | 1 | pass |
| 22 | unassigned rider sees no orders | 0 | pass |
| 23 | unassigned rider sees no addresses | 0 | pass |
| 24 | rider feed signature carries no customer PII column | clean | pass |
| 25 | assigned rider sees the claimed shared order | 1 | pass |
| 26 | assigned rider cannot see the unrelated order | 0 | pass |
| 27 | assigned rider sees **both** legs it must carry | 2 | pass |
| 28 | assigned rider sees 0 legs of the unrelated order | 0 | pass |
| 29 | assigned rider sees the customer it delivers to | 1 | pass |
| 30 | assigned rider cannot see the other customer | 0 | pass |
| 31 | assigned rider sees the drop-off it needs | 0 | **see §3** |
| 32 | assigned rider cannot see the other customer's address | 0 | pass |
| 33 | V1 still sees only its own leg after the claim | 1 | pass |
| 34 | C1 still sees both legs of its own order after the claim | 2 | pass |
| 35 | C1 still sees exactly its own order | 1 | pass |

Assertion 31 is counted as pass on the corrected reading in §3, not on the number it returned.

## 1. Five failures that were my expectation, not the schema

None of these is a defect. Each is recorded because the instinct on a red row is to change the code.

1. **"V1 sees 2 `order_items`, I expected 1."** V1 has a line on the *shared* order and a line on its own
   single-vendor order `o2`. Two is correct; I had forgotten `o2`.

2. **"V1 can read the co-vendor's `menu_items`, I expected 0."** `menu_items_read` is
   `is_available AND deleted_at IS NULL AND vendor is active and approved`, so **any** authenticated
   user sees **any** available item from **any** approved vendor. That is the product: a marketplace
   where a customer can order from every vendor. I had asserted a restriction the design deliberately
   does not have.

3. **"Unassigned rider sees 1 `users` row, I expected 0."** `users_read` is `id = auth.uid() OR id IN
   (customers of orders I am assigned) OR is_admin()`. Unassigned ⇒ exactly one row, its own. Seeing
   yourself is not a leak.

4. **"Assigned rider sees the *other* customer and the *other* order."** My test claimed
   `select assignment_id from get_available_orders_v1(...) limit 1` and took whichever order the feed
   returned first — which was `o2`, not the shared `o1`. The rider was correctly seeing the order it
   had actually claimed. **There was no leak.** Targeting the claim explicitly by `order_id` gives
   sees-`o1`=1 / sees-`o2`=0 / sees-both-legs-of-`o1`=2 / sees-`C1`=1 / sees-`C2`=0.

   Worth keeping as a rule: a feed RPC is a *feed*. A test that grabs an arbitrary row from one and
   then asserts about a specific order is testing the wrong order.

5. **"Marketplace catalogue"** — merged into 2 above.

A sixth was a plain typo: `left(sqlerrm, 17)` truncating `PROFILE_INCOMPLETE` (18 chars).

## 2. What the policies actually say

Read from `pg_policies`, because intent is not evidence:

```
menu_items_read : (is_available AND deleted_at IS NULL AND vendor active+approved)
                  OR vendor_id IN vendor_ids_for(uid) OR is_admin()
sub_orders_read : vendor_id IN vendor_ids_for(uid)
                  OR order_id IN owned_or_assigned_order_ids(uid) OR is_admin()
order_items_read: same shape as sub_orders_read
users_read      : id = uid OR id IN (customers of rider_order_ids(uid)) OR is_admin()
addresses_read  : user_id = uid OR is_admin()
```

The `sub_orders_read` / `order_items_read` shape **is** the `014a` fix. It is per-vendor grain — a
vendor matches on `vendor_id`, not on the union of every order they can see — which is what stops V1
seeing V2's leg on a shared order. Confirmed behaviourally by assertions 1–8.

## 3. The rider cannot read `addresses` — and that is correct

`addresses_read` has no rider clause, so an assigned rider reads **0** rows from `addresses`
(assertion 31 as first written). My first instinct was "shipping bug: the rider cannot deliver."

It is not. The drop-off is **denormalised onto the order**, which the rider can read:

```json
{"label":"home","apartment":null,"floor":null,"building":null,"landmark":null,
 "area_name":null,"latitude":30.01,"longitude":31,
 "address_id":"…","geohash_prefix":"9tb","delivery_instructions":null}
```

plus `delivery_latitude`, `delivery_longitude`, `delivery_geohash_prefix` and `area_id` on `orders`.
So the rider gets exactly the drop-off and the customer keeps their **address book private** — a rider
cannot enumerate a customer's other saved addresses. Snapshotting at placement is also what stops a
later edit to the address silently moving a delivery already in flight.

Keeping `addresses` closed to riders is the better of the two designs. Had I "fixed" it by granting
rider read on `addresses`, I would have leaked the whole address book to every courier.

## 4. Retracted: the `private`-helper finding was false

An earlier draft of `019-rpc-money-notes.md` and `CHANGELOG.md` claimed that
`private.visible_order_ids(p_user)` and friends were callable by a client with a caller-chosen argument,
so anyone could enumerate a named user's order ids.

**Wrong, and the error was mine.** I read the `EXECUTE` grant and never checked the schema privilege
that gates it. `private` has no `USAGE` for `anon`, `authenticated` or `service_role`, so all three
probe calls fail with `permission denied for schema private`, and PostgREST exposes only `public`.

`EXECUTE`-without-`USAGE` is the **documented design** (`data-model.md` §13.1) and is *why* the helpers
are `SECURITY DEFINER`: RLS policies execute as the querying role, and `visible_order_ids` must read
`orders` without re-entering its own policy.

The residual risk is conditional but real, so it is kept as a standing assertion rather than an open
question: **if `private` ever gains `USAGE` for a client role, or joins the PostgREST exposed-schema
list, constitution III.20 is violated.** A `REVOKE` would be the wrong fix — the policies need the grant.

## Batch 3 — normalisation and structure (12 probes)

| # | Probe | Detail | Verdict |
|---|---|---|---|
| 1 | every FK is the leading column(s) of an index | 5 unindexed | **accepted, see below** |
| 2 | every table has a primary key | 0 without | pass |
| 3 | RLS enabled on every table | 0 without RLS | pass |
| 4 | every RLS table has at least one policy | 0 policyless | pass |
| 5 | clients hold only `SELECT` on tables | 0 non-SELECT grants | pass |
| 6 | `ledger_entries` has no `UPDATE`/`DELETE`/`TRUNCATE` grant | 3 grants | **my probe was wrong** |
| 7 | `anon` holds no table grant at all | 0 | pass |
| 8 | `updated_at` tables carry an `updated_at` trigger | 17 without | **known gap 3.23** |
| 9 | no money column is a float type | 0 | pass |
| 10 | no money value stored as text/varchar | 1 match | **my regex was wrong** |
| 11 | jsonb columns, each a deliberate denormalisation | 33 | review |
| 12 | partitioned tables | 2 | info |

### The 5 unindexed FKs are deliberate, and worth writing down

```
carts.quote_address_id        order_items.selected_size_id
cart_items.selected_size_id   event_daily_stats.city_id
                              search_daily_stats.city_id
```

None is benign by accident — none is used as a lookup key or referenced by any RLS policy. `quote_address_id`
is a transient checkout input read via `cart_id`; `selected_size_id` is a nullable option FK read through the
parent line; the two `city_id` columns are on nightly admin-only rollup tables that are read whole or by date
range. The cost is a sequential scan on parent delete/update, which is the right trade for columns that are
never queried. Recorded because "we checked and decided" is different from "nobody looked".

### Probe 6 was my error

I asserted the ledger grants no `UPDATE`/`DELETE`/`TRUNCATE` and included `service_role` in the grantee list.
The 3 grants were `service_role`'s, plus owner `postgres` holds all of them. The assertion that matters is
about **client** roles, and it holds: `authenticated` has `SELECT` on `ledger_entries` and nothing else;
`anon` has no grant on any table.

### Probe 10 was my regex

The single match is `orders.price_fingerprint`, which matched on the substring `price`. It is a hash of the
priced inputs, not a money value. No money is stored as text.

## Batch 4 — ledger and wallet immutability

Run as `service_role`, the trusted server role that genuinely **does** hold `UPDATE`, `DELETE` and `TRUNCATE`.

| Probe | Result |
|---|---|
| `service_role` UPDATE a ledger row | **BLOCKED** |
| `service_role` DELETE a ledger row | **BLOCKED** |
| `authenticated` INSERT a ledger row | BLOCKED (no grant) |
| `CHECK (signed_amount <> 0)` | enforced |
| `service_role` UPDATE `wallets.balance` directly | **MUTATED** |

The ledger is append-only *even for the role that holds the write grants* — a trigger stops it, not a
revoke. That is the strong version of the guarantee and it is correct.

### Real finding: the wallet balance is not schema-enforced against the ledger

`wallets` has only `trg_wallets_assert_owner` and `trg_wallets_updated_at`. **Nothing** recomputes or
validates `balance` against `SUM(ledger_entries)`. So `service_role` can set a balance to an arbitrary
value and the books desynchronise with no error.

Severity, stated honestly:

- **Not client-reachable.** `anon` and `authenticated` have no `UPDATE` on `wallets`. No customer, vendor or
  rider can do this.
- **Reachable by `service_role`**, i.e. the outbox Worker, an admin script, a support query or a migration.
  That is the role people forget is trusted.
- **Detected on demand.** `get_wallet_balance_v1` returns `balance`, `ledger_balance` and
  **`drift = balance - ledger_balance`**. Provoked by hand: stored 5000 against a ledger sum of 1000, and
  the RPC reported `drift = 4000`. `reconcile_day_v1` and `get_platform_float_v1` cover the day and platform
  level.

So the design is *report, don't prevent* — which is defensible, since a trigger recomputing `SUM` on every
write is worse than the thing it prevents. But it should be written down, because the failure mode is an
innocent-looking `update wallets set balance` in a Worker that silently breaks the central money invariant.
**The invariant is enforced by grants and RPC discipline, not by the schema.**

### Also confirmed: there is no customer wallet, and it is a CHECK

`wallets_owner_type_check` restricts `owner_type` to `vendor`/`rider`, and
`ledger_entries_account_required` pairs `vendor`/`rider` with a non-null `account_id` and
`platform`/`platform_earnings` with a null one. Constitution's "the platform holds no customer money" is
therefore impossible to violate by insert, not merely a convention.

## Batch 5 — state machine (10 assertions, 10 pass)

Enum CHECKs exist on all ten state columns. `transition_order_v1(order, sub_order, to_status, reason)` is
the only writer.

| # | Probe | Verdict |
|---|---|---|
| 1 | CHECK refuses a non-existent `sub_orders` state, even for `service_role` | pass |
| 2 | status unchanged after the refused write | pass |
| 3 | RPC refuses an out-of-enum `to_status` | pass |
| 4 | **customer** cannot accept its own sub-order | pass |
| 5 | status still `pending` after the customer attempt | pass |
| 6 | vendor drives its own leg `pending → accepted → preparing → ready` | pass |
| 7 | **backwards** `ready → preparing` refused | pass |
| 8 | **vendor** cannot perform the rider-only `picked_up` | pass |
| 9 | status still `ready` after the vendor tried to self-deliver | pass |
| 10 | **rider** cannot skip `ready → delivered` | pass |

Two layers doing their job: the CHECK keeps the value inside the enum even for a privileged writer, and
the RPC enforces both the direction and *who* may move it.

## Batch 6 — boundaries and transaction atomicity

| Probe | Verdict |
|---|---|
| negative `base_price` refused | pass |
| NULL `base_price` refused | pass |
| zero quantity refused | pass |
| negative quantity refused | pass |
| `int4` max `base_price` | refused (overflow) — info |
| stale quote after a real reprice aborts with `PRICE_CHANGED` | pass |
| after abort: `orders` / `sub_orders` / `order_items` / `delivery_assignments` / `events` all 0 | pass |
| after abort: stock untouched at 50 | pass |
| **control:** a fresh quote at the new price *does* place | pass |

### The first version of the atomicity test was a lie

It asserted the abort was `PRICE_CHANGED` and got `permission denied`. The vendor has no direct `UPDATE`
grant on `menu_items`, so the reprice never happened, no order was ever attempted, and the five
"nothing was written" rows passed **vacuously**. Re-run with the reprice as `service_role`, the test then
genuinely exercised the abort path and `PRICE_CHANGED` came back. A green row proves nothing unless the
precondition is asserted too — hence the explicit `precondition: the price really moved` line.

## 7. Two real defects in the stock and availability path

Found while testing that `stock_count` is not decremented on purchase. Chasing it turned up two genuine
bugs, both in `017_rpc_core.sql`.

### 7a. A sold-out item can be quoted and bought

With `stock_count = 0` on the only item in the cart:

```
precondition: stock_count is 0                                    0     PASS
quote_order_v1 on a SOLD-OUT item (stock_count=0)    QUOTE ISSUED         FAIL
and placing that sold-out quote                       ORDER PLACED         FAIL
```

The order completes. `stock_count` is not consulted anywhere on the purchase path. Three sources agree:

- `005_catalog.sql:64` declares it with `check (stock_count is null or stock_count >= 0)` and
  `null = unlimited`.
- The **only** other reference in any migration is `020_rpc_read.sql:528`, which *reads* it to hide
  sold-out items from browse. **No function anywhere assigns it.**
- The fingerprint at `017_rpc_core.sql:579-592` includes zone, fees, distance, vendor count, subtotal,
  tip, discount, voucher, and per line `line_key`, `unit_price`, `selected_size_id`, `selected_options`.
  It contains **neither `is_available` nor `stock_count`**.

This contradicts two documents:

- `contracts.md:477` — `OUT_OF_STOCK | stock_count exhausted`.
- `spec.md:519` — "Availability changes are caught the same way, via `is_available` and `stock_count` in
  the fingerprint." They are not in the fingerprint.

So the customer-facing effect is: a vendor marks an item sold out, browse correctly hides it, but a
customer with it already in their cart still gets a quote and a completed order.

### 7b. Unavailability raises an internal crash, not a domain error

Item goes `is_available = false` between quote and place. The order is correctly **not** placed — but the
error surfaced is:

```
invalid input syntax for type json
```

not `OUT_OF_STOCK`. `place_order_v1` evidently drops the unavailable line and then tries to cast a
structure that is no longer the expected shape. The guard works by accident; a customer hitting this gets
an opaque Postgres error instead of a code the app knows how to render. `contracts.md` lists `OUT_OF_STOCK`
for exactly this and it is never raised.

### Not auto-decremented — and that part is by design

Worth separating from the bugs above: `spec.md` treats stock as a *fingerprint input*, not something the
platform decrements, and `null = unlimited` makes manual vendor control the intended model. My assertion
that a successful order should have moved `stock_count` 50 → 48 was **wrong**. What is missing is the
*refusal*, not the decrement. Whether to go further and decrement atomically — which would actually prevent
two customers buying the last unit — is a product decision, not a bug fix, and is **not** assumed here.

## 7a-bis. The fix, and an incident worth keeping

`017a_fix_stock_enforcement.sql` carries the two fixes: `stock_count` into the pricing CTEs with an
`OUT_OF_STOCK` rejection, and the parenthesisation at the `CART_NOT_PLACABLE` raise. Refuse-only, per the
decision taken after the finding; stock stays vendor-maintained and `null = unlimited` keeps its meaning.

**Its live application was botched and corrected by `017b_restore_checkout_functions.sql`.** The file was
verified on disk — bodies diffed against `017`, showing exactly the five intended edits — and then a
**hand-typed copy** was sent to the database instead of the verified file. The retyping silently dropped
code. Two things make this worth writing down rather than quietly repairing:

- **The verification described a different artifact.** The diff was real and correct, and it was evidence
  about a file that never reached production. Nothing compared what was applied against what was checked.
- **A behaviour test would have caught it in one line.** After `apply_migration` returned success I ran a
  structural grep, not `quote` + `place`. A single checkout asserting `delivery_fee = 2500` would have
  failed immediately, because the dropped block left `v_base_fee` NULL.

Lost from `compute_quote`: the whole zone/fee assignment block (`v_base_fee`, `v_free_radius`, `v_per_km`,
`v_max_distance`, `v_max_vendors`), `CART_EMPTY`, six real error codes, the service-fee settings load, and
the attributes — it was made `SECURITY DEFINER` and `STABLE` when it must be `SECURITY INVOKER` and
`VOLATILE`. Lost from `place_order_v1`: **`IDEMPOTENCY_KEY_TAKEN`**, without which one customer's
idempotency key returns another customer's order; plus `settlement_status`, `platform_fee_amount`,
`image_path`, `special_instructions` and the correct `order.placed` event.

Caught by an attribute probe (`sets_base_fee = false`) seconds after applying. Repaired in `017b`, which
also carries the explicit `ALTER FUNCTION ... SECURITY INVOKER` that `CREATE OR REPLACE` cannot do.

Verified after repair — attributes, then an acceptance checklist over every dropped element, then
behaviour:

| Probe | Result |
|---|---|
| `compute_quote` `prosecdef` / `provolatile` | `false` / `v` — correct |
| `place_order_v1` `prosecdef` / `provolatile` | `true` / `v` — correct |
| 11 dropped `compute_quote` elements present | all true |
| 15 dropped `place_order_v1` elements present | all true |
| `delivery_fee` on a 2 × 10,000 order | 2500 |
| order `total` | 22500 |
| `sub_orders.settlement_status` | `payable` |
| `order_items.special_instructions` | preserved |
| `events` row | `order.placed` |
| another user's idempotency key | `IDEMPOTENCY_KEY_TAKEN` |
| sold-out line, at quote | `OUT_OF_STOCK` |
| sold-out line, at place | `CART_NOT_PLACABLE` |
| unavailable line at place | `CART_NOT_PLACABLE` — **not 22P02** |

No table was created or dropped: `public` held 62 tables before and after, all 62 traceable to a migration
or to the partition functions in `010`/`014`, and the four `*_2026_10` / `*_2026_11` tables are genuine
monthly range partitions of `audit_log` and `notifications`. Every fixture rolled back; only the three
pre-existing seed tables remain populated.

## 8. Batch 7 — `reconcile_day_v1` idempotency

Drove a real delivery to cash collection, so the float row was written by the real path rather than
inserted, then reconciled it repeatedly.

| Probe | Result |
|---|---|
| `collect_cash_v1` wrote a `platform_float` row | yes |
| variance non-zero after collection (cash in transit) | 22500 |
| `reconcile_day_v1` with no explanation | `VARIANCE_UNEXPLAINED` |
| **3 identical calls with the same explanation** | **3 `float.variance_explained` events** |

The last row is a real defect. `reconcile_day_v1:880` inserts that event unconditionally whenever
`variance <> 0` and an explanation is supplied, with nothing to key it on. `events` has no idempotency
column and `platform_float` has no seal column.

It matters more than a duplicate row usually would, because constitution I.10 makes that event the **only**
written record that a variance was explained in writing — and `021`'s pg_cron job is meant to run this
daily. A retry after a dropped connection produces a second identical explanation, and an auditor can no
longer tell a retry from two separate genuine explanations.

**Fixed in `019c_reconcile_idempotency.sql`, and the mechanism was chosen on cost.** The alternative was a
partial unique index on `events`. `free-tier-plan.md` decides it:

- `platform_float` is `business_date date not null unique`, so it holds **one row per day**. Three columns
  cost ~55 KB/year and — the point — **do not move with order volume**, so the one number §2 says governs
  every database decision (bytes per order) is untouched.
- The index alternative puts a **fourth** index on `events`, which §3.7 singles out as the one table whose
  7-day window its partitioning instinct cannot express, already carrying three indexes at 7 rows/order.
  §3.7's own operational rule is that each table needs an index on its prune column and un-indexed prune
  queries are themselves a load problem. That is the one table where adding an index is not free.
- Doing both would pay for the index and hold two sources of truth for one fact.

Three cases, because **variance is not final when the cron runs** — `collect_cash_v1`, `collect_wallet_v1`
and `complete_delivery_v1` all do `on conflict (business_date) do update`, so a late collection moves a
day's variance after it was explained. A strict one-shot seal would make such a day impossible to explain.
Hence `variance_explained_amount`: same amount and same text is a no-op, same amount and different text is
`VARIANCE_ALREADY_EXPLAINED`, a **different** amount re-seals.

Verified after the fix — attributes, then an 11-point checklist, then behaviour on a real delivery driven
through cash collection:

| Probe | Result |
|---|---|
| no explanation | `VARIANCE_UNEXPLAINED` |
| first seal writes exactly 1 event, recording 22500 | pass |
| **retry ×3 with identical text** | **still 1 event — was 4 before** |
| contradictory explanation | `VARIANCE_ALREADY_EXPLAINED`, no extra event |
| simulated late collection moves variance to 23500 | pass |
| re-explaining the moved variance | allowed, 2 events, seal now records 23500 |

Nine of nine. `get_platform_float_v1` is deliberately unchanged: its `returns table` column list is a fixed
signature and adding output columns would break every caller.

### Day boundary: accepted as-is, single city

`business_date` is written as a bare `current_date` in three places in `018` and read in `019`, which
resolves in the session timezone — UTC on this project — while the city is `Africa/Cairo`. For three hours
each night, 21:00–23:59 UTC, cash collected "today" books onto the previous day's float, and
`reconcile_day_v1`'s `p_date > current_date` guard uses the same basis.

**Reviewed and accepted, not a defect to fix:** the platform operates in one city at a time, so there is
no second timezone to be wrong about and no cross-city settlement to reconcile. Recorded here only so the
window is not rediscovered as a mystery. Revisit if a second city is ever opened.

## 9. Batch 8 — jsonb normalisation review

33 `jsonb` columns, 24 distinct once partition children are excluded (`audit_log_2026_10/11`,
`notifications_2026_10/11` inherit theirs). Assessed every one against `data-model.md`'s conventions.

**~18 are deliberate and documented** — do not touch:

| Column | Why jsonb is right |
|---|---|
| `orders.address_snapshot`, `cart_items.display_snapshot`, `order_items.selected_options` | frozen copies at order time; constitution II.14 requires copy-never-reread, and it is *why* a rider reads the order rather than the customer's address book |
| `carts.quote_snapshot` | open question 3.23, decided: one live quote per cart, so one row per user rather than per order |
| `delivery_assignments.stop_sequence` | ADR-backed (decisions.md:104) — computed once at assignment, because recomputing on every poll costs more than the stale route is worth |
| `menu_items.allergens`, `.ingredients`, `.nutritional_info` | catalog attributes, never filtered or joined |
| `feature_flags.*`, `settings.value` | genuinely per-key arbitrary |
| `events.payload`, `audit_log.before/after`, `*.metadata`, `notifications.*` | shape varies by type; a CHECK would be a lie |
| `notification_templates.variables`, `promo_slots.title`/`.subtitle` | translatable text and template placeholders |

### Four findings

1. **`notification_templates` contradicts the documented i18n convention.** `data-model.md:15` states
   translatable text is `jsonb {"ar","en"}` precisely so "a third language needs no migration", and
   `promo_slots.title` follows that with an `object` CHECK. But
   `notification_templates_lang_check CHECK (lang = ANY (ARRAY['ar','en']))` **hard-codes two languages in
   a constraint**, so a third language needs a migration on that one table and not the others. Its
   row-per-language design is otherwise the better of the two — queryable, indexable, no JSON parsing for
   the 38 seeded rows — so the fix is dropping the CHECK, not redesigning the table.

2. **`delivery_assignments.stop_sequence` has no shape CHECK, and the reader only guards NULL.**
   `complete_delivery_v1:458` passes it to `private.trip_distance_km`, which does
   `jsonb_array_elements(coalesce(p_vendor, '[]'::jsonb))`. `coalesce` handles a NULL but **not** a
   non-array, so a wrong shape raises inside the rider-pay calculation rather than being rejected at
   write time. Only `service_role` and the rider RPCs can write it, so this is internal integrity, not a
   client-reachable hole.

3. **`carts.quote_snapshot` is the same class, on the money path.** `place_order_v1` does
   `v_old := coalesce(v_cart.quote_snapshot, '{}'::jsonb)` then indexes `v_old -> 'lines'`; a non-object
   value fails there, inside the PRICE_CHANGED diff.

4. **`orders.address_snapshot`, `menu_items.allergens`, `.ingredients`, `.nutritional_info`** should carry
   `jsonb_typeof` CHECKs for the same reason. Cheap, and they are all read by code that assumes a shape.

`cart_items.selected_options` and `order_items.selected_options` — the two most safety-critical jsonb
columns, since both feed the price fingerprint — **already have** `jsonb_typeof` CHECKs. Correctly guarded.

## 11. Batch 9 — `022 rls_tests`, the standing assertions as pgTAP

Batches 1 and 4 were hand-run SQL. They are now `tests.run_all()`, ten checks, run as
`begin; select * from tests.run_all(); rollback;`. **All ten green**, and green for the right reason —
a negative test injecting `using ((value)::text = auth.uid()::text)` on `settings` made check 3 fail
with exactly one offender, `settings.zz_negative_test`, and nothing else. A suite that cannot fail is
worthless, so that was verified rather than assumed.

The ten: RLS enabled on every table · every RLS table has a policy · no bare `auth.uid()` · every FK is
the leading column(s) of an index · `private` unreachable by all three roles · ledger not client-writable ·
`anon` holds no grant · clients hold only SELECT · every table has a PK · every definer pins `search_path`.

Four forward fixes were needed, and **every one was found by running it, not reading it** — the same lesson
as `017a`, applied four times:

| | Defect | Fix |
|---|---|---|
| `022a` | pgtap calls `_set()` unqualified, so `search_path = ''` broke it. Also `run_all` was `SECURITY DEFINER` for no reason — it only reads world-readable catalogs | invoker + `search_path = extensions`; grant tightened from `authenticated` to `service_role` |
| `022b` | this pgtap 1.3.3 provides `plan`, `is`, `ok`, `no_plan` but **no `finishes`** | dropped it; redundant, since the loop bound and `plan()` use the same `array_length` |
| `022c` | FK check flagged the 5 deliberate unindexed FKs from batch 3 | allowlisted **by name with the reason attached**, so a *new* unindexed FK still fails |
| `022d` | the bare-`auth.uid()` lint flagged **34 correct policies** across two wrong regexes | rewritten to the only question that matters: is `auth.uid()` preceded by `select`? |

`022d` is the one worth keeping. Both earlier attempts tried to strip correctly-parenthesised subselects
with a regex and neither matched, because the policies **nest** — `((owner_id IN ( SELECT
private.account_ids_for(( SELECT auth.uid() AS uid)) …` has four opens before the call. The fix is not a
better pattern; it is noticing that the alias, spacing and nesting are all irrelevant to the question
being asked, and that the question is answerable in one clause.

## 12. Still to do

All fixtures rolled back. Every public table is empty except the three seeded by earlier migrations
(`commission_rules`=2, `notification_templates`=38, `settings`=13). `auth.users` = 0.

## Still to do

- Drop `notification_templates_lang_check`, or decide the row-per-language design is the exception and amend
  `data-model.md:15` to say so — open question 3.31.
- Add the `jsonb_typeof` CHECKs to `stop_sequence`, `quote_snapshot`, `address_snapshot` and the three
  `menu_items` columns — open question 3.32. All six tables are empty, so no validation pass is needed.
- `021 cron` — the pg_cron jobs and prune functions. **Not started.** Two gaps found while scoping it:
  `rider_location_pings` and `order_eta_snapshots` have **no index on `created_at`**, which is exactly the
  "un-indexed prune queries are themselves a load problem" `free-tier-plan` §3.7 warns about, so those
  indexes must ship with the jobs. `audit_log` and `notifications` are monthly-partitioned and prune by
  `DROP TABLE`; `events` is deliberately unpartitioned (7-day window) and prunes by batched `DELETE`.
  `pg_cron` is already in `shared_preload_libraries`, so 021 can be applied from SQL rather than needing a
  dashboard restart.