# Admin write surface + the six money functions — implementation plan

**Status: LOCKED.** Agreed and closed. No further design questions outstanding; the three that were open
in §8 are answered below. This document exists so the shape of the work is agreed before a migration is
authored, after the `017a` lesson that a verified file is worth nothing if the wrong bytes reach the
database.

**Decisions taken (asked, not assumed, per `AGENTS.md` rule 9):**

| Question | Decision |
|---|---|
| Scope | **Everything** admin-writable, not just the merchant minimum |
| Function shape | **One function per table, table name hardcoded in the function body, `jsonb` patch payload** |
| Who may write | **Platform admin only.** Vendor self-service is a separate, later surface |

---

## 1. Grounding — the invariants this work must not break

Loaded for this task: `.specify/memory/constitution.md` (rules 1, 5, 9, 16, 17, 32),
`data-model.md` §15.2, `contracts.md` §1.8, `tasks.md`, `open-questions.md` 3.30.

| # | Invariant | How this work must honour it |
|---|---|---|
| 1 | Prices, fees, discounts, commissions computed in **Postgres, never the app** | No admin function may accept a computed money value. `set_fee_tier_v1` takes `multiplier_bps`, not a percentage string; nothing takes a precomputed total |
| 9 | Commission and fees are switched on by an `update`, never a migration, **never retroactively** | `set_commission_rule_v1` must reject an `effective_from` in the past, or must ignore it. Retroactive commission is a silent money bug |
| 16 | **Every state change writes its `events` row in the same transaction** | Every single admin mutation writes an `events` row. This is Checklist A3 and is non-negotiable |
| 17 | **Soft delete plus `updated_at` on every business table** | `admin_*_delete_v1` sets `deleted_at`, never `DELETE`. And see §2 — this is currently violated on 17 tables |
| 5 | Every `idempotency_key` is unique; a retry must never double-charge | The four **money** functions (`freeze_wallet_v1`, `adjust_wallet_v1` callers, fee/commission setters) take an `idempotency_key`. Catalog writes do not — they are not money and a retry is harmless |
| 32 | Event consumers are idempotent, delivery at-least-once | Not directly affected, but the reason the `events` rows matter |
| 6 | No customer wallet; wallets are vendor and rider only | `wallets.owner_type` stays `vendor`/`rider`. Already a CHECK |

## 2. The blocking prerequisite: `updated_at` triggers

Rule 17 requires `updated_at` on every business table. **17 tables have none** — and 15 of them are
tables this plan writes:

```
cities, areas, delivery_zones, delivery_fee_tiers, settings,
vendors, brands, menu_categories, menu_items, menu_item_sizes, item_options, option_choices,
users, addresses, feature_flags, vendor_schedules, vendor_earnings_daily
```

**All 17 get the trigger**, decided. Not only the 15 Tier 1 tables: `addresses` is Tier 2 read-only but
a support dashboard will want to see when a customer last changed their address, and
`vendor_earnings_daily` is a machine-written rollup where uniformity is easier to keep true than a
carve-out nobody remembers six months later.

Without this first, an admin edit to `menu_items` would not move `updated_at`, which breaks:

- the incremental export that `free-tier-plan` §3.4 depends on
- snapshot invalidation, per rule 17's own wording — any catalog write bumps `vendors.menu_version`
  and changes the R2 snapshot URL, but a dashboard needs `updated_at` to show "last edited" and to
  drive delta syncs

So `updated_at` triggers are migration **one**, not a cleanup.

## 3. Function shape, and why

```sql
create or replace function public.admin_upsert_menu_item_v1(p_patch jsonb)
returns ... language plpgsql security definer set search_path = '' as $$
```

Rules, applied uniformly:

1. **The table name is a literal in the function body.** Never a parameter. A client-supplied
   `p_table` choosing the write target has the same shape as the auth-argument defect constitution
   III.20 forbids — permission must not come from a client value.
2. **`p_patch` is validated against an explicit key allowlist** inside the function. An unknown key is
   an error, not a silently ignored field. This is what stops a typo'd key from reading as success.
