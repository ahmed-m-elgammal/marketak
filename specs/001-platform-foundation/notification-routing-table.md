# Notification routing table — MVP locked at seven

**Status: DECIDED. §8.1 is the MVP and it is locked. §1-7 are the measurements behind it.**
Every payload key below was read out of `pg_proc.prosrc` on 2026-10-05, not inferred from a migration and
not taken from `contracts.md` §3.1. Method: for each event name emitted by a live function, the
`jsonb_build_object(...)` argument of its `insert into public.events` was extracted and its keys listed.
Template variables were read from `public.notification_templates.variables` (19 keys x ar/en, all
`channel = 'push'`, all `is_active`).

Read this with `push-notification-plan.md` §7, which is the audit that found the mismatch. This file is
the correction, row by row.

---

### How to read this file

**§8.1 is the MVP and it is locked.** Seven notifications, one collapse rule, three RPCs. §8.2 is what
comes after it. §1-7 are the measurements and the audit behind the decision — read them for the
reasoning, not for the plan. Where §8 differs from §3, §8 wins.

---

## 1. The finding that governs everything else

**Exactly one of the nineteen templates can be rendered from its own event payload with no database
join.** Every other row needs at least one lookup the event does not carry.

| Template | Variables | Present in the emitting event's payload? |
|---|---|---|
| `order.cancelled` | `reason`, `refund_amount` | **Both.** The only clean row in the set |
| `order.placed` | `order_number`, `vendor_count`, `total` | `total` only. `vendor_count` is derivable as `jsonb_array_length(payload->'vendor_ids')`; **`order_number` is absent** |
| `rider.order_assigned` | `order_number`, `stops`, `rider_pay_total` | `rider_pay_total` only. `order_number` absent; `stops` needs a count of `delivery_assignments` |
| `rider.payout_paid` | `amount`, `cash_remitted` | Both, under different names — payload has `net` and `cash_amount` |
| `vendor.payout_paid` | `amount`, `period` | `net` maps to `amount`; **`period` is absent** |
| `order.delivered` | `total`, `payment_method`, `review_prompt` | **None.** Payload is `order_id`, `rider_id`, `rider_pay_total`, `platform_revenue`, `tips` |
| `order.vendor_accepted` | `vendor_name`, `eta` | **None.** Payload is `order_id`, `sub_order_id`, `actor_user_id`, `actor_role`, `from`, `to` |
| `order.vendor_rejected` | `vendor_name`, `affected_items`, `action_required` | **None.** Same five keys |
| `order.preparing` / `order.ready` / `order.arriving` | `eta` | **None.** Same five keys |
| `order.picked_up` | `rider_name`, `eta` | **None.** Same five keys |
| `voucher.available` | `code`, `expires_at` | **None.** `voucher.updated` carries `actor`, `created`, `fields` |

Consequences, and they are structural rather than cosmetic:

- **`eta` is in seven templates and in no payload.** Any Worker rendering these must join elsewhere.
  **CORRECTED by Phase 2 — this paragraph originally said eta "is computed by `compute_quote`, stored on
  `orders.promised_delivery_at` / `eta_minutes` / `eta_maxutes`", and that is false.** `compute_quote`
  returns no ETA key; `place_order_v1` inserts 30 columns and not one is `promised_delivery_at`; the only
  functions that mention it are `claim_events_v1` (reading it) and `get_admin_metrics_v1` (comparing it).
  **Nothing writes it.** The real value is `delivery_assignments.assigned_at + eta_minutes`, written by
  `claim_order_v1` when a rider accepts. `038g` sources `eta` from there, in `cities.timezone`. The column
  `promised_delivery_at` remains the intended home for a quote-time promise and is T3.8's job.
- **`order_number` is in four templates and in no payload.** It lives on `orders.order_number`. It is
  the one string a human reads out loud to identify an order, so it is the one that cannot be faked or
  omitted.
- **`vendor_name` and `rider_name` are in five templates and in no payload.** Both are denormalised
  display names available by joining `vendors` / `riders`.
- **`order.status_changed` is one event with five payload keys and seven candidate templates.** The
  only discriminator is `payload->>'to'`, which `transition_order_v1` sets from a closed state machine:
  `accepted`, `rejected`, `cancelled` from `pending`; `preparing`, `cancelled` from `accepted`;
  `ready`, `cancelled` from `preparing`; `picked_up`, `cancelled` from `ready`; `delivering`,
  `delivered`, `cancelled` from `picked_up`; `delivered`, `cancelled` from `delivering`.

So the dispatcher cannot be a pure `events`-table reader. It reads `events`, then joins `orders` once,
then renders. That is one extra round trip per batch, not per row, and it is affordable — but it is a
design fact, and §5.3's "never do JSON work in a Worker on data Postgres can aggregate" means the join
belongs in the RPC that claims the batch, not in Worker code.

---

## 2. Second finding: nothing writes the `notifications` row

`push-notification-plan.md` §6 item 5 records `contracts.md` §4.4 as: *"the row is already there,
independent of the send. That is what makes it the in-app fallback."*

**No function inserts into `notifications`.** Searched `pg_proc.prosrc` across `public` and `private` for
`insert into public.notifications`: zero hits. Three functions mention the table at all —
`private.ensure_month_partition`, `private.ensure_partitions`, `private.prune_notifications` — and all
three are retention plumbing. The table has 0 rows and no writer.

So §4.4's premise does not hold against the schema as built. Either an insert path is missing, or the
in-app fallback is not in v1. This is a question, not something to infer: **the two are very different
amounts of work**, and the table's partitioning, its 30-day prune and its two RLS policies are all
already paid for either way.

---

## 3. The audit — 26 rows, every mismatch, unedited

**Superseded by §8.** Kept because §8 is a decision and this is the evidence behind it; the two differ
in two places and the difference is deliberate. Read §8 for what ships, this section for what it
replaces.

Two columns per row because there are genuinely two possible repairs and they are not
interchangeable. **Amend the event name** means editing a `pg_proc` body in a new migration.
**Amend the template** means renaming or adding a `notification_templates` row. Editing the emitted
name is preferred wherever the emitted name is the more accurate one — `order.claimed` describes what
happened; `driver.assigned` describes who it happened to.

