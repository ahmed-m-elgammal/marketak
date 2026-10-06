# Changelog

All notable changes to Marketak. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is not yet meaningful — there
is no released version, and the schema is still pre-review.

## [Unreleased]

### Fixed - the Worker was logging everything to `console.log`, so no error was ever visible

Cloudflare Workers Logs is **off by default**. `wrangler tail` against this Worker returned request
metadata and nothing else, and a manual drain of five real notifications returned a complete JSON report
while logging nothing retrievable. The failure that proved it — `device_tokens.deleted_at` does not
exist — was therefore *invisible from the Worker side* and had to be found from the database side, by
grouping five `sqlstate 42703` rows per minute at seconds `:59`, `:00`, `:01`, `:02`, `:03`. Each
minute's five errors were one bad query executed once per claimed notification.

Three changes, all measured against the live project rather than read from documentation:

1. **`[observability.logs] head_sampling_rate = 1`** in `wrangler.toml`. Sampling the drain would
   discard exactly the runs that failed.
2. **New `config/logger.ts`** — one structured line per event, with `console.error` for anything needing
   attention. `$metadata.level` is what `wrangler tail --status error` filters on, so an error sent to
   `log` is invisible to an error filter. That was the single defect: every line used `console.log`.
3. **A stable `ErrorCode` per failure**, so a failure is countable without matching on English prose.
   The FCM statuses are split by what an operator should *do*: `FCM_AUTH` clears the token cache,
   `FCM_TOKEN_DEAD` is expected noise until Phase 4 removes stale tokens, `FCM_THROTTLED` backs off.

Also:

- Every HTTP failure (`401`, `404`, `405`, `503`) previously returned a clear message and recorded
  **nothing**. Each now writes a `warn` (4xx) or `error` (5xx) line carrying `http_status`, `path`,
  `method` and `cf_ray`.
- `cf_ray` is now carried on every line as the join key to Cloudflare's dashboard.
- Every drain run emits one `drain_run_id`, so a single run's lines group even when ticks overlap.
- The per-notification catch now names its stage (`get_template`, `get_device_tokens`, `fcm_send`).
  "request failed" did not distinguish two guarded calls with different causes and different fixes.
- `unwrap()` in `database/supabase.ts` prefixes the PostgREST **sqlstate** into the message, because
  `postgres_logs.message` comes back **empty** and the sqlstate is the only reliably populated field
  there.

Verified live on version `db078acf-61df-4b70-aa55-78d3671e0d46`:

| Request | Status | Log level | Code |
|---|---|---|---|
| `GET /drain` | 405 | `warn` | `CONFIG_INVALID` |
| `POST /drain`, wrong token | 401 | `warn` | `CONFIG_INVALID` |
| `GET /nope` | 404 | `warn` | `CONFIG_INVALID` |
| `POST /drain`, valid, nothing claimed | 200 | `info` | `DELIVERED` |

109 tests pass, up from 77. 32 new: 16 for the logger, 11 for the HTTP surface, 5 for error codes
reaching the report.

### Still not tested: a real push

The pipeline is proven up to the HTTP request that leaves the Worker. `DRY_RUN="log"` means no request
has been made to FCM. `public.device_tokens` is empty and there is no `google-services.json` or
`GoogleService-Info.plist` in the repository, so no token can be registered.

A real device **is** required, and it is required for one specific reason: FCM only delivers to a token
that was issued by a Firebase SDK on an installed app. The service account in `FCM_SERVICE_ACCOUNT_JSON`
authenticates the *sending* side and cannot manufacture a token. Android needs a configured app and a
real device or emulator; iOS additionally needs an APNs key uploaded to Firebase. A deliberately
invalid token would prove the send path reaches Google and is rejected, which is worth doing before a
device exists, and is not the same claim as a delivery.

### Fixed - `eta` had no source at all (`038g`)

The plan stated `eta` "is computed by `compute_quote`, stored on `orders.promised_delivery_at`". **That was
false.** Reading the emitters proved it: `private.compute_quote` returns no ETA key in its result object,
`place_order_v1` inserts 30 columns into `orders` and not one of them is `promised_delivery_at`, and the only
two functions that mention the column are `claim_events_v1` (reading it) and `get_admin_metrics_v1`
(comparing it for the ETA-accuracy report). **Nothing writes it**, so it was permanently null, so
`jsonb_strip_nulls` dropped `{eta}` entirely from `order.picked_up` — "Estimated arrival {eta}" would have
reached the customer with the literal placeholder in the sentence.

`038g` sources `eta` from `delivery_assignments.assigned_at + eta_minutes`, which `claim_order_v1` really
does write at the moment a rider accepts, with the quote-time `promised_delivery_at` kept as a fallback for
when T3.8 populates it. Formatted in `cities.timezone`, not UTC: the previous expression used
`at time zone 'UTC'`, which would have told an Egyptian customer their food arrives at the wrong hour.
Observed `"eta": "02:41"` against a real order.

This was a **pre-existing gap in the emitters**, not something the drain introduced. The drain surfaced it
by being the first code to actually need the value.

### Added - `038h`: P1.7 passes, P1.4 characterised and measured

Installs nothing; reads only. Closes the last two open Phase 1 items by observing behaviour rather than
inspecting `pg_proc`, because four migrations in a row passed their own catalog assertions while shipping a
function that could not run.

**P1.7 PASSED.** Deactivating the one template `order.claimed` routes to, then claiming: 0 rows returned,
the event stays `delivered_at IS NULL`, `attempts` stays 0, and — after reactivating the template — **the
same event is claimable again**. That last step is the one that matters: a guard that skipped the event
forever would pass the first three and be useless, swallowing the notification with no backlog entry and no
alarm. Blocked, not destroyed.

**P1.4 CHARACTERISED, NOT FIXED.** The plan asks for two concurrent `claim_events_v1` calls to return
disjoint sets. That cannot hold, and no test can make it hold: `FOR UPDATE SKIP LOCKED` is a *transaction*
lock, released when the claim transaction commits, which is before the Worker has sent anything. Measured
overlap rather than described. `claim_order_v1` gets the same guarantee with no locking clause at all, via a
guarded single-row `UPDATE ... where rider_id is null`; the push drain cannot use that shape because one
notification spans N rows that must close together. Accepted for MVP with the trigger condition recorded: a
lease becomes mandatory at the first second concurrent consumer.

Also **Phase 2 — the payloads are real now.** 24 events read back from two orders driven end to end, and
three of the plan's findings were corrected by observation:

- `reason`, `refund_amount` and `rider_pay_total` were **already in the payloads**, written by
  `cancel_order_v1` and `claim_order_v1`. Only `affected_items` is genuinely computed in the claim.
- The `eta` claim above.
- **`order.delivered` is emitted by `complete_delivery_v1`, not by `transition_order_v1`** — driving an
  order to `delivered` through transitions alone produces no delivery notification, and the probe fails for
  a reason that is not the one it is testing.

### Added - `038`–`038f`: the push drain, and four functions that shipped broken

The MVP push drain: token registration, a collapsing claim, and a partial-failure-aware mark. Applied to the
live project as `20261005224620` (`038`), `20261005230103` (`038b`), `20261005230315` (`038a`),
plus `038d`, `038e` and `038f`.

| Migration | What it did |
|---|---|
| `038_push_drain` | `private.push_routing()` (7 MVP routes), `claim_events_v1`, `mark_events_delivered_v1`, `service_role`-only grants |
| `038a_push_drain_assertions` | Corrected `register_device_token_v1`; P1.8 grant read-back |
| `038b_push_drain_claim_fix` | `e.v_recipient` → `r.v_recipient`; `min(uuid)` → `select distinct` |
| `038d_push_drain_template_variables` | Added `reason`, `refund_amount`, `rider_pay_total`, `affected_items` |
| `038e_claim_restore_recipient_id` | Restored `recipient_id`; added the runtime call to every migration |
| `038f_claim_vendor_name_for_rejection` | `vendor_name` on `order.vendor_rejected` |

**Every one of `038`, `038a`, `038d` and `038e` applied successfully while shipping a function that could
not run.** This is the single most important thing in this entry.

| # | Symptom | Cause | Found by |
|---|---|---|---|
| 1 | `42703: column e.v_recipient does not exist` | `v_recipient` lives in the routing table, not on `events`; the CTE aliased it `r` | executing `claim_events_v1` |
| 2 | `42883: function min(uuid) does not exist` | PostgreSQL has no `min(uuid)`; the vendor fan-out needed `select distinct` | executing it |
| 3 | `42702: column reference "token" is ambiguous` | `returns table (token text, …)` OUT params shadowed the column in `on conflict (token)` | first registration call |
| 4 | `42803: aggregate functions are not allowed in GROUP BY` | `038d` reordered the CTE and dropped `recipient_id`, so `group by 6` pointed at an aggregate | executing it |
| 5 | `vendor_name` silently null on `order.vendor_rejected` | The customer is the recipient, so the vendor join cannot match — the one template naming a vendor while addressed to the customer | executing against a real rejection |

The cause is identical in all five: **PostgreSQL does not validate a plpgsql body at `create function`
time.** It parses the body into a syntax tree and defers every name and semantic check to first execution.
A `create function` with a wrong column, a wrong group-by ordinal or a wrong aggregate is not an error — it
is a valid function that fails when called.

Three lessons are now encoded rather than just noted:

1. **Every migration that touches a plpgsql function ends with a `perform * from fn(…)` call.** `038e`
   makes this mandatory. Catalog assertions are kept because they check a different thing — `pg_proc`
   proves the grants are right, the call proves the body is right — but only the call catches any of the
   five defects above.
2. **A fix and a probe never share a migration.** The first attempt put the `claim_events_v1` fix and a
   700-line assertion block in one file; the probe failed for an unrelated reason and the transaction rolled
   the fix back with it, leaving the database with the broken function and a migration history claiming
   otherwise. `035` had already established this rule by having no `begin;`/`commit;`.
3. **Read the emitters, do not assume.** `reason`, `refund_amount` and `rider_pay_total` were already in
   the event payloads all along — `cancel_order_v1` and `claim_order_v1` wrote them. Only `affected_items`
   is genuinely derived. Reading `prosrc` before writing the fix turned a three-migration debugging session
   into a two-column change.

**Verified by execution, not by inspection.** A real 3-vendor order driven through `quote_order_v1` →
`place_order_v1` → `transition_order_v1` → `claim_order_v1` → `cancel_order_v1`, rolled back by a sentinel:

| Check | Result |
|---|---|
| Collapse (P1.5) | 3 × `picked_up` → **1** notification carrying `picked_ids: 3`; all 3 marked |
| Fan-out | `vendor_rows: 3`, `vendor_names: 3` — one row per vendor, not one row total |
| Partial failure (P1.3) | `marked_ok: 1, still_open: 1` — the failure stays claimable |
| Unrouted (P1.6) | 18-event census contains no `cancelled` and no `delivered` |
| Grants (P1.8) | `anon_exec: false, auth_exec: false, svc_exec: true` on both drain RPCs |
| Registration (P1.1) | token registered as rider, `language` read from `users.preferred_language` = `ar` |
| `affected_items` | `3`, not `1` — sums `order_items.quantity`, not row count |
| `vendor_name` | `"Kofta"` on the rejection, resolved through the rejected sub_order |

