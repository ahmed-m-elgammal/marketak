-- =============================================================================================
-- 019b_fix_paid_event_actor.sql
-- =============================================================================================
-- payout.paid was the only 019 event without an 'actor' key in its payload, so a consumer could not
-- attribute the approval without special-casing that one event type.
--
-- 018 established the convention: the actor goes in payload, because events has no actor_user_id
-- column. The outbox dispatcher and the admin audit view both read payload->>'actor'. 019 followed it
-- for payout.created, wallet.adjusted and payout.rejected, then used 'approved_by' for payout.paid
-- instead. Both keys now carry the same value: the approver IS the actor of the state change, and
-- 'approved_by' is kept because it is the domain word for it.
--
-- Caught by an assertion written as "every 019 event row carries an actor", which is the kind of
-- assertion that only exists if someone decided a convention and then checked it. A per-event-type
-- check would have passed while leaving the inconsistency in place.
-- =============================================================================================

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
  if p_period_end - p_period_start > 366 then
    perform private.err('PERIOD_TOO_LONG', 'period must not exceed 366 days');
  end if;

  if p_action = 'create' then
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

    insert into public.payouts (
      payout_type, account_id, period_start, period_end,
      gross_amount, fee_amount, net_amount, status, idempotency_key)
    values (p_payout_type, p_account_id, p_period_start, p_period_end, 0, 0, 0, 'draft', v_key)
    returning id into v_payout;

    if p_payout_type = 'vendor' then
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
        perform private.err('NOTHING_DUE', 'nothing payable for this account in that period');
      end if;

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

        insert into public.payout_lines (
          payout_id, sub_order_id, assignment_id, payout_line_type, source,
          gross_amount, fee_amount, net_amount)
        values (
          v_payout.id, null, v_row.id, 'rider_trip',
          case when v_row.collection_method = 'cash' then 'cash_collected' else 'wallet_payment' end,
          v_row.rider_pay_total + v_row.rider_tip, 0,
          v_row.rider_pay_total + v_row.rider_tip);

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

  if v_payout.status <> 'draft' then
    perform private.err('PAYOUT_NOT_DRAFT',
      'only a draft payout can be approved; this is ' || v_payout.status);
  end if;
  if p_method is null or btrim(p_method) = '' then
    perform private.err('METHOD_REQUIRED', 'a payout method is required to approve');
  end if;
  if p_reference is null or btrim(p_reference) = '' then
    perform private.err('REFERENCE_REQUIRED', 'a bank or transfer reference is required to approve');
  end if;

  v_key := 'payout:approve:' || v_payout.id::text;
  select exists (select 1 from public.ledger_entries le
                  where le.idempotency_key = v_key) into v_reapplied;

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
                               'approved_by', v_user,
                               'actor', v_user));
  end if;

  select * into v_updated from public.payouts p where p.id = v_payout.id;

  return query
    select v_updated.id, v_updated.status,
           (select count(*)::int from public.payout_lines pl where pl.payout_id = v_updated.id),
           v_updated.gross_amount, v_updated.fee_amount, v_updated.net_amount,
           v_cash, v_reapplied;
end;
$$;

revoke all on function public.run_payout_v1(text,uuid,date,date,text,uuid,text,text) from public, anon;
grant execute on function public.run_payout_v1(text,uuid,date,date,text,uuid,text,text) to authenticated;