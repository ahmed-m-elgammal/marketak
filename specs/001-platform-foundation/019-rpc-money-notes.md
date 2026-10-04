# 019 `rpc_money` — working notes

Grounding record for migration `019`. Everything here was **read from the repo or queried live** on
2026-10-05, not recalled. Section 4 is the part that matters most: it is the schema as it actually
is, which differs from `data-model.md` §7 in two places.

## 1. Scope

`data-model.md` §15.2 row 019 — **authoritative**, it is the migration inventory:

| Function | Returns |
|---|---|
| `adjust_wallet_v1` | new balance, ledger entry id |
| `get_wallet_balance_v1` | balance, status, recent entries |
| `run_payout_v1` | `payout_id` |
| `reconcile_day_v1` | expected vs banked vs owed |
| `get_platform_float_v1` | daily float with `variance` |

### Naming divergence — unresolved, recorded not decided

`contracts.md` §1.8 names **13** money functions and disagrees with §15.2 on three of them:

| §1.8 | §15.2 row 019 | Note |
|---|---|---|
| `get_wallet_v1` | `get_wallet_balance_v1` | same thing, different name |
| `run_vendor_payout_v1` + `run_rider_payout_v1` | one `run_payout_v1` | §1.8 also lists a third |
| `approve_payout_v1` | *absent* | see below |

§1.8 also names `freeze_wallet_v1`, `list_frozen_v1`, `get_commission_v1`,
`set_commission_rule_v1`, `get_fee_rules_v1`, `set_fee_tier_v1` — **none of which are assigned to
any migration.** `wallets.status` already has `'frozen'`/`'review'` in its CHECK and
`wallets_status_reason_required` already demands a reason for them, but no function can set one.

**`approve_payout_v1` cannot simply be dropped.** `payouts_paid_is_approved` is
`CHECK (status NOT IN ('paid','processing') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))`.
Without an approval path that CHECK is unsatisfiable and **no money can ever move**. So the gate must
live inside one of the five names. Options: `p_action` parameter on `run_payout_v1`, or a 6th
function. **Open — needs a decision.**

## 2. Invariants at risk

| # | Invariant | Where it bites in 019 |
|---|---|---|
| I.3 | money is `int` piastres + `currency`; bps for percentages | every sum; `net = gross − fee` is a CHECK |
| I.4 | ledger append-only; **balance cached in the same transaction as its entries** | forces `wallets.balance` to move whenever a party-account entry is written |
| I.5 | every `idempotency_key` unique | `payouts.idempotency_key` UNIQUE; `ledger_entries.idempotency_key` UNIQUE |
| I.6 | no customer money | wallets are vendor/rider only, enforced by CHECK |
| I.7 | money constants are configuration | **no literal fee/limit in a function body** |
| I.9 | launch revenue is a cut of the delivery fee | vendor `commission` line is 0 until month 3–4 |
| I.10 | cash in transit reconciled daily, variance zero **or explained in writing** | `reconcile_day_v1` must refuse an unexplained non-zero variance |
| II.11/12 | one order + N sub_orders; items belong to a sub-order | payout pays `sub_orders`, never `orders` |
| II.15 | status changes only via `transition_order_v1` | `019` must not write `orders.status` |
| II.16 | every state change writes its `events` row in the same transaction | each `019` mutation needs an events insert |
| III.20 | permission from the caller's JWT, never a client-supplied role | admin checks via `private.is_admin()`, wallet reads via `private.vendor_ids_for` / `rider_ids_for` |

## 3. Constraints the schema already enforces

Verified live via `pg_get_constraintdef`. These are not things `019` must implement — they are
things it must not fight.

**`payouts`**
- `status IN ('draft','approved','processing','paid','failed','cancelled')`
- `payout_type IN ('vendor','rider')`
- `gross_amount >= 0 AND fee_amount >= 0 AND net_amount = gross_amount - fee_amount`
  (net may go negative: a fee larger than the gross is a clawback)
- `period_end >= period_start`
- `status NOT IN ('paid','processing') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)`
- `status <> 'failed' OR failure_reason IS NOT NULL`
- `idempotency_key` UNIQUE, `approved_by REFERENCES users(id)` — **not** `auth.users`

