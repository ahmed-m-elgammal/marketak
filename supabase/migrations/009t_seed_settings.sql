-- 009t_seed_settings.sql
-- DATA ONLY. No DDL in this file, per data-model.md §15.1 rule 1.
--
-- constitution.md III.7: every money constant is configuration, not code. No fee, multiplier or
-- limit is hardcoded in an app or a function. These rows are where the money constants live, and
-- an admin edits them at runtime through set_setting_v1.
--
-- platform_name and platform_name_ar are rows rather than constants so a rebrand is an UPDATE, not a
-- release. Order numbers read MK-261004-7F3K9.
--
-- rider_max_cash_held_default is the one that matters for correctness here: 008's
-- effective_cash_limit_v1 falls back to this key, and with it absent that function returns 0 - which
-- per data-model.md §8 disables cash collection entirely. A rider limit of zero is safe but wrong,
-- and it fails by looking like a business decision rather than a missing row.
--
-- on conflict (key) do update matches the pattern 002s used, so re-running this file cannot fail on
-- the primary key. settings.key is the primary key, so this is safe.

insert into public.settings (key, value, description) values
  ('platform_name', '"Marketak"'::jsonb, 'English brand. Shown in the app, on the receipt and in order messages'),
  ('platform_name_ar', '"ماركتك"'::jsonb, 'Arabic brand. The default everywhere, because Arabic is the primary market language'),
  ('order_number_prefix', '"MK"'::jsonb, 'Order numbers read MK-261004-7F3K9'),
  ('default_country_code', '"EG"'::jsonb, 'ISO 3166-1 alpha-2'),
  ('currency', '"EGP"'::jsonb, '1 EGP = 100 piastres. Every money column in the schema is integer piastres'),
  ('service_fee_enabled', 'false'::jsonb, 'Activates the customer service fee. Inactive at launch (ADR 3)'),
  ('service_fee_default', '0'::jsonb, 'Amount or basis points, per service_fee_type'),
  ('service_fee_type', '"fixed"'::jsonb, 'fixed or percentage'),
  ('vendor_commission_enabled', 'false'::jsonb, 'Flipped in month 3-4, together with the vendor row in 009s'),
  ('rider_commission_enabled', 'true'::jsonb, 'The launch revenue line: a cut of the delivery fee taken from the rider (ADR 3)'),
  ('max_vendors_per_order', '3'::jsonb, 'Global ceiling. A zone may be lower, never higher'),
  ('rider_max_cash_held_default', '250000'::jsonb, '2,500 EGP. effective_cash_limit_v1 falls back to this; a rider row overrides it. 0 disables cash collection for that rider'),
  ('rider_cash_limit_warning_pct', '80'::jsonb, 'Warn the rider at 80% of the limit')
on conflict (key) do update
  set value = excluded.value,
      description = excluded.description,
      updated_at = now();