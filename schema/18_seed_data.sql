-- =============================================================================
-- 18_seed_data.sql
-- Reference data that must exist before the app is useful. Read from the live
-- database, not authored.
--
-- This is the ONLY file in schema/ that contains INSERTs. Everything else is
-- structure. Note that it is small on purpose: there is no demo data, no test
-- fixtures, and no customer accounts. The live counts at the time of writing
-- were 1 city, 1 area, 1 zone, 2 vendors, 1 rider, 4 users and 1 order — the
-- database is essentially empty of real traffic.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- settings: 14 rows. Every one is read through private.setting_*(), so this
-- table is the single place a behaviour constant can live.
-- -----------------------------------------------------------------------------
insert into public.settings (key, value, description) values
  ('currency', '"EGP"'::jsonb, '1 EGP = 100 piastres. Every money column in the schema is integer piastres'),
  ('default_country_code', '"EG"'::jsonb, 'ISO 3166-1 alpha-2'),
  ('max_vendors_per_order', '3'::jsonb, 'Global ceiling. A zone may be lower, never higher'),
  ('order_number_prefix', '"MK"'::jsonb, 'Order numbers read MK-261004-7F3K9'),
  ('platform_name', '"Marketak"'::jsonb, 'English brand. Shown in the app, on the receipt and in order messages'),
  ('platform_name_ar', '"ماركتك"'::jsonb, 'Arabic brand. The default everywhere, because Arabic is the primary market language'),
  ('rider_cash_limit_warning_pct', '80'::jsonb, 'Warn the rider at 80% of the limit'),
  ('rider_commission_enabled', 'true'::jsonb, 'The launch revenue line: a cut of the delivery fee taken from the rider (ADR 3)'),
  ('rider_max_cash_held_default', '250000'::jsonb, '2,500 EGP. effective_cash_limit_v1 falls back to this; a rider row overrides it. 0 disables cash collection for that rider'),
  ('service_fee_default', '0'::jsonb, 'Amount or basis points, per service_fee_type'),
  ('service_fee_enabled', 'false'::jsonb, 'Activates the customer service fee. Inactive at launch (ADR 3)'),
  ('service_fee_type', '"fixed"'::jsonb, 'fixed or percentage'),
  ('vendor_commission_enabled', 'false'::jsonb, 'Flipped in month 3-4, together with the vendor row in 009s');

-- -----------------------------------------------------------------------------
-- delivery_fee_tiers: 3 rows, one per vendor count, all at 1.00x.
--
-- The launch posture is a FLAT fee: adding a second or third vendor to the
-- basket does not change the delivery price. The multiplier_bps column and the
-- whole tier mechanism exist so this can be changed to a rising schedule
-- without touching a line of code — assert_fee_tiers_monotonic() will refuse a
-- schedule that makes a bigger basket cheaper.
--
-- Ids are environment-specific and omitted here; bind them from your own rows.
-- -----------------------------------------------------------------------------
-- insert into public.delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
-- select id, 1, 10000 from public.delivery_zones where is_active;
-- insert into public.delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
-- select id, 2, 10000 from public.delivery_zones where is_active;
-- insert into public.delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
-- select id, 3, 10000 from public.delivery_zones where is_active;

-- -----------------------------------------------------------------------------
-- commission_rules: 2 rows. This pair IS the revenue model.
--
--   rider / delivery_fee / percentage / 2000 bps / ACTIVE
--       -> the platform takes 20% of the delivery fee. This is the entire
--          launch revenue line. It is taken FROM THE RIDER, not the customer.
--   vendor / subtotal / percentage / 0 bps / INACTIVE
--       -> a zero-commission placeholder, present and ready but off. Turning
--          the vendor commission on is a single UPDATE, which is why
--          vendor_commission_enabled is a setting rather than a code path.
--
-- private.resolve_pay() reads the rider rule when no pay rule matches, and
-- private.compute_quote() reads the vendor rule behind the
-- vendor_commission_enabled setting. Both are READ, never hard-coded.
-- -----------------------------------------------------------------------------
insert into public.commission_rules (scope, applies_to, commission_type, value, is_active)
  values ('rider', 'delivery_fee', 'percentage', 2000, true);