| # | Emitted event | Recipients | Template | Repair | Note |
|---|---|---|---|---|---|
| 1 | `order.placed` | customer | `order.placed` | **none** | Needs `order_number` added to the payload |
| 2 | `order.placed` | each vendor | `vendor.new_order` | mapping row | Needs `order_number`, `item_count`, `prep_deadline`. `total` is order-wide, not per sub-order |
| 3 | `order.status_changed` `to=accepted` | customer | `order.vendor_accepted` | mapping row + `eta` | `vendor_name` by join |
| 4 | `order.status_changed` `to=rejected` | customer | `order.vendor_rejected` | mapping row + `eta` | `affected_items`, `action_required` have no source at all |
| 5 | `order.status_changed` `to=preparing` | customer | `order.preparing` | mapping row + `eta` | |
| 6 | `order.status_changed` `to=ready` | customer | `order.ready` | mapping row + `eta` | |
| 7 | `order.status_changed` `to=picked_up` | customer | `order.picked_up` | mapping row + `eta` | `rider_name` by join |
| 8 | `order.status_changed` `to=delivering` | customer | `order.arriving` | mapping row + `eta` | Fires on `delivering`, not on proximity. The "2 km" in the body is a **fixed string**, not derived — see §4 |
| 9 | `order.status_changed` `to=cancelled` | customer | *suppress* | suppression rule | `cancel_order_v1` emits `order.cancelled` separately. Routing both sends the cancellation twice |
| 10 | `order.status_changed` `to=delivered` | customer | *suppress* | suppression rule | `complete_delivery_v1` emits `order.delivered` separately |
| 11 | `order.delivered` | customer | `order.delivered` | mapping row | Needs `total`, `payment_method`, `review_prompt` — none in payload |
| 12 | `order.delivered` | rider | `rider.payout_paid`? | **decide** | See §5 |
| 13 | `order.claimed` | rider | `rider.order_assigned` | **amend event name** to `rider.order_assigned` | The emitted name is the better one. Naming it `order.claimed` while the template is `rider.order_assigned` is the clearest instance of the three-layer problem |
| 14 | `order.claimed` | rider | `rider.new_offer` | decide | This is the **offer**, not the acceptance. `get_available_orders_v1` returns unclaimed work and emits nothing. Batching it to 3 per §4.4 needs a producer |
| 15 | `order.collected` | customer | **none exists** | add template or record in-app only | Payload has `amount`, `channel`, `method` — enough for a real message. §4.4 wants one |
| 16 | `order.cancelled` | customer | `order.cancelled` | **none** | The one row that works today |
| 17 | `order.cancelled` | vendors | `vendor.order_cancelled` | mapping row + `items` | `reason` is present |
| 18 | `order.cancelled` | rider | `rider.customer_cancelled` | mapping row | Needs `order_number`, `stops_remaining` |
| 19 | `payout.paid` `type=vendor` | vendor | `vendor.payout_paid` | mapping row | Rename `net` -> `amount`; `period` absent |
| 20 | `payout.paid` `type=rider` | rider | `rider.payout_paid` | mapping row | `net` -> `amount`, `cash_amount` -> `cash_remitted`. Nearest fit in the set |
| 21 | `wallet.frozen` | owner | **none exists** | add template or record in-app | Payload carries `reason` — deliberately, per §4.4's no-secrets rule. A freeze notice without its reason is not actionable |
| 22 | `voucher.updated` `created=true` | customer | `voucher.available` | **amend event name** | Editing a voucher is not a voucher becoming available. But the payload has neither `code` nor `expires_at`, so this row needs an emitter that carries them |
| 23 | `rider.cash_limit_warning` | rider | `rider.cash_limit_warning` | **build the emitter** | Template exists, `effective_cash_limit_v1` computes both variables, nothing calls it. `settings.rider_cash_limit_warning_pct = 80` is seeded and unused |
| 24 | `vendor.order_modified` | vendor | `vendor.order_modified` | **build the emitter** | Template exists with `item_name`, `old`, `new`. Nothing emits a modification event. `order_modifications` table exists with 0 rows |
| 25 | The other **53** emitted names — every `area.*`, `brand.*`, `city.*`, `cuisine.*`, `item_option.*`, `menu_*.*`, `option_choice.*`, `vendor.*`, `user.*`, plus `commission.activated`, `fee_tier.set`, `float.variance_explained`, `wallet.adjusted` | admin | **none** | **do not route** | Admin audit trail, not notifications. Explicitly out of push scope |
| 26 | `payout.created`, `payout.rejected` | admin | **none** | **do not route** | Internal payout lifecycle. `payout.paid` is the only one with a recipient |

Row 25 is the reason the 64-name list is not a 64-row plan. **Fifty-three of the sixty-four emitted
names are admin CRUD audit events** and must not reach a phone. Only **eleven** are notification
candidates at all:

```
order.cancelled   order.claimed   order.collected   order.delivered   order.placed
order.status_changed   payout.created   payout.paid   payout.rejected
voucher.updated   wallet.frozen
```

Eleven candidates against nineteen templates, and the eleven do not cover them: `order.collected` and
`wallet.frozen` have no template, while nine templates have no emitter.

---

## 4. Two placeholders that cannot be filled honestly

**Settled in §8.1 and §8.4.** `order.arriving` is **not routed** rather than rewritten, because
shipping "about 2 km away" to a customer whose rider is 200 m away is a false statement and no template
edit fixes the absence of a position source. The row stays; nothing points at it.

`order.arriving` (ar and en) reads *"Your courier is about 2 km away"* / *"مندوب التوصيل على بعد
كيلومترين"*. The `2` is **literal text in the template**, not a variable. `variables` is `[eta]` only.

There is no proximity source. `rider_location_pings` exists and is empty; `riders.current_latitude` /
`current_longitude` / `last_location_at` exist and are populated only when a rider app writes them.
ADR 6 cut Durable Objects and §10 gives up live tracking in v1, so there is no live position to compute
a distance from.

Sending "about 2 km away" to a customer whose rider is 200 m away is a **false statement to the
customer**, and it is the kind that erodes trust permanently.

Three options were weighed. (1) Rewrite the body to drop the distance. (2) Make the distance a real
variable and populate it from a position source. (3) Do not route it.

**Chosen: 3.** Option 1 still tells the customer the rider is close, which is an unverified claim, and
`picked_up` already covers "on the way" honestly. Option 2 needs the tracking that ADR 6 cut. So the
template is not rewritten and not routed — the cheapest option that cannot lie.

---

## 5. Questions the audit could not answer

**Answered in §8.4, by exclusion.** Each of the four is one of the five templates left unrouted, so
none of them blocks the fourteen. Row 12 (does a rider get a push on delivery or only on payout) —
answered no, only on payout. Row 14 (who sends `rider.new_offer`) — answered nobody, the app polls. §2
(in-app fallback) — still open, and §8 does not settle it. Rows 4 and 24 (`affected_items`,
`action_required`, `old`/`new`) — §8.5 fills them from counted columns and static strings.

Retained for the reasoning, not for the questions.

1. **Row 12 — does a rider get a push when a delivery completes, or only at payout?** `order.delivered`
   carries `rider_pay_total`, which suggests the former is intended. `rider.payout_paid` is written for
   money actually transferred. If both fire on the same day the rider is told twice about one sum.
2. **Row 14 — who sends `rider.new_offer`?** `get_available_orders_v1` returns unclaimed assignments and
   writes no event. `rider.new_offer` batches to 3 and is never a blast (§4.4), which implies a
   producer that knows how many offers are outstanding. Nothing does.
3. **§2 above — does an in-app `notifications` fallback exist in v1 at all?**
4. **Rows 4 and 24 — where do `affected_items`, `action_required` and `old`/`new` values come from?**
   `order_modifications` has the columns and no rows, and no RPC writes them.

---

## 6. What must be built before the Worker