**`payout_lines`**
- `payout_line_type IN ('vendor_earning','riper_trip','tip','bonus','adjustment')`
- `source IN ('cash_collected','wallet_payment','adjustment')`
- `gross_amount >= 0 AND fee_amount >= 0 AND net_amount = gross_amount - fee_amount`
- **`sub_order_id IS NULL OR payout_line_type IN ('vendor_earning','rider_trip','adjustment')`**
  → a `tip` or `bonus` line is **forbidden** from carrying a `sub_order_id`
- `UNIQUE (sub_order_id) WHERE sub_order_id IS NOT NULL` — **global**, not per payout
- `payout_id REFERENCES payouts(id) ON DELETE CASCADE`

**`ledger_entries`**
- `account_type IN ('vendor','rider','platform','platform_earnings')`
- `account_type IN ('vendor','rider') → account_id IS NOT NULL`;
  `IN ('platform','platform_earnings') → account_id IS NULL`
- `entry_type IN ('rider_cut','cash_collected','cash_remitted','delivery_fee','service_fee',
  'commission','refund','reversal','vendor_payout','rider_payout','adjustment','float_sweep')`
- **`signed_amount <> 0`** → a zero entry is unrepresentable; every insert must be guarded
- `idempotency_key` UNIQUE
- Rules `ledger_no_update` / `ledger_no_delete` — `DO INSTEAD NOTHING`
  ⇒ **Postgres refuses `INSERT ... ON CONFLICT` against this table entirely.** Guards must be
  `INSERT ... SELECT ... WHERE NOT EXISTS (idempotency_key = …)`.

**`platform_float`**
- `business_date` UNIQUE
- `variance = cash_expected - cash_remitted`
- `cash_expected >= 0 AND cash_remitted >= 0`
- `external_cash_orders >= 0 AND external_wallet_orders >= 0`

**`wallets`**
- `owner_type IN ('vendor','rider')`, `UNIQUE (owner_type, owner_id)`
- `status IN ('active','frozen','review')`, `status = 'active' OR status_reason IS NOT NULL`
- `version >= 0`
- **no non-negativity CHECK on `balance`** — deliberate (009 header: a negative balance means that
  party owes the platform). Do not "fix" this.

**`sub_orders`** — `settlement_status IN ('payable','in_payout','settled','void')`,
`vendor_net_payout NOT NULL DEFAULT 0`, `payout_id` FK.

## 4. Two places the applied schema differs from `data-model.md` §7

1. **`ledger_entries.account_id` is nullable.** §7 line 1357 says `account_id uuid not null` with
   the comment "or NULL for platform accounts" — the comment contradicts its own `NOT NULL`. The
   applied column is nullable and `ledger_entries_account_required` carries the real rule. §7 is
   wrong; the migration is right.
2. `payout_lines_sub_order_type` and `platform_float_cash_nonneg` exist in the database but appear
   nowhere in §7.

## 5. Index coverage — what `019` must add

The two payout scans are not served by any existing index:

| Scan | Existing indexes | Verdict |
|---|---|---|
| `sub_orders WHERE vendor_id = ? AND settlement_status = 'payable' AND status = 'delivered' AND delivered_at ∈ period` | `sub_orders_settlement_payable` on `(settlement_status)` only; `sub_orders_vendor_created` on `(vendor_id, created_at desc)` | **each serves one side only.** Need a partial composite on `(vendor_id)` where payable, and one where `in_payout` |
| `delivery_assignments WHERE rider_id = ? AND status = 'delivered' AND delivered_at ∈ period` | `delivery_assignments_rider_history` on `(rider_id, assigned_at desc)` — wrong end of the trip | need partial `(rider_id, delivered_at)` where `status = 'delivered'` |

`platform_float_date` (added by `018`) already serves the range scan and the `ON CONFLICT
(business_date)` upsert. `wallets_owner` and `ledger_entries_account_created` are sufficient.

Partial indexes, because the row count that matters is the work *owed*, which is near zero most of
the day. A full index would grow forever and be scanned forever for a payout that usually finds
nothing.

## 6. Blocking design gap — `payout_lines` cannot identify a trip

`payout_lines` columns are exactly: `id, payout_id, sub_order_id, payout_line_type, source,
gross_amount, fee_amount, net_amount, created_at`.