`rider_pay_total` returned `0` and that is **correct**: `rider_pay_rules` is empty, so `private.resolve_pay`
returns 0 with `has_pay_rule` false and the emitter recorded that honestly. Seeding pay rules is Phase 4
configuration, and putting a money default in SQL would break constitution rule 4.

**Not done, deliberately:** P1.4 concurrent disjoint claims. `FOR UPDATE SKIP LOCKED` releases when the claim
transaction commits, but the Worker sends after that, so two concurrent drains would claim the same
events. Accepted for MVP because there is one drain consumer and a 50-event drain finishes in well under a
second; a crashed run is already safe, since events stay undelivered and are reclaimed next tick. A lease
becomes mandatory at the first second concurrent consumer. Recorded in contracts §1.9.0.3.

Also not done: P1.7's probe. The `private.notification_type_exists` guard is in the SQL and has never been
executed against a missing or inactive template.

`038c_push_drain_probe.sql` is written and **not applied**.

### Added - `035_retention_and_cron`: `pg_cron`, four prunes, six schedules

Applied to the live project as version `20261005211015`. **This was the only migration in
`supabase/migrations/` that had never been applied** — 61 files, 60 applied, verified by diffing
filenames against `supabase_migrations.schema_migrations` and then confirming each object in
`pg_extension`, `pg_proc`, `pg_indexes` and `pg_class`. The prunes install now:

| Piece | Window | Schedule |
|---|---|---|
| `private.prune_events` | 7 d, delivered only | `7 * * * *` |
| `private.prune_order_eta_snapshots` | 24 h | `13 * * * *` |
| `private.prune_notifications` | 30 d | `23 3 * * *` |
| `private.prune_rider_location_pings` | 30 d | `41 3 * * *` |
| `private.ensure_partitions` | current + next month | `10 0 1 * *` |
| `vacuum (analyze)` on `events`, `orders`, `order_items`, `cart_items` | — | `37 4 * * *` |

Every prune batches `limit 1000` with `pg_sleep(0.05)` between batches and returns the number of rows
removed, so a cron run is observable. `order_eta_snapshots_computed_at` is added, because that table was
the only one of the four without an index on its prune column.

Three decisions worth recording:

- **`events` stays unpartitioned.** `free-tier-plan.md` §3.7 priced both: 45 MB pruned by `DELETE`
  against 239 MB partitioned, because a monthly partition cannot express a 7-day window.
- **Only delivered events are pruned.** The predicate requires `delivered_at is not null`, so a stuck
  event is never destroyed. A broken dispatcher would otherwise delete its own backlog, and §11 item 8
  — "undelivered `events` older than 1 hour" — would have nothing left to count.
- **`private.ensure_month_partition` was an orphan.** It existed since `001` with zero callers, which
  meant `notifications` would have failed on 2026-12-01 when `notifications_2026_12` did not exist. It
  is now wired up, called only for the two tables that are actually partitioned.

All five maintenance functions are `revoke execute ... from public, anon, authenticated`, asserted by
the migration. This matters more than usual: `create or replace function` re-grants EXECUTE to PUBLIC,
so without the revoke any signed-in client could call `prune_notifications` and delete another user's
inbox.

**Verified by execution, not inspection.** The assertion block inserts aged rows, runs each prune, and
checks both directions — the aged row is gone *and* the fresh row survives, plus an undelivered aged
event survives. All four prunes passed, and the probe rolled itself back through a sentinel exception,
so no test data reached the tables the jobs now delete from.

### Fixed - `035`'s probe referenced three tables it could not have written, and had never been run

`035` shipped with assertions that **could not execute**. It had never been applied, so the block had
never run, and it would have failed on its first attempt. Both defects were in the probe, not the
schema:

1. It inserted into `order_eta_snapshots` and `rider_location_pings` with invented uuids. Both `order_id`
   and `rider_id` are `not null` foreign keys. `rider_id` references `public.riders`, **not**
   `auth.users` — a rider is onboarded through the verification flow, and `on_auth_user_created`
   deliberately creates only `public.users` rows, so a probe user is not a rider row.
2. It passed uuids for `rider_location_pings.id` and `notifications.id`. Both are `bigint` off a
   sequence.

The probe now creates a real `riders` row and a real `orders` row first — the latter needs a unique
`order_number`, a live `user_id`, a non-null `address_snapshot`, and `orders_total_consistent`, which
all-zero money satisfies — and reads both sequence ids back with `returning`. Applied on the third
attempt; the two failures rolled back completely, leaving `pg_cron` itself uninstalled, which is the
behaviour the file's own header argues for by relying on one implicit transaction per file.

This is the `027` lesson again, in a different shape: a file can be reviewed repeatedly, be internally
consistent, and still never have been executed against the database. Reading it is not testing it.

### Found, not fixed - the event catalogue and the emitters disagree, and nothing maps events to templates

Measured against the live database on 2026-10-05. **Documentation only - no migration was applied and
nothing in the database was changed.** Method: every `<noun>.<verb>` string literal was extracted from
`pg_proc.prosrc` across all 127 `public` + `private` functions and compared against
`contracts.md` 3.1. The `events` table is empty, so `select distinct type from events` returns nothing;
the names have to come from the code that writes them.

| Measure | Count |
|---|---|
| Distinct event names emitted by live functions | **63** |
| Names listed in `contracts.md` 3.1 | 18 |
| Emitted under the exact same name | **10** |
| **Never emitted by anything** | **8** |
| Emitted but absent from the 3.1 catalogue | **53** |

The eight catalogue names with no emitter:

| Catalogue name | What the code actually emits |
|---|---|
| `driver.assigned` | `order.claimed` from `claim_order_v1`. Payload is a superset of what 3.1 promises |
| `payment.collected` | `order.collected`, from **both** `collect_cash_v1` and `collect_wallet_v1`. One name for two methods, separated only by payload `method` / `channel` |
| `menu.updated` | **Five** names: `menu_item.updated`, `menu_category.updated`, `menu_item_size.updated`, `item_option.updated`, `option_choice.updated`, plus 10 `.deleted` / `.restored` variants |
| `vendor.rejected_sub_order` | nothing. A rejection is folded into `order.status_changed` with `to = 'rejected'` |
| `driver.arrived` | nothing, and `delivery_assignments.arrived_at` / `arrived_vendor_at` are never written |
| `rider.cash_limit_warning` | nothing, though `effective_cash_limit_v1` computes the number and a template key exists |
| `voucher.created` | `voucher.updated` with `payload->>'created' = true`. Create and update share one name |
| `vendor.earnings_rolled` | nothing. 3.1 marks it "None in v1" anyway |

**The larger problem is three naming layers, and only the middle one is real.**

| Layer | Example | Where |
|---|---|---|
| 1. Catalogue event type | `driver.assigned` | `contracts.md` 3.1 |
| 2. Emitted `events.type` | `order.claimed` | the function body |
| 3. `notification_templates.key` | `rider.order_assigned` | `public.notification_templates`, 19 keys |

Layer 3 is fully populated - 19 keys, ar and en, every one a real template with declared variables.
But **nothing maps layer 2 to layer 3**, and the names do not line up:

- `order.claimed` -> `rider.order_assigned`. Same meaning, different name, nothing records it.
- `order.status_changed` -> **seven** template keys (`order.vendor_accepted`, `order.vendor_rejected`,
  `order.preparing`, `order.ready`, `order.picked_up`, `order.arriving`, `order.delivered`). The fan-out
  rule is not written anywhere, and `order.delivered` **also** exists as its own event, so the customer
  would be told twice without an explicit suppression rule.
- `order.collected` -> **no template at all.** `contracts.md` 4.4 wants an FCM to the customer on
  payment and there is no key to render.
- `order.placed` -> `order.placed` and `vendor.new_order`. **The only clean 1:1 in the set.**

**Why this blocks the Worker.** The dispatcher needs a lookup from an `events` row to a template key
per recipient role. That lookup cannot be inferred, because one entry is one-to-many and another is
one-to-none. It needs an ADR against `contracts.md` 3.1 and 4, and possibly small emitter changes.
Writing the Worker against a guessed mapping would bake the guess into the routing.

Recorded in full, with the per-name table and the decision list, in
`specs/001-platform-foundation/push-notification-plan.md` section 7.

### Fixed - no voucher could ever work, because an empty vendor scope meant "no vendors" (036)

A voucher created with schema defaults was rejected on every cart. `private.compute_quote` tested the
vendor scope with an array-overlap operator:

    elsif v_voucher.applies_to_vendor_ids is not null
       and not (v_voucher.applies_to_vendor_ids && v_vendor_ids) then
      ... VOUCHER_NOT_APPLICABLE

The column is `uuid[] NOT NULL DEFAULT '{}'`, so `is null` is never true and that first operand was
dead code. An empty array overlaps nothing, `&&` is always false, `not false` is true, and the
rejection fired unconditionally. Measured on the live database, same cart, same code, differing only
in scope:

| `applies_to_vendor_ids` | result |
|---|---|
| `{}` (the schema default) | `voucher_discount 0`, `VOUCHER_NOT_APPLICABLE` |
| `[vendor_one]` | `voucher_discount 1000`, no rejection |

So 100% of vouchers were refused rather than only mis-scoped ones, and because
`place_order_v1` re-runs `compute_quote` inside the placing transaction (constitution 2), the customer
could not even check out afterwards without dropping the code.

`compute_quote` is the **only** function in the database that reads `applies_to_vendor_ids`, verified
across all 127 public + private functions, so this one predicate was the entire behaviour of vendor
scoping. The deeper gap was expressive: "applies to every vendor" could not be written at all, and
enumerating ids at creation time would exclude every merchant onboarded later.

One predicate:

    elsif cardinality(v_voucher.applies_to_vendor_ids) > 0
       and not (v_voucher.applies_to_vendor_ids && v_vendor_ids) then

An empty list is now an unrestricted voucher and skips the check. A non-empty list still runs the
overlap test, so single-vendor and multi-vendor scoping are unchanged. The dead `is not null` operand
was removed rather than bypassed, because leaving it in place means dead code that reads as a guard.

**This migration does not restate the function.** It reads the live body from `pg_proc.prosrc` and
substitutes one substring, asserted to match exactly once, so a drifted guard fails the migration
instead of silently producing a different pricing engine. Two earlier drafts retyped all ~400 lines;
the first dropped the declaration of `v_discount` and failed to compile with an error far from the
real cause. That is the same failure mode as the defect being fixed - a hand-maintained copy of a
function that quietly stops matching the function it replaces.

### Added - the voucher admin surface (037)