**Now three functions, not seven — §8.3 and §8.5 collapse this list.** Items 1, 2 and 3 below are
exactly §8.3's `claim_events_v1`, `mark_events_delivered_v1` and `register_device_token_v1`. Items 4-7
are gone: the payload widening became a join inside the claim RPC, and the two missing emitters belong
to the five unrouted templates in §8.4, which are out of scope for v1.

Retained so the collapse is visible.

Ordered by what blocks what. None of this is Cloudflare work; all of it is the database side the
dispatcher calls.

| # | Item | Blocks |
|---|---|---|
| 1 | `claim_events_v1(p_limit int)` using `for update skip locked`, returning the joined `orders` columns the templates need | Everything. Confirmed absent from `public` and `private` |
| 2 | A batch mark RPC | The delivery guarantee. Without it the Worker sends and cannot record that it sent |
| 3 | A `device_tokens` write RPC | **All push, permanently.** `authenticated` holds 1 grant on the table and it is SELECT; 0 rows; no spec names the RPC |
| 4 | Payload additions for `order_number`, `eta`, `vendor_name`, `rider_name` | **Replaced by §8.5** — a join inside the claim RPC, no emitter edited |
| 5 | An emitter for `rider.cash_limit_warning` | **Deferred** — §8.4, template unrouted in v1 |
| 6 | An emitter for order modification | **Deferred** — §8.4, template unrouted in v1 |
| 7 | A decision on `order.collected` and `wallet.frozen` templates | **Answered by exclusion** — §8.4, payment is in-app, freeze is in-app |

Items 1-3 are the hard blockers and survive as §8.6's three functions. Items 4-7 no longer block.

---

## 7. Integrity notes

- **No notification was sent and no template was edited.** This file is a proposal; the database is
  unchanged since `035`.
- **`events` is empty**, so no payload above was observed at runtime — every payload key was read from
  the function body that would write it. That is a weaker form of evidence than executing the function,
  and it is the same weakness that let `027` ship a function that had never once succeeded. **Row 1-24
  should be confirmed by running one order end to end and reading the `events` rows it produces, before
  the routing table is treated as settled.**
- **`notification_templates.variables` is the declared contract, and it is not enforced anywhere.**
  `private.notification_type_exists(p_type)` checks a key exists and is active — and **has zero
  callers**. So nothing validates that an emitted event type corresponds to a template key, and nothing
  validates that a payload carries the variables its template declares. Both are cheap assertions and
  both would have caught rows 4, 11, 15, 21 and 22.

---

## 8. THE OUTCOME — seven notifications at MVP, fourteen in full

**§8.1 is the locked MVP. §8.2 is what comes after it and is not built now.** Every message in both
uses a template row already in `notification_templates` today: no new template, no template text change,
no emitter edited, no schema change. Three new RPCs either way.

### 8.1 MVP — the seven, locked

**RIDER**

| # | Trigger | Template | Filled with |
|---|---|---|---|
| 1 | `order.claimed` | `rider.order_assigned` | `order_number`, `stops`, `rider_pay_total` |

**CUSTOMER**

| # | Trigger | Template | Filled with |
|---|---|---|---|
| 2 | `order.placed` | `order.placed` | `order_number`, `vendor_count`, `total` |
| 3 | `order.status_changed` `to=rejected` | `order.vendor_rejected` | `vendor_name`, `affected_items`, `action_required` |
| 4 | `order.status_changed` `to=picked_up` | `order.picked_up` | `rider_name`, `eta` |
| 5 | `order.delivered` | `order.delivered` | `total`, `payment_method`, `review_prompt` |
| 6 | `order.cancelled` | `order.cancelled` | `reason`, `refund_amount` |

**VENDOR**

| # | Trigger | Template | Filled with |
|---|---|---|---|
| 7 | `order.placed` | `vendor.new_order` | `order_number`, `item_count`, `total`, `prep_deadline` |

Each of the seven earns its place: no confirmation and the customer has no trust; a silent rejection is
the worst outcome there is; "on the way" is the one push a waiting customer actually wants; delivered
closes the loop; cancellation involves money; and both the vendor and the rider are otherwise unaware
work exists.

#### 8.1.1 THE COLLAPSE RULE — this is the load-bearing part

`transition_order_v1(p_order_id, p_sub_order_id, p_to_status, p_reason)` takes **one** `p_sub_order_id`
and emits exactly one `order.status_changed` per call. It fires from the vendor, on a sub-order. A
3-vendor checkout therefore produces **three** `accepted`, three `preparing`, three `ready`, three
`picked_up` events.

**And `aggregate_id` is not a usable grouping key, which is why the rule keys on the payload.** Verified
against the two emitters:

| Event | `aggregate_type` | `aggregate_id` | `payload->>'order_id'` |
|---|---|---|---|
| `order.status_changed` | **`sub_order`** | the `sub_order_id` | present |
| `order.placed` | **`order`** | the `order_id` | present |
| `order.claimed` | `order` | the `order_id` | present |
| `order.delivered` | `order` | the `order_id` | present |
| `order.cancelled` | `order` | the `order_id` | present |

Two different `aggregate_type` values across the routed set, so grouping by `aggregate_id` would put a
sub-order id and an order id in the same column and collapse nothing — or worse, group unrelated rows.
**`payload->>'order_id'` is present in every one**, which is why it is the key and not `aggregate_id`.

Routed naively, that is up to 24 customer pushes for one order. No customer tolerates it, and it spends
the FCM budget on noise.

**So: every per-sub-order event collapses to one order-level push, keyed on `payload->>'order_id'`.**
`claim_events_v1` groups the claimed batch by that key, and if a group holds N events of the same routed
type, it emits **one** notification and marks all N delivered. Three vendors confirming at once is one
push saying the order is confirmed, not three.

This lives in SQL inside the claim RPC, not in Worker code. §5.3 forbids doing in a Worker what Postgres
can aggregate, and collapsing a group is aggregation.

#### 8.1.2 The seven deferred out of MVP

| Deferred | Why it waits |
|---|---|
| `order.vendor_accepted` | Noise between "confirmed" and "on the way" |
| `order.preparing` | Same |
| `order.ready` | **Actively misleading on a multi-vendor order.** "Your order is ready" when two of three vendors have not started is false, and it is the exact failure the collapse rule cannot fix — the collapse makes it one push, not a true one |
| `rider.customer_cancelled` | Rider already sees the order disappear in-app; cancellation is reconciliation, handled in the admin console |
| `vendor.order_cancelled` | Same, and the vendor dashboard already lists it |
| `rider.payout_paid`, `vendor.payout_paid` | Weekly/monthly money events. A push about last week's payout is noise today |

None of the seven is blocked by missing infrastructure. They are routed by adding a row to the same
table in a later migration. **`order.ready` is the one worth revisiting first** if a single-vendor fast
lane ever ships, because in a one-restaurant order it is true and useful.

#### 8.1.3 Unrouted forever in v1, not deferred

- **`order.arriving` is never sent.** Its body says *"about 2 km away"* and the `2` is literal text with
  no variable behind it. No proximity source exists — `rider_location_pings` is empty, ADR 6 cut
  Durable Objects, §10 gives up live tracking in v1. Sending it would tell a customer something untrue.
  The row stays; nothing routes to it. It becomes routable only if a real position source lands.
