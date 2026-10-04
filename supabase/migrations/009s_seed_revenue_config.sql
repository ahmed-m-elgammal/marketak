-- 009s_seed_revenue_config.sql
-- DATA ONLY. No DDL in this file, per data-model.md §15.1 rule 1: mixing DDL and DML makes a
-- migration un-rollable and holds a transaction open.
--
-- The revenue line is data, not schema. constitution.md III.9 and ADR 3: the platform's launch
-- revenue is a cut of the delivery fee taken from the rider; vendor commission on items and the
-- customer service fee exist as rows and are switched on later, by an UPDATE and never by a
-- migration.
--
-- These two rows are the whole revenue model at launch. The rider rule is ACTIVE and is how the
-- platform earns anything in month one. The vendor rule is present but INACTIVE, and that is the
-- point: month 3-4 flips is_active, and nothing else changes.
--
-- 2000 basis points = 20%, per constitution.md III.3. data-model.md §7 shows this seed as the
-- literal 20 against a numeric(12,4) column, which the constitution forbids; 009 changed the column
-- to integer basis points, so the same intent is 2000 here.
--
-- on conflict is not available on commission_rules - it has no natural unique key beyond its uuid,
-- and inventing one to make the seed idempotent would be a schema decision. These are insert-once
-- rows and the migration runner applies each file exactly once.

-- Launch: the platform takes its revenue from the delivery fee, charged to the rider. The rider
-- keeps pct_of_delivery_fee_bps from rider_pay_rules; the remainder is platform revenue.
insert into public.commission_rules (scope, commission_type, value, applies_to, is_active)
values ('rider', 'percentage', 2000, 'delivery_fee', true);

-- Month 3-4: commission on the items, charged to the vendor. Inactive until then.
insert into public.commission_rules (scope, commission_type, value, applies_to, is_active)
values ('vendor', 'percentage', 0, 'subtotal', false);