insert into public.commission_rules (scope, applies_to, commission_type, value, is_active)
  values ('vendor', 'subtotal', 'percentage', 0, false);

-- -----------------------------------------------------------------------------
-- notification_templates: 38 rows = 19 keys x 2 languages, all channel 'push'.
--
-- The ar/en split is by ROW, not by column. Adding a language is an insert;
-- changing the Arabic copy never touches the English row. That is why the
-- unique constraint is (key, channel, lang) and not (key, channel).
--
-- The 19 keys, grouped by audience:
--   customer (8)  order.placed, vendor_accepted, vendor_rejected, preparing,
--                 ready, picked_up, arriving, delivered, cancelled
--   vendor   (4)  vendor.new_order, vendor.order_modified,
--                 vendor.order_cancelled, vendor.payout_paid
--   rider    (5)  rider.new_offer, rider.order_assigned,
--                 rider.customer_cancelled, rider.cash_limit_warning,
--                 rider.payout_paid
--   growth   (2)  voucher.available, and one spare
-- -----------------------------------------------------------------------------
insert into public.notification_templates (key, channel, lang, title) values
  ('order.placed',               'push', 'ar', 'تم استلام طلبك'),
  ('order.placed',               'push', 'en', 'Order received'),
  ('order.vendor_accepted',      'push', 'ar', 'تم قبول طلبك'),
  ('order.vendor_accepted',      'push', 'en', 'Vendor accepted'),
  ('order.vendor_rejected',      'push', 'ar', 'تغيّر طلبك'),
  ('order.vendor_rejected',      'push', 'en', 'Your order changed'),
  ('order.preparing',            'push', 'ar', 'طلبك قيد التحضير'),
  ('order.preparing',            'push', 'en', 'Being prepared'),
  ('order.ready',                'push', 'ar', 'طلبك جاهز'),
  ('order.ready',                'push', 'en', 'Order ready'),
  ('order.picked_up',            'push', 'ar', 'انطلق مندوب التوصيل'),
  ('order.picked_up',            'push', 'en', 'Courier on the way'),
  ('order.arriving',             'push', 'ar', 'مندوب التوصيل قريب'),
  ('order.arriving',             'push', 'en', 'Courier is close'),
  ('order.delivered',            'push', 'ar', 'تم التوصيل'),
  ('order.delivered',            'push', 'en', 'Delivered'),
  ('order.cancelled',            'push', 'ar', 'تم إلغاء الطلب'),
  ('order.cancelled',            'push', 'en', 'Order cancelled'),
  ('vendor.new_order',           'push', 'ar', 'طلب جديد'),
  ('vendor.new_order',           'push', 'en', 'New order'),
  ('vendor.order_modified',      'push', 'ar', 'تغيّر في الطلب'),
  ('vendor.order_modified',      'push', 'en', 'Order changed'),
  ('vendor.order_cancelled',     'push', 'ar', 'تم إلغاء طلب'),
  ('vendor.order_cancelled',     'push', 'en', 'Order cancelled'),
  ('vendor.payout_paid',         'push', 'ar', 'تم تحويل مستحقاتك'),
  ('vendor.payout_paid',         'push', 'en', 'Payout sent'),
  ('rider.new_offer',            'push', 'ar', 'طلب قريب منك'),
  ('rider.new_offer',            'push', 'en', 'Order near you'),
  ('rider.order_assigned',       'push', 'ar', 'تم إسناد طلب إليك'),
  ('rider.order_assigned',       'push', 'en', 'Order assigned'),
  ('rider.customer_cancelled',   'push', 'ar', 'سقط طلب'),
  ('rider.customer_cancelled',   'push', 'en', 'Order dropped'),
  ('rider.cash_limit_warning',   'push', 'ar', 'تنبيه حد النقد'),
  ('rider.cash_limit_warning',   'push', 'en', 'Cash limit warning'),
  ('rider.payout_paid',          'push', 'ar', 'تم تحويل مستحقاتك'),
  ('rider.payout_paid',          'push', 'en', 'Payout sent'),
  ('voucher.available',          'push', 'ar', 'عرض متاح'),
  ('voucher.available',          'push', 'en', 'Promotion available');