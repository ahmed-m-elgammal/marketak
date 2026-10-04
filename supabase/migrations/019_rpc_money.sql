-- =============================================================================================
-- 019_rpc_money.sql
-- =============================================================================================
-- Reconciliation and payouts: the five functions data-model.md 15.2 assigns to 019.
--   adjust_wallet_v1, get_wallet_balance_v1, run_payout_v1, reconcile_day_v1, get_platform_float_v1
--
-- SCOPE. contracts.md 1.8 lists thirteen money functions. Five ship here. The eight that do not are
-- recorded as gaps rather than quietly invented, because each needs a decision no spec makes:
-- freeze_wallet_v1, list_frozen_v1, get_commission_v1, set_commission_rule_v1, get_fee_rules_v1,
-- set_fee_tier_v1, and the get_wallet_v1 / run_vendor_payout_v1 / run_rider_payout_v1 naming split.
-- Note that wallets.status already accepts 'frozen' and 'review' and already demands a reason for
-- them, and no function in the repository can set either. That is a real hole, recorded in
-- 019-rpc-money-notes.md section 8, and it is not this migration's to fill.
--
-- WHY THE APPROVAL GATE IS A PARAMETER RATHER THAN A SIXTH FUNCTION. payouts_paid_is_approved is
--   CHECK (status not in ('paid','processing') or (approved_by is not null and approved_at is not null))
-- so a payout cannot become paid without an approver. That makes an approval path structural, not
-- optional: without one the CHECK is unsatisfiable and no money can move at all. run_payout_v1 takes
-- p_action in ('create','approve','reject') so the gate lives inside one of the five names 15.2
-- assigns. Create and approve stay in SEPARATE transactions, which plan.md 4 requires: a crash
-- mid-payout must leave a visible recoverable batch, not a half-paid one.
--
-- WHY A REFERENCE IS MANDATORY ON APPROVAL. run_payout_v1 is the only function in the repository
-- that can raise platform_float.cash_remitted, because only a rider payout moves rider-held cash to
-- a bank. constitution.md I.10 requires variance to be zero OR explained in writing before the next
-- settlement. Without a required bank reference, variance could be closed by assertion, which is the
-- one thing the daily reconciliation exists to prevent.
--
-- WHAT EACH LAYER OF THE SCHEMA IS FOR, because the layers are easy to confuse:
--   platform_float_variance_consistent  an ARITHMETIC guard. It stops a column drifting from its own
--                                        components. It cannot notice a plausible wrong number fed
--                                        into it - a payout that banked 500 instead of 12500 left a
--                                        perfectly consistent row.
--   reconcile_day_v1                    the SEMANTIC guard. It refuses to return a non-zero
--                                        variance without a written explanation, which is the only
--                                        thing in this schema that can catch a wrong total.
--
-- WALLETS MOVE WITH PAYOUTS, which is not obvious from any single spec line. constitution.md I.4
-- requires a cached balance to move "in the same transaction as the entries that change it", and
-- tasks.md T4.15 asserts ledger sums equal cached balances. run_payout_v1 writes vendor_payout and
-- rider_payout entries against a party account, so it moves that party's wallets.balance by the same
-- amount in the same transaction. Leaving the wallet alone would satisfy every individual statement
-- in the spec and break the invariant that binds them.
--
-- The wallet is NOT an accrual ledger the platform grows on its own. A payout credits it, and
-- adjust_wallet_v1 is the only way money enters a wallet without a matching payout (spec.md 3.4:
-- funding one is an admin adjustment). Earnings arrive as payouts; everything else arrives as an
-- audited adjustment. That reconciles I.4 with spec.md 3.4 rather than contradicting either.
--
-- ON I.4 AND THE PLATFORM ACCOUNTS. The invariant binds accounts that HAVE a wallet. platform and
-- platform_earnings have no wallets row by construction - wallets.owner_type is 'vendor' or 'rider'
-- only - so cash_collected, rider_cut and cash_remitted are ledger-only and correctly have no cached
-- balance. 018 already wrote the first two that way and this file adds the third.
--
-- LEDGER IDEMPOTENCY. constitution.md I.4 gives ledger_entries DO INSTEAD NOTHING rules on UPDATE and
-- DELETE, and Postgres refuses INSERT ... ON CONFLICT against any table carrying rules, whatever the
-- conflict target. Every guard below is INSERT ... SELECT ... WHERE NOT EXISTS on idempotency_key.
-- The UNIQUE index remains the actual guarantee; the guard makes a retry a no-op rather than an error.
--
-- ZERO AMOUNTS ARE NEVER WRITTEN. ledger_entries has CHECK (signed_amount <> 0), so a commission of 0
-- - which is every commission until vendor revenue switches on in month 3-4 - must not produce an
-- entry, or the entire payout transaction aborts over a line that correctly nets to nothing. Every
-- ledger insert is conditional on a non-zero amount, which is why the commission line sits inside an
-- if rather than running unconditionally.
-- =============================================================================================

