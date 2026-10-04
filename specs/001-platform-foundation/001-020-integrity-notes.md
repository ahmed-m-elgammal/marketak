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

## 5. Database state after the suite

All fixtures rolled back. Every public table is empty except the three seeded by earlier migrations
(`commission_rules`=2, `notification_templates`=38, `settings`=13). `auth.users` = 0.

## Still to do

- State machine: every illegal transition refused from and to every state, as the actor that owns it.
- Integrity at boundaries: `0`, negative, and `int4` max on money columns; NULL in NOT NULL columns.
- Transaction atomicity: force a mid-function failure and assert no partial write survives.
- Reconcile idempotency across a day boundary.
- Review the 33 jsonb columns for normalisation.