There is **no** link to `delivery_assignments`. A rider payout line must therefore carry
`sub_order_id = NULL`, because:

- the global `UNIQUE (sub_order_id) WHERE NOT NULL` is already consumed by the vendor payout for
  that same sub-order, so a rider line claiming it collides; and
- `sub_order_id` identifies a *vendor's leg*, not a *rider's trip*, so it is the wrong key anyway.

Consequence: **a rider payout gets no double-pay protection from
`payout_lines_sub_order_unique`.** Its only guard is `payouts.idempotency_key` covering
(type, account, period). That is sufficient for a retried job but not for two overlapping periods.

Two ways forward, **now decided**:

**(a) CHOSEN — add `assignment_id uuid REFERENCES delivery_assignments(id)` to `payout_lines`,
nullable, in `019` itself, before the functions.**

- `payout_lines` is empty, so an additive nullable FK is instant: no rewrite, no `NOT NULL` without
  default (the anti-pattern `database-migrations` warns about), no backfill.
- A **UNIQUE** index `payout_lines_assignment_unique (assignment_id) WHERE NOT NULL` gives rider
  payouts the same double-pay protection `payout_lines_sub_order_unique` gives vendors. This is the
  part that matters: without it, rider payouts were guarded only by `payouts.idempotency_key`
  covering (type, account, period), which does not stop two overlapping periods paying one trip.
- Cash is then read by joining the payout's own lines to their assignments, so the figure comes from
  the rows in **this batch** rather than from a re-derived date window. That removes the boundary case
  where a trip completing between create and approve had no line.
- `payout_lines_sub_order_type` is replaced by one stronger constraint covering both columns, so a
  mis-paired line is structurally impossible: `vendor_earning` must carry `sub_order_id` and no
  `assignment_id`; `rider_trip` and `tip`/`bonus` must carry `assignment_id` and no `sub_order_id`;
  `adjustment` carries neither.