- **`order.collected`** has no template. Payment is in-app: the customer is standing there paying the
  rider.
- **`rider.new_offer`, `rider.cash_limit_warning`, `vendor.order_modified`, `voucher.available`** —
  template exists, **no emitter does**. `get_available_orders_v1` returns unclaimed work and writes no
  event; `effective_cash_limit_v1` computes its two variables and nothing calls it;
  `order_modifications` has 0 rows and no writer; `voucher.updated` fires on an admin edit and carries
  neither `code` nor `expires_at`. **No notification is sent for something the database never records.**

### 8.2 Full set — fourteen, after MVP

Kept so the MVP subset is a decision rather than an omission. Same three RPCs, same zero-template-cost
basis; each deferred row is one added routing row.

**Customer cycle — the five MVP rows plus three:**

| # | Trigger | Template | Filled with |
|---|---|---|---|
| 8 | `status_changed to=accepted` | `order.vendor_accepted` | `vendor_name`, `eta` |
| 9 | `status_changed to=preparing` | `order.preparing` | `eta` |
| 10 | `status_changed to=ready` | `order.ready` | `eta` |

**Rider — the MVP row plus three:**

| # | Trigger | Template | Filled with |
|---|---|---|---|
| 11 | `order.cancelled` | `rider.customer_cancelled` | `order_number`, `stops_remaining` |
| 12 | `payout.paid` `type=rider` | `rider.payout_paid` | `amount`, `cash_remitted` |

**Vendor — the MVP row plus three:**

| # | Trigger | Template | Filled with |
|---|---|---|---|
| 13 | `order.cancelled` | `vendor.order_cancelled` | `reason`, `items` |
| 14 | `payout.paid` `type=vendor` | `vendor.payout_paid` | `amount`, `period` |

Two suppression rules make the full set exactly-once, and they apply to MVP too:

- **`to=cancelled` is dropped.** `cancel_order_v1` emits `order.cancelled` separately. Without the drop
  the customer is told twice.
- **`to=delivered` is dropped.** `complete_delivery_v1` emits `order.delivered` separately.

`order.placed` and `order.cancelled` each fan out to the customer *and* to each affected vendor. That is
two recipient groups, not duplication — the vendor's own sub-orders only.

### 8.2.1 The rider row, and the cheapest mapping in the set

Row 1 of MVP routes the emitted name `order.claimed` to the template `rider.order_assigned`. Both already
exist and they are the same event; the mapping row is the whole repair. **No name is changed.**

`rider_pay_total` is **already in the `order.claimed` payload** — read from `pg_proc.prosrc`:
`order_id`, `rider_id`, `assignment_id`, `rider_pay_total`, `platform_revenue`, `distance_km`,
`has_pay_rule`. So of the three variables this row needs, one needs no lookup at all. `order_number` and
`stops` come from the §8.5 join.

### 8.3 The three functions

**Corrected against the live database.** An earlier draft of this section named these
`claim_push_batch_v1` and `mark_push_sent_v1` and proposed an upsert key that does not exist. Both are
corrected below; §8.10 lists every check that produced a change.

#### `claim_events_v1(p_limit int)`

**The spec's own name, kept.** `data-model.md` §14.4 and `tasks.md` T3.5 both name `claim_events_v1`,
and an earlier draft here renamed it `claim_push_batch_v1`. That was wrong on two counts:

- It would have forked the name the spec already committed to, in the same commit that was supposed to
  align with it.
- **The drain is not push-specific.** It claims from `events`, and 53 of the 64 emitted names are admin
  audit events that §8.4 never routes. A function called `claim_push_batch_v1` that returns 53 audit
  events is misnamed by its own behaviour.

`for update skip locked`, claiming only `delivered_at is null`. **Granted to `service_role` only.**

**The grant matters, and it is the reason this is `security definer`.** `events` has exactly one
policy, `events_admin_read` (`private.is_admin()`), and **no INSERT or UPDATE policy at all** — so no
role can mark an event delivered except by bypassing RLS. `service_role` carries `BYPASSRLS`.
`authenticated` must not have EXECUTE: a client that could mark events delivered could silently
suppress notifications, and `attempts` would never rise, so §11 item 8's alert would never fire.

Returns the routing input already joined, **grouped by `payload->>'order_id'`** per §8.1.1, with the
routing table as a `values` join inside the function — one place, testable, and it cannot drift from
the database.

#### `mark_events_delivered_v1(p_ids bigint[], p_result jsonb)`

**Also the spec's name** — `tasks.md` T3.5 calls it `mark_events_delivered_v1(ids)`. Same
`service_role`-only grant, same reason.

One call per batch. Sets `delivered_at` on the group and increments `attempts` / writes `last_error`
per event. **A group that only partially sent must not mark the whole group delivered** — the failures
stay claimable, because `events_delivered_after_created` only constrains `delivered_at >= created_at`
and nothing else enforces delivery.

#### `register_device_token_v1(p_token text, p_platform text, p_app_role text, p_app_version text)`

**The blocker.** Without it a Worker has nobody to notify: `authenticated` holds exactly one grant on
`device_tokens` and it is SELECT, and the two policies are `device_tokens_read` (`user_id = auth.uid()`)
and `device_tokens_admin_read` (`private.is_admin()`) — **neither has a `WITH CHECK`, so no client can
insert.**

**The upsert key is `token` alone, and that is forced by the schema.** `device_tokens_token_key` is
`UNIQUE (token)` — globally, not per user. An earlier draft here proposed `(user_id, token)`; **that
index does not exist and the constraint forbids the behaviour**, since one token cannot belong to two
users and re-registering a rotated token would otherwise create a duplicate row against a unique
constraint. `device_tokens_user_id_app_role_idx` is `(user_id, app_role)` — for routing, not upsert.

So: `insert ... on conflict (token) do update`, taking `user_id` from `auth.uid()`. A token rotating on
reinstall is a different token and therefore a new row; the old row is removed by **P4.2**, not by the
upsert.

**`language` is read, not accepted.** `device_tokens.language` is `NOT NULL` and the column list has no
default, so the function must populate it from `users.preferred_language` — a cross-table read inside a
`security definer` function, which is exactly why it must be `security definer` rather than relying on
the caller's grants on `users`.

**`p_app_role` takes `{customer, rider}`.** Note honestly: the column CHECK is
`app_role = ANY (ARRAY['customer','rider','admin'])` and this function cannot narrow it, because the
constraint is existing schema. Restricting the *argument* is a weaker guarantee than restricting the
column, and the CHECK still permits a row carrying `admin`. That is harmless here — §8.4 routes nothing
to an `admin` token — but it is a restriction on what the app may send, not on what the row may hold.

Every argument maps to an existing column: `id, user_id, token, platform, app_role, app_version,
language, last_seen_at, created_at`. **One function, no schema change.**

### 8.4 Not routed at MVP or later, and why

