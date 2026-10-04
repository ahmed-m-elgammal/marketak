-- 005b's assert_fee_tiers_monotonic referenced new.delivery_zone_id. The column is actually
-- named zone_id, and PL/pgSQL resolves record fields at RUNTIME, so the function and its
-- constraint trigger were created successfully and would only have failed on first use.
-- This is the third time this exact trap has appeared in this repo (005a was the first).
create or replace function public.assert_fee_tiers_monotonic()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_zone uuid;
begin
  v_zone := coalesce(new.zone_id, old.zone_id);

  if exists (
    select 1 from public.delivery_fee_tiers a
    join public.delivery_fee_tiers b on b.zone_id = a.zone_id
    where a.zone_id = v_zone
      and a.vendor_count < b.vendor_count
      and a.multiplier_bps > b.multiplier_bps
  ) then
    raise exception
      'FEE_TIER_NOT_MONOTONIC: zone % has a lower vendor_count with a higher multiplier_bps', v_zone
      using errcode = 'P0001';
  end if;
  return null;
end $$;