Rejected: re-querying `delivery_assignments` by (rider, status, period). That is the derivation that
already produced one wrong-column bug (reading the rider's *pay* instead of the cash *held*), and it
leaves a payout line untraceable to its trip.

## 7. Decisions taken (with authority)

| Decision | Who |
|---|---|
| Scope is the five functions in `data-model.md` §15.2 row 019 | user, explicit |
| A bank reference is **mandatory** to approve a payout, so `cash_remitted` is evidence not assertion | user, explicit |
| One rider payout batch mixes cash and earnings; cash is flagged per `payout_lines.source` | user, explicit |
| Wallets move with payouts (constitution I.4), and `adjust_wallet_v1` is the only way money enters a wallet without one | derived from I.4 + `tasks.md` T4.15 + `data-model.md` §7 |
| Add `payout_lines.assignment_id` (+ UNIQUE index, + stronger shape CHECK) in `019` | user, explicit |
| Approval gate is a `p_action` parameter on `run_payout_v1`, values `create` \| `approve` \| `reject` — not a 6th function | user, explicit |

Rejected for the gate: implementing `contracts.md` §1.8's three separate payout functions, which
exceeds the five-name scope and contradicts §15.2; and deferring approval to a later migration, which
would leave `payouts_paid_is_approved` unsatisfiable in the meantime.

`p_action` keeps create and approve in **separate transactions**, which `plan.md` §4 requires — a crash
mid-payout must leave a visible, recoverable batch rather than a half-paid one.

## 8. Gaps `019` will leave, recorded rather than invented

- `freeze_wallet_v1` / `list_frozen_v1` — `status` enum and CHECK exist, no writer
- `get_commission_v1` / `set_commission_rule_v1` — constitution I.9 requires vendor commission to be
  switchable by an **`update`, never a migration**; there is no RPC to do it, so today it needs SQL
- `get_fee_rules_v1` / `set_fee_tier_v1` — same for constitution I.7
- `get_wallet_v1` vs `get_wallet_balance_v1` naming
- `payout_lines` ↔ `delivery_assignments` (section 6)

## 9. Verification plan

Direct SQL only — `npm run verify` does not exist. Every fixture inside `begin; … rollback;`.

**Fixture prerequisite:** `handle_new_user` trigger on `auth.users` creates the `public.users` row,
so fixtures must `INSERT INTO auth.users` and then `UPDATE public.users`, never insert both.

Actor map: customer quotes/places; vendor staff `accepted→preparing→ready`; rider
`picked_up→delivering→delivered` + `complete_delivery_v1`; admin runs payouts. Getting this wrong
produces `NOT_AUTHORIZED` from `transition_order_v1`, which is a **test** error, not a code error.

| Group | Assertions |
|---|---|
| vendor payout | draft created, net = `Σ vendor_net_payout`, `payable→in_payout`, `payout_id` stamped, no `commission` row while it is 0 |
| approval gate | reference mandatory, method mandatory, `payout_id` mandatory, still draft after each refusal, `approved_by`+`approved_at` recorded, second approve → `PAYOUT_NOT_DRAFT`, no duplicate ledger row |
| rider payout | trip + tip lines, net = `rider_pay + tip`, cash flagged per line, **`cash_amount` = `collected_amount` and ≠ net** |
| float | `cash_held` zeroed, `cash_remitted` = cash collected, `variance` → 0, `cash_remitted` entry negative on platform |
| constitution I.4 | `wallets.balance` = `Σ ledger_entries` for that account, after payout, after adjust, and after a replayed adjust |
| reconcile | balanced when variance 0; unexplained variance refused; explanation recorded as an event; day with no float row returns zeros; future date refused |
| isolation | vendor staff cannot pay or adjust; vendor staff **can** read its own wallet; customer can read neither another's wallet, reconcile, nor the float |
| idempotency | replayed `create` refused; replayed `adjustment` is a no-op with `version` unchanged; replayed `approve` refused |
| ledger immutability | `UPDATE` and `DELETE` against `ledger_entries` are silent no-ops |
| zero-amount | commission 0 writes no row (CHECK `signed_amount <> 0`) |
| structure | `search_path = ''` on every function, `SECURITY DEFINER` where needed, no `anon` EXECUTE, no `private` helper reachable by `authenticated`, all rows 0 after rollback |

## 10. Migration mechanics

Applied as `019` in one call, so `schema_migrations.statements` holds **29,266 bytes of real DDL** —
functions, the `assignment_id` ALTER, the shape CHECK and the grants. That is the point: `018`'s
ledger row is a 407-byte comment stub, which makes the applied state unreproducible from the repo.
Never copy that.

- **Never edit an applied migration.** Fixes go in `019a`, `019b`, … per `database-migrations`
  ("migrations are immutable once deployed"). Existing precedent: `005a`, `007a`, `010a`, `014a`,
  `018a`. Two were needed here; both are recorded in section 11.
- **Every applied migration must have a file on disk in the same commit.** A migration that exists
  only in the database cannot be reviewed or replayed. An earlier draft of this work applied `019b`
  and `019c` from inline bodies with no files at all, which is the `018` defect reproduced two
  migrations later. It was caught only by listing the ledger against the directory.
- Applied via `supabase_apply_migration` because no Supabase CLI credentials are linked. Verify the
  ledger row afterwards rather than assuming it took.

## 11. What actually happened

Applied as `019` (29,266 bytes of real DDL in the ledger), then two forward migrations, each because
the first attempt failed when executed rather than when read:

| Migration | Cause |
|---|---|
| `019` | shipped |
| `019a_fix_payout_line_uniqueness` | `payout_lines_assignment_unique` was UNIQUE on `assignment_id` alone, so one trip could not have both a `rider_trip` line and a `tip` line. The first rider payout with a tip aborted the transaction. Now UNIQUE on `(assignment_id, payout_line_type)` |
| `019b_fix_paid_event_actor` | `payout.paid` was the only 019 event whose payload lacked `actor` |

### Verification results — 51 assertions in four batches

| Batch | Result |
|---|---|
| vendor payout + approval gate + balance invariant | 28/30 |
| rider payout, float, reconcile, isolation, idempotency | 38/40 |
| `service_role` gate | 7/7 |
| structure, events, ledger immutability | 12/12 |

**Seven of the nine failures were my test, not the code**, and are recorded rather than quietly
corrected:

1. Asserted a replayed `create` would raise `NOTHING_DUE`. It returns the existing batch with
   `already_applied = true` instead, because the idempotency-key lookup runs before the payable scan.
   That is **better** than an error — a retried daily cron job should be a no-op, not a failure.
2. Truncated `PAYOUT_NOT_DRAFT` to 15 characters; it is 16.
3. Truncated `DATE_IN_FUTURE` to 13; it is 14.
4. Asserted a vendor balance would go negative from a −500 adjustment on a 10,000 payout. It is 9,500.
   Proving the *absence* of a non-negativity CHECK needs a structural assertion, not a fixture, and one
   was added: `wallets` has zero CHECK constraints mentioning `balance`, and a −99,999 clawback is
   accepted, leaving `balance = −89,999` with the ledger still in agreement.
5. Asserted a vendor line's `source` was derived from a column no longer selected. Rewritten.
6. Dropped the vendor-staff actor from a fixture, so the leg never reached `ready` and the rider's
   `picked_up` was refused with `INVALID_TRANSITION`. The state machine was right.
7. Expected 5 ledger rows; there are 6 (2 collection + 2 payout + 1 remittance + 1 adjustment).

**Two were real, and both are fixed:** the single-column uniqueness above, and the missing `actor`.

### Confirmed by execution

Vendor net equals `Σ vendor_net_payout`; `payable → in_payout → settled` with `payout_id` stamped;
no `commission` row while commission is 0, because of `CHECK (signed_amount <> 0)`; approval refuses
without a method, without a bank reference, without a `payout_id`, and twice; `approved_by` and both
timestamps recorded. Rider payout emits a `rider_trip` line **and** a `tip` line pointing at the same
trip, with net = `rider_pay + tip`. **`cash_amount` is the cash held (13,000), not the pay owed (500)** —
the two are asserted to be distinct, because conflating them is the bug that `018a`-style errors come
from. `cash_held` reaches 0, `cash_remitted` equals what was collected, and **`variance` reaches zero**:
constitution I.10 discharged. `wallets.balance` equals the ledger sum after payout, after a negative
adjustment, and after a replayed adjustment, with `version` at 2 rather than 3.

`service_role` holds `EXECUTE` on the mutations but **cannot use them without a user JWT**: all three
refuse with `AUTH_REQUIRED` and write nothing. The gate is `private.is_admin()`, which is `false` with
no JWT. Recorded because "service_role can run payouts" is the alarming reading and it is not what
happens.

Ledger `UPDATE` and `DELETE` are silent no-ops. No non-SELECT grant to `anon` or `authenticated`.
RLS on every public table.

## 12. Pre-existing finding, NOT caused by 019, not fixed here

`private.visible_order_ids(p_user uuid)`, `private.vendor_ids_for(p_user uuid)`,
`private.rider_ids_for(p_user uuid)`, `private.account_ids_for`, `private.owned_or_assigned_order_ids`,
`private.rider_order_ids` and `private.is_admin()` are all `SECURITY DEFINER` and **executable by
`authenticated`**. They must be — RLS policies execute as the querying role.

The problem is that they **trust the `p_user` argument**. A client can therefore call
`select private.visible_order_ids('<any user uuid>')` over PostgREST and receive that user's order ids,
or `vendor_ids_for` to learn which vendors a person is affiliated with.

- **What leaks:** the set of order ids belonging to a user id the caller can name, and a user's
  vendor/rider affiliations.
- **What does not leak:** order contents. Reading `orders` still goes through RLS, which calls
  `visible_order_ids(auth.uid())` — the caller's own — so no row becomes readable this way. This is
  information disclosure, not a data breach.
- **Why it matters anyway:** constitution III.20 says permission comes from the user's own JWT and
  never from a client-supplied argument. These helpers invert that.
- **The fix is not a revoke.** The policies need the grant. The fix is for each helper to ignore its
  argument and read `auth.uid()` itself, so the parameter becomes decorative, or to move them out of a
  client-reachable schema.
- **Left unfixed deliberately.** It belongs to `014`, not `019`, and changing RLS helper signatures
  mid-money-cycle without a decision is exactly the sort of quiet scope expansion AGENTS.md rule 9
  forbids. It is now an open question, not a silent defect.

Also noted while looking: `data-model.md` §7 declares `ledger_entries.account_id NOT NULL` and then
comments "or NULL for platform accounts". The applied column is nullable and
`ledger_entries_account_required` carries the real rule. §7 is wrong.