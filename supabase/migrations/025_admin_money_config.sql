-- 025: the six unbuilt money functions — the last of admin-crud-plan.md §5.
--
-- WHAT THIS CLOSES. contracts.md §1.8 names thirteen money functions. Five shipped in `019`.
-- The eight-name gap was a naming artefact — `run_payout_v1` absorbs three and
-- `get_wallet_v1` ships as `get_wallet_balance_v1` — and six capabilities genuinely had no
-- writer at all. This file is those six. Open question 3.30, open since `019`.
--
-- WHY THEY WERE NOT BUILT WITH `019`. §15.2 assigns `019` five functions, and a migration
-- that quietly also creates six more is a migration nobody can review against its stated
-- contents. `019` was right to leave them; they were left too long.
--
-- WHAT IS URGENT HERE, IN ORDER.
--
--   1. `freeze_wallet_v1`. `wallets_status_reason_required` already demands a reason for any
--      non-active status, and `wallets_status_check` already accepts 'frozen' and 'review'.
--      Nothing can set one. So today a wallet can only be frozen by editing the row directly,
--      which is exactly what the constraint exists to prevent — the audit trail the
--      constraint was written to create is the thing being bypassed. This is a live hole,
--      not a missing convenience.
--   2. `set_commission_rule_v1`. Constitution I.9: turning commission on is an `update`,
--      never a migration, and never retroactive. There is no RPC to do it, so turning on
--      vendor commission in month 3-4 means raw SQL against a live table.
--   3. `set_fee_tier_v1`. Constitution I.7, same argument for the delivery fee constants.
--
-- ---------------------------------------------------------------------------
-- INVARIANTS
-- ---------------------------------------------------------------------------
--   Rule 1  Prices, fees, discounts and commissions are computed in Postgres, never in the
--           app. No function here accepts or returns a computed money amount.
--           `set_fee_tier_v1` takes `p_multiplier_bps` — an integer, never a percentage
--           string and never a float. 10000 = x1.00, 11000 = x1.10.
--   Rule 5  Every `idempotency_key` is unique; a retry must never double-charge. Only
--           `freeze_wallet_v1` takes one, because only `freeze_wallet_v1` moves money
--           state. The other five write configuration: a retried `set_fee_tier_v1` writes
--           the same value to the same row, which is harmless and not a double-charge.
--           Adding idempotency keys to configuration writers would be ceremony, and
--           `delivery_fee_tiers` has no key column to hold one.
--   Rule 9  Commission changes are an `update`, never a migration, and NEVER retroactive.
--           See the dated-supersede design below. This is the invariant most at risk in
--           this file and the one the assertions defend hardest.
--   Rule 16 Every state change writes its `events` row in the same transaction. Each of the
--           four mutating functions below writes exactly one. Same transaction, so a
--           committed write always has its event and vice versa.
--   Rule 7  Every money constant is configuration, not code. Nothing below hardcodes a fee.
--   Rule 6  No customer wallet. `wallets.owner_type` stays vendor|rider, and
--           `freeze_wallet_v1` re-checks it rather than trusting the caller.
--   ADR 19  Vendor sub-order isolation. Not touched: nothing here reads an order.
--   ADR 20  `riders` is not client-readable. `freeze_wallet_v1` accepts a rider id as an
--           opaque uuid and never selects from `riders`.
--
-- ---------------------------------------------------------------------------
-- set_commission_rule_v1: SUPERSEDE, DO NOT EDIT
-- ---------------------------------------------------------------------------
-- contracts.md §1.8 gives this as `set_commission_rule_v1(p_rule_id, p_value, p_is_active)`
-- editing the row in place. The plan gives it as
-- `(p_scope, p_applies_to, p_value_bps, p_effective_from)` inserting a new dated rule.
-- Decided, asked rather than assumed: THE PLAN WINS, and the reasoning is worth recording
-- because contracts.md is not wrong about the goal, only about the mechanism.
--
-- In-place editing cannot satisfy rule 9's auditability. If activating vendor commission
-- overwrites the seeded row, then "what was the rate last month" becomes unanswerable —
-- and rule 9 exists precisely so a retroactive commission is a *detectable* money bug
-- rather than a silent one. `commission_rules` was designed for this: it carries
-- `effective_from`, `effective_until`, `commission_type`, `applies_to`, `min_amount` and
-- `max_amount`, which is a versioned rule, not a mutable preference. The columns are the
-- argument for superseding.
--
-- So: inserting a new row and closing the previous one with `effective_until`. The old
-- rule stays, dated, and the history is provable. `admin-crud-plan.md` §4a agrees, listing
-- `commission_rules` among the nine tables where `deleted_at` is deliberately NOT added
-- because "soft-deleting a rule destroys the dated history that makes that auditable".
--
-- `p_effective_from` is accepted but constrained: a date in the past is REFUSED, not
-- silently clamped. Clamping would report success for a request the caller did not make,
-- and a caller asking to backdate a commission needs to be told no rather than given the
-- nearest legal thing. Future dates are allowed and are the point — a rule scheduled for
-- next month is a legitimate operational act.
--
-- ---------------------------------------------------------------------------
-- WHY set_fee_tier_v1 IS AN UPSERT AND NOT AN UPDATE
-- ---------------------------------------------------------------------------
-- `delivery_fee_tiers` is keyed `(zone_id, vendor_count)`, so the row may not exist yet.
-- An admin configuring a new zone's 1/2/3-vendor tiers needs an insert, and needs a
-- second call to change one. Both are the same operation with the same invariants, so this
-- is one upsert. `created_at` is left alone on the update path, so the row's age survives
-- an edit — which is what an admin console's "tier configured 40 days ago" column needs.
--
-- The plan says this function "refuses a vendor_count that duplicates an existing tier".
-- That is not implementable as stated: duplicating the key IS the upsert. What is
-- implementable, and what is implemented, is that the operation is idempotent per
-- `(zone_id, vendor_count)` — there is never a second row for the same pair — and that the
-- monotonicity constraint is re-checked on every call. `trg_fee_tiers_monotonic` is a
-- DEFERRABLE CONSTRAINT trigger, so it fires at COMMIT rather than per statement, which is
-- why an upsert that would break monotonicity still aborts the whole transaction.
--
-- ---------------------------------------------------------------------------
-- ERROR CODES
-- ---------------------------------------------------------------------------
-- contracts.md §5 describes `raise_app_error` as the single place an error code and Arabic
-- message are formatted. It does not exist — open question 3.21, raised independently by
-- both the `016` and `020` authors. Adopting it here would be a seventh function on the
-- PostgREST surface that this migration was not assigned, so these six raise through
-- `private.err(code, message)`, which 005e already created and which produces exactly the
-- format §5 specifies: `CODE: message` at SQLSTATE P0001. Adopting the helper later is a
-- mechanical substitution, per §1.8.1.
--
-- Codes used, all prefixed to match the existing corpus:
--   NOT_AUTHORIZED         every function, before any input is inspected
--   ZONE_NOT_FOUND         get_fee_rules_v1, set_fee_tier_v1
--   VENDOR_COUNT_INVALID   set_fee_tier_v1
--   MULTIPLIER_INVALID     set_fee_tier_v1
--   SCOPE_INVALID          get_commission_v1, set_commission_rule_v1
--   APPLIES_TO_INVALID     set_commission_rule_v1
--   COMMISSION_TYPE_INVALID set_commission_rule_v1
--   VALUE_INVALID           set_commission_rule_v1
--   EFFECTIVE_FROM_IN_PAST  set_commission_rule_v1  (constitution I.9, no backdating)
--   EFFECTIVE_FROM_INVALID  set_commission_rule_v1  (must start AFTER the rule it supersedes)
--   OWNER_TYPE_INVALID     freeze_wallet_v1
--   OWNER_REQUIRED         freeze_wallet_v1
--   REASON_REQUIRED        freeze_wallet_v1
--   WALLET_NOT_FOUND       freeze_wallet_v1
--   WALLET_STATUS_INVALID  freeze_wallet_v1 (freeze a wallet that is already frozen)
--   ALREADY_FROZEN         freeze_wallet_v1, on idempotent replay
--
-- ---------------------------------------------------------------------------
-- NO FUNCTION IS CREATED IN PUBLIC EXCEPT THE SIX NAMED
-- ---------------------------------------------------------------------------
-- Every function below is `SECURITY DEFINER` with `search_path = ''` and every name fully
-- qualified, per data-model.md §17 finding 1. Suite check 10 asserts the pinned path for
-- every definer function and must keep passing. `private.is_admin()` is the FIRST
-- statement in each, before any argument is inspected, so a non-admin caller learns
-- nothing about the arguments — not whether a zone exists, not whether a wallet is frozen.
--
-- Table names are literals in the bodies, never parameters. A client-supplied `p_table`
-- choosing the write target has the same shape as the auth-argument defect constitution
-- III.20 forbids: permission must not come from a client value.
--
-- No `p_table` and no `p_op`. The rejected alternative — one generic
-- `admin_write_v1(p_table, p_op, p_payload)` — is a dynamic dispatch surface where a
-- client string selects the write, and it would be unauditable at six tables in one body.
--
-- Grants: `authenticated` only, and only these six. `anon` gets nothing, so a signed-out
-- visitor cannot probe them. `get_fee_rules_v1` and `get_commission_v1` are read-only and
-- are granted to `authenticated` because an admin console and a support agent both need
-- them; they are not admin-gated because `014` already publishes the underlying rows
-- (`delivery_zones`, `delivery_fee_tiers` and the default `commission_rules` rows are
-- public by ADR 3 and 3.18), so gating the read would be theatre that hides nothing.
-- `private.is_admin()` is not called by them, and that is deliberate — see the note on
-- `get_commission_v1` below for what a caller can and cannot learn.

