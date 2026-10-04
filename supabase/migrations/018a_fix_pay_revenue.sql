-- =============================================================================================
-- 018a_fix_pay_revenue.sql
-- =============================================================================================
-- A money bug found by running 018, not by reading it. Demonstrated, not theorised.
--
-- WHAT 018 GOT WRONG. private.resolve_pay has two branches: one when a rider pay rule matched,
-- and one when none did. The matching branch computed platform revenue as a commission ON the
-- delivery fee:
--
--   round(p_delivery_fee::numeric * cr.value / 10000)
--
-- and the no-rule branch returned cr.value itself, unscaled:
--
--   coalesce((select cr.value from commission_rules ...), 0)
--
-- cr.value is BASIS POINTS. Returning it as an amount books 2000 rather than 550 on a 2750 fee
-- (2750 * 2000 / 10000 = 550) - platform revenue overstated by a factor of fee/10000.
--
-- WHY IT SURVIVED THE FIRST PASS. Every claim test in 018 seeded a rider_pay_rule, because a
-- rider with no pay rule is the misconfiguration this branch exists to report. The no-rule path
-- was exercised only by a rider id that could not exist, and in that run I asserted has_rule =
-- false and pay = 0 without asserting the revenue figure. A test that checks two of three
-- outputs of the branch under test is the hole, not the code.
--
-- WHY IT MATTERS MORE THAN A TYPO - IT WAS THE DEFAULT PATH, NOT AN EDGE CASE. The seed ships a
-- live commission rule (scope=rider, applies_to=delivery_fee, 2000 bps) but ships NO
-- rider_pay_rules rows at all: rider pay is per-rider configuration that an admin adds later.
-- So on this project the no-rule branch was the only branch any rider could reach, and every
-- rider was booked at 2000 revenue while being paid 0 - overstated by a factor of fee/10000,
-- which is 3.6x on a 2750 fee. It is not a rare misconfiguration path. It was the behaviour of
-- every delivery the platform could have processed.
--
-- THE FIX. Scale by the fee in both branches, exactly as constitution 9 requires: launch revenue
-- is a cut of the delivery fee taken from the rider. rider_pay_rules pays the rider;
-- commission_rules books the revenue line. Each table for its own concern.
--
-- Also drops the `coalesce(null::int, 0)` that 018 wrote for the first column. coalesce over a
-- literal null is a roundabout way of writing 0.
--
-- 018 IS NOT EDITED. It is already applied and committed, so this is a forward migration, in the
-- same spirit as 005a, 007a, 010a and 014a. Replaying 018 then this file on a fresh database
-- produces byte-identical function bodies to the live project, which 018 alone did not.
-- =============================================================================================

create or replace function private.resolve_pay(
  p_rider_id     uuid,
  p_city_id      uuid,
  p_delivery_fee int,
  p_leg_km       numeric,
  p_legs         int
)
returns table (
  rider_pay_base     int,
  rider_pay_distance int,
  rider_pay_bonus    int,
  rider_pay_total    int,
  platform_revenue   int,
  has_rule           boolean
)
language plpgsql
stable
set search_path to ''
as $$
declare
  v_rule public.rider_pay_rules;
  v_hit  boolean := false;
begin
  v_rule := private.pay_rule_for(p_rider_id, p_city_id);
  -- `found` refers to the LAST statement executed inside pay_rule_for, not to whether the
  -- function returned a row, so the NULL test is the only trustworthy signal that no rule
  -- matched. 018 already corrected this; repeated here so the branch stays coherent.
  v_hit := (v_rule.id is not null);

  -- One commission expression, two branches. Previously this was duplicated and the copies
  -- disagreed, which is how the no-rule copy came to return raw basis points.
  if not v_hit then
    -- No pay rule is an admin-visible misconfiguration, not a reason to refuse a delivery that
    -- is already under way: the rider earns zero and has_rule = false, so it surfaces in
    -- reporting. Revenue is still booked - the platform earned its cut of the fee whether or not
    -- a rule exists to pay the rider from it.
    return query
      select 0, 0, 0, 0,
             coalesce((select round(p_delivery_fee::numeric * cr.value / 10000)::int
                        from public.commission_rules cr
                       where cr.scope = 'rider' and cr.applies_to = 'delivery_fee'
                         and cr.is_active and cr.effective_from <= now()
                         and (cr.effective_until is null or cr.effective_until > now())
                       order by cr.effective_from desc limit 1), 0),
             false;
    return;
  end if;

  return query
    select coalesce(v_rule.per_trip_amount, 0),
           round(coalesce(v_rule.per_km_amount, 0) * coalesce(p_leg_km, 0))::int,
           coalesce(v_rule.bonus_per_leg, 0) * greatest(coalesce(p_legs, 1), 1),
           coalesce(v_rule.per_trip_amount, 0)
             + round(coalesce(v_rule.per_km_amount, 0) * coalesce(p_leg_km, 0))::int
             + coalesce(v_rule.bonus_per_leg, 0) * greatest(coalesce(p_legs, 1), 1),
           coalesce((select round(p_delivery_fee::numeric * cr.value / 10000)::int
                       from public.commission_rules cr
                      where cr.scope = 'rider' and cr.applies_to = 'delivery_fee'
                        and cr.is_active and cr.effective_from <= now()
                        and (cr.effective_until is null or cr.effective_until > now())
                      order by cr.effective_from desc limit 1), 0),
           true;
end;
$$;

revoke all on function private.resolve_pay(uuid,uuid,int,numeric,int) from public, anon, authenticated;