`select count(*) from pg_proc where proname ilike '%voucher%'` in `public` returned **0** before this
migration. Every other admin entity had an upsert, a soft delete and a restore; vouchers had none, so
a discount code could only be created by writing SQL by hand - no `created_by`, no audit trail.

| Function | Purpose |
|---|---|
| `admin_upsert_voucher_v1(p_patch jsonb, p_id uuid)` | Create or update. Returns the id |
| `admin_delete_voucher_v1(p_id uuid, p_reason text)` | Soft delete. Reason mandatory |
| `admin_restore_voucher_v1(p_id uuid, p_reason text)` | Clear `deleted_at`. Reason mandatory |

Shapes and refusals are copied from `admin_upsert_area_v1` and friends rather than invented:
`private.err(code, message)` for every refusal, an allow-list of patch keys, one `events` row per
mutation in the same transaction, and a mandatory reason on both delete and restore.

Three hazards the table does not explain:

- **`usage_count` is not in the allow-list.** It is system state. A dashboard that could write it
  would reset a usage limit by posting `{"usage_count":0}`.
- **`percentage` is basis points, not percent.** 1000 means 10.0%. Repeated in the function so the
  caller gets `DISCOUNT_PERCENTAGE_INVALID` instead of a raw constraint violation.
- **`free_delivery` needs a positive `discount_value`** even though the number is never read for that
  type, because `vouchers_discount_value_check` is `> 0`. The function substitutes 1.

`applies_to_vendor_ids` accepts the string token `"ALL_VENDORS"` and stores the empty array, which is
how a dashboard says "all shops" now that `036` established that empty means every vendor.

`restore` deliberately does **not** flip `is_active`. Delete and disable are different acts, and a
restore that re-enabled a voucher an admin had already switched off would undo the second decision.

**One real security finding, caught by asserting rather than assuming.** This project's
`pg_default_acl` for `public` functions grants EXECUTE to `anon`, so `CREATE OR REPLACE` grants it
automatically and a `revoke` written *before* the create is undone by the create. All three functions
were left callable by `anon`. Every pre-existing RPC is correctly denied to `anon`
(`admin_upsert_area_v1`, `quote_order_v1`, `search_catalog_v1`, `place_order_v1` all `false`), so these
would have been the only anonymous entry points into the admin surface. The admin gate inside still
refused them at run time, so this was defence in depth rather than a live hole - but a granted EXECUTE
on a `SECURITY DEFINER` function is never acceptable. Fixed by revoking *after* the create, adding
`alter default privileges in schema public revoke execute on functions from anon`, and asserting the
privilege is absent by reading it back from the catalog.

`036` and `037` were proven by **executing** the surface, 28 checks across two phases, plus a full
two-vendor checkout. Four defects were caught that reading the code would not have found: two real
ones in the new function (`'ALL_VENDORS'::jsonb` is not valid JSON, so it raised `22P02`; and
`case when p_patch ? 'k' and jsonb_typeof(...) <> 'null'` conflates an absent key with an explicit
null, so `{"max_discount_cap":null}` silently kept the old value) and two in the probe harness itself.

### Known gaps, not fixed

- **Reviews never roll up.** No trigger on `public.reviews` updates `vendors.rating_avg` or
  `rating_count`, so a 5-star review leaves a vendor at `0.00` / `0` forever. Reproduced on the live
  database. Affects C-16 and every vendor rating surface. Needs a trigger.
- **No `claim_events_v1`,** so the bulk push dispatcher described in `free-tier-plan.md` has nothing to
  call. `claim_order_v1` exists; the event counterpart does not.
- **The blanket `anon=X` default ACL** is a standing trap for any new function in `public`. `037`
  corrected it for the default going forward, but `storage`, `graphql` and `graphql_public` still
  carry it.

### Fixed - the catalog was unusable, and every assertion said it was fine (027a)

`027_admin_menu` was applied and green, and the catalog could not be used. Two independent defects,
both shipped behind a fully passing assertion block.

**`admin_upsert_menu_item_v1` had never once succeeded.** It read the patch's `tags` with
`coalesce((p_patch->'tags')::text[], ...)`. PostgreSQL has **no `jsonb → text[]` cast** — there is no
`pg_cast` entry and no assignment cast; `jsonb_array_elements_text` is the only route. The cast
resolves when the statement runs, not when the key is looked up, so the failure was unconditional:
`create, no tags key → cannot cast type jsonb to text[]`, `create, tags = [] → same`, and
`update, {"name":…} → same`. Every create and every update of a menu item raised. The other
fourteen functions were fine, which is why the file reads as healthy — fourteen working functions
hide one dead one, and a catalog with no dishes still looks like a catalog until someone tries to add
one.

The irony is the point. `027:349-357` adds a dedicated `tags` validator whose stated reason is that
"a jsonb scalar or an array of non-strings would fail the cast with a raw driver error instead of a
code, so it is checked here." The guard was written, it is correct, and it passed. The line it was
guarding could not execute at all.

Fixed with `array(select jsonb_array_elements_text(p_patch->'tags'))`. The **update** branch needed a
`case when p_patch ? 'tags'` rather than a `coalesce`, and that distinction is load-bearing: the new
expression yields `{}` rather than NULL for an absent key, so a `coalesce` would have taken `{}` over
`mi.tags` and silently cleared the tags of every item on every unrelated edit. The `case` encodes the
three cases the column actually has — absent means LEAVE ALONE, present means REPLACE, `[]` means
CLEAR — and it is the same shape the three `jsonb` columns immediately above it already used.

**`item_options_read` referenced its own table, and took `option_choices` down with it.** The policy
`027` added to fix `item_options` having no hiding lever wrote its vendor-staff branch as
`exists (select 1 from public.item_options io join public.menu_items mi … )` — on the policy **on
`public.item_options`**. A policy naming its own table in its own `USING` expression is a loop, and
PostgreSQL refuses to plan it: `42P17 infinite recursion detected in policy for relation
"item_options"` on every statement. Not a silent empty result — a hard error. `option_choices_read`
was collateral, because it subqueries `item_options`, so expanding its policy expanded the broken one.
Measured across all five catalog tables:

| role | `item_options` | `option_choices` | `menu_categories` / `menu_items` / `menu_item_sizes` |
|---|---|---|---|
| `anon` | permission denied (no grant) | permission denied (no grant) | permission denied (no grant) |
| admin | **42P17 infinite recursion** | **42P17 infinite recursion** | OK |
| customer | **42P17 infinite recursion** | **42P17 infinite recursion** | OK |

Two of five catalog tables — the item-customisation group and its choices — were unreadable to every
signed-in client, admin console included. The three that survived are the tell: they reach
`menu_items` through their own `item_id` and never name their own table. `027`'s header claimed the
policy "mirrors `menu_item_sizes_read`", and mirroring it is precisely the fix.

The six admin functions over those two tables kept working, and that is worth recording because it is
*why* this shipped. They are `SECURITY DEFINER` and their owner bypasses RLS, so they never expand the
policy. Their correctness depended on who owns the functions — an accident of deployment that no
assertion checked and no test would have caught.

**Why nothing caught either.** All thirteen of `027`'s assertions read `pg_proc` and `pg_policies`
**as text**. None executed a function body. None executed a `SELECT`. Assertion 12 checked
`item_options_read`'s qual for `%is_available%` and `%deleted_at%` — both substrings are present in a
policy that raises on every use. `tests.run_all()` was 11/11 green throughout, because none of its
eleven checks runs a policy either; it counts them.

That is the general lesson and the reason this entry is here rather than a line about one file. **A
green assertion block that only inspects the catalog is not evidence that anything runs.** A body that
is syntactically perfect and semantically dead passes every text-shaped check there is. So `027a` ships
the two assertions `027` needed:

1. **Execute the policy.** Switch to a client role and actually issue `SELECT count(*)` against
   `item_options` and `option_choices`; fail if the planner refuses. Stated over `pg_policies` as a
   *general* guard — no policy in the database may name its own table — with the negative test in both
   directions, because a regex that cannot fail is not a check. Validated against all 62 tables: it
   flagged exactly the one offender and nothing else, and the lookbehind is what stops a qualified
   column reference like `menu_item_sizes.item_id` from matching.
2. **Execute the function.** A real admin, vendor, category and item created inside a subtransaction
   that is rolled back by raising a sentinel, asserting tags written, tags preserved when the key is
   absent, and tags cleared by `[]` — then a follow-up check that the probe leaked no rows. Unconditional
   by construction: the probe seeds its own vendor rather than borrowing one, because an assertion that
   quietly skips when the table it needs is empty is a fail-open, which is the defect this migration
   exists to remove.

**Three of my own assertions were wrong before the migration would apply**, all caught by
fail-closed rather than by inspection, and all three are recorded in the file because each is a trap:

- The self-reference negative test was written `public.item_options io`, which the lookbehind correctly
  **rejects** — a dot in front of the name means it is a column reference, not a `FROM` item. PostgreSQL
  renders policy quals against `search_path`, so a real self-reference appears unqualified. The probe
  was fighting its own pattern.
- `tags = []` was asserted with `coalesce(array_to_string(tags, ','), '<empty>')`. An empty array
  renders as the empty **string**, not NULL, so the coalesce never fired.
- The same check then used `array_length`, which returns **NULL** for `{}` rather than 0, so a
  `coalesce` against 0 never fired either. Only `cardinality` distinguishes cleared from absent:
  `cardinality('{}')` is 0, `cardinality(NULL)` is NULL.

An assertion that cannot tell "cleared" from "absent" passes for the wrong reason, which is the same
failure mode as a regex that cannot fail. `admin-crud-plan.md` §7 has been amended to say so.

**Re-verified after the fix**, all against the live project in rolled-back transactions: **59
behavioural probes pass, 0 fail**, and the fifteen-function auth gate is 30/30 — `anon` refused on all
fifteen at the GRANT layer, and a signed-in non-admin refused with `NOT_AUTHORIZED` on all fifteen,
never reaching an argument check. `tests.run_all()` remains 11/11. No fixture rows leaked; the
database is as empty as it was.

### Added - the catalog write surface (027)

Fifteen functions over `menu_categories`, `menu_items`, `menu_item_sizes`, `item_options` and
`option_choices` — five upserts, five soft deletes, five restores — completing the "load a merchant
and take an order" minimum of `admin-crud-plan.md` §6 alongside `026`.

**Read this entry together with `027a` above.** `027` shipped applied, passed its own thirteen
assertions, passed `tests.run_all()` 11/11, and was unusable: one of its fifteen functions had never
succeeded and two of its five tables could not be read by any client. The fourteen working functions
are real and are unchanged by `027a`.

**Soft delete means something different on each of the five tables, and this is the finding that
shaped the file.** `menu_categories_read` and `menu_items_read` filter `deleted_at`, so `deleted_at`
alone hides them. `menu_item_sizes_read` and `option_choices_read` do **not** filter it, and
`item_options` had no lever at all before this migration. So the three deletes set
`is_available = false` as well as `deleted_at`: a delete that set only `deleted_at` would have
returned success, written its `events` row, and changed nothing a customer can see.
`admin_restore_*` clears `deleted_at` and nothing else — archive is not a covert publish, so a vendor
who unpublished something on purpose does not find that choice reversed by a restore.

