-- 019c: make reconcile_day_v1 idempotent, and seal the day's explanation.
--
-- Found by the 001-020 integrity suite, batch 7
-- (specs/001-platform-foundation/001-020-integrity-notes.md section 8).
--
-- THE DEFECT
-- reconcile_day_v1:880 inserted a float.variance_explained event unconditionally
-- whenever variance <> 0 and an explanation was supplied, with nothing to key it
-- on: events has no idempotency column and platform_float has no seal column.
-- Three identical calls produced three events.
--
-- That matters more than a duplicate row usually would. constitution I.10 makes
-- that event the ONLY written record that a variance was explained in writing,
-- and 021's pg_cron job is meant to run this daily - so a retry after a dropped
-- connection silently doubles the audit trail, and an auditor can no longer tell
-- a retry from two separate genuine explanations.
--
-- WHY THE SEAL, NOT A UNIQUE INDEX ON events
-- Decided on the arithmetic in free-tier-plan.md, not on taste.
--
--   * platform_float is `business_date date not null unique`, so it holds exactly
--     ONE ROW PER DAY. Three columns therefore cost roughly 55 KB/year and, more
--     importantly, do not move with order volume at all. free-tier-plan section 2
--     states that only one number matters - bytes per order - and this addition
--     leaves it untouched.
--   * The alternative puts a FOURTH index on events, which free-tier-plan 3.7
--     singles out as the one table whose 7-day window its partitioning instinct
--     cannot express (60% of the ceiling if monthly-partitioned, 45 MB pruned by
--     DELETE), already carrying three indexes at 7 rows/order. That section's own
--     operational rule is that every table above needs an index on its prune
--     column and un-indexed prune queries are themselves a load problem. This is
--     the one table in the schema where adding an index is not free.
--   * Doing both would pay for the index and hold two sources of truth for one
--     fact.
--
-- The seal is also the more honest model: "explained in writing before the next
-- settlement" is a property of the day, not an emergent property of an index.
--
-- THE THREE CASES, because variance is not final when the cron runs
-- collect_cash_v1, collect_wallet_v1 and complete_delivery_v1 all do
-- `on conflict (business_date) do update`, so a late collection MOVES a day's
-- variance after it was explained. A strict one-shot seal would make such a day
-- impossible to explain, which is a dead end rather than a safeguard. Hence
-- variance_explained_amount, and:
--
--   same amount, same explanation  -> no-op, returns normally (the retry case)
--   same amount, other explanation -> VARIANCE_ALREADY_EXPLAINED, the first
--                                      record stands
--   different amount               -> re-seals, because the variance moved and a
--                                      fresh explanation is legitimate
--
-- variance_explained_amount is what makes the first two distinguishable. Without
-- it the three cases collapse into one and either retries duplicate the event or
-- genuine late variances can never be explained.
--
-- get_platform_float_v1 is deliberately NOT changed: it returns a fixed
-- `returns table` column list, and adding output columns would break its
-- signature for every caller. The new columns are readable by an admin directly.
-- No table or column is dropped, and no row is rewritten: both new columns are
-- nullable and the table is currently empty.

alter table public.platform_float
  add column if not exists variance_explained_at     timestamptz,
  add column if not exists variance_explained_amount integer,
  add column if not exists variance_explanation      text;

comment on column public.platform_float.variance_explained_at is
  'When this day''s variance was explained in writing. Null until reconcile_day_v1 sealed it. constitution I.10.';
comment on column public.platform_float.variance_explained_amount is
  'The variance figure the explanation was written against. A later collection moves the variance; when it differs from this, the day may be explained again.';
comment on column public.platform_float.variance_explanation is
  'The written explanation. First one stands for a given variance amount; a different explanation for the same amount is refused.';

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

    -- 019c: the day's explanation is sealed, so a pg_cron retry cannot double the
    -- audit trail. Three cases, distinguished by variance_explained_amount - see
    -- the header for why a strict one-shot seal would be wrong.
    if v_float.variance_explained_at is not null
       and v_float.variance_explained_amount = v_float.variance then
      if v_float.variance_explanation is distinct from btrim(p_explanation) then
        perform private.err('VARIANCE_ALREADY_EXPLAINED',
          'variance ' || v_float.variance::text || ' on ' || p_date
          || ' is already explained as "' || v_float.variance_explanation
          || '"; that record stands. Re-run with the same text to be a no-op, or'
          || ' wait for the variance to change');
      end if;
      -- Same amount and same text: an idempotent retry. Fall through and report.
    else
      update public.platform_float f
         set variance_explained_at     = now(),
             variance_explained_amount = v_float.variance,
             variance_explanation      = btrim(p_explanation)
       where f.business_date = p_date;

      insert into public.events (type, aggregate_type, aggregate_id, payload)
      values ('float.variance_explained', 'platform_float', v_float.id,
              jsonb_build_object('business_date', p_date, 'variance', v_float.variance,
                                 'cash_expected', v_float.cash_expected,
                                 'cash_remitted', v_float.cash_remitted,
                                 'explanation', btrim(p_explanation), 'actor', v_user));
    end if;
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