3. **`private.is_admin()` is the first statement**, before any input is inspected.
4. **`search_path = ''`** and every name fully qualified, per `data-model.md` §17 finding 1. The 022
   suite now asserts this for every definer function.
5. **One `events` row per mutation**, same transaction, per rule 16.
6. **`p_patch` never carries an `id` for updates on a row the admin cannot see** — every function
   checks `deleted_at` on read and refuses to touch a soft-deleted row except via `restore`.
7. **Tier 2 and Tier 3 get read RPCs only, never write functions.** There is deliberately no
   `admin_update_order_v1` to be careful with later. The absence is the safety property.

Rejected: **one generic `admin_write_v1(p_table, p_op, p_payload)`.** Compact, but it is a dynamic
dispatch surface where a client string selects the write. It would also be unauditable — 24 tables in
one function body — and it would fail the 022 suite's spirit immediately.

## 4. Access tiers — every table classified

"Not writable" and "not readable" are different permissions, and conflating them is how an admin
dashboard ends up with raw `UPDATE` on `ledger_entries`. So all 58 tables (plus 4 partitions) are
classified three ways.

### Tier 1 — WRITE. Admin creates, edits, soft-deletes.

| Group | Tables |
|---|---|
| Geography | `cities`, `areas` |
| Money configuration | `delivery_zones`, `delivery_fee_tiers`, `commission_rules`, `rider_pay_rules`, `settings` |
| Vendor | `vendors`, `brands`, `cuisines`, `vendor_areas`, `vendor_cuisines`, `vendor_schedules`, `vendor_holidays`, `vendor_staff` |
| Menu | `menu_categories`, `menu_items`, `menu_item_sizes`, `item_options`, `option_choices` |
| Engagement | `promo_slots`, `notification_templates`, `vouchers` |
| Feature flags | `feature_flags` |

**Hybrid within Tier 1 — writable, but only in one direction:**

| Table | Admin may | Admin may **not** |
|---|---|---|
| `wallets` | `status` via `freeze_wallet_v1` / unfreeze, with a reason | **never touch `balance`.** It moves only with its ledger rows, in one transaction. `019c` exists because a direct write desyncs the books |
| `reviews` | `is_hidden` only — moderate, with a reason | **never `vendor_rating`, `rider_rating` or `comment`.** Those are the customer's score and words. See below |
| `user_roles` | grant/revoke `admin`, `vendor_staff` | never grant themselves a role they are removing in the same call |

**`reviews` moderation is one column, and the schema already supports it.** `is_hidden` exists
(`010:54`), the rating index is already partial on `not is_hidden` (`010:68`), and RLS already lets an
admin see hidden rows while hiding them from everyone else (`014_rls.sql:364`). So hiding a review
already removes it from any rating aggregate — no recompute, no cache to invalidate. The only missing
piece is an RPC to set it, because clients hold no `UPDATE`.

The one thing this plan will **not** build is an admin path that rewrites a rating or edits a comment.
Your stated reason for wanting review control is that early users posting bad reviews cost you
merchants, and hiding is the direct answer to that. Rewriting someone's score does not solve it and
costs the one thing a review table has: that the number on it means something. If you want a lever
against a hostile reviewer that is *not* falsification, the honest options are a vendor reply field
(the schema has no `vendor_response` column yet) and weighting by order value. Say the word and I will
add either.

**Found while answering this: `reviews` has no create path at all.** `update_profile_v1` is the only
write RPC in the database, so no customer can leave a review and no admin can moderate one. The table,
its indexes and its RLS are all correct and entirely unused. `create_review_v1` is missing alongside
`admin_set_review_hidden_v1`, and FR-C-16 rates the vendor and the rider separately, so both are needed
before launch.

### 4a. Soft delete — only where archiving is the real lifecycle

Rule 17 says "soft delete plus `updated_at` on every business table". Checked: **23 of the 27 Tier 1
tables have no `deleted_at` column at all.** Only `vendors`, `menu_categories`, `menu_items` and
`vendor_staff` have one. So the rule was being applied to a schema that does not follow it, and taking
it literally would put a meaningless `deleted_at` on tables whose lifecycle is something else.