**`item_options` gains the column it never had**: `is_available boolean not null default true`, plus
a replacement read policy. Existing rows default to visible, so applying this changed nothing until an
admin wrote. That policy's first draft is what `027a` had to repair.

**Two refusals that prevent data the checkout cannot handle.** `option_selections_sane` only enforces
`max_selections >= min_selections`, which permits `is_required = true` with `max_selections = 0` — a
group the customer must choose from and may choose nothing from. The same contradiction is reachable by
deleting choices until fewer remain than `max_selections` promises, or by raising `max_selections` above
the number of live choices. `OPTION_REQUIRED_UNSATISFIABLE` and `OPTION_UNSATISFIABLE` refuse all three,
which keeps every option satisfiable — the difference between an admin mistake caught in the console and
an `OPTION_UNAVAILABLE` raised against a customer holding a cart.

**Parents are refused while children are live.** `CATEGORY_NOT_EMPTY`, `ITEM_NOT_EMPTY`,
`OPTION_NOT_EMPTY`. This is not tidiness: `menu_items_read` does not check the parent category, and
`menu_item_sizes_read` / `option_choices_read` do not check the parent item, so a soft-deleted parent
with live children would leave those children directly readable. Rather than amend three applied read
policies for a hole no admin action could reach, the admin surface refuses the state that produces it.
Subtrees go dark in reverse order, which is also the order an admin thinks in.

**`menu_items.vendor_id` is not admin-writable and that is the truth, not an omission.**
`sync_menu_item_vendor` is a BEFORE INSERT OR UPDATE trigger that overwrites it from the parent
category's vendor, so the column is derived; passing `vendor_id` returns `UNKNOWN_KEY`. Moving a
*category* between vendors is refused outright with `IMMUTABLE_FIELD` rather than merely left off the
allowlist, because the trigger recomputes every item's vendor from its category — re-homing one
category silently re-homes all forty of its items to a different merchant's storefront, with a different
rating, different reviews and a different payout ledger. Delete and recreate instead.

**Money is in piastres and always was.** `base_price`, `menu_item_sizes.price` and
`option_choices.price_modifier` are integer columns passed through untouched; an admin sending `250`
means 2.50 EGP. The file contains no currency literal and no conversion. A dashboard that renders "250"
as "250 EGP" is a dashboard bug, and one that sends a float here is a rejected insert.

### Added - the admin write surface for geography and vendors (026)

Thirty functions over the ten tables `admin-crud-plan.md` §6 assigns to `026`. **A real merchant now
loads end-to-end through this surface and appears in the customer app** — verified by execution.

Ten upserts, ten soft deletes, ten restores. The six rules from `admin-crud-plan.md` §3 are applied
uniformly: the table name is a **literal** in every function body, `p_patch` is validated against an
explicit key allowlist, `private.is_admin()` is the **first** statement, every name is fully qualified
under `search_path = ''`, one `events` row per mutation in the same transaction, and every function
refuses to touch a soft-deleted row except through its matching restore.

**Verified end to end by execution.** A full merchant — Cairo, a Zamalek area, a brand, a cuisine, a
vendor, an area mapping with a 15–25 minute ETA, a cuisine mapping, two split shifts on the same
weekday, a holiday and a staff owner — created through the RPCs in twelve calls. A customer session
then saw exactly one approved vendor, "Koshary Abdel Rahman". The Arabic `name_normalized` generated
column auto-filled as `كشري عبد الرحمن`, confirming the 015 search plumbing still works on a row this
surface created.

**What the allowlists deliberately refuse**, and why it matters: `vendors.rating_avg`,
`rating_count` and `menu_version` are all rejected with `UNKNOWN_KEY`. `menu_version` is bumped by the
`005b` catalog triggers and an admin setting it would desynchronise the R2 snapshot pointer from the
catalog — the same class of bug `014a` fixed. The generated `*_normalized` columns are rejected too,
which is the correct answer since no caller can set them, including this function.

**The lifecycle is real, and reversible.** Deleting a vendor set `deleted_at` **and** `is_active`
(two flags disagreeing about one intent is how a vendor reappears after deletion). The row survived —
soft delete, never `DELETE`. The customer's approved-vendor count went 1 → 0 → 1 across
delete/restore. Editing a soft-deleted row returned `NOT_FOUND`, deleting twice returned
`ALREADY_DELETED`, restoring a live row returned `NOT_DELETED`, and a customer attempting any of the
three got `NOT_AUTHORIZED` before reaching a single argument check. Restore re-activates but does
**not** re-approve, because publishing to the customer app is a separate decision.

**23 rejection paths verified individually**, each returning its own code rather than a raw
constraint violation: `UNKNOWN_KEY`, `PATCH_EMPTY`, `NOT_AUTHORIZED`, `REASON_REQUIRED`, `KEY_REQUIRED`,
`NOT_FOUND`, `ALREADY_DELETED`, `NOT_DELETED`, `ETA_RANGE_INVALID`, plus the schema's own CHECKs
catching `closes_at <= opens_at`, `day_of_week = 9` and an invalid `staff_role`. The
`eta_maxutes > eta_minutes` rule is checked **in the function** because there is no CHECK on
`vendor_areas` for it, and an inverted range would silently produce nonsense delivery promises.

**Role matrix.** `anon` refused on all 30 by GRANT. Customer, vendor staff and rider refused with
`NOT_AUTHORIZED` on all 30. Admin permitted. Crucially, `is_admin()` runs *before* the allowlist
check, so a non-admin never learns whether a column exists — confirmed by the refusal reason being
`NOT_AUTHORIZED` and never `UNKNOWN_KEY` for a non-admin.

**Two assertion bugs I shipped and caught, both the same class.** Assertion 8 (no admin function
issues a `DELETE`) shipped with the regex `\melete\b`, which matches the literal word "elete" and
therefore **nothing** — it passed because it could not fail. The obvious repair,
`\mdelete\s+from\b`, also matched nothing, because the trailing `\b` does not behave as expected in
that position on this Postgres 17 build. The pattern that works is `(^|[^a-z_])delete\s+from`, which
matches a real `DELETE` and ignores the `deleted_at` column this file is full of. Both a
positive and a negative test now run inside the migration, because a regex that cannot fail is not a
check — the same defect `022c` was written about.

### Added - the two missing lifecycle columns (024)

Constitution II.17 was violated in two directions, and `023` closed only one of them.

- **`deleted_at timestamptz`** (nullable) on the 14 tables that genuinely archive. This was the
  blocking prerequisite: 8 of the 10 tables in `026` are among them, so no admin delete function could
  be written without it. The nine tables whose lifecycle is superseded, frozen, hidden or
  hard-deleted **deliberately do not get one**, and an assertion checks their absence — a future
  migration that "helpfully" added `deleted_at` to `commission_rules` would destroy the dated history
  constitution I.9 depends on.
- **`updated_at timestamptz not null default now()`** plus the `set_updated_at` trigger on the five
  tables that owned no such column: `cuisines`, `vendor_areas`, `vendor_cuisines`, `vendor_holidays`,
  `vendor_staff`. This **closes open question 3.31**, recorded yesterday. Five of the ten tables in
  `026` are among them, so before this an admin edit to a staff grant or a holiday moved no timestamp
  at all.

One index, `vendor_areas_live`. The other eighteen tables here are small configuration, and fifteen
partial indexes on tables that will never need them is fifteen things to maintain; `vendor_areas` is
the exception because it grows with (vendors × areas). `cuisines`, `vendor_areas` and
`vendor_cuisines` deliberately get **no** `created_at`: a cuisine is a code and a `vendor_cuisines` row
is a pair of ids, so a creation timestamp on them is a second thing to keep true.

Six assertion groups, and the suite's own `updated_at_trigger_offenders()` is called rather than a
second hand-rolled predicate, so the migration and the suite cannot disagree about what "has the
trigger" means. Result: **27 tables own `deleted_at`, 41 own `updated_at`, 41 triggers, zero
offenders.**

### Added - the six unbuilt money functions (025)

Closes **open question 3.30**. `contracts.md` §1.8 names thirteen money functions; five shipped in
`019`. The eight-name gap was a naming artefact — `run_payout_v1` absorbs three and `get_wallet_v1`
ships as `get_wallet_balance_v1` — and six capabilities genuinely had no writer. All six now exist.

**The hole this closes was live, not theoretical.** `wallets_status_reason_required` already demands
a reason for any non-active status and `wallets_status_check` already accepted `frozen` and
`review`, but **nothing could set one**. The only way to freeze a wallet was a direct `UPDATE` — which
is precisely the audit-trail bypass the constraint was written to prevent. `freeze_wallet_v1` is
admin-only, requires a non-blank reason, and writes a `wallet.frozen` event in the same transaction.

| Function | What it does |
|---|---|
| `get_fee_rules_v1(p_zone_id)` | Zone fee config + every tier, one row per tier, plus the service-fee settings. Not admin-gated: `014` already publishes those tables and a customer is quoted from them |
| `set_fee_tier_v1(p_zone_id, p_vendor_count, p_multiplier_bps)` | Upsert one tier. **Basis points only** — an integer, never a float or a percentage string. Admin. Writes `fee_tier.set` |
| `get_commission_v1(p_scope, p_target_id)` | Commission rules with `is_effective_now` computed by **the same predicate `private.resolve_pay` prices with**, so an admin read cannot disagree with a delivery |
| `set_commission_rule_v1(p_scope, p_applies_to, p_value_bps, p_effective_from, p_target_id, p_commission_type)` | Insert a **new dated rule**, closing the previous one. Admin. Writes `commission.activated` |
| `freeze_wallet_v1(p_owner_type, p_owner_id, p_reason, p_idempotency_key)` | Freeze a vendor or rider wallet. Bumps `version`, never touches `balance`. Admin. Writes `wallet.frozen` |
| `list_frozen_v1()` | Frozen **and** under-review wallets with reasons and balances. Admin — a freeze reason is an investigation note, not public configuration |

**Two decisions, asked rather than assumed, and both recorded in `contracts.md` §1.8:**

- `set_commission_rule_v1` **supersedes** rather than editing in place. `contracts.md` originally gave
  it `(p_rule_id, p_value, p_is_active)`; `admin-crud-plan.md` §5 gives it the dated-insert form. The
  plan wins, even though `contracts.md` outranks it under `data-model.md` §16, because in-place editing
  cannot satisfy constitution I.9's auditability — overwriting the row makes "what was the rate last
  month" unanswerable, and I.9 exists so a retroactive commission is a *detectable* bug rather than a
  silent one. `admin-crud-plan.md` §4a independently reaches the same conclusion by refusing
  `deleted_at` on this table for the same reason.