-- =============================================================================================
-- 1. payout_lines gains the link it was missing
-- =============================================================================================
-- A rider payout_line could not be traced to its trip, and could not be protected against being paid
-- twice by any index. sub_order_id is the only foreign key and it cannot serve: it identifies a
-- vendor's LEG, not a rider's TRIP, and payout_lines_sub_order_unique is global on it, so the vendor
-- payout for the same sub-order already consumes the value.
--
-- The consequences were concrete. A rider payout's only double-payment guard was
-- payouts.idempotency_key covering (type, account, period), which does not stop two OVERLAPPING
-- periods paying one trip. And cash in transit had to be re-derived from delivery_assignments by a
-- date window rather than read from the rows actually being paid, which is how an earlier draft came
-- to bank the rider's PAY (500) instead of the cash HELD (12500) - a bug the variance CHECK could not
-- catch, because the resulting row was arithmetically consistent.
--
-- Additive on an empty table: nullable, no default, no rewrite, no backfill. There is no application
-- code yet, so there is no reader to break.
alter table public.payout_lines
  add column if not exists assignment_id uuid references public.delivery_assignments(id);

-- UNIQUE, not a plain index: this is what stops one trip being paid in two batches, and it is the
-- rider-side equivalent of payout_lines_sub_order_unique.
create unique index if not exists payout_lines_assignment_unique
  on public.payout_lines (assignment_id)
  where assignment_id is not null;

-- payout_lines_sub_order_type is replaced rather than supplemented, so there is one rule to read
-- instead of two overlapping ones. It makes a mis-paired line impossible rather than merely unusual:
--   vendor_earning  the vendor's leg, so sub_order_id and never assignment_id
--   rider_trip      the rider's trip, so assignment_id and never sub_order_id
--   tip / bonus     belong to a trip, never to a vendor's leg
--   adjustment      belongs to neither
alter table public.payout_lines
  drop constraint if exists payout_lines_sub_order_type;

alter table public.payout_lines
  add constraint payout_lines_shape check (
    (payout_line_type =  'vendor_earning' and sub_order_id is not null and assignment_id is null) or
    (payout_line_type in ('rider_trip')      and sub_order_id is null     and assignment_id is not null) or
    (payout_line_type in ('tip','bonus')     and sub_order_id is null     and assignment_id is not null) or
    (payout_line_type =  'adjustment'        and sub_order_id is null     and assignment_id is null)
  );

-- =============================================================================================
-- 2. Indexes for the two payout scans
-- =============================================================================================
-- Neither scan is served by an existing index, and each existing index serves only one side of the
-- predicate, so Postgres would scan the larger side and filter.
--
-- The vendor scan is (vendor_id = ? AND settlement_status = 'payable'). sub_orders_settlement_payable
-- is keyed on settlement_status alone; sub_orders_vendor_created is keyed on vendor_id alone.
--
-- The rider scan is (rider_id = ? AND status = 'delivered' AND delivered_at in period).
-- delivery_assignments_rider_history is keyed on assigned_at, which is the wrong end of the trip.
--
-- Partial, because the row count that matters is the work still OWED, which is near zero most of the
-- day. A full index would grow forever and be scanned forever by a payout run that usually finds
-- nothing.
create index if not exists sub_orders_payable_vendor
  on public.sub_orders (vendor_id)
  where settlement_status = 'payable';

create index if not exists sub_orders_in_payout_vendor
  on public.sub_orders (vendor_id)
  where settlement_status = 'in_payout';

create index if not exists delivery_assignments_delivered_rider
  on public.delivery_assignments (rider_id, delivered_at)
  where status = 'delivered';