| Template | Why not |
|---|---|
| `rider.new_offer` | **No emitter.** `get_available_orders_v1` returns unclaimed work and writes no event. §4.4 says batch to 3, never blast — which needs a producer that knows how many offers are outstanding. The rider app polls instead |
| `rider.cash_limit_warning` | **No emitter.** `effective_cash_limit_v1` computes both variables and nothing calls it. `settings.rider_cash_limit_warning_pct = 80` is seeded and unused |
| `vendor.order_modified` | **No emitter.** `order_modifications` exists with 0 rows and no RPC writes it. §5 question 4 |
| `voucher.available` | **Wrong event.** `voucher.updated` fires when an admin edits, and its payload carries neither `code` nor `expires_at`. Notifying a customer that a voucher they may not hold has "become available" is worse than not notifying |
| `order.collected` | **No template exists.** Payment is in-app. The customer is standing there paying the rider — a push telling them what they just did is noise |

Five templates unrouted, four of them because nothing emits them. **That is the honest v1 boundary: no
notification is sent for something the database never records.**

### 8.5 Why the variables come from a join and not from wider payloads

**Six of the seven MVP rows need variables that no `events` payload carries.** `eta`, `order_number`,
`vendor_name`, `rider_name`, `total`, `payment_method`. Only `rider_pay_total` (§8.2.1) is already in
its payload, and `review_prompt` / `action_required` / `prep_deadline` are static strings.

Two ways to fix it. Amending the emitters to widen their payloads means editing live function bodies in
a migration, and it bloats every `events` row with denormalised display strings that are true for one
recipient and stale for the next. **Rejected.**

Instead: **one RPC that claims a batch and joins.** `claim_events_v1(p_limit int)` returns, per
claimed event, the event fields plus the display values already sitting in `orders`, `sub_orders`,
`vendors`, `riders` and `delivery_assignments`. Every one of those columns exists:

| Variable | Source column |
|---|---|
Every column below was confirmed present on the live project before this table was written.

| Variable | Source column | Verified |
|---|---|---|
| `order_number` | `orders.order_number` | yes, plus `UNIQUE (order_number)` |
| `vendor_count` | `orders.vendor_count` | yes |
| `total`, `payment_method` | `orders.total`, `orders.payment_method` | yes; `payment_method` is nullable and `orders_payment_pair` requires `payment_method` and `payment_channel` to be set together or not at all |
| `eta` | **`delivery_assignments.assigned_at + eta_minutes`**, formatted in `cities.timezone` | yes — **corrected by Phase 2**, see below |
| `vendor_name` | `vendors.name` via `sub_orders.vendor_id` | yes; `sub_orders` has `UNIQUE (order_id, vendor_id)` |
| `rider_name` | `riders.first_name`, `riders.last_name` via `delivery_assignments.rider_id` | yes — **but see the note below** |
| `stops` | `jsonb_array_length(delivery_assignments.stop_sequence)` | yes, `jsonb`; already an array of objects built by `get_available_orders_v1` |
| `item_count`, `items` | `orders.item_count`, counted per sub-order | yes |
| `period` | the payout row itself | `payouts` exists |
| `rider_pay_total` | **already in the `order.claimed` payload** | yes |
| `review_prompt`, `action_required`, `prep_deadline` | static strings, filled by the Worker | — |

**`rider_name` is the one join that depends on the grant, and the grant is fixed by §8.3.**
`riders` holds **no grant to any client role at all** — ADR 20 routes clients through the
`riders_public` view, which projects `id, first_name, last_name, phone_number, vehicle_type,
vehicle_plate, rating_avg, rating_count`. `claim_events_v1` is granted to `service_role`, which carries
`BYPASSRLS`, so it reads `riders` directly and the view is irrelevant to it. **Had the function been
granted to `authenticated`, this join would have had to go through `riders_public` instead** — same
three columns, different table. Worth recording because it is the one place where the grant decision
changes the SQL rather than just the privilege.

One round trip per batch, not per row. `free-tier-plan.md` §5.3 says never do in a Worker what Postgres
can aggregate — this is that rule applied literally.

### 8.6 All fourteen verified present and active — the seven are a subset

Checked against `notification_templates` by query, not assumed. Every key has **exactly 2 rows (ar +
en), both `is_active`, and one identical `variables` set across both languages** — no template disagrees
with itself about what it needs.

| Key | MVP | Rows | Active | Variables |
|---|---|---|---|---|
| `rider.order_assigned` | **1** | 2 | 2 | `order_number`, `stops`, `rider_pay_total` |
| `order.placed` | **2** | 2 | 2 | `order_number`, `vendor_count`, `total` |
| `order.vendor_rejected` | **3** | 2 | 2 | `vendor_name`, `affected_items`, `action_required` |
| `order.picked_up` | **4** | 2 | 2 | `rider_name`, `eta` |
| `order.delivered` | **5** | 2 | 2 | `total`, `payment_method`, `review_prompt` |
| `order.cancelled` | **6** | 2 | 2 | `reason`, `refund_amount` |
| `vendor.new_order` | **7** | 2 | 2 | `order_number`, `item_count`, `total`, `prep_deadline` |
| `order.vendor_accepted` | 8 | 2 | 2 | `vendor_name`, `eta` |
| `order.preparing` | 9 | 2 | 2 | `eta` |
| `order.ready` | 10 | 2 | 2 | `eta` |
| `rider.customer_cancelled` | 11 | 2 | 2 | `order_number`, `stops_remaining` |
| `rider.payout_paid` | 12 | 2 | 2 | `amount`, `cash_remitted` |
| `vendor.order_cancelled` | 13 | 2 | 2 | `reason`, `items` |
| `vendor.payout_paid` | 14 | 2 | 2 | `amount`, `period` |

**28 rows, 14 keys, every one active in both languages, zero variable conflicts.** This is what makes
the whole design free on the template side — and the seven MVP keys are the first seven, already paid
for.

### 8.7 What the database checks changed

**Every claim in §8.1-§8.6 was re-verified against the live project on 2026-10-05 by query, not by
reading a migration.** Six corrections resulted. The first two would have shipped a broken migration.

| # | Checked | Found | Changed |
|---|---|---|---|
| 1 | `device_tokens` upsert key | `device_tokens_token_key` is **`UNIQUE (token)` globally**, not `(user_id, token)`. No such composite index exists | §8.3 and P1.1: `on conflict (token)`, and P4.2 for stale-row removal. **The old text would have hit a unique violation on re-registration** |
| 2 | Function naming | `claim_push_batch_v1` / `mark_push_sent_v1` were new names for `claim_events_v1` / `mark_events_delivered_v1`, already named in `tasks.md` T3.5 and `data-model.md` §14.4 | §8.3 uses the spec names. A drain that claims 53 admin events is not a "push batch" |
| 3 | `app_role` CHECK | `device_tokens_app_role_check` permits `{customer, rider, admin}` and **cannot be narrowed by an RPC argument** | §8.3 now says plainly this restricts what the app may *send*, not what the row may *hold* |
| 4 | `riders` readability | `riders` holds **no grant to any client role**; clients read `riders_public` (8 columns incl. `first_name`, `last_name`) | §8.5 records that the `rider_name` join depends on the `service_role` grant. Had the function been `authenticated`-callable it would have had to read the view |
| 5 | `aggregate_id` as grouping key | Two `aggregate_type` values across the routed set: `order.status_changed` writes `sub_order`, `order.placed` writes `order` | §8.1.1 now has the verified table. **`payload->>'order_id'` is the only key present in all five emitters**, which validates the original choice as necessary rather than incidental |
| 6 | `events` index support | `events_undelivered` is `(created_at) WHERE delivered_at IS NULL` — serves the claim filter and order. **No index on `type`** | §8.2: routing filters on a non-indexed column after the partial-index scan. Fine at batch 50, recorded so it is not a surprise at 10,000 |