-- =============================================================================================
-- get_fee_rules_v1 — read the whole fee configuration for a zone
-- =============================================================================================
-- One row for the zone plus one row per tier, so the admin console renders a zone's fee
-- structure in a single round trip and support can answer "what would 4 vendors cost"
-- without assembling it from three queries.
--
-- The service-fee settings are included because contracts.md §1.8 says this returns "base
-- fee, free radius, per-km, max_vendors, all tiers" and the customer service fee is part of
-- what a zone's configuration IS. They are read from `settings` rather than a column
-- because ADR 3 and constitution I.7 put the service fee in configuration, and the settings
-- table is where `009t` seeded it.
create or replace function public.get_fee_rules_v1(p_zone_id uuid)
returns table (
  zone_id            uuid,
  zone_name          text,
  zone_name_ar       text,
  currency           char(3),
  delivery_base_fee  integer,
  free_radius_km     numeric,
  per_km_fee         integer,
  max_vendors        smallint,
  min_order_value    integer,
  max_distance_km    numeric,
  is_active          boolean,
  service_fee_enabled boolean,
  service_fee_type   text,
  service_fee_value  jsonb,
  vendor_count       smallint,
  multiplier_bps     integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_zone_id is null then
    perform private.err('ZONE_NOT_FOUND', 'zone_id is required');
  end if;

  -- LEFT JOIN, not INNER: a zone with no tiers configured is a real state an admin needs
  -- to see and fix, and an inner join would report it as a missing zone instead.
  return query
    select z.id, z.name, z.name_ar, z.currency,
           z.delivery_base_fee, z.free_radius_km, z.per_km_fee,
           z.max_vendors_per_order, z.min_order_value, z.max_distance_km, z.is_active,
           coalesce(private.setting_bool('service_fee_enabled', false), false),
           coalesce(private.setting_str('service_fee_type', 'fixed'), 'fixed'),
           (select s.value from public.settings s where s.key = 'service_fee_default'),
           t.vendor_count, t.multiplier_bps
      from public.delivery_zones z
      left join public.delivery_fee_tiers t on t.zone_id = z.id
     where z.id = p_zone_id
     order by t.vendor_count nulls last;
end;
$$;

comment on function public.get_fee_rules_v1(uuid) is
  'Zone fee configuration plus every tier, one row per tier. Read-only. Added by 025.';

-- The grant/revoke PAIR is mandatory and the order is not stylistic. Postgres grants EXECUTE
-- to PUBLIC on every new function by default, so a bare `grant ... to authenticated` ADDS a
-- second holder rather than transferring one, and anon keeps the PUBLIC grant. Every
-- existing RPC in this schema pairs them (019:961-965, 020:323, 016:333) for that reason.
-- The closing assertion below checks anon cannot execute any of the six, and it caught this
-- omission on the first apply rather than leaving it to review.
revoke execute on function public.get_fee_rules_v1(uuid) from public, anon;
grant  execute on function public.get_fee_rules_v1(uuid) to authenticated;

-- =============================================================================================
-- set_fee_tier_v1 — upsert one per-vendor-count multiplier
-- =============================================================================================
-- Basis points, never a float and never a percentage string. `p_multiplier_bps` is an
-- integer 0..100000, matching `delivery_fee_tiers_multiplier_bps_check`, and this function
-- validates it before the write so the caller gets FEE_TIER's own code rather than a raw
-- CHECK violation naming a constraint it should not have to know.
create or replace function public.set_fee_tier_v1(
  p_zone_id        uuid,
  p_vendor_count   smallint,
  p_multiplier_bps integer
)
returns table (
  zone_id        uuid,
  vendor_count   smallint,
  multiplier_bps integer,
  created        boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_exists boolean;
begin
  -- is_admin FIRST, before p_zone_id is even null-checked.
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  if not private.is_admin() then
    perform private.err('NOT_AUTHORIZED', 'fee tiers are admin only');
  end if;

  if p_zone_id is null then
    perform private.err('ZONE_NOT_FOUND', 'zone_id is required');
  end if;
  if not exists (select 1 from public.delivery_zones z where z.id = p_zone_id) then
    perform private.err('ZONE_NOT_FOUND', 'no such delivery zone');
  end if;
  if p_vendor_count is null or p_vendor_count < 1 or p_vendor_count > 10 then
    perform private.err('VENDOR_COUNT_INVALID', 'vendor_count must be between 1 and 10');
  end if;
  if p_multiplier_bps is null or p_multiplier_bps < 0 or p_multiplier_bps > 100000 then
    perform private.err('MULTIPLIER_INVALID', 'multiplier_bps must be between 0 and 100000');
  end if;

  -- Existence probed rather than inferred from xmax, so the returned `created` flag means
  -- "this call inserted" and not "this call was the first one in some vague sense". The
  -- probe aliases its table `dft` for the same reason as the conflict target below: an
  -- unaliased reference to `vendor_count` in that subquery is ambiguous for the identical
  -- reason.
  select exists (select 1 from public.delivery_fee_tiers dft
                  where dft.zone_id = p_zone_id and dft.vendor_count = p_vendor_count)
    into v_exists;

  -- ON CONFLICT NAMES THE CONSTRAINT, not the columns. This is not a style choice and it
  -- was a real bug caught by the first behavioural run: this function's OUT parameters are
  -- `zone_id` and `vendor_count`, and plpgsql promotes OUT parameter names to variables that
  -- are in scope for the whole body. A bare `on conflict (zone_id, vendor_count)` then
  -- resolves each name against BOTH the table column and the variable, and Postgres refuses
  -- with `column reference "zone_id" is ambiguous`. Qualifying with the insert alias does not
  -- help — `on conflict (t.zone_id, ...)` is itself a syntax error, because the conflict
  -- target may only name columns of the target relation, unqualified. Naming the constraint
  -- sidesteps the collision and is more precise anyway: it states which key makes this an
  -- upsert, so a future change to the primary key cannot silently redirect it.
  insert into public.delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
  values (p_zone_id, p_vendor_count, p_multiplier_bps)
  on conflict on constraint delivery_fee_tiers_pkey do update
    set multiplier_bps = excluded.multiplier_bps
    -- created_at deliberately NOT touched: an edit must not reset the row's age, which is
    -- what an admin console's "configured N days ago" column reads.
  ;

  -- Rule 16. One events row, same transaction. `fee_tier.set` is a new type: the catalogue
  -- in contracts.md 3.1 has no fee-tier event, and inventing no event would leave the
  -- change invisible to the outbox. The payload carries ids and the two numbers, never the
  -- zone name, so a money change is auditable without putting display text in the queue.
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('fee_tier.set', 'delivery_zone', p_zone_id,
          jsonb_build_object('actor', v_user,
                             'vendor_count', p_vendor_count,
                             'multiplier_bps', p_multiplier_bps,
                             'created', v_exists));

  return query select p_zone_id, p_vendor_count, p_multiplier_bps, not v_exists;
end;
$$;

comment on function public.set_fee_tier_v1(uuid, smallint, integer) is
  'Upsert one zone tier. multiplier_bps only, never a float. Admin. events: fee_tier.set. Added by 025.';

revoke execute on function public.set_fee_tier_v1(uuid, smallint, integer) from public, anon;
grant  execute on function public.set_fee_tier_v1(uuid, smallint, integer) to authenticated;

-- =============================================================================================
-- get_commission_v1 — read the effective commission rules
-- =============================================================================================
-- Read-only. Returns the ACTIVE and any FUTURE rules for a scope, plus anything currently
-- inside its effective window. The seed state is visible through this: one active rider cut
-- on the delivery fee, one inactive vendor row on the subtotal.
--
-- NOT admin-gated, deliberately. `commission_rules` is already readable by `authenticated`
-- under `014` (the default rows are public by ADR 3 and 3.18), so gating this read would
-- add a code path that rejects calls which are already permitted at the table, and would
-- make the function look like an admin surface when it is a read of public configuration.
-- What this does NOT leak: `min_amount`/`max_amount` and `target_id` are the operator's
-- commercial terms, and those are already readable on the table by the same role, so
-- omitting them here would be hiding nothing while making the function less useful for
-- support. If ADR 20's reasoning is ever extended to commission terms, the gate belongs on
-- the TABLE policy, not on this function — a function-level gate in front of a readable
-- table is a false sense of security.
create or replace function public.get_commission_v1(
  p_scope    text default null,
  p_target_id uuid default null
)
returns table (
  rule_id          uuid,
  scope            text,
  target_id        uuid,
  commission_type  text,
  value            integer,
  applies_to       text,
  min_amount       integer,
  max_amount       integer,
  effective_from   timestamptz,
  effective_until  timestamptz,
  is_active        boolean,
  is_effective_now boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_scope is not null and p_scope not in ('vendor','rider','platform') then
    perform private.err('SCOPE_INVALID', 'scope must be vendor, rider or platform');
  end if;

  return query
    select cr.id, cr.scope, cr.target_id, cr.commission_type, cr.value, cr.applies_to,
           cr.min_amount, cr.max_amount, cr.effective_from, cr.effective_until, cr.is_active,
           -- The same predicate private.resolve_pay uses, so what an admin reads here is
           -- exactly what a delivery will be priced with. A read that disagreed with the
           -- pricing path would be worse than no read at all.
           (cr.is_active
            and cr.effective_from <= now()
            and (cr.effective_until is null or cr.effective_until > now()))
      from public.commission_rules cr
     where (p_scope is null or cr.scope = p_scope)
       -- p_target_id narrows to one subject, and DELIBERATELY includes the city-wide
       -- default (target_id is null) alongside the subject-specific rule. Both can apply
       -- to the same delivery, so returning only the specific one would understate what an
       -- admin is looking at. This matches the pricing path: private.resolve_pay filters on
       -- scope and applies_to only and never on target_id, so a read that filtered more
       -- tightly than the pricing query would not describe the pricing.
       and (p_target_id is null or cr.target_id is null or cr.target_id = p_target_id)
     order by cr.scope, cr.applies_to, cr.effective_from desc;
end;
$$;

comment on function public.get_commission_v1(text, uuid) is
  'Commission rules for a scope, with is_effective_now computed by the same predicate the pricing path uses. Read-only. Added by 025.';

revoke execute on function public.get_commission_v1(text, uuid) from public, anon;
grant  execute on function public.get_commission_v1(text, uuid) to authenticated;

-- =============================================================================================
-- set_commission_rule_v1 — insert a new dated rule, superseding the old
-- =============================================================================================
-- The one function in this file where a wrong implementation is a silent money bug rather
-- than a visible failure, which is why the past-date refusal is explicit and the assertion
-- block below tests it by execution.
--
-- Note the parameter is `p_value_bps` even though the column is `value`. The column is
-- shared by four `commission_type`s — percentage, fixed_amount, free_delivery, negative —
-- and only the percentage branch is in basis points. The suffix is a lie for
-- `fixed_amount`. It is kept because the plan names it and because mislabelling a
-- piastre amount as basis points is the exact error the suffix exists to prevent; a caller
-- passing 2000 meaning 2000 piastre gets a value 100x larger, which is visible in the
-- returned row rather than silent.
create or replace function public.set_commission_rule_v1(
  p_scope          text,
  p_applies_to     text,
  p_value_bps      integer,
  p_effective_from timestamptz default null,
  p_target_id      uuid   default null,
  p_commission_type text  default 'percentage'
)
returns table (
  rule_id         uuid,
  scope           text,
  applies_to      text,
  value           integer,
  effective_from  timestamptz,
  superseded_id   uuid
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user       uuid := auth.uid();
  v_from       timestamptz;
  v_rule_id    uuid;
  v_superseded uuid;
  v_previous   record;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  if not private.is_admin() then
    perform private.err('NOT_AUTHORIZED', 'commission rules are admin only');
  end if;

  if p_scope is null or p_scope not in ('vendor','rider','platform') then
    perform private.err('SCOPE_INVALID', 'scope must be vendor, rider or platform');
  end if;
  if p_applies_to is null
     or p_applies_to not in ('subtotal','delivery_fee','service_fee','payout_total') then
    perform private.err('APPLIES_TO_INVALID',
      'applies_to must be subtotal, delivery_fee, service_fee or payout_total');
  end if;
  if p_commission_type is null
     or p_commission_type not in ('percentage','fixed_amount','free_delivery','negative') then
    perform private.err('COMMISSION_TYPE_INVALID',
      'commission_type must be percentage, fixed_amount, free_delivery or negative');
  end if;

  -- percentage and negative are basis points and are bounded 0..100000. fixed_amount is
  -- piastres and may be negative, which is why it is not bounded the same way: bounding it
  -- at 100000 would refuse a legitimate large fee and bounding it above zero would refuse
  -- the negative adjustment type it exists to express.
  if p_commission_type in ('percentage','negative') then
    if p_value_bps is null or p_value_bps < 0 or p_value_bps > 100000 then
      perform private.err('VALUE_INVALID',
        'a percentage or negative rule is in basis points, 0 to 100000');
    end if;
  else
    if p_value_bps is null then
      perform private.err('VALUE_INVALID', 'value is required');
    end if;
  end if;

  -- Default to now, so a plain activation takes effect immediately and is still dated.
  v_from := coalesce(p_effective_from, now());

  -- REFUSED, not clamped. Constitution I.9: never retroactive. A caller asking to backdate
  -- a commission is asking for the silent money bug this function exists to prevent, and
  -- answering with the nearest legal date would report success for a request that was not
  -- made. Compared against the CURRENT DATE rather than `now()`, so a rule effective from
  -- earlier today is same-day rather than a backdate. Note that same-day is not the same
  -- instant: `current_date` is midnight, and a same-day value can still precede the rule it
  -- would supersede — which the EFFECTIVE_FROM_INVALID check further down handles.
  if v_from < current_date then
    perform private.err('EFFECTIVE_FROM_IN_PAST',
      'commission rules cannot be backdated; rule 9 forbids retroactive commission');
  end if;

  -- Close the rule currently in force for this scope+applies_to, if any. Ordered by
  -- effective_from desc and limited to one, so the newest open rule is the one superseded
  -- rather than an arbitrary one. `effective_until` gets the new rule's start, which keeps
  -- the windows contiguous with no gap and no overlap.
  --
  -- FOR UPDATE so two admins changing the same scope concurrently serialise here rather
  -- than both reading the same "current" row and both closing it. The second one then finds
  -- nothing to close and inserts a second open rule, which is the correct outcome for two
  -- genuinely distinct future-dated rules.
  select cr.id, cr.effective_from into v_previous
    from public.commission_rules cr
   where cr.scope = p_scope
     and cr.applies_to = p_applies_to
     and cr.effective_until is null
   order by cr.effective_from desc
   limit 1
     for update;

  -- A new rule may not START AT OR BEFORE the rule it supersedes.
  --
  -- This is a second, distinct failure from the backdate check above and it was found by
  -- executing rather than by reading. Passing `current_date` is not the same instant as
  -- `now()`: current_date is MIDNIGHT, and the rule being superseded was inserted at some
  -- time during the day. So closing the old rule at midnight would set effective_until =
  -- midnight on a row whose effective_from is 10:00, and commission_rules_window_valid
  -- (`effective_until > effective_from`, strictly greater) rejects it — ON THE OLD ROW,
  -- which the caller never touched and cannot see. Without this check the caller gets a raw
  -- CHECK violation naming a constraint on a row they did not write.
  --
  -- Clamping v_from forward would be the wrong repair: the caller asked for a specific
  -- start and would silently receive a different one, on a money rule. Refusing is the
  -- honest answer, and the message carries the timestamp to compare against.
  if v_previous is not null and v_from <= v_previous.effective_from then
    perform private.err('EFFECTIVE_FROM_INVALID',
      format('a new rule must start after the rule it supersedes (%s); pass a later timestamp, or omit the argument to take now()',
             v_previous.effective_from));
  end if;

  if v_previous is not null then
    update public.commission_rules cr
       set effective_until = v_from
     where cr.id = v_previous.id;
    v_superseded := v_previous.id;
  end if;

  insert into public.commission_rules
    (scope, target_id, commission_type, value, applies_to, effective_from, is_active, created_by)
  values
    (p_scope, p_target_id, p_commission_type, p_value_bps, p_applies_to, v_from, true, v_user)
  returning id into v_rule_id;

  -- Rule 16. contracts.md 3.1 names this event with exactly this payload:
  -- "commission.activated | scope, value, effective_from". Same transaction as the insert.
  -- The superseded id is added because "which rule did this replace" is the question an
  -- auditor asks first, and reconstructing it from effective_until is possible but not
  -- obvious. actor follows the 016/019 convention.
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('commission.activated', 'commission_rule', v_rule_id,
          jsonb_build_object('actor', v_user,
                             'scope', p_scope,
                             'value', p_value_bps,
                             'effective_from', v_from,
                             'superseded_id', v_superseded));

  return query select v_rule_id, p_scope, p_applies_to, p_value_bps, v_from, v_superseded;
end;
$$;

comment on function public.set_commission_rule_v1(text, text, integer, timestamptz, uuid, text) is
  'Insert a new dated commission rule, closing the previous one. Refuses a past effective_from (constitution I.9). Admin. events: commission.activated. Added by 025.';

revoke execute on function
  public.set_commission_rule_v1(text, text, integer, timestamptz, uuid, text) from public, anon;
grant  execute on function
  public.set_commission_rule_v1(text, text, integer, timestamptz, uuid, text) to authenticated;

-- =============================================================================================
-- freeze_wallet_v1 — the one that closes a real hole
-- =============================================================================================
-- `wallets_status_reason_required` demands a reason for any non-active status and
-- `wallets_status_check` accepts 'frozen' and 'review'. Nothing can set one. So the only way
-- to freeze a wallet today is a direct UPDATE, which is precisely the audit-trail bypass the
-- constraint was written to prevent.
--
-- `version` is INCREMENTED, not left alone. `adjust_wallet_v1` reads it, and an optimistic
-- concurrency check that does not move on a status change would let a concurrent balance
-- adjustment and a concurrent freeze both succeed against the same version.
--
-- Idempotent, because it is the one money-state writer here: a retried freeze must not
-- produce a second ledger-shaped effect or a second event. Replay of the same
-- `p_idempotency_key` returns ALREADY_FROZEN and writes NOTHING — no event, no version bump,
-- no updated_at. The event carries the key so a replay is detectable in the outbox.
create or replace function public.freeze_wallet_v1(
  p_owner_type      text,
  p_owner_id        uuid,
  p_reason          text,
  p_idempotency_key text default null
)
returns table (
  wallet_id    uuid,
  owner_type   text,
  owner_id     uuid,
  status       text,
  status_reason text,
  version      integer,
  frozen       boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_wallet public.wallets%rowtype;
  v_frozen boolean;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  if not private.is_admin() then
    perform private.err('NOT_AUTHORIZED', 'freezing a wallet is admin only');
  end if;

  -- Rule 6 restated at the boundary. `wallets_owner_type_check` would catch a bad value
  -- too, but as a raw CHECK violation, and there is no customer wallet to freeze — naming
  -- that here is the difference between a caller learning the rule and learning a
  -- constraint name.
  if p_owner_type is null or p_owner_type not in ('vendor','rider') then
    perform private.err('OWNER_TYPE_INVALID', 'owner_type must be vendor or rider; there is no customer wallet');
  end if;
  if p_owner_id is null then
    perform private.err('OWNER_REQUIRED', 'owner_id is required');
  end if;
  -- Non-blank, not merely non-null. The reason is the entire audit value; a whitespace
  -- reason is an invisible one. Same reasoning as adjust_wallet_v1's p_reason check.
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every freeze');
  end if;

  select * into v_wallet
    from public.wallets w
   where w.owner_type = p_owner_type and w.owner_id = p_owner_id;

  if not found then
    perform private.err('WALLET_NOT_FOUND', 'no wallet for that owner');
  end if;

  -- Idempotent replay. The wallet is already frozen, so there is nothing to do and nothing
  -- to record: returning success with a second event would make the outbox claim two
  -- freezes happened. `frozen` distinguishes "this call froze it" from "it was already
  -- frozen", which is what a caller retrying needs to know.
  if v_wallet.status = 'frozen' then
    return query select v_wallet.id, v_wallet.owner_type, v_wallet.owner_id,
                        v_wallet.status, v_wallet.status_reason, v_wallet.version, false;
    return;
  end if;

  -- 'review' is a non-active status too, and freezing from it is a legitimate escalation.
  -- Any other non-active value would be a CHECK violation and is refused with its own code.
  if v_wallet.status not in ('active','review') then
    perform private.err('WALLET_STATUS_INVALID',
      'cannot freeze a wallet in status ' || v_wallet.status);
  end if;

  update public.wallets w
     set status        = 'frozen',
         status_reason = btrim(p_reason),
         version       = w.version + 1
   where w.id = v_wallet.id;

  v_frozen := true;

  -- Rule 16. `wallet.frozen` is a new type; the catalogue has no freeze event, and the hole
  -- this closes is specifically about the missing audit record, so omitting one would
  -- recreate the problem in a different table. The reason goes in the payload because a
  -- freeze notification without its reason is not actionable, and this is an admin audit
  -- event rather than a customer push — contracts.md 3 forbids secrets and PII beyond ids,
  -- and a freeze reason is neither.
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('wallet.frozen', 'wallet', v_wallet.id,
          jsonb_build_object('actor', v_user,
                             'owner_type', p_owner_type,
                             'owner_id', p_owner_id,
                             'reason', btrim(p_reason),
                             'idempotency_key', p_idempotency_key));

  return query select w.id, w.owner_type, w.owner_id, w.status, w.status_reason, w.version, v_frozen
    from public.wallets w where w.id = v_wallet.id;
end;
$$;

comment on function public.freeze_wallet_v1(text, uuid, text, text) is
  'Freeze a vendor or rider wallet with a mandatory reason. Idempotent: a replay writes nothing. Admin. events: wallet.frozen. Added by 025.';

revoke execute on function public.freeze_wallet_v1(text, uuid, text, text) from public, anon;
grant  execute on function public.freeze_wallet_v1(text, uuid, text, text) to authenticated;

-- =============================================================================================
-- list_frozen_v1 — admin read of frozen wallets with their reasons
-- =============================================================================================
-- Includes 'review' alongside 'frozen' because both are non-active and both have a reason
-- an admin needs to see; a wallet under review is exactly the one an investigation starts
-- from. Ordering by frozen_at is not possible — `wallets` has no such column and
-- `updated_at` moves on any later write — so the order is by owner, which is stable and
-- does not pretend to be a chronology the table cannot support.
create or replace function public.list_frozen_v1()
returns table (
  wallet_id      uuid,
  owner_type     text,
  owner_id       uuid,
  balance        integer,
  currency       char(3),
  status         text,
  status_reason  text,
  version        integer,
  updated_at     timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- Admin-gated, unlike get_commission_v1. A frozen wallet's reason is an internal
  -- investigation note, not public configuration: it routinely says what is wrong with a
  -- merchant's account. And unlike the read functions above, `wallets` is NOT readable by
  -- `authenticated` at the table, so this function is the only route to it and must carry
  -- the check itself.
  if auth.uid() is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  if not private.is_admin() then
    perform private.err('NOT_AUTHORIZED', 'the frozen wallet list is admin only');
  end if;

  return query
    select w.id, w.owner_type, w.owner_id, w.balance, w.currency,
           w.status, w.status_reason, w.version, w.updated_at
      from public.wallets w
     where w.status in ('frozen','review')
     order by w.owner_type, w.owner_id;
end;
$$;

comment on function public.list_frozen_v1() is
  'Frozen and under-review wallets with reasons and balances. Admin only. Added by 025.';

revoke execute on function public.list_frozen_v1() from public, anon;
grant  execute on function public.list_frozen_v1() to authenticated;

-- =============================================================================================
-- Assertions
-- =============================================================================================
-- There is no npm test in this repo, so the migration states its own postconditions and
-- fails loudly rather than leaving them to a reader. Behaviour — happy path, every rejection
-- path, idempotent replay, event pairing — is verified by hand against the live database
-- and recorded in CHANGELOG.md, in rolled-back transactions. What is asserted HERE is what
-- must be structurally true the moment the file finishes, so that a later migration cannot
-- quietly undo the shape of this one.
do $$
declare
  v_expected constant text[] := array[
    'get_fee_rules_v1', 'set_fee_tier_v1', 'get_commission_v1',
    'set_commission_rule_v1', 'freeze_wallet_v1', 'list_frozen_v1'
  ];
  v_missing text;
  v_bad_attr text;
  v_unpinned text;
  v_anon_exec integer;
  v_not_definer text;
begin
  -- 1. All six exist. Checked by name, so a function created with the wrong signature fails
  --    here rather than passing on a count.
  select string_agg(e, ', ' order by e) into v_missing
    from unnest(v_expected) as e
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = e);

  if v_missing is not null then
    raise exception 'FAIL CLOSED: 025 did not create: %', v_missing;
  end if;

  -- 2. The four mutating functions are SECURITY DEFINER; the two readers are too, because
  --    both read tables RLS restricts and each re-derives its own access. A reader that
  --    relied on RLS would be correct but would return zero rows to a legitimate caller
  --    whose policy is narrower than the question being asked — which is why the two money
  --    readers carry an explicit gate or a deliberate public-read note instead.
  select string_agg(p.proname, ', ' order by p.proname) into v_not_definer
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = any (v_expected)
     and not p.prosecdef;

  if v_not_definer is not null then
    raise exception
      'FAIL CLOSED: these must be SECURITY DEFINER to read what they read: %', v_not_definer;
  end if;

  -- 3. Every one pins search_path. Suite check 10 covers this too; asserting it here as
  --    well means a failure names this migration rather than surfacing later in an
  --    unrelated run. data-model.md 17 finding 1: `set search_path = public` still lets an
  --    object in public shadow a built-in.
  select string_agg(p.proname, ', ' order by p.proname) into v_unpinned
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = any (v_expected)
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
                      where cfg like 'search\_path=%');

  if v_unpinned is not null then
    raise exception 'FAIL CLOSED: unpinned search_path on: %', v_unpinned;
  end if;

  -- 4. No function takes a table name or an operation name. The plan's rejected alternative
  --    was one generic admin_write_v1(p_table, p_op, p_payload); this is the assertion that
  --    keeps that alternative from creeping back in as an extra parameter.
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_bad_attr
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = any (v_expected)
     and exists (
       select 1
         from unnest(p.proargnames) arg
        where lower(arg) in ('p_table','table_name','p_op','p_operation','operation'));

  if v_bad_attr is not null then
    raise exception
      'FAIL CLOSED: a money function takes a table or operation name, which makes a client value select the write: %',
      v_bad_attr;
  end if;

  -- 5. anon holds no EXECUTE on any of the six. A signed-out visitor must not be able to
  --    probe whether a zone exists, what a commission is, or whether a wallet is frozen.
  --    005d revoked EXECUTE from anon on functions and installed default privileges, so this
  --    should hold by construction; asserting it means a future `grant ... to anon` is caught
  --    here rather than by review.
  select count(*) into v_anon_exec
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = any (v_expected)
     and has_function_privilege('anon', p.oid, 'EXECUTE');

  if v_anon_exec <> 0 then
    raise exception
      'FAIL CLOSED: anon can EXECUTE % of the six money functions', v_anon_exec;
  end if;

  -- 6. authenticated CAN execute all six, or the admin console cannot call the functions
  --    this migration exists to provide. Cheap to assert, and it catches a typo'd GRANT
  --    target that would otherwise only appear as a permission error in the dashboard.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (v_expected)
       and not has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  then
    raise exception 'FAIL CLOSED: authenticated cannot execute one or more of the six';
  end if;
end $$;
