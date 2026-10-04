-- 002s_seed_fee_tiers.sql
-- DATA ONLY. No DDL in this file, per data-model.md 15.1 rule 1: mixing DDL and DML makes a
-- migration un-rollable and holds a transaction open.
--
-- These are starting values, not policy. An admin edits them per zone at runtime through
-- set_fee_tier_v1. The 1/2/3-vendor split exists because one rider making three stops is
-- worth more than one rider making one, and the customer is shown the difference (ADR 4).

insert into delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
select z.id, v.vendor_count, v.multiplier_bps
from delivery_zones z
cross join (values (1, 10000), (2, 11000), (3, 12000)) as v(vendor_count, multiplier_bps)
where z.is_active
on conflict (zone_id, vendor_count) do update
  set multiplier_bps = excluded.multiplier_bps,
      updated_at = now();