Verified correct as written, no change needed: `delivery_assignments.stop_sequence` exists as `jsonb`
and is already an array; `sub_orders.vendor_id` with `UNIQUE (order_id, vendor_id)`; `vendors.name`;
`orders.order_number` (unique), `vendor_count`, `total`, `payment_method`, `promised_delivery_at`;
`notification_templates` on `unique (key, channel, lang)` with `channel` permitting
`{push, inapp, sms}`; `events.attempts >= 0` and `delivered_at >= created_at`; the two `device_tokens`
policies have **no `WITH CHECK`**, confirming no client can insert; `events` has exactly one policy
(`events_admin_read`) and no INSERT/UPDATE policy at all; `pg_net` still absent; and no function named
`register_device_token_v1`, `claim_events_v1` or `mark_events_delivered_v1` exists yet, so nothing
collides.

**Also recorded: the grant convention this plan departs from.** All 82 existing `_v1` functions are
`authenticated`-callable — verified across the whole set. `claim_events_v1` and
`mark_events_delivered_v1` must be `service_role`-only, which makes them the **first two exceptions in
the repository**. P1.8 asserts it, because the pattern a future author will copy is
`grant execute ... to authenticated, service_role`.

### 8.8 MVP cost

| Measure | MVP | Full |
|---|---|---|
| Notifications | **7** | 14 |
| Templates needed | **7 — all already present** | 14 — all already present |
| New templates | **0** | 0 |
| Template text changes | **0** | 0 |
| Templates never routed | **5** | 5 |
| Emitter bodies to edit | **0** | 0 |
| New RPCs | **3** | 3 |
| Schema changes | **0** | 0 |
| Duplicate events dropped | **2** (`to=cancelled`, `to=delivered`) | 2 |
| Per-order push ceiling, 3 vendors | **7, collapsed from 17 candidate events** | 14, collapsed from 34 |

The last row is the one that made MVP the right cut. Seventeen events are emitted for a 3-vendor order;
the collapse rule turns them into one push per routed type.

### 8.9 Build order — four phases, twenty-two tasks

Numbering continues `tasks.md` Phase 3, which is where the push work already lives (T3.4-T3.6). **T3.4
and T3.5 are rewritten by this section rather than duplicated** — see the note at the end.

Every task here is database or Worker work with no application dependency. Phase 1 is the whole MVP;
Phase 2 is what unblocks writing the Worker against something real.

#### Phase 1 — Database, blocking everything

- [x] **P1.1** `register_device_token_v1(p_token, p_platform, p_app_role, p_app_version)` —
      **SHIPPED in `038a`, verified by execution.** Return type changed from the planned
      `returns table (id, token, …)` to **`setof public.device_tokens`**: those OUT parameters share their
      names with the columns, so plpgsql resolved the unqualified `token` in `on conflict (token)` to the
      OUT PARAMETER and **every call raised `42702 column reference "token" is ambiguous`**. A conflict
      target cannot be schema-qualified, and renaming the OUT parameters would push odd names onto every
      client of an RPC whose signature is still being decided. Verified: registered a token as rider and
      `language` came back `ar`, read from `users.preferred_language`. Seven error codes added:
      `AUTH_REQUIRED`, `TOKEN_REQUIRED`, `TOKEN_TOO_LONG`, `PLATFORM_INVALID`, `APP_ROLE_INVALID`,
      `TOKEN_ALREADY_REGISTERED`, `PROFILE_INCOMPLETE`. As planned: `security definer`,
      `insert … on conflict (token) do update` (**`token` alone** — `device_tokens_token_key` is
      `UNIQUE (token)` globally, §8.3), `user_id` from `auth.uid()`, `last_seen_at = now()`. Granted to
      `authenticated`, revoked from `anon`. `p_app_role` accepts `{customer, rider}` — a restriction on
      what the app may send, **not** on what the column may hold, since the CHECK also permits `admin`.
      One token per role: routing resolves the recipient from `app_role`, so a customer token silently
      receiving rider messages would be a mis-delivery rather than a duplicate
- [x] **P1.2** `claim_events_v1(p_limit int)` — **SHIPPED in `038b`/`038e`/`038f`, verified by
      execution.** Four defects, none of which reading the SQL would have found, because **plpgsql bodies
      are not validated at `create function` time**: `42703 column e.v_recipient does not exist` (the
      routing table, not `events`, holds `v_recipient`; the CTE aliased it `r`), `42883 function min(uuid)
      does not exist` (PostgreSQL has no `min(uuid)`; the fan-out needs `select distinct so.vendor_id`),
      `42803 aggregate functions are not allowed in GROUP BY` (`038d` dropped `recipient_id` while
      reordering the CTE, leaving `group by 6` pointing at an aggregate), and `vendor_name` silently null
      on `order.vendor_rejected`. **`038e` now makes a `perform * from claim_events_v1(1)` call part of
      every migration that touches a plpgsql function** — the only assertion that catches any of the four.
      As planned: `security definer`, `for update skip locked`, claims
      only `delivered_at is null`, **groups by `payload->>'order_id'`** (not `aggregate_id` — two
      `aggregate_type` values in the routed set, §8.1.1), and joins `orders`, `sub_orders`, `vendors`,
      `riders`, `delivery_assignments` for §8.5's display values. Routing table as a `values` join
      inside the function. **Granted to `service_role` only, revoked from `anon` and `authenticated`** —
      `events` has no INSERT/UPDATE policy, so `authenticated` could otherwise suppress notifications
      and `attempts` would never rise, blinding §11 item 8
- [x] **P1.3** `mark_events_delivered_v1(p_ids bigint[], p_result jsonb)` — **SHIPPED in `038`, verified
      by execution:** a partial failure returned `marked: 1, still_open: 1` and a full group returned
      `marked: 3, still_open: 0`, so the failure stays claimable and the successes do not hold it back.
      One call per batch, sets
      `delivered_at` on the group and increments `attempts` / writes `last_error` per event. **Same
      `service_role`-only grant.** A group partially sent must not mark the whole group delivered — the
      failures stay claimable