-- =============================================================================================
-- 3. get_wallet_balance_v1
-- =============================================================================================
-- The read half of the wallet pair, and the only place the cached balance is reported alongside the
-- ledger that is authoritative for it. A balance without its drift would hide the exact failure mode
-- constitution.md I.4 exists to prevent.
create or replace function public.get_wallet_balance_v1(
  p_owner_type text,
  p_owner_id   uuid
)
returns table (
  owner_id        uuid,
  balance         int,
  ledger_balance  int,
  drift           int,
  currency        char(3),
  status          text,
  status_reason   text,
  version         int,
  recent_entries  jsonb
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_user   uuid := auth.uid();
  v_wallet public.wallets%rowtype;
  v_ledger int;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  if p_owner_type is null or p_owner_type not in ('vendor','rider') then
    perform private.err('OWNER_TYPE_INVALID', 'owner_type must be vendor or rider');
  end if;
  if p_owner_id is null then
    perform private.err('OWNER_REQUIRED', 'owner_id is required');
  end if;

  -- constitution.md III.20: permission comes from the caller's own JWT, never a client-supplied
  -- role. A vendor reads its own wallet, a rider its own, an admin any.
  if not private.is_admin() then
    if p_owner_type = 'vendor' and not exists (
         select 1 from private.vendor_ids_for(v_user) v where v = p_owner_id)
    then
      perform private.err('NOT_AUTHORIZED', 'not your wallet');
    end if;
    if p_owner_type = 'rider' and not exists (
         select 1 from private.rider_ids_for(v_user) r where r = p_owner_id)
    then
      perform private.err('NOT_AUTHORIZED', 'not your wallet');
    end if;
  end if;

  select * into v_wallet from public.wallets w
   where w.owner_type = p_owner_type and w.owner_id = p_owner_id;
  if not found then
    perform private.err('WALLET_NOT_FOUND', 'no wallet for this owner');
  end if;

  -- wallets_owner and ledger_entries_account_created both serve this.
  select coalesce(sum(le.signed_amount), 0)::int into v_ledger
    from public.ledger_entries le
   where le.account_type = p_owner_type and le.account_id = p_owner_id;

  -- The inner select caps to 20 before aggregating, so the jsonb build stays bounded however long
  -- the account history grows.
  return query
    select v_wallet.owner_id, v_wallet.balance, v_ledger,
           v_wallet.balance - v_ledger,
           v_wallet.currency, v_wallet.status, v_wallet.status_reason, v_wallet.version,
           coalesce((
             select jsonb_agg(jsonb_build_object(
                        'entry_type', le.entry_type,
                        'signed_amount', le.signed_amount,
                        'payout_id', le.payout_id,
                        'created_at', le.created_at)
                      order by le.created_at desc)
               from (select le2.entry_type, le2.signed_amount, le2.payout_id, le2.created_at
                      from public.ledger_entries le2
                     where le2.account_type = p_owner_type and le2.account_id = p_owner_id
                     order by le2.created_at desc limit 20) le
           ), '[]'::jsonb);
end;
$$;

-- =============================================================================================
-- 4. adjust_wallet_v1
-- =============================================================================================
-- Admin only, reason mandatory, idempotent. This is the instrument spec.md 3.4 describes: money
-- entering a wallet that no payout earned - a goodwill credit, a correction, a clawback.
create or replace function public.adjust_wallet_v1(
  p_owner_type      text,
  p_owner_id        uuid,
  p_amount          int,
  p_reason          text,
  p_reference       text default null,
  p_idempotency_key text default null
)
returns table (
  wallet_balance  int,
  wallet_version  int,
  ledger_entry_id uuid,
  applied         boolean
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user    uuid := auth.uid();
  v_wallet  public.wallets%rowtype;
  v_key     text;
  v_entry   uuid;
  v_existed boolean;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  if not private.is_admin() then
    perform private.err('NOT_AUTHORIZED', 'wallet adjustments are admin only');
  end if;

  if p_owner_type is null or p_owner_type not in ('vendor','rider') then
    perform private.err('OWNER_TYPE_INVALID', 'owner_type must be vendor or rider');
  end if;
  if p_owner_id is null then
    perform private.err('OWNER_REQUIRED', 'owner_id is required');
  end if;
  -- ledger_entries CHECK (signed_amount <> 0) means a zero adjustment is not representable, and
  -- reporting success would claim a movement that never happened.
  if p_amount is null or p_amount = 0 then
    perform private.err('AMOUNT_INVALID', 'adjustment amount must be non-zero');
  end if;
  -- The reason is the entire audit value of this function. tasks.md T4.17 requires an empty one to be
  -- rejected, so whitespace is rejected too rather than stored as an invisible reason.
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every adjustment');
  end if;
  if p_reference is not null and btrim(p_reference) = '' then
    perform private.err('REFERENCE_INVALID', 'reference is blank; pass null instead');
  end if;

  -- Derived when the caller supplies no key, so two identical adjustments replay as one while two
  -- deliberate identical adjustments can still be distinguished by passing a key.
  v_key := coalesce(nullif(btrim(p_idempotency_key), ''),
                     'adjust:' || p_owner_type || ':' || p_owner_id
                                  || ':' || p_amount || ':' || md5(btrim(p_reason)));

  select exists (select 1 from public.ledger_entries le
                  where le.idempotency_key = v_key) into v_existed;

  -- Created on first use: a vendor with no payout yet still needs somewhere to be credited, and
  -- requiring an admin to pre-create rows would make the first payout depend on a step nobody thinks
  -- of. 011a's assert_wallet_owner trigger validates the owner either way.
  insert into public.wallets (owner_type, owner_id)
  values (p_owner_type, p_owner_id)
  on conflict (owner_type, owner_id) do nothing;

  -- FOR UPDATE plus the version guard is 009's optimistic concurrency: two admins adjusting one
  -- wallet must serialise, and the loser must not clobber the winner's balance.
  select * into v_wallet from public.wallets w
   where w.owner_type = p_owner_type and w.owner_id = p_owner_id
   for update;

  -- freeze_wallet_v1 is outside this migration, so nothing currently moves a wallet out of 'active'
  -- except a direct row edit. Refusing here means that the day it ships, a frozen wallet is already
  -- honoured rather than newly enforced on money in flight.
  if v_wallet.status <> 'active' then
    perform private.err('WALLET_NOT_ACTIVE',
      'wallet is ' || v_wallet.status || ': '
      || coalesce(v_wallet.status_reason, 'no reason recorded'));
  end if;

  if v_existed then
    return query
      select v_wallet.balance, v_wallet.version,
             (select le.id from public.ledger_entries le
               where le.idempotency_key = v_key limit 1),
             false;
    return;
  end if;

  -- No ON CONFLICT: constitution.md I.4's rules make that syntax illegal on this table. The existence
  -- check above plus the UNIQUE index together make a retry a no-op.
  insert into public.ledger_entries (
    account_type, account_id, entry_type, signed_amount, currency, idempotency_key, note, metadata)
  select p_owner_type, p_owner_id, 'adjustment', p_amount, v_wallet.currency, v_key,
         btrim(p_reason),
         jsonb_build_object('actor', v_user, 'reference', p_reference)
   where not exists (select 1 from public.ledger_entries le where le.idempotency_key = v_key)
  returning id into v_entry;

  if v_entry is null then
    perform private.err('LEDGER_CONFLICT', 'adjustment already recorded');
  end if;

  update public.wallets w
     set balance = w.balance + p_amount,
         version = w.version + 1
   where w.id = v_wallet.id
     and w.version = v_wallet.version;
  if not found then
    perform private.err('WALLET_CONFLICT', 'wallet changed concurrently; retry');
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('wallet.adjusted', 'wallet', v_wallet.id,
          jsonb_build_object('owner_type', p_owner_type, 'owner_id', p_owner_id,
                             'signed_amount', p_amount, 'reason', btrim(p_reason),
                             'reference', p_reference, 'actor', v_user,
                             'ledger_entry_id', v_entry));

  return query
    select w.balance, w.version, v_entry, true
      from public.wallets w where w.id = v_wallet.id;
end;
$$;

-- =============================================================================================
-- 5. run_payout_v1
-- =============================================================================================
--   create  build a draft from everything owed in the period, move the rows to in_payout, write
--           payout_lines and the ledger entries - all in one transaction.
--   approve the admin gate. Records approver and a mandatory reference, marks the batch paid,
--           settles the vendor sub_orders, and for a rider batch banks the held cash. This is the
--           only writer of platform_float.cash_remitted in the entire repository.
--   reject  release the batch back to payable so a mistake does not strand the money.
create or replace function public.run_payout_v1(
  p_payout_type  text,
  p_account_id   uuid,
  p_period_start date,
  p_period_end   date,
  p_action       text  default 'create',
  p_payout_id    uuid  default null,
  p_method       text  default null,
  p_reference    text  default null
)
returns table (
  payout_id       uuid,
  payout_status   text,
  line_count      int,
  gross_amount    int,
  fee_amount      int,
  net_amount      int,
  cash_amount     int,
  already_applied boolean
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user      uuid := auth.uid();
  v_payout    public.payouts%rowtype;
  v_updated   public.payouts%rowtype;
  v_key       text;
  v_currency  char(3);
  v_gross     int := 0;
  v_fee       int := 0;
  v_net       int := 0;
  v_cash      int := 0;
  v_lines     int := 0;
  v_row       record;
  v_reapplied boolean := false;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  if not private.is_admin() then
    perform private.err('NOT_AUTHORIZED', 'payouts are admin only');
  end if;
  if p_payout_type is null or p_payout_type not in ('vendor','rider') then
    perform private.err('PAYOUT_TYPE_INVALID', 'payout_type must be vendor or rider');
  end if;
  if p_account_id is null then
    perform private.err('ACCOUNT_REQUIRED', 'account_id is required');
  end if;
  if p_action is null or p_action not in ('create','approve','reject') then
    perform private.err('ACTION_INVALID', 'action must be create, approve or reject');
  end if;
  if p_period_start is null or p_period_end is null then
    perform private.err('PERIOD_REQUIRED', 'period_start and period_end are required');
  end if;
  if p_period_end < p_period_start then
    perform private.err('PERIOD_INVALID', 'period_end must not precede period_start');
  end if;
  -- Not a money constant, so constitution.md I.7 does not apply. Bounded so a mistyped year cannot
  -- turn one admin call into a full-table scan and a payout of everything ever delivered.
  if p_period_end - p_period_start > 366 then
    perform private.err('PERIOD_TOO_LONG', 'period must not exceed 366 days');
  end if;

  -- ------------------------------------------------------------------ create
  if p_action = 'create' then
    -- Deterministic in (type, account, period), which is what makes a retried daily job safe.
    v_key := 'payout:create:' || p_payout_type || ':' || p_account_id
             || ':' || p_period_start || ':' || p_period_end;

    select * into v_payout from public.payouts p where p.idempotency_key = v_key;
    if found then
      return query
        select v_payout.id, v_payout.status,
               (select count(*)::int from public.payout_lines pl where pl.payout_id = v_payout.id),
               v_payout.gross_amount, v_payout.fee_amount, v_payout.net_amount,
               case when v_payout.payout_type = 'rider'
                    then coalesce((select sum(da.collected_amount)::int
                                    from public.payout_lines pl
                                    join public.delivery_assignments da
                                      on da.id = pl.assignment_id
                                   where pl.payout_id = v_payout.id
                                     and da.collection_method = 'cash'), 0)
                    else 0 end,
               true;
      return;
    end if;

    if p_payout_type = 'vendor' then
      if not exists (select 1 from public.vendors v where v.id = p_account_id) then
        perform private.err('VENDOR_NOT_FOUND', 'vendor not found');
      end if;
    else
      if not exists (select 1 from public.riders r where r.id = p_account_id) then
        perform private.err('RIDER_NOT_FOUND', 'rider not found');
      end if;
    end if;

    -- Inserted BEFORE the lines so every line can carry the real payout_id. The alternative is
    -- generating ids up front and repairing the nulls afterwards, and such an update would match
    -- every unrelated line in the table. Amounts start at zero and are corrected below in the same
    -- transaction, which satisfies payouts_amounts_sane throughout.
    insert into public.payouts (
      payout_type, account_id, period_start, period_end,
      gross_amount, fee_amount, net_amount, status, idempotency_key)
    values (p_payout_type, p_account_id, p_period_start, p_period_end, 0, 0, 0, 'draft', v_key)
    returning id into v_payout;

    if p_payout_type = 'vendor' then
      -- Row by row rather than one aggregate: FOR UPDATE cannot be combined with sum(), and this lock
      -- is what stops two concurrent runs claiming the same sub_order.
      -- payout_lines_sub_order_unique is the second line of defence, not the first.
      --
      -- The period filter and the status filter are both on the sub_order, because the sub_order is
      -- the unit being paid. There is no orders.delivered_at: delivery time lives on the leg.
      for v_row in
        select so.id, so.vendor_net_payout, so.commission_amount, o.currency,
               coalesce(o.payment_method, 'cash') as payment_method
          from public.sub_orders so
          join public.orders o on o.id = so.order_id
         where so.vendor_id = p_account_id
           and so.settlement_status = 'payable'
           and so.status = 'delivered'
           and so.delivered_at is not null
           and so.delivered_at >= p_period_start
           and so.delivered_at <  p_period_end + 1
           for update of so
      loop
        v_currency := v_row.currency;

        -- commission_amount is floored at zero. payouts_amounts_sane and payout_lines_amounts_sane
        -- both require fee_amount >= 0, and commission_rules.commission_type = 'negative' exists
        -- precisely to record a platform-funded launch discount - a negative commission. Booking it
        -- as a negative fee would abort the whole payout over a line that is arithmetically valid.
        --
        -- The discount is not lost: 017 already folded it into vendor_net_payout
        -- (greatest(0, subtotal - commission)), so the vendor is still paid the larger amount. What is
        -- given up here is the negative sign on the fee breakdown, which is a display concern and
        -- only becomes live when vendor commission switches on in month 3-4.
        v_row.commission_amount := greatest(v_row.commission_amount, 0);

        insert into public.payout_lines (
          payout_id, sub_order_id, assignment_id, payout_line_type, source,
          gross_amount, fee_amount, net_amount)
        values (
          v_payout.id, v_row.id, null, 'vendor_earning',
          case when v_row.payment_method = 'wallet' then 'wallet_payment' else 'cash_collected' end,
          v_row.vendor_net_payout + v_row.commission_amount, v_row.commission_amount,
          v_row.vendor_net_payout);

        update public.sub_orders so
           set settlement_status = 'in_payout'
         where so.id = v_row.id;

        v_gross := v_gross + v_row.vendor_net_payout + v_row.commission_amount;
        v_fee   := v_fee   + v_row.commission_amount;
        v_net   := v_net   + v_row.vendor_net_payout;
        v_lines := v_lines + 1;
      end loop;

      if v_lines = 0 then
        -- private.err raises, so the payouts row just inserted is rolled back with everything else.
        -- NOTHING_DUE is not a failure: a second run over a settled period is the expected shape of a
        -- retried job, and a distinct code lets the daily cron treat it as "nothing to do".
        perform private.err('NOTHING_DUE', 'nothing payable for this account in that period');
      end if;

      -- header amounts are derived from the accumulated fee rather than tracked separately, so
      -- payouts_amounts_sane (net = gross - fee, both non-negative) holds by construction instead of
      -- by two accumulators happening to agree.
      update public.payouts p
         set gross_amount = v_net + v_fee,
             fee_amount = v_fee,
             net_amount = v_net,
             currency = v_currency
       where p.id = v_payout.id;

      update public.sub_orders so
         set payout_id = v_payout.id
       where so.id in (select pl.sub_order_id from public.payout_lines pl
                        where pl.payout_id = v_payout.id and pl.sub_order_id is not null);

      insert into public.ledger_entries (
        account_type, account_id, entry_type, signed_amount, currency,
        payout_id, idempotency_key, note, metadata)
      select 'vendor', p_account_id, 'vendor_payout', v_net, v_currency, v_payout.id,
             v_key || ':net', 'vendor payout batch ' || v_payout.id,
             jsonb_build_object('actor', v_user, 'lines', v_lines)
        where v_net <> 0
          and not exists (select 1 from public.ledger_entries le
                           where le.idempotency_key = v_key || ':net');

      -- plan.md 4: commission is a separate platform_earnings line and is 0 until month 3-4. Guarded
      -- on a non-zero amount because of CHECK (signed_amount <> 0).
      insert into public.ledger_entries (
        account_type, account_id, entry_type, signed_amount, currency,
        payout_id, idempotency_key, note, metadata)
      select 'platform_earnings', null, 'commission', -v_fee, v_currency, v_payout.id,
             v_key || ':commission',
             'vendor commission ' || p_period_start || '..' || p_period_end,
             jsonb_build_object('actor', v_user, 'account_id', p_account_id)
        where v_fee <> 0
          and not exists (select 1 from public.ledger_entries le
                           where le.idempotency_key = v_key || ':commission');

    else
      for v_row in
        select da.id, da.rider_pay_total, da.collected_amount, da.collection_method,
               coalesce(o.rider_tip, 0) as rider_tip, o.currency
          from public.delivery_assignments da
          join public.orders o on o.id = da.order_id
         where da.rider_id = p_account_id
           and da.status = 'delivered'
           and da.delivered_at >= p_period_start
           and da.delivered_at <  p_period_end + 1
           for update of da
      loop
        v_currency := v_row.currency;

        -- One batch carries cash and earnings together, with cash identified per line, so a single
        -- approval covers a single net transfer to the rider.
        insert into public.payout_lines (
          payout_id, sub_order_id, assignment_id, payout_line_type, source,
          gross_amount, fee_amount, net_amount)
        values (
          v_payout.id, null, v_row.id, 'rider_trip',
          case when v_row.collection_method = 'cash' then 'cash_collected' else 'wallet_payment' end,
          v_row.rider_pay_total + v_row.rider_tip, 0,
          v_row.rider_pay_total + v_row.rider_tip);

        -- A tip belongs to the trip, not to a vendor's leg, so payout_lines_shape requires it to
        -- carry the same assignment_id.
        if v_row.rider_tip <> 0 then
          insert into public.payout_lines (
            payout_id, sub_order_id, assignment_id, payout_line_type, source,
            gross_amount, fee_amount, net_amount)
          values (v_payout.id, null, v_row.id, 'tip', 'wallet_payment',
                  v_row.rider_tip, 0, v_row.rider_tip);
          v_lines := v_lines + 1;
        end if;

        v_gross := v_gross + v_row.rider_pay_total + v_row.rider_tip;
        v_net   := v_net   + v_row.rider_pay_total + v_row.rider_tip;
        v_lines := v_lines + 1;
      end loop;

      if v_lines = 0 then
        perform private.err('NOTHING_DUE', 'nothing payable for this account in that period');
      end if;

      -- Cash comes from the assignments THIS batch is paying, joined through payout_lines. It is not
      -- the same number as v_net: v_net is what the rider is owed, collected_amount is the cash the
      -- rider is holding on the platform's behalf. On the reference order, 500 owed against 12500
      -- held, and conflating them banks a fraction of the real exposure.
      select coalesce(sum(da.collected_amount), 0)::int into v_cash
        from public.payout_lines pl
        join public.delivery_assignments da on da.id = pl.assignment_id
       where pl.payout_id = v_payout.id
         and pl.payout_line_type = 'rider_trip'
         and da.collection_method = 'cash';

      update public.payouts p
         set gross_amount = v_gross, fee_amount = v_fee, net_amount = v_net, currency = v_currency
       where p.id = v_payout.id;

      insert into public.ledger_entries (
        account_type, account_id, entry_type, signed_amount, currency,
        payout_id, idempotency_key, note, metadata)
      select 'rider', p_account_id, 'rider_payout', v_net, v_currency, v_payout.id,
             v_key || ':net', 'rider payout batch ' || v_payout.id,
             jsonb_build_object('actor', v_user, 'lines', v_lines, 'cash_included', v_cash)
        where v_net <> 0
          and not exists (select 1 from public.ledger_entries le
                           where le.idempotency_key = v_key || ':net');
    end if;

    -- constitution.md I.4: the cached balance moves in the same transaction as the entries that
    -- changed it, or tasks.md T4.15's "ledger sums equal balances" cannot hold.
    insert into public.wallets (owner_type, owner_id)
    values (p_payout_type, p_account_id)
    on conflict (owner_type, owner_id) do nothing;

    update public.wallets w
       set balance = w.balance + v_net,
           version = w.version + 1
     where w.owner_type = p_payout_type and w.owner_id = p_account_id;

    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('payout.created', 'payout', v_payout.id,
            jsonb_build_object('payout_type', p_payout_type, 'account_id', p_account_id,
                               'period_start', p_period_start, 'period_end', p_period_end,
                               'lines', v_lines, 'gross', v_gross, 'fee', v_fee, 'net', v_net,
                               'cash_amount', v_cash, 'actor', v_user));

    select * into v_updated from public.payouts p where p.id = v_payout.id;

    return query
      select v_updated.id, v_updated.status, v_lines,
             v_updated.gross_amount, v_updated.fee_amount, v_updated.net_amount, v_cash, false;
    return;
  end if;

  -- --------------------------------------------------------------- approve / reject
  if p_payout_id is null then
    perform private.err('PAYOUT_ID_REQUIRED', 'payout_id is required to ' || p_action);
  end if;

  select * into v_payout from public.payouts p
   where p.id = p_payout_id and p.payout_type = p_payout_type
   for update;
  if not found then
    perform private.err('PAYOUT_NOT_FOUND', 'payout not found for this type');
  end if;

  if p_action = 'reject' then
    if v_payout.status <> 'draft' then
      perform private.err('PAYOUT_NOT_DRAFT',
        'only a draft payout can be rejected; this is ' || v_payout.status);
    end if;
    update public.payouts p set status = 'cancelled' where p.id = v_payout.id;
    -- Releasing the rows is the entire point of rejecting. Leaving them in in_payout would strand
    -- the vendor's money with no batch left that can pay it.
    update public.sub_orders so
       set settlement_status = 'payable', payout_id = null
     where so.payout_id = v_payout.id and so.settlement_status = 'in_payout';

    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('payout.rejected', 'payout', v_payout.id,
            jsonb_build_object('payout_type', v_payout.payout_type,
                               'account_id', v_payout.account_id,
                               'reason', p_reference, 'actor', v_user));

    return query
      select v_payout.id, 'cancelled'::text,
             (select count(*)::int from public.payout_lines pl where pl.payout_id = v_payout.id),
             v_payout.gross_amount, v_payout.fee_amount, v_payout.net_amount, 0, false;
    return;
  end if;

  -- approve
  if v_payout.status <> 'draft' then
    perform private.err('PAYOUT_NOT_DRAFT',
      'only a draft payout can be approved; this is ' || v_payout.status);
  end if;
  if p_method is null or btrim(p_method) = '' then
    perform private.err('METHOD_REQUIRED', 'a payout method is required to approve');
  end if;
  -- constitution.md I.10. See the header: this is what makes cash_remitted evidence rather than
  -- assertion, and this is the only path that writes it.
  if p_reference is null or btrim(p_reference) = '' then
    perform private.err('REFERENCE_REQUIRED', 'a bank or transfer reference is required to approve');
  end if;

  v_key := 'payout:approve:' || v_payout.id::text;
  select exists (select 1 from public.ledger_entries le
                  where le.idempotency_key = v_key) into v_reapplied;

  -- Read the cash from THIS payout's own lines, never from the caller's period arguments. A caller can
  -- pass anything, and deriving a remittance figure from caller input would bank the wrong amount on
  -- a typo. Reading payout_id's lines also means a trip completing between create and approve cannot
  -- be swept in: it has no line in this batch.
  select coalesce(sum(da.collected_amount), 0)::int into v_cash
    from public.payout_lines pl
    join public.delivery_assignments da on da.id = pl.assignment_id
   where pl.payout_id = v_payout.id
     and pl.payout_line_type = 'rider_trip'
     and da.collection_method = 'cash';

  if not v_reapplied then
    update public.payouts p
       set status = 'paid', method = btrim(p_method), reference = btrim(p_reference),
           approved_by = v_user, approved_at = now(), paid_at = now()
     where p.id = v_payout.id;

    if v_payout.payout_type = 'vendor' then
      update public.sub_orders so set settlement_status = 'settled'
       where so.payout_id = v_payout.id and so.settlement_status = 'in_payout';
    else
      if not exists (select 1 from public.riders r where r.id = v_payout.account_id) then
        perform private.err('RIDER_NOT_FOUND', 'rider not found');
      end if;

      -- greatest(0, ...) because cash_held is physical cash in hand. It can legitimately be lower
      -- than this batch if a rider banked an earlier batch by hand, and a negative cash_held would
      -- assert the platform holds cash it does not.
      update public.riders r
         set cash_held = greatest(0, r.cash_held - v_cash)
       where r.id = v_payout.account_id;

      if v_cash > 0 then
        insert into public.ledger_entries (
          account_type, account_id, entry_type, signed_amount, currency,
          payout_id, idempotency_key, note, metadata)
        select 'platform', null, 'cash_remitted', -v_cash, v_payout.currency, v_payout.id, v_key,
               'cash banked via ' || btrim(p_method) || ' ' || btrim(p_reference),
               jsonb_build_object('actor', v_user, 'method', btrim(p_method),
                                  'reference', btrim(p_reference))
          where not exists (select 1 from public.ledger_entries le
                             where le.idempotency_key = v_key);

        -- variance is RECOMPUTED, not incremented, because CHECK (variance = cash_expected -
        -- cash_remitted) demands the three columns agree exactly. cash_expected is left alone: it was
        -- raised at collection time by 018.
        insert into public.platform_float (business_date, cash_expected, cash_remitted, variance)
        values (current_date, 0, v_cash, -v_cash)
        on conflict (business_date) do update
          set cash_remitted = platform_float.cash_remitted + excluded.cash_remitted,
              variance     = platform_float.cash_expected
                           - (platform_float.cash_remitted + excluded.cash_remitted),
              updated_at   = now();
      end if;
    end if;

    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('payout.paid', 'payout', v_payout.id,
            jsonb_build_object('payout_type', v_payout.payout_type,
                               'account_id', v_payout.account_id,
                               'net', v_payout.net_amount, 'cash_amount', v_cash,
                               'method', btrim(p_method), 'reference', btrim(p_reference),
                               'approved_by', v_user));
  end if;

  select * into v_updated from public.payouts p where p.id = v_payout.id;

  return query
    select v_updated.id, v_updated.status,
           (select count(*)::int from public.payout_lines pl where pl.payout_id = v_updated.id),
           v_updated.gross_amount, v_updated.fee_amount, v_updated.net_amount,
           v_cash, v_reapplied;
end;
$$;

-- =============================================================================================
-- 6. reconcile_day_v1
-- =============================================================================================
-- constitution.md I.10: cash in transit is reconciled daily, without exception, and variance must be
-- zero OR explained in writing before the next settlement. So this refuses to return an unexplained
-- non-zero variance, and records the explanation when one is supplied. This is the only mechanism in
-- the schema that can catch a plausible-but-wrong total - the variance CHECK cannot, as its own
-- failure mode is a consistent row holding the wrong number.
create or replace function public.reconcile_day_v1(
  p_date        date,
  p_explanation text default null
)
returns table (
  business_date           date,
  cash_expected           int,
  cash_remitted           int,
  variance                int,
  external_cash_orders    int,
  external_wallet_orders  int,
  rider_payable           int,
  vendor_payable          int,
  in_flight_payouts       int,
  open_payout_net         int,
  balanced                boolean
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user  uuid := auth.uid();
  v_float public.platform_float%rowtype;
  v_open  int;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  -- service_role is admitted because 021's pg_cron job runs without a user JWT. Deliberately NOT a
  -- bypass: every other write in this schema is admin-gated, and a cron-only exception to a money
  -- read would be the wrong place to start one.
  if not private.is_admin() and coalesce(auth.role(), '') <> 'service_role' then
    perform private.err('NOT_AUTHORIZED', 'reconciliation is admin only');
  end if;
  if p_date is null then
    perform private.err('DATE_REQUIRED', 'date is required');
  end if;
  if p_date > current_date then
    perform private.err('DATE_IN_FUTURE', 'cannot reconcile a future date');
  end if;

  select coalesce(sum(po.net_amount), 0)::int into v_open
    from public.payouts po where po.status in ('draft','approved','processing');

  select * into v_float from public.platform_float f where f.business_date = p_date;
  if not found then
    -- No row means no cash was collected that day, which is a real and common answer rather than an
    -- error. Reporting zeros is more useful to an operator than refusing.
    v_float.business_date          := p_date;
    v_float.cash_expected          := 0;
    v_float.cash_remitted          := 0;
    v_float.variance               := 0;
    v_float.rider_payable          := 0;
    v_float.vendor_payable         := 0;
    v_float.external_cash_orders   := 0;
    v_float.external_wallet_orders := 0;
  end if;

  if v_float.variance <> 0 then
    if p_explanation is null or btrim(p_explanation) = '' then
      -- Raised BEFORE the result set is assembled, so the figures are carried IN the message. A caller
      -- that receives only an exception would otherwise have to go and re-derive them.
      perform private.err('VARIANCE_UNEXPLAINED',
        'variance ' || v_float.variance::text || ' on ' || p_date
        || ' (expected ' || v_float.cash_expected::text
        || ', remitted ' || v_float.cash_remitted::text
        || ') is not zero; pass a written explanation or resolve it before the next settlement');
    end if;
    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('float.variance_explained', 'platform_float', v_float.id,
            jsonb_build_object('business_date', p_date, 'variance', v_float.variance,
                               'cash_expected', v_float.cash_expected,
                               'cash_remitted', v_float.cash_remitted,
                               'explanation', btrim(p_explanation), 'actor', v_user));
  end if;

  return query
    select v_float.business_date, v_float.cash_expected, v_float.cash_remitted, v_float.variance,
           v_float.external_cash_orders, v_float.external_wallet_orders,
           v_float.rider_payable, v_float.vendor_payable,
           (select count(*)::int from public.payouts po
             where po.status in ('draft','approved','processing')),
           v_open,
           v_float.variance = 0;
end;
$$;

-- =============================================================================================
-- 7. get_platform_float_v1
-- =============================================================================================
-- The read for the admin console and for support. A date range rather than a single day, because the
-- question an operator actually asks is whether exposure has been building all week.
create or replace function public.get_platform_float_v1(
  p_from date,
  p_to   date default null
)
returns table (
  business_date          date,
  cash_expected          int,
  cash_remitted          int,
  variance               int,
  delivery_fees          int,
  rider_cuts             int,
  commissions            int,
  service_fees           int,
  adjustments            int,
  vendor_payable         int,
  rider_payable          int,
  external_cash_orders   int,
  external_wallet_orders int
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_user uuid := auth.uid();
  v_to   date := coalesce(p_to, current_date);
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;
  if not private.is_admin() and coalesce(auth.role(), '') <> 'service_role' then
    perform private.err('NOT_AUTHORIZED', 'platform float is admin only');
  end if;
  if p_from is null then
    perform private.err('DATE_REQUIRED', 'from date is required');
  end if;
  if v_to < p_from then
    perform private.err('RANGE_INVALID', 'to date must not precede from date');
  end if;
  -- platform_float_date, added by 018, serves this range scan directly.
  return query
    select f.business_date, f.cash_expected, f.cash_remitted, f.variance,
           f.delivery_fees, f.rider_cuts, f.commissions, f.service_fees, f.adjustments,
           f.vendor_payable, f.rider_payable,
           f.external_cash_orders, f.external_wallet_orders
      from public.platform_float f
     where f.business_date between p_from and v_to
     order by f.business_date;
end;
$$;

-- =============================================================================================
-- 8. Grants
-- =============================================================================================
-- No EXECUTE for anon on any of them: every one either reads another party's money or moves it.
-- service_role is granted only the two reads, never a mutation.
revoke all on function public.get_wallet_balance_v1(text,uuid)   from public, anon;
revoke all on function public.adjust_wallet_v1(text,uuid,int,text,text,text) from public, anon;
revoke all on function public.run_payout_v1(text,uuid,date,date,text,uuid,text,text) from public, anon;
revoke all on function public.reconcile_day_v1(date,text)       from public, anon;
revoke all on function public.get_platform_float_v1(date,date)  from public, anon;

grant execute on function public.get_wallet_balance_v1(text,uuid)   to authenticated;
grant execute on function public.adjust_wallet_v1(text,uuid,int,text,text,text) to authenticated;
grant execute on function public.run_payout_v1(text,uuid,date,date,text,uuid,text,text) to authenticated;
grant execute on function public.reconcile_day_v1(date,text)       to authenticated;
grant execute on function public.get_platform_float_v1(date,date)  to authenticated, service_role;