**`deleted_at` is added to these 14** — entities that are genuinely archived rather than ended:

`cities`, `areas`, `brands`, `cuisines`, `vendor_areas`, `vendor_cuisines`, `vendor_schedules`,
`vendor_holidays`, `menu_item_sizes`, `item_options`, `option_choices`, `promo_slots`,
`notification_templates`, `vouchers`

**These 9 keep their own lifecycle, and `deleted_at` is deliberately not added:**

| Table | Its real lifecycle | Why not a soft delete |
|---|---|---|
| `commission_rules` | **superseded** by a new dated rule | rule 9 says commission changes are an `update` that never applies retroactively. Soft-deleting a rule destroys the dated history that makes that auditable |
| `rider_pay_rules` | superseded, same reasoning | same |
| `delivery_zones`, `delivery_fee_tiers` | `is_active` | a retired zone is inactive, not deleted |
| `wallets` | **frozen** via `freeze_wallet_v1` | deleting a wallet destroys the balance history rule 1 requires to stay computable |
| `reviews` | `is_hidden` | the mechanism already exists and the rating index is already partial on `not is_hidden` |
| `user_roles` | hard delete | a join table. A revoked role that is merely soft-deleted still reads as present |
| `settings`, `feature_flags` | hard delete | key/value. A removed key means the key does not exist |

**This amends rule 17** and needs its own ADR, because "every business table" is wrong as written for
money configuration, wallets and join tables. Recorded rather than silently reinterpreted: the rule's
*purpose* — archiving, snapshot invalidation and incremental export all need a soft delete — is fully
honoured for every table where those three actually apply.

### Tier 2 — READ ONLY. The admin dashboard sees these; the system owns every write.

`users` sits here by decision: the dashboard reads a customer, it does not edit one. Name, phone and
identity are the user's, and `handle_new_user` plus `update_profile_v1` own them. Roles are still
writable, through `user_roles` in Tier 1.

| Group | Tables | Who writes |
|---|---|---|
| Order lifecycle | `orders`, `sub_orders`, `order_items`, `order_status_history`, `order_modifications`, `order_eta_snapshots`, `delivery_assignments` | `place_order_v1`, `transition_order_v1`, `cancel_order_v1`, rider RPCs |
| Money records | `payouts`, `payout_lines`, `ledger_entries`, `platform_float`, `voucher_redemptions` | `run_payout_v1`, `collect_*`, `adjust_wallet_v1`, `reconcile_day_v1` |
| Customer state | `addresses`, `carts`, `cart_items`, `favorites`, `favorite_items`, `notifications`, `device_tokens`, **`users`** | the customer's own RPCs |
| Operations | `events`, `audit_log`, `driver_shifts` | append-only triggers and the outbox |
| Analytics rollups | `event_daily_stats`, `search_daily_stats`, `auth_daily_stats`, `vendor_earnings_daily`, `rider_earnings_daily` | nightly jobs |

**Why the order lifecycle is read-only even though admins will want to "fix" an order.** An `UPDATE` on
`sub_orders.status` would bypass the state machine's actor check, skip the `events` row that rule 16
requires, and leave `order_status_history` inconsistent — the same class of damage `014a` fixed for
vendor visibility. Corrections go through `transition_order_v1`, which is the only legal writer.
`cancel_order_v1` is the admin's tool for a wrong order.

**Why `ledger_entries` is read-only.** Append-only by trigger, and `009`'s rule is that a balance must be
computable at any time. An admin correcting money writes an `adjust_wallet_v1` reversal, which keeps the
sum derivable. Editing a ledger row breaks the one invariant the whole money design rests on.

### Tier 3 — NOT ACCESSIBLE from the dashboard at all

| Target | Why |
|---|---|
| `riders` (raw table) | ADR 20: not client-readable. Support needs name and phone, so it gets a **projection function**, never the table |
| `user_auth_providers` | identity-provider data. Admin has no legitimate need and a large one to misuse it |
| `auth` schema | `auth.users`, `auth.identities`. Supabase-owned |
| `private` schema | no `USAGE` for any role. Never, by anyone — see the 022 suite |
| `rider_location_pings` | live tracking is cut by ADR 6, so nothing writes it. There is nothing to read |