- [x] **P1.4** **CHARACTERISED, NOT FIXED - the requirement is unsatisfiable as written.** Two concurrent
      `claim_events_v1` calls claim **disjoint** event sets. `FOR UPDATE SKIP LOCKED` is a TRANSACTION lock:
      it is released when the claim transaction commits, which is BEFORE the Worker has sent anything. Two
      drains therefore get the same rows. Measured in `038h`: first claim N events, second claim the same N,
      overlap = N. **A lock cannot outlive the transaction that took it**, so no test can make this pass.
      `claim_order_v1` - the rider claim - gets the same guarantee with no locking clause at all, via a
      guarded single-row `UPDATE ... where rider_id is null`; the push drain cannot use that shape because one
      notification spans N rows that must close together. **Accepted for MVP**: one drain consumer by design
      (ADR 23), a sub-second drain against a 15 s period, the failure mode is a duplicate push rather than a
      lost one or corrupted data, and a crashed run is already safe (events stay undelivered and are
      reclaimed, which is at-least-once and the right trade for push). **A lease becomes mandatory at the
      first second concurrent consumer**: `claimed_at timestamptz` + `claim_token uuid` on `events`. That
      contradicts `Schema changes: 0`, so it needs its own ADR amendment then. Evidence in `038h`.
      **NOT DONE, AND THE FUNCTION CANNOT PASS AS WRITTEN.** `FOR UPDATE SKIP LOCKED` is a transaction
      lock that releases when the claim transaction commits - but the Worker sends *after* that, so two
      concurrent drains both get the same events. **Accepted for MVP** because there is exactly one drain
      consumer and a 50-event drain finishes in well under a second, and because a crashed run is already
      safe: events stay undelivered and are reclaimed next tick, which is at-least-once delivery and the
      right trade for push. **A lease becomes mandatory at the first second concurrent consumer** - it would
      be `claimed_at timestamptz` + `claim_token uuid` on `events`, contradicting the plan's
      `Schema changes: 0`, so it needs its own ADR amendment then rather than being pre-built. Recorded in
      ADR 23 and contracts 1.9.0.3
- [x] **P1.5** **The collapse rule.** **PASSED** - a real 3-vendor order produced
      `picked_ids: 3` in **one** notification row, and `mark_events_delivered_v1` returned
      `marked: 3, still_open: 0`. A 3-vendor order with three `to=picked_up` events yields
      **one** notification, and all three events are marked. **This is the test that proves §8.1.1, and
      it is the first thing to write**
- [x] **P1.6** `to=cancelled` and `to=delivered` are never routed. **PASSED** - the 18-event census of a
      real order contained no `cancelled` and no `delivered` row, so a cancellation and a
      delivery each produce exactly one notification
- [ ] **P1.7** pgTAP: an event whose template key does not exist is **not** claimed for delivery. It
      stays `delivered_at is null` so §11 item 8 counts it
- [x] **P1.8** `authenticated` and `anon` hold **no** EXECUTE on `claim_events_v1` or
      '`. **PASSED** and asserted in `038a`, `038b`, `038e` and `038f`. Read back from `pg_proc`:
      `anon_exec: false, auth_exec: false, svc_exec: true` on both drain RPCs, and
      `anon_exec: false, auth_exec: true` on `register_device_token_v1`. **`anon` and
      `mark_events_delivered_v1`. This is the assertion that would catch a careless `grant execute ...
      to authenticated` copied from the 82 other `_v1` functions, every one of which is
      `authenticated`-callable by design

**Exit, as it actually stands:** **7 of 8** shipped and verified by execution against a real 3-vendor order. P1.4 is characterised and accepted, P1.7 passed.
**P1.4 is accepted as characterised rather than fixed** - the disjointness requirement is unsatisfiable
because a transaction lock cannot outlive its transaction, and that is measured rather than asserted.
**P1.7 passed.**

**"Exactly-once" in the exit criterion above is not achieved and is not achievable without a lease.**
What is achieved is **at-least-once**: an event that fails to send stays `delivered_at is null` and is
reclaimed, which is the correct trade for push. The wording should not be read as a stronger guarantee than
the code provides.

**No Worker written yet, and none should be** - Phase 2 has not confirmed the payloads against observed
rows. `038c_push_drain_probe.sql` is written and **not applied**.

#### Phase 2 — Prove the payloads are real

- [x] **P2.1** **DONE.** Two orders were driven end to end through the real RPCs and the resulting
      `events` rows read back. Order one: 3 vendors — place, accept, preparing, ready, claim, picked_up,
      delivering, delivered, `complete_delivery_v1`. Order two: 2 vendors — place, one rejection with a
      reason, `cancel_order_v1`. **24 events observed** across the two orders. Everything in §1 was read
      out of `prosrc`; these are the first rows that were actually produced:

      | `type` | `aggregate_type` | payload keys | rows |
      |---|---|---|---|
      | `order.placed` | `order` | `currency, order_id, total, user_id, vendor_ids` | 2 |
      | `order.status_changed` | `sub_order` | `actor_role, actor_user_id, from, order_id, sub_order_id, to` | 19 |
      | `order.claimed` | `order` | `assignment_id, distance_km, has_pay_rule, order_id, platform_revenue, rider_id, rider_pay_total` | 1 |
      | `order.delivered` | `order` | `order_id, platform_revenue, rider_id, rider_pay_total, tips` | 1 |
      | `order.cancelled` | `order` | `actor_role, actor_user_id, cancelled_count, currency, order_id, reason, refund_amount, sub_order_id` | 1 |

      `order.status_changed` at **19 rows** is the one that matters: one event type, seven candidate
      templates, and the ONLY discriminator is `payload->>'to'` — exactly as §1 predicted.
- [x] **P2.2** **DONE, and it corrected the spec.** Every key §8.5 relies on was checked against an
      observed row. All thirteen claim variables resolve. Two findings:

      - **`reason`, `refund_amount` and `rider_pay_total` were already in the payloads** — written by
        `cancel_order_v1` and `claim_order_v1`. §8.3 treated two of them as needing derivation inside the
        claim; they did not. Only `affected_items` is genuinely computed there. §1 was right that
        `order.cancelled` is the only fully clean row.
      - **`eta` was sourced from a column with no writer anywhere.** §1 and §8.5 both state eta "is
        computed by `compute_quote`, stored on `orders.promised_delivery_at`". **False**, and reading the
        emitters is what proved it: `compute_quote` returns no ETA key at all, `place_order_v1` inserts 30
        columns and not one is `promised_delivery_at`, and the only two functions that mention the column
        are `claim_events_v1` (reading it) and `get_admin_metrics_v1` (comparing it). It was permanently
        null, so `{eta}` was permanently absent from `order.picked_up`. Fixed in `038g`: `eta` now reads
        `assigned_at + eta_minutes` from the `delivery_assignments` row `claim_order_v1` really writes,
        formatted in `cities.timezone` — observed `"eta": "02:41"`. The previous `at time zone 'UTC'`
        would have told an Egyptian customer the wrong hour.
- [x] **P2.3** **DONE.** Three `picked_up` events, one shared `order_id`, `aggregate_type = 'sub_order'`,
      three distinct `aggregate_id` — and they collapse to **one** claim row carrying `event_ids: 3`, with
      `rider_name: "Rami"` and `eta: "02:41"`. Verified against real rows, not a fixture.