- `freeze_wallet_v1` gained a fourth `p_idempotency_key` argument, which §1.8's three-argument form
  lacks. A replay returns `frozen = false` and writes **nothing** — no second event, no version bump,
  `updated_at` untouched. Verified by execution.

**Rule 9 is enforced by refusal, not by clamping.** A `p_effective_from` before today raises
`EFFECTIVE_FROM_IN_PAST`. Clamping would report success for a request the caller did not make.
A second, distinct refusal was found by executing and not by reading: `current_date` is **midnight**,
and the rule being superseded was inserted during the day, so closing the old rule at midnight
violated `commission_rules_window_valid` (`effective_until > effective_from`, strictly greater) **on
the old row, which the caller never touched**. That now raises `EFFECTIVE_FROM_INVALID` carrying the
timestamp to compare against. Omitting the argument takes `now()` and is the right way to say
"activate now".

**One omission the migration's own assertion caught on the first apply.** The `grant execute ...
to authenticated` lines were written without their paired `revoke ... from public, anon`. Postgres
grants EXECUTE to `PUBLIC` by default, so the grant *added* a holder rather than transferring one and
`anon` could call all six. Every existing RPC pairs the two (`019:961-965`, `020:323`, `016:333`);
assertion 5 in the closing `DO` block now checks `anon` holds no EXECUTE, which is what surfaced it.
The `service_role` grant that `019b` lost the same way is noted there.

**Verified against the live database, in rolled-back transactions.** 40 behavioural assertions across
the six functions, plus a role matrix over `anon` / `customer` / `vendor_staff` / `rider` / `admin`:
`anon` refused on all six by grant; the two configuration readers callable by every signed-in role as
designed; the four mutating functions refused with `NOT_AUTHORIZED` to customer, vendor staff and
rider, and permitted to admin. Fee tiers: insert then upsert in place, never a duplicate row,
`created_at` survives an edit, exactly one `events` row per call (measured 1:1 across six calls), and
every rejection path (`VENDOR_COUNT_INVALID` at 0 and 11, `MULTIPLIER_INVALID` at -1 and 100001,
`ZONE_NOT_FOUND` for null and unknown, `NOT_AUTHORIZED`). Commission: supersede confirmed — the old row
is closed and retained, windows contiguous, exactly one rule open at a time, the rider seed untouched
by a vendor-scope change, and the three refused calls wrote zero events. Wallet: freeze sets status
and reason, `version` 3→4, **`balance` unchanged at 50000** (it moves only with the ledger), replay is
inert, escalation from `review` is legal, and `list_frozen_v1` returns both wallets with reasons and
balances. Suite **11 of 11**. Database left exactly as found: every fixture table at 0, `settings` at
its seeded 13, `commission_rules` still the two seed rows with the rider cut active and the vendor row
inactive.

### Fixed - constitution II.17 on 17 tables (023)

`updated_at timestamptz not null default now()` was declared on 36 tables between `002` and `012`.
Nineteen got a `set_updated_at` trigger. **Seventeen did not** — a live rule 17 violation across
`001`–`015`, and open question 3.20 since `016`.

**Why it survived ten migrations.** Almost every one of those tables is mutated only through an RPC
that assigns `updated_at = now()` in the same `SET` list as the data it changes. That hides the
missing trigger rather than compensating for it: the timestamp is right, so nothing looks broken.
`016` found the gap while reviewing `users`, and correctly refused to fix one arbitrary table in a
migration assigned three functions. `023` adds all 17 together.

**No behaviour change anywhere.** Every write that moved `updated_at` before still moves it, by the
same mechanism. This closes a constitution violation and makes an invariant true; it does not fix a
user-visible bug, because there was no user-visible bug.

**What shipped**
- 17 `set_updated_at` BEFORE UPDATE row triggers. `public.set_updated_at()` already existed from
  `006_cart.sql:17` and is deliberately **not** redefined — 19 triggers already depend on it.
- `tests.updated_at_trigger_offenders()`, the suite's **eleventh** check, plus the runner rebuilt
  around it. `admin-crud-plan.md` §7 defers all suite work to `031`; this one exception was decided
  rather than assumed, because the guard for an invariant belongs with the migration that establishes
  it. Without it the next table that declares the column and forgets the trigger reproduces this
  defect silently — which is how these 17 accumulated.
- A closing `DO` block asserting four postconditions: exactly 17 triggers created against a baseline
  captured at the top of the file, all 17 present **by name** (so a trigger on the wrong table fails
  rather than balancing the count), the suite's own check reporting zero offenders, and
  `set_updated_at()` still non-`SECURITY DEFINER` with a pinned `search_path`.

**Four explicit assignments are now redundant, and are not edited.** `005a`/`005b` set
`updated_at = now()` on `vendors` inside `bump_version_for_*`; `016:516` and `016:820` do the same on
`users`. All four now assign the same value twice and the two agree, because `now()` is the
transaction timestamp and both writers see it in the same statement. `data-model.md` §15.1 rule 3
forbids editing an applied migration, so the redundancy stands and `016`'s comment predicting this
exact outcome is now historical rather than current.

**Verified by hand against the live database**, in rolled-back transactions. `settings` is the only
one of the 17 with rows (13 seeded), so it carries the behavioural tests: a no-op `UPDATE` moves
`updated_at`; an explicit `updated_at = now()` and the trigger produce the identical value; and a
deliberately backdated `updated_at` is overwritten, so no caller can backdate a row. Coexistence was
tested on all three tables that already had a trigger — `menu_items` still derives `vendor_id`
correctly with two BEFORE row triggers present, and one `UPDATE` both re-derives the vendor and bumps
`updated_at`; `vendors` still takes exactly one `menu_version` bump per statement, asserted as a
delta from a captured baseline rather than an assumed number; `delivery_fee_tiers` updates one tier
without disturbing the other two, with the deferred `trg_fee_tiers_monotonic` constraint trigger
still clean. `users` was tested with the `016` update shape and with
`trg_user_contact_to_rider` firing alongside. Suite: **11 of 11 pass**. Negative test: dropping
`trg_brands_updated_at` makes check 11 fail and name `public.brands` — the check is not a tautology.
All test rows rolled back; `cities`, `menu_items`, `users`, `vendors` and `auth.users` all at 0.

**Three corrections made during the work, all caught by checking rather than assuming:**
- The first `tgtype` bitmask was wrong (`ROW`/`BEFORE`/`INSTEAD` read as 1/2/8 instead of 1/2/64).
  Caught by querying the 19 existing triggers before applying anything: they report `tgtype = 19`.
- The header comment claimed 35 tables and "eighteen" pre-existing. The catalog says 36 and 19.
- `menu_version = 4` looked like a double-bump and was not: three prior `INSERT`s had already bumped
  it. The assertion became a delta from a captured baseline.

**Not fixed, and recorded as open question 3.31.** `cuisines`, `vendor_areas`, `vendor_cuisines`,
`vendor_holidays` and `vendor_staff` have **no `updated_at` column at all**, so no trigger could be
added to them. All five are Tier 1 in `admin-crud-plan.md` §4 and all five are written by `026`, so
rule 17 is still violated on tables the admin surface writes — and `024` makes that easy to miss,
because it gives four of them a `deleted_at` and `vendor_staff` already has one, so each looks
lifecycle-complete while owning no `updated_at`. Decided: `023` stays triggers-only. Two further
classes are recorded there too — `favorites`, `favorite_items`, `device_tokens` and `driver_shifts`
are mutable and own no `updated_at` (Tier 2/3), and `user_roles` owns no timestamp of any kind as the
consequence of two recorded decisions in the admin plan.

### Fixed - stock on the checkout path (017a, 017b)

Two real defects in `017_rpc_core.sql`, both found by executing the purchase path rather than reading it.

**A sold-out item could be bought.** With `stock_count = 0` on the only line in the cart,
`quote_order_v1` issued a quote and `place_order_v1` completed the order. `stock_count` was not consulted
anywhere on the purchase path: `005_catalog.sql:64` declares it with `null = unlimited`, the only other
reference in any migration is `020_rpc_read.sql:528` *reading* it to hide sold-out items from browse, and
the fingerprint at `017_rpc_core.sql:579-592` contains neither `is_available` nor `stock_count`. That
contradicted `contracts.md:477` (`OUT_OF_STOCK`) and `spec.md:519`, which claimed availability *is*
fingerprinted. `017a` carries `stock_count` into the `private.compute_quote` pricing CTEs and adds an
`OUT_OF_STOCK` rejection with an Arabic message, in the same shape as the six already there.

**The refusal was itself broken, so every rejection reached the client as a crash.** With `is_available`
flipped false between quote and place the order was correctly not placed, but the error was
`SQLSTATE 22P02 invalid input syntax for type json` instead of a `contracts.md` code. Cause: in
`place_order_v1:809` `||` binds **tighter** than `->`, so
`'cart has unpriceable lines: ' || v_q -> 'rejections'::text` concatenates the prose first and then hands
it to `->` as JSON — `Token "cart" is invalid`, reproduced standalone. `private.err` was never entered,
because the crash happens while evaluating its argument. So `ITEM_UNAVAILABLE`, `ITEM_RETIRED`,
`VENDOR_UNAVAILABLE` and the rest have all been surfacing as opaque Postgres errors. Fixed by
parenthesising; `CART_NOT_PLACABLE` is reachable for the first time.

**Refuse only, no decrement** — ADR 22. Stock is not added to the fingerprint and is not decremented.
`null = unlimited` keeps its meaning and stock stays vendor-maintained. **Known and accepted: two
customers can still race for the last unit.** `spec.md:519` has been corrected, since it claimed the
opposite mechanism.

Verified after the repair: `delivery_fee` 2500 and order total 22500 on a 2 × 10,000 piastre basket,
`settlement_status = payable`, `special_instructions` and `image_path` preserved, `order.placed` event
written, another user's idempotency key refused with `IDEMPOTENCY_KEY_TAKEN`, a sold-out line refused
`OUT_OF_STOCK` at quote and `CART_NOT_PLACABLE` at place, and an unavailable line refused with
`CART_NOT_PLACABLE` rather than 22P02.

### Fixed - `017a` was applied from the wrong bytes (017b)

**`017a` was verified on disk and then a hand-typed copy was applied instead**, which silently dropped
large parts of both function bodies. The diff was real evidence, but it described a file that never
reached the database; nothing compared what was applied against what was checked.

Lost from `compute_quote`: the block assigning `v_base_fee`, `v_free_radius`, `v_per_km`,
`v_max_distance` and `v_max_vendors` from the delivery zone — so the spec 2.5 fee formula ran on NULLs —
plus `CART_EMPTY`, six real error codes, the service-fee settings load, and the attributes, which were
made `SECURITY DEFINER` and `STABLE` when they must be `SECURITY INVOKER` and `VOLATILE`. Lost from
`place_order_v1`: **`IDEMPOTENCY_KEY_TAKEN`**, without which one customer's idempotency key returns
another customer's order and the early return skips every later check, plus `settlement_status`,
`platform_fee_amount`, `image_path`, `special_instructions` and the correct `order.placed` event.

Caught by an attribute probe seconds after applying — not by a behaviour test, which is the part that
should have run first; one `delivery_fee = 2500` assertion would have failed immediately. `017b` restores
both bodies byte-identical to `017a` and adds the explicit
`ALTER FUNCTION private.compute_quote(...) SECURITY INVOKER` that `CREATE OR REPLACE` cannot perform.
Repaired and verified by attribute probe, an acceptance checklist over every dropped element, and the
behavioural pass above. Full record in `specs/001-platform-foundation/001-020-integrity-notes.md` §7a-bis.

No table, column or index was created or dropped at any point: `public` held 62 tables before and after,
and all 62 trace to a migration or to the partition functions in `010`/`014`.

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

Migrations 001–015 written **and applied** to the live project `erxxsebcqqcpkipzcdhg`. 62 tables and
partitions, 239 indexes, 115 RLS policies, 10 trigram indexes, 0 tables without RLS, 0 unindexed foreign
keys, 0 client write grants, 0 grants to `anon`.

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

### Fixed - rider revenue scaled by the fee, not by the basis points (018a)

`private.resolve_pay` had two branches and they disagreed. The branch for a rider with a matching
`rider_pay_rules` row computed launch revenue as a commission **on** the delivery fee; the branch for
a rider with none returned `commission_rules.value` **unscaled**. That column is basis points, so the
no-rule branch booked `2000` where the fee-based answer was `550` — overstating revenue by a factor of
fee ÷ 10000, which is 3.6× on a 2750 fee.

**This was not an edge case. It was the only behaviour available.** The seed ships a live
`commission_rules` row for `scope=rider, applies_to=delivery_fee, value=2000` but ships **no**
`rider_pay_rules` rows at all, because rider pay is per-rider configuration an admin adds later. On
this project the broken branch was the branch every rider could reach, so every delivery would have
booked 2000 revenue while paying the rider 0. The two errors point in opposite directions, so no
reconciliation would have caught it.

**Why it survived the first pass: my test checked two of the three outputs of the branch under test.**
Every claim test in 018 seeded a pay rule, so the no-rule path was only ever reached by a rider id that
could not exist — and in that run I asserted `has_rule = false` and pay `= 0` and said nothing about
revenue. The hole was the assertion, not the code.

`018` is already applied and committed, so this is a forward migration in the same spirit as `005a`,
`007a`, `010a` and `014a`. Replaying `018` then `018a` on a fresh database produces byte-identical
function bodies to the live project.

Verified by direct SQL, 52 assertions in two batches plus 21 structural checks:

| Suite | Assertions | Result |
|---|---|---|
| `resolve_pay` both branches, fee scaling, rounding, expiry, cross-table leakage | 27 | 26 pass, 1 bad expectation of mine (see below) |
| full lifecycle: claim → collect → float → complete → replay → isolation → ledger immutability | 25 | pass |
| AST markers present / known-bad patterns absent across all 9 functions | 21 | pass |

Confirmed by execution: the no-rule branch now returns 20% of the actual fee and scales correctly in
both directions (2500 → 500, 1000 → 200, 10000 → 2000, 0 → 0); rounding is half-away-from-zero
(2750 × 1337 bps = 367.675 → 368); the with-rule branch is unchanged at pay 3334 / revenue 550; a
rider-specific rule still beats the city default; an expired default correctly falls through to the
no-rule branch; and a rule for `applies_to=subtotal` or `scope=vendor` does **not** leak into rider
delivery revenue. End to end, the frozen figure and the `rider_cut` ledger entry are both 500 on a
2500 fee rather than 2000.

Two of my own test expectations were wrong and are recorded rather than quietly corrected. I asserted
that a city with no commission rule returns 0 revenue, but the seed already provides the rider rule, so
the correct way to test that branch is to deactivate the seeded row inside the transaction. And one
assertion tried to print what the old code "would have" returned by recomputing the arithmetic, which
produced the fixed value instead; the old value had already been proven directly.

### Added - reconciliation and payouts (019)

`adjust_wallet_v1`, `get_wallet_balance_v1`, `run_payout_v1`, `reconcile_day_v1`,
`get_platform_float_v1` — the five functions `data-model.md` §15.2 row 019 assigns. Plus
`payout_lines.assignment_id`, the `payout_lines_shape` CHECK, and four indexes.

**This closes the cash-in-transit loop.** Constitution I.10 requires `platform_float.variance` to be
zero or explained in writing before the next settlement, and `018` left it permanently non-zero: it
raised `cash_expected` on every cash collection and nothing could ever lower it, because no function
existed that banked cash. `run_payout_v1` approving a rider payout is now the only writer of
`cash_remitted` in the repository, and **variance reaching zero is verified end to end**.

**The number that mattered most, and the one an earlier draft got wrong.** A rider payout's `net` is
what the rider is **owed** — `rider_pay_total + tip`, 500 on the reference order. The cash in transit
is what the rider is **holding** on the platform's behalf — `delivery_assignments.collected_amount`,
13,000 on the same order. They differ by more than an order of magnitude, and reading one where the
other belongs banks a fraction of the real exposure while looking plausible. `cash_amount` is read from
the payout's own `payout_lines` joined to their assignments, so it cannot drift from what is being
paid. The test asserts the two figures are **distinct**, not merely that one equals the other.

**A rider payout line could not identify its trip, and that was a schema hole rather than a code
mistake.** `payout_lines` had only `sub_order_id`, which identifies a vendor's *leg*, not a rider's
*trip* — and `payout_lines_sub_order_unique` is global on it, so the vendor payout for a leg already
consumes the value a rider line would need. So a rider line had to carry `NULL`, which meant it was
untraceable and its only double-payment guard was `payouts.idempotency_key` covering (type, account,
period) — insufficient against two *overlapping* periods. `019` adds a nullable
`assignment_id uuid REFERENCES delivery_assignments(id)` with a UNIQUE index, additive on an empty
table: no rewrite, no `NOT NULL` without default, no backfill, and no application code to break.

`payout_lines_shape` then makes a mis-paired line impossible rather than merely unusual:
`vendor_earning` carries `sub_order_id` and no `assignment_id`; `rider_trip` and `tip`/`bonus` carry
`assignment_id` and no `sub_order_id`; `adjustment` carries neither.

**Two bugs found by executing, not reading, both now forward migrations.**

- `019a` — `payout_lines_assignment_unique` was UNIQUE on `assignment_id` **alone**. One trip
  legitimately earns two lines, a `rider_trip` line and a `tip` line, so the first rider payout with a
  non-zero tip aborted the whole transaction on a duplicate key. The index is now
  `(assignment_id, payout_line_type)`: one trip, one line of each type. That is the rider-side
  equivalent of `payout_lines_sub_order_unique`, which is single-column precisely because one vendor
  leg earns exactly one line type. Caught by the schema change I had just made myself.
- `019b` — `payout.paid` was the only 019 event whose payload lacked `actor`, using `approved_by`
  instead, so a consumer could not attribute the approval without special-casing that one event type.
  Both keys are now present and carry the same value.

**Seven of the nine test failures were mine, recorded rather than quietly corrected.** The one worth
repeating: I asserted a replayed `create` would raise `NOTHING_DUE`, and it instead returned the
existing batch with `already_applied = true` — because the idempotency-key lookup runs before the
payable scan. That is **better** than an error, and my expectation had been written against the
previous draft's behaviour. Two more were string truncations (`PAYOUT_NOT_DRAFT` is 16 characters,
`DATE_IN_FUTURE` is 14), one assumed a fixture would go negative when it did not, and one dropped the
vendor-staff actor so the leg never reached `ready`.

| Suite | Assertions | Result |
|---|---|---|
| vendor payout, approval gate, balance invariant | 30 | 28 pass, 2 bad expectations |
| rider payout, float, reconcile, isolation, idempotency | 40 | 38 pass, 2 bad expectations |
| `service_role` cannot bypass the admin gate | 7 | pass |
| structure, events, ledger immutability | 12 | pass |

Confirmed by execution: vendor net equals `Σ vendor_net_payout`; `payable → in_payout → settled` with
`payout_id` stamped; **no `commission` ledger row while commission is 0**, because
`CHECK (signed_amount <> 0)`; approval refused without a method, without a bank reference, without a
`payout_id`, and on a second attempt; `approved_by` and both timestamps recorded. Rider payout emits
both line types against one trip, net = `rider_pay + tip`, `cash_held` reaches 0, `cash_remitted`
equals what was collected and **`variance` reaches zero**. `wallets.balance` equals the ledger sum after
a payout, after a **negative** adjustment (`-89,999`, accepted, because `009` deliberately gave balance
no non-negativity CHECK) and after a replayed adjustment, with `version` at 2 rather than 3.
`service_role` holds `EXECUTE` on the mutations and still writes nothing, since all three require a
user JWT. Ledger `UPDATE` and `DELETE` are silent no-ops.

**Two things this deliberately did not fix.** `contracts.md` §1.8 names 13 money functions; **six are
unbuilt** — `freeze_wallet_v1`, where the `frozen` status and its mandatory reason already exist with no
writer, plus `list_frozen_v1`, `get_commission_v1` / `set_commission_rule_v1` and
`get_fee_rules_v1` / `set_fee_tier_v1` (open question 3.30). The apparent count of eight comes from
naming, not from missing capability: `run_payout_v1` absorbs the contract's
`run_vendor_payout_v1` / `run_rider_payout_v1` / `approve_payout_v1`, and `get_wallet_v1` ships as
`get_wallet_balance_v1`.

**A finding from this entry was retracted.** An earlier draft reported that
`private.visible_order_ids(p_user)` and friends were callable by a client with a caller-chosen argument,
letting anyone enumerate a named user's order ids. **That was wrong, and the error was mine** — I read
the `EXECUTE` grant and never checked the schema privilege that gates it. `private` has **no `USAGE` for
`anon`, `authenticated` or `service_role`**, so every one of those calls fails with
`permission denied for schema private`. The helpers are `SECURITY DEFINER` and executable because RLS
policies execute as the querying role; the pairing of `EXECUTE`-without-`USAGE` is the documented design
(`data-model.md` §13.1), not a hole. It is now a standing assertion in the integrity suite.

**Money constants: none.** No fee, multiplier, limit or rate appears as a literal in any function body.
The only numeric literal is the 366-day bound on a payout period, which is a safety bound rather than a
money constant and is called out as such in the source.

**One real finding from the 001–020 integrity sweep, and it is about `019`'s money invariant.** The ledger
is append-only *even for `service_role`*, which genuinely holds `UPDATE`/`DELETE`/`TRUNCATE` — a trigger
stops it, not a revoke, which is the strong form of the guarantee. But `wallets` carries only an owner check
and `updated_at`: **nothing** enforces `balance = SUM(ledger_entries)`. `service_role` can therefore set a
balance arbitrarily and desynchronise the books with no error. No client role can — both hold `SELECT` only
on `wallets` — so this is not customer-facing, but it is reachable from a Worker or an admin script, which is
the role people forget is trusted. It is **detected rather than prevented**: `get_wallet_balance_v1` returns
`balance`, `ledger_balance` and `drift`, and a hand-provoked desync of 5000 against a ledger sum of 1000
reported `drift = 4000`. Reporting beats a trigger recomputing `SUM` on every write, so this stays as designed
and is documented instead — **the money invariant is enforced by grants and RPC discipline, not by the
schema.** Also confirmed while testing it: `wallets_owner_type_check` admits only `vendor`/`rider`, so
constitution's "no customer wallet" is impossible to violate by insert rather than merely conventional.

### Added - rider delivery (018)

`get_available_orders_v1`, `claim_order_v1`, `begin_collection_v1`, `collect_cash_v1`,
`collect_wallet_v1`, `complete_delivery_v1`, plus `private.pay_rule_for`, `private.resolve_pay` and
`private.trip_distance_km`.

**This closes open question 3.26.** `017` deliberately wrote `rider_pay_total = 0` and
`platform_revenue = 0` at placement because no rider existed yet. `claim_order_v1` now resolves the
pay rule, freezes it onto the assignment, and **mirrors both figures onto `orders`** — so the
obligation recorded as deferred is discharged rather than forgotten.

**Multi-vendor confirmed by execution, since that was the question asked.** A three-merchant cart
produces three `sub_orders`, three distinct vendors, three `order_items` each bound to its own
`sub_order_id`, `vendor_count = 3`, `item_count = 6` dishes, per-vendor subtotals `20000, 8000, 18000`
preserved as payouts, and **fee shares that sum to the single order delivery fee**. One rider claims
the whole order; the three pickups live in `stop_sequence` and `bonus_per_leg × 3` pays more for a
three-stop trip than a one-stop one.

**Three of my own arithmetic errors, recorded because they are the dangerous kind.** I asserted a
48000 subtotal for `2×10000 + 8000 + 3×6000`, which is **46000** — I mis-added. I asserted a 3000
delivery fee for three vendors, which is `round(2500 × 1.20) = 3000` **plus a 200 distance charge**,
because my fixture happened to put a vendor 5.884 km away, just past the 5 km free radius. And I
asserted a total of 51000. In all three the code was right and the expectation was wrong; the distance
component was exercised for real rather than skipped. A test that fails for the wrong reason invites
a "fix" to correct code.

**Five real bugs found by running the code, all fixed before commit.**

- **`ON CONFLICT` cannot be used against `ledger_entries` at all.** Constitution 4 gives the table
  `DO INSTEAD NOTHING` rules, and Postgres refuses any `INSERT ... ON CONFLICT` against a table that
  has rules — whatever the conflict target. Every idempotency backstop had to become
  `INSERT ... SELECT ... WHERE NOT EXISTS`. The UNIQUE index is still the guarantee; this is its
  guarded form. Recorded because `019` writes the ledger heavily and would otherwise hit it again.
- **`riders` has no `deleted_at`.** I filtered on `r.deleted_at is null` by analogy with the
  `vendors` family; `is_active` is the soft-delete flag there. The query failed loudly rather than
  silently returning nothing, which is the better of the two failure modes.
- **`payment_collected_by` references `users(id)`, not `riders(id)`.** Writing the rider id is an FK
  violation. The column wants the *person* who took the money, which is what an audit of it needs.
- **`platform_float.variance` is `NOT NULL` with `CHECK (variance = cash_expected - cash_remitted)`.**
  A first insert must seed `cash_remitted = 0` *and* `variance` explicitly, and the upsert branch must
  recompute `variance` rather than adding to it. `cash_remitted` belongs to the settlement sweep in
  `021`, never to a collection.
- **`resolve_pay` used `IF NOT FOUND` after calling a helper that returns a row.** `FOUND` reflects
  the last statement executed *inside* that function, not whether it returned anything, so the no-rule
  branch never fired and every rider silently earned **zero** while `platform_revenue` was still
  booked. Now tests `v_rule.id is not null`. This is the same class of bug as the `SETOF`/`ANY` error in
  `017`: it produced a plausible number, not an error.

**Verified by direct SQL, in five batches:**

| Batch | Assertions | Result |
|---|---|---|
| multi-vendor shape | 13 | 10 pass, 3 bad expectations (above) |
| availability + claim + pay freeze | 16 | pass |
| pay resolution after the `FOUND` fix | 16 | pass |
| cash collection, float, completion | 21 | pass |
| cash limit, amount guards, isolation | 14 | pass |

Confirmed by execution: rider pay resolves to `per_trip 2000 + 100/km × leg_km + 500 × legs`, the
components sum to the total, `platform_revenue` is 20% of the actual fee and never negative, the
017 mirror lands on `orders`, a repeat poll inserts no duplicate offer, a second claim raises
`ORDER_ALREADY_CLAIMED`, a cash collection raises `cash_held` by exactly the total and writes exactly
one `cash_collected` and one `rider_cut` entry, a second collection and a wallet-after-cash are both
refused with `ALREADY_COLLECTED` without double-counting the float, cash in excess of the per-rider
limit is refused with **no** ledger row and **no** float movement, a rider cannot collect another
rider's trip, the customer cannot collect at all, `complete_delivery_v1` refuses while any sub-order is
unfinished, the `rider_cut` backstop does not duplicate the collection entry, and **an `UPDATE` against
the ledger is a silent no-op** — constitution 4 holding under test.

### Added - checkout (017)

`quote_order_v1`, `place_order_v1`, `cancel_order_v1`, `transition_order_v1`. Written by me, not
delegated, because this is the money path and every one of its four functions had to agree with the
other three on the same arithmetic.

**The single most important structural decision in this file:** pricing lives in exactly one
function, `private.compute_quote`, which both `quote_order_v1` and `place_order_v1` call. Had each
carried its own arithmetic they would eventually disagree on a rounding boundary, `PRICE_CHANGED`
would fire on an unchanged cart, and customers would be shown a "prices changed" sheet for nothing.
There is now one implementation of the fee formula in this database.

**Verified by direct SQL against the live database, in four batches:**

| Batch | Assertions | Result |
|---|---|---|
| `quote_order_v1` pricing | 22 | pass |
| `place_order_v1` placement | 35 | 34 pass, 1 bad assertion (below) |
| cancel and transition, isolation | 17 | 14 pass, 3 bad assertions (below) |
| state machine, full lifecycle | 10 | 9 pass, 1 bad assertion (below) |

Confirmed by execution, not by inspection: the spec §2.5 formula produces `round(2500 × 1.00) = 2500`
for one vendor and `round(2500 × 1.10) = 2750` for two, from configuration rows rather than
literals; a 2-line cart of 3 dishes produces 2 `order_items` rows with `item_count = 3`, which is
exactly what open question 3.11 defines; fee shares sum to the order delivery fee across sub-orders;
an idempotent replay returns the original `order_id` and writes no second order and no second event;
a spent quote cannot be reused; and a user without `profile_completed_at` is refused by the RPC.

**Four real bugs found by testing, all fixed before commit.** None were visible by reading the code.

- **`private.vendor_ids_for` and `private.rider_ids_for` return `SETOF uuid`, not an array.** My
  authorization used `uuid = any(private.vendor_ids_for(v_user))`, which raises `op ANY/ALL (array)`
  at runtime. The effect was that **no vendor and no rider could ever transition an order** — the
  entire fulfilment flow was dead — while the code still read as correct. It surfaced only because a
  test asserted a *specific error code* rather than "it failed". Rewritten as `EXISTS` over the set.
- **`count(*) filter (where oc.id is null)` counted the empty array.** `LEFT JOIN LATERAL
  jsonb_array_elements` emits one row with `oc.id` null for an item with **no** options, so every
  item that legitimately had no options was rejected `OPTION_UNAVAILABLE` and its money zeroed. An
  order of ordinary dishes quoted `subtotal: 0` while still charging a delivery fee. Now counts only
  elements that actually failed to resolve.
- **`::` binds tighter than `->>`**, so `l ->> 'vendor_id'::uuid` cast the *literal string*
  `'vendor_id'`. The `uuid` form raised loudly; the `::text` form on `selected_options` would have
  failed **silently as NULL**, feeding a wrong fingerprint. All such casts are now parenthesised, and
  the grep for the pattern is now part of the review.
- **`events` has no `actor_user_id` column.** The three inserts named one. Correct shape is
  `(type, aggregate_type, aggregate_id, payload)`, with the actor inside the payload — which is what
  `016` already did.

**Two things I got wrong in the tests themselves, recorded because they are the more dangerous kind
of failure.** I asserted 3 `order_items` for a 2-line cart (3 dishes, 2 lines — the code was right),
and I asserted `orders.status = 'picked_up'` for an order with one picked-up and one still-pending leg,
when `partially_confirmed` is the correct derivation. A test that fails for the wrong reason invites
a "fix" to correct code, so both are written down rather than quietly corrected.

- **Rejections are per vendor, not fatal.** One unavailable vendor does not lose the basket, per
  spec 2.6: `quote_order_v1` returns the rejection list and the app offers to drop that vendor.
  `place_order_v1` refuses with `CART_NOT_PLACABLE`.
- **Unconfigured money is an error, never a guess.** No active zone for the address raises
  `NO_DELIVERY_ZONE`; no fee tier for the vendor count raises `MISSING_FEE_TIER`. Neither falls back
  to a default, because constitution 7 makes these configuration and a silent fallback is how a
  platform ends up charging a fee nobody set.
- **`rider_pay_total` and `platform_revenue` are 0 at placement** (open question 3.26). No rider
  exists yet, so `pct_of_delivery_fee_bps` cannot be resolved; spec 3.3 freezes it at assignment.
  `018` owns writing the authoritative figures at claim.
- **Added `orders.order_number_key`.** `order_number` had no unique constraint at all, and it is the
  identifier printed on a receipt and read over the phone.
- **Database posture**: 62 tables, all RLS-enabled, 0 non-SELECT grants to `authenticated`, `anon`
  holds no EXECUTE on any of the four, `private.*` unreachable by `authenticated`, all test rows
  rolled back leaving `users`, `orders`, `carts`, `events`, `vendors` and `cities` at 0.

### Added - profile and read RPCs

`016_rpc_profile` and `020_rpc_read` were authored by two delegated agents **in parallel**, then
reviewed by me before anything was committed. They touch disjoint objects, which is the only reason
that was safe: `016` is one `before update of phone_number, country_code` trigger on `users` plus
three functions, `020` is seven functions and no triggers. Nothing else in the schema moved.

Both files were applied to the live database **before** review, against the standing instruction to
apply after sign-off. That is reversible for functions but not for a ledger, and it had one lasting
effect: `016` was applied three times while its agent fixed two bugs, so
`supabase_migrations.schema_migrations` held **three rows** named `016_rpc_profile`. Deduplicated to
one — `supabase migration list` would otherwise show `016` three times and a future
`migration repair` would be guessing which version matches the code. The two superseded rows were
deleted, not the code around them. Worth recording because the cause was my instruction, not the
agent's work.

**Verified by direct SQL, not by a test suite** - `AGENTS.md` records that `npm run verify` does not
exist yet, so this section claims nothing beyond what was executed.

- **Cross-tenant isolation proven, not assumed.** Two vendors, two vendor-staff users, one rider and
  one plain customer were created, then each identity called `get_vendor_earnings_v1` and
  `get_rider_earnings_v1` as itself. Vendor A's payload contained only A's `vendor_id`; B's id string
  appears nowhere in it, and the reverse holds. A plain customer with neither role gets **empty
  arrays, not an error and not the whole table** - the distinction that matters, since "no access"
  and "no rows" are different answers to a screen that has to decide whether to show an empty state
  or an error.
- **`020`'s author flagged its own biggest gap as untested cross-tenant behaviour.** That was the one
  thing a code read could not settle, so it went first. It passed.
- **`get_earnings_v1` does not exist.** `data-model.md` §15.2 named one function; `contracts.md` §1.6
  and §1.7 name two, and the contracts win. Both take **no owner parameter** - the vendor is derived
  from JWT via `private.jwt_vendor_ids()` and the rider from `private.jwt_rider_id()`, so there is no
  argument through which one vendor can ask for another's money. An owner id on either function would
  have made this a single-line leak.
- **The earnings payload keys are `vendor_id`, not `id`.** My own isolation test asserted `->>'id'`,
  read `null`, and looked like a failure until the payload was dumped. The data was right and the
  assertion was wrong - recorded because a test that passes for the wrong reason is worse than one
  that fails.
- **Payloads are id-only.** `user.profile_completed` and `user.profile_updated` carry the changed
  field **names** and never their values, because the values include a phone number and the outbox
  fans out to a dispatcher, R2 snapshots and push. Adding a profile event was a genuine gap:
  constitution 18 makes the profile gate load-bearing and nothing recorded that it was ever cleared.
- **Added 5 error codes to `contracts.md` §5**: `PHONE_INVALID`, `NAME_INVALID`,
  `PHONE_IN_USE_BY_RIDER`, `PROFILE_ALREADY_COMPLETE`, `INVALID_PATCH`.
  `PHONE_IN_USE_BY_RIDER` is deliberately **not** `PHONE_IN_USE`, and the reason is a dead end:
  `014b`'s trigger keeps `riders.phone_number` in step with `users.phone_number`, so completing a
  profile can be aborted by a rider row the user has never seen - possibly their own, possibly a
  colleague's, possibly one admin-onboarded with a null `user_id`. `PHONE_IN_USE` is documented as an
  inline error **on the phone field**, and retrying with a different number is exactly what would
  loop them. A distinct code routes to support instead. It is reachable from a **name-only** edit
  too, because `014b` fires on `update of first_name, last_name, phone_number, country_code`.
- **`complete_profile_v1` is idempotent for identical retries** but raises
  `PROFILE_ALREADY_COMPLETE` when values differ, so a client re-sending after a timeout is not shown
  an error for a request that succeeded, and a changed name is never silently dropped.
- **`can_browse` is unconditionally `true`.** A user with no profile can browse but not order, per
  constitution 5. It is hardcoded rather than computed because the only thing that would make it
  false is not existing.

### Fixed

- **`data-model.md` §15.2 undercounted both migrations.** Row `016` listed two of three functions and
  omitted `update_profile_v1` entirely. Row `020` listed one `get_earnings_v1` where two exist. The
  same table also disagreed with the applied schema at `012`. Documented rather than silently
  dropped, with the precedence rule stated inline: constitution, then `contracts.md`, then
  `data-model.md`.
- **`016` had two bugs found in review, both fixed before commit**: a bare `RETURN` that returned zero
  rows instead of one status row, and an array append that reset `missing` on every iteration.

### Security

- **Both mutators assign `updated_at = now()` themselves instead of relying on a trigger.** While
  reviewing `016` I found no `set_updated_at` trigger on `users`, and then found the same gap on 16
  more tables - `addresses`, `areas`, `brands`, `cities`, `delivery_fee_tiers`, `delivery_zones`,
  `feature_flags`, `item_options`, `menu_categories`, `menu_item_sizes`, `menu_items`,
  `option_choices`, `settings`, `users`, `vendor_earnings_daily`, `vendor_schedules`, `vendors` - which
  is a live constitution 17 violation across `001`–`015`, recorded as **open question 3.20**. It went
  unnoticed because these tables are mostly mutated through RPCs that set the column explicitly,
  which hides the missing trigger rather than compensating for it. `016`'s agent had proposed adding
  one for `users`; that was declined, because a function whose correctness depends on a trigger is a
  comment-shaped claim, and because a 17-table fix belonging to no migration is how `014`'s RPC work
  and `015`'s search work came to touch unrelated tables. The 17 need one migration together.
- **`020` was checked for the failure mode that makes `SECURITY DEFINER` dangerous**: a bare
  `auth.uid()` call anywhere in the body would read the **caller's** value, not the invoker's, because
  the function runs as its owner. Zero executable bare occurrences - only comments and error text.
  Every ownership decision routes through a helper that returns the caller's ids, and there are no
  raw literals in a predicate anywhere in either file.
- **Database posture after `016`/`020`**: 62 tables and partitions, all with RLS enabled; 0
  non-SELECT grants to `authenticated`; `anon` holds no table grants and no EXECUTE on any function;
  0 function definitions without a pinned `search_path` or volatility marker; all test rows
  rolled back, leaving `users`, `events` and `vendors` at 0.

### Known gaps - recorded, not fixed

- **`raise_app_error` still does not exist.** `contracts.md` §5 specifies it; `020` raised longhand for
  all 21 of its assertions and `016` for its domain errors. Both agents raised it as out of scope,
  which is the correct call - it is a fourth function on the PostgREST surface, and its grant belongs
  with whichever migration finally establishes the error contract for `017`–`020`. Every raise already
  inlines exactly the format the helper would produce, so adopting it later is substitution, not a
  rewrite. **Open question 3.21.**
- **`order_eta_snapshots.computed_at` is unindexed** while `free-tier-plan.md` §3.3 prunes on it - a
  sequential scan over the second-largest transient table at 3 rows per order. `021` owns the cron
  jobs and should add it. **Open question 3.22.**
### Added - search

**`015_search`** makes catalog search work in Arabic, which data-model.md 5 warned was impossible with an
index on `lower(name)`. A customer typing the bare alef must match a row storing a hamza'd alef, and a
customer typing taa marbuta must match taa marbuta.

**`extensions.unaccent` could not be used.** It is **STABLE on this project**, not IMMUTABLE, and a
`GENERATED ... STORED` column may only call immutable functions - verified before writing rather than
discovered at DDL time. Latin folding is hand-rolled instead; `unaccent` remains correct for ad-hoc ILIKE.

**A silent character-mapping bug, caught by testing.** The first implementation typed `translate()`'s
from-string and to-string as literals, and the from-string turned out to be **one character shorter** in
its first group. `translate` maps positionally, so every later mapping was shifted: **e-acute folded to
`a`, n-tilde to `u`, and Arabic alef-with-hamza to `c`.** The function ran, returned plausible text, and
raised nothing. The to-string is now built with `repeat()` so both lengths derive from the same intent.

**Then the guard against it was also wrong.** The first fix asserted the *length difference* between the
two strings, via a helper that re-typed the same character literals. That failed on correct code, because
the helper's copy had drifted by one character. **A guard that duplicates the thing it guards is a second
source of truth, not a check.** Replaced with behavioural assertions that call the real function: all 8
folds, all 11 deletions, 7 Latin folds, digit and comma mappings, and the jsonb overload - all by
codepoint via `chr()`, because hand-typed Arabic is what caused the original bug.

**Folding, all 22 verified against raw codepoints:** alef madda / hamza-above / hamza-below / wasla to
bare alef; waw-with-hamza to waw; yeh-with-hamza and alef-maksura to yeh; teh-marbuta to heh; Arabic-Indic
digits to ASCII; Arabic comma to space; deletes tashkeel, superscript alef, standalone hamza, tatweel;
Latin accents; `ss` from sharp s; ligature expansion.

**`haversine_km` is created here deliberately, not invented for one call site** - contracts.md 1.2 wants
distance as a search tie-breaker and free-tier-plan.md needs the same number for per_km_fee. Its
least/greatest clamp is load-bearing: `acos()` raises a domain error when float drift pushes its argument
outside [-1,1].

**`search_catalog_v1` is SECURITY DEFINER and therefore re-implements the 13.1 visibility rules rather
than inheriting them** - definer bypasses RLS, so an omitted predicate would be a leak no policy could
catch. An empty query is **browse, not search**, because similarity-ranked nonsense for an empty box is
worse than showing the good local vendors.

### Measured - and one honest negative result

**Search works, verified end to end:** an Arabic query finds the Arabic item name; **the same word typed
without hamza still matches**, which is the entire point of normalisation; a Latin query finds the vendor;
an **unapproved vendor is invisible even when it matches**; max_price filters; distance computes from the
area; a 2-character query takes the non-indexed path without error; p_limit clamps to [1,50].

**The trigram indexes are not used by the planner at realistic catalog sizes.** Measured here:

| Rows | Observed |
|---|---|
| 40,000 menu_items | **Seq Scan**, 2,352 buffers |
| 100,000 menu_items | 119 MB total with indexes, 62 MB heap |

So they cost ~570 bytes/row in storage and buy nothing at launch scale - free-tier-plan.md models 150
vendors and ~4,500 items, where the indexes would be about 2.6 MB and unused. **Kept anyway** because they
are partial on live rows only, they cost ~2.6 MB at the plan's own scale, and they are what stops search
degrading into a full scan as the catalog grows; dropping them later is a cheap DROP INDEX. **Recorded as a
measured trade, not asserted as a win.**

The **generated columns are cheap** - 11 + 13 + 5 = 29 bytes/row, 2.7 MB per 100,000 rows - so the storage
cost is in the indexes, not the columns.

`tags text[]` is **deliberately not indexed**: casting an array to text is not immutable, so it cannot go
in a generated column, and a fourth trigram index on the largest catalog table is not worth a bespoke
wrapper for admin metadata rather than customer-facing copy.

**`menu_items.ingredients` is jsonb and no shape for it is specified anywhere** in data-model.md or
contracts.md. Rather than bet on one, `normalize_text_v1(jsonb)` flattens arrays, objects and scalars
mechanically. **If ingredients turns out to be an object whose keys are the searchable part, this
normalises the values and the search silently matches nothing** - recorded as an open assumption rather
than buried in a CASE.
- **All open questions raised by `012`–`015` are now closed.**

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
- `015_search` — Arabic-aware catalog search: normalisation, 10 generated columns, 10 trigram
  indexes, `haversine_km`, `search_catalog_v1`

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