### The invariant that makes this safe

Tier 1 is writable **only through `SECURITY DEFINER` RPCs that check `private.is_admin()`**. No client
role holds `INSERT`, `UPDATE` or `DELETE` on any table — 022's check 8 asserts it and must keep passing.
That is what makes "admin may write 26 tables" compatible with "62 tables sit behind RLS": the
permission is in the function, not in a grant.

## 5. The six money functions

These are the open question 3.30 remainder, and the reason `contracts.md` §1.8 lists functions no
migration implements. All operate on tables that already exist — no schema change.

| Function | Signature sketch | Invariant at risk |
|---|---|---|
| `get_fee_rules_v1(p_zone_id)` | zone + all tiers + service fee settings | Rule 1 — reads configuration, computes nothing |
| `set_fee_tier_v1(p_zone_id, p_vendor_count, p_multiplier_bps)` | upsert one tier | Rule 7 — bps, never a float; refuses a vendor_count that duplicates an existing tier |
| `get_commission_v1(p_scope)` | active + future rules for `vendor` or `rider` | Rule 9 |
| `set_commission_rule_v1(p_scope, p_applies_to, p_value_bps, p_effective_from)` | insert a new dated rule | Rule 9 — **must not apply retroactively.** Refuses `effective_from < current_date` |
| `freeze_wallet_v1(p_owner_type, p_owner_id, p_reason, p_idempotency_key)` | `status → frozen` | Rule 5 — idempotent; requires a non-blank reason because `wallets_status_reason_required` already demands one |
| `list_frozen_v1()` | frozen wallets with reason and actor | Admin read only |

`freeze_wallet_v1` is the one that closes a real hole: `wallets_status_reason_required` already demands
a reason for any non-active status, but **nothing can currently set one** — so a wallet can only be
frozen by editing the row directly, which bypasses the audit trail the constraint exists to create.

## 6. Migration order

Each is independently applicable and independently verified, so a failure in one does not leave a
half-built surface.

| # | Migration | Contents |
|---|---|---|
| `023_updated_at_triggers.sql` | `set_updated_at` triggers on all 17 tables | Prerequisite for everything |
| `024_soft_delete_columns.sql` | `deleted_at timestamptz` on the 14 tables in §4a that archive | Prerequisite for the admin delete functions |
| `025_admin_money_config.sql` | `get_fee_rules_v1`, `set_fee_tier_v1`, `get_commission_v1`, `set_commission_rule_v1`, `freeze_wallet_v1`, `list_frozen_v1` | The six, first, because they are the named gap |
| `026_admin_geo_vendor.sql` | `cities`, `areas`, `vendors`, `brands`, `cuisines`, `vendor_areas`, `vendor_cuisines`, `vendor_schedules`, `vendor_holidays`, `vendor_staff` | Enough to load a real merchant |
| `027_admin_menu.sql` | `menu_categories`, `menu_items`, `menu_item_sizes`, `item_options`, `option_choices` | The catalog |
| `028_admin_engagement_users.sql` | `promo_slots`, `notification_templates`, `vouchers`, `feature_flags`, `user_roles` | Config and moderation |
| `029_reviews.sql` | `create_review_v1` (customer) and `admin_set_review_hidden_v1` (admin) | Reviews are unwritable by anyone today |
| `030_admin_read_only.sql` | read RPCs for Tier 2 and the `riders` projection | Nothing to write, by design |
| `031_rls_tests_admin.sql` | extend the 022 suite | See §7 |

`026` and `027` together are the smallest set that lets you load a merchant and take an order. `025` is
independent and comes first because it is the named gap. `023` and `024` are both additive and reversible,
so they are safe to land before anything depends on them.

## 7. Verification — and how it differs from the last pass

The 022 suite gains four checks, so a regression here fails the build rather than waiting to be noticed:

1. every `public.admin_*` and named money function is `SECURITY DEFINER` **and** pins `search_path`
2. none of them accepts a table name as a parameter
3. every `public.admin_*` function writes an `events` row — asserted by executing, not by reading
4. no `anon`/`authenticated` grant exists on any of the 24 writable tables (already covered by check 8,
   but restated here because these functions are the reason it must stay true)

Each migration is then executed by hand, in a rolled-back transaction, covering at minimum:
the happy path · a non-admin caller refused · an unknown `p_patch` key refused · a soft-deleted row
not editable · `events` written exactly once · `updated_at` bumped · money idempotency replayed.

## 8. Resolved by decision

Asked and answered, recorded so the reasoning survives:

| # | Question | Answer |
|---|---|---|
| 1 | `vouchers` — admin-creatable, or read plus soft-delete? | **Read and write.** Full CRUD. A voucher is money-adjacent, so it gets the same care as a fee tier: `idempotency_key` on create, an `events` row, and no retroactive `effective_from` |
| 2 | `reviews` — how far does "write" go? | **`is_hidden` only.** Not the rating, not the comment |
| 3 | `users` — which fields? | **Read only.** Roles move via `user_roles` |
| 4 | `vendor_staff` | **Read and write.** Admin adds and removes staff |
| 5 | Should admin edits *also* write `audit_log`? | **No.** The `events` row in the same transaction is the record, per rule 16. `audit_log` stays append-only and admin reads it |
| 6 | `deleted_at` on the 23 tables that lack it? | **Add to the 14 that archive; amend rule 17** for the 9 whose lifecycle is superseded, frozen, hidden or hard-deleted. See §4a |
| 7 | Should customers be able to leave a review? | **Yes — `create_review_v1` is in scope** |
| 8 | `updated_at` triggers: all 17 or just the Tier 1 ones? | **All 17** |

### The finding that came out of question 2

`reviews` had **no create path at all** — not for a customer, not for an admin. `update_profile_v1` is the
only write RPC in the entire database. So the table, its partial index on `not is_hidden`, and its RLS
are all built, correct, and completely unused. Both functions are now in scope as `029_reviews.sql`:

- `create_review_v1(p_sub_order_id, p_vendor_rating, p_rider_rating, p_comment)` — customer path.
  FR-C-16 rates vendor and rider **separately**, and the CHECK `reviews_rider_rating_needs_rider`
  already enforces that a rider rating needs a rider.
- `admin_set_review_hidden_v1(p_review_id, p_hidden, p_reason)` — moderation, writes `events`.

The moderation lever needs no new schema and no aggregate rebuild. Hiding a bad review removes it from
the rating immediately, because `reviews_vendor_created` is already partial on `not is_hidden`. That is
worth knowing given the reason review control was wanted.

### Not assumed

**Vendor replies.** There is no `vendor_response` column and none is being added — reviews are hide-only
as decided. If a merchant should answer a bad review publicly, that is a separate migration and a
separate decision.

**`voucher_redemptions`.** Tier 2 read-only. An admin never voids or refunds a redemption directly; the
correction is a new voucher, not an edit to history.

## 9. ADRs at risk

| ADR | Risk |
|---|---|
| **New — admin write surface** | Needs a new ADR: per-table functions, hardcoded table name, `jsonb` patch, admin-only. This is the decision that shapes 24 tables of API |
| **New — soft delete as the only admin delete** | Rule 17 implies it; making it explicit prevents a future `admin_hard_delete_v1` |
| ADR 19 (vendor sub-order isolation) | Admin reads must not widen `sub_orders` visibility. Not touched by this plan, but the 022 suite must keep passing |
| ADR 20 (`riders` not client-readable) | Admin surface must not become a way to read `riders` |
| ADR 22 (availability refused, not fingerprinted) | `menu_items.is_available` and `stock_count` are now admin-editable. `017a` refuses on them; this plan must not reintroduce the fingerprint mechanism |
| ADR 8 (`feature_flags` replaces Firebase RC) | `feature_flags` becomes admin-writable; flags are read by the client, so a bad write reaches every app |