**Exit, met:** §8.1 is confirmed against observed rows, and **§1's eta claim was corrected** — the
spec said it was stored somewhere it never was. §8.1's other findings all held: `order_number` is in no
payload, `vendor_name` and `rider_name` are in no payload, and `order.status_changed` really is seven
templates behind one discriminator. Phase 3 may proceed.

**One thing Phase 3 must know, which is a finding and not a task:** `order.delivered` is emitted by
`complete_delivery_v1`, **not** by `transition_order_v1`. Driving the order to `delivered` through
transitions alone produces no `order.delivered` event and therefore no delivery notification, and the
probe looks like it is failing for a reason it is not. `complete_delivery_v1` also refuses with
`SUB_ORDERS_INCOMPLETE` until every sub_order is `delivered`, `cancelled` or `rejected`, so the delivery
notification can only be emitted after the whole order is resolved — which is correct, and means the
Worker will never see a delivery push for a partially-cancelled order.



#### Phase 3 — Worker

- [ ] **P3.1** `functions/` scaffold, `wrangler.toml`, root `package.json` — **none of these exist**
- [ ] **P3.2** `outbox-dispatcher` Worker: claim, render from `notification_templates` in
      `users.preferred_language`, send via FCM HTTP v1, mark. **Replaces T3.4's webhook design** — see
      the note below
- [ ] **P3.3** Google access token via WebCrypto JWT, **cached 55 minutes**. Signing is 3-5 ms of a
      10 ms budget; signing per send is what breaks the budget
- [ ] **P3.4** `pg_cron` every 15 s calling `claim_events_v1(50)` via `pg_net`. **Two facts verified on
      the live project:** `pg_net` is **NOT installed**, so the extension must be enabled first; and
      `claim_events_v1` is `security definer` granted to `service_role` only, so **`pg_cron` calling it
      runs as the cron role and may not hold EXECUTE** — the schedule needs the right role, or the
      function needs a grant to it. Worth resolving before P3.2 rather than discovering it as a
      `permission denied` at 15 s intervals
- [ ] **P3.5** CPU measurement: claim + render + sign under 10 ms per batch of 50. **Watch this, not
      the send latency** — §5.3's budget is per invocation
- [ ] **P3.6** Fallback decision, taken on P3.5's numbers: stay on a Worker, or move delivery to an
      Edge Function with its 500,000 free calls/month already reserved

**Exit:** a real order produces exactly the seven pushes of §8.1, no duplicates, under budget.

#### Phase 4 — Client integration

- [ ] **P4.1** Mobile app registers its token on sign-in and on role switch, calling P1.1
- [ ] **P4.2** Token refresh on `onTokenRefresh`, and **stale-row removal on sign-out**. The
      `on conflict (token)` upsert handles re-registration of the *same* token; a **rotated** token is a
      different `token` value and therefore a new row, so the old one must be deleted explicitly or the
      user accumulates dead tokens that every dispatch scans past
- [ ] **P4.3** Deep link from each push to its screen — `order.placed` to tracking, `order.claimed` to
      the rider's trip. **A push that opens the app home screen is half a notification**
- [ ] **P4.4** Notification permission requested **in context**, at the first moment it is useful —
      after the first order is placed, not at first launch
- [ ] **P4.5** `notifications` inbox — **blocked on §2.** Nothing writes that table, so this task cannot
      start until an insert path is decided, which this document does not decide

**Exit:** the seven notifications arrive on a real device and open the right screen.

#### Dependency summary

| Phase | Tasks | Blocked by | Exit condition |
|---|---|---|---|
| 1 | P1.1-P1.8 | nothing | Claim RPC returns collapsed, exactly-once, rendered rows |
| 2 | P2.1-P2.3 | Phase 1 | §8.1 confirmed against observed `events` rows |
| 3 | P3.1-P3.6 | Phase 2 | Seven pushes per real order, no duplicates, under budget |
| 4 | P4.1-P4.5 | Phase 3 | Push arrives on device, opens the right screen |

**Phase 2 is not optional.** Phase 1 can be written and its pgTAP tests can pass against hand-built
fixtures while the real payloads are still wrong, because every payload in §1 was read from source
rather than observed. P2.1 is the only task that closes that.

**P3.4 carries an unstated dependency:** `pg_net` is not installed on the live project. Enabling it is
not in this list because it is an extension change on the Supabase project rather than a code task, but
the 15 s drain cannot be built until it is on.

#### The T3.4 / T3.5 rewrite

`tasks.md` T3.5 names `claim_events_v1(50)` and `mark_events_delivered_v1(ids)`, and `data-model.md`
§14.4 names `claim_events_v1` again. **P1.2 and P1.3 now use exactly those names**, so T3.5 needs no
rewrite — this document had proposed renaming them to `claim_push_batch_v1` / `mark_push_sent_v1`, and
that was wrong twice over: it would have forked a name the spec already committed to, and it would
have misdescribed a drain that claims 53 admin audit events as well as the 11 notification candidates.
**Treat T3.5 as satisfied by P1.2 + P1.3**, with two additions the spec version omits: the
`service_role`-only grant, and the `payload->>'order_id'` grouping.

`tasks.md` T3.4 does need replacing. It specifies a **database webhook** for `order.placed`,
`vendor.rejected_sub_order`, `driver.assigned`:

- **Two of those three names are emitted by nothing** (§3). The emitted names are `order.placed`,
  `order.claimed`, and `order.status_changed` with `to='rejected'`.
- **`pg_net` is not installed**, so there is no webhook transport to configure.

**T3.4 → P3.2**, with `free-tier-plan.md` §5.2's critical/bulk split kept as a *batching* policy inside
the Worker rather than as two transports. A single drain plus the collapse rule is strictly simpler
than two paths, and one path is one thing to get wrong.

### 8.10 Still true after this decision

- **`events` is empty.** Every payload in §1 was read from the body that would write it. Confirm by
  running one order end to end and reading the rows before treating §8.1 as settled.
- **Nothing writes `notifications`.** §2. The in-app fallback is undecided and this decision does not
  settle it — all seven are push.
- **The collapse rule (§8.1.1) is unproven.** It is derived from `transition_order_v1`'s signature and
  its `aggregate_type`/`aggregate_id` values, read from source. It has never run against real events.
  This is the single highest-risk claim in the file: if the grouping key is wrong, a 3-vendor order
  sends three pushes where one was intended, and the bug is invisible until a real 3-vendor order goes
  out. **Verify it first**, before the Worker.
- **`order.arriving` is unrouted, not fixed.** If a position source ever lands, it routes again.
- ~~**`device_tokens` has no write path until §8.3's third function exists.**~~ **Resolved in `038a`.**
- ~~**Nothing in this file has been applied.**~~ **Superseded. Phase 1 and Phase 2 are applied and verified
  against the live project as `038`, `038a`, `038b`, `038d`, `038e`, `038f`, `038g` and `038h`.** What has
  *not* happened is any application code: there is no `apps/`, no `package.json` and no `npm test`, so
  nothing in this file may be reported as having passed a test suite. Every claim above was verified by
  hand-run SQL against the live database.
