-- 044: idempotent development seed.
--
-- ## Why this is a migration and not a throwaway script
--
-- Every row below is addressed by a NATURAL KEY (slug, email, code, day_of_week) rather than by a
-- generated uuid, so running this file twice produces no duplicates and no broken relationships.
-- That is a requirement, not a nicety: migrations run in order on a fresh database and again on
-- every developer machine, and a seed that only works once is a seed that silently diverges.
--
-- Every insert is `on conflict ... do update` against a real unique constraint. There is no
-- `do nothing` anywhere, because `do nothing` hides drift instead of repairing it: a category
-- whose name changed would keep its old name forever.
--
-- ## What is created
--
--   1 admin, 3 customers, 3 riders, 3 merchant vendor accounts
--   3 areas in 1 city (so "not served" is testable), 1 active + 1 inactive delivery zone
--   3 vendors x 2-3 categories x 2-3 items, a mix of fixed and sized pricing
--   3 vouchers: valid, expired, and future (not yet started)
--   opening hours for every vendor, all seven days
--   rider pay rules and commission rules so payouts are non-zero
--
-- ## What is deliberately NOT created
--
--   * Orders. Order examples need a session and a live cart, so they are produced by
--     `scripts/seed-orders.sql` through the real RPCs. Seeding order rows directly would put states
--     on the table that no code path can reach, which is worse than no examples.
--   * Stock movements. The platform does not track merchant inventory: `place_order_v1` never
--     decrements `menu_items.stock_count`, which is vendor-declared display data only. An earlier
--     migration added a decrement and it was reverted, so `stock_count` is written once here and
--     then only moves if someone edits the item by hand.
--
-- ## Areas and why there are three
--
-- Exactly one area has an active delivery zone; the other two do not. That makes the
-- NO_DELIVERY_ZONE path reachable from real data rather than from a synthetic fixture: a shopper
-- who picks the wrong area gets a named error at address-entry time, not a failed checkout.
--
-- ## Determinism
--
-- Every uuid is derived from a fixed seed string through `private.seed_uuid`, so the same row keeps
-- the same id across runs and across machines. That is what makes a second run a repair rather
-- than a duplicate. It also means a test can hardcode an id.

-- ---------------------------------------------------------------------------
-- 0. deterministic id helper
-- ---------------------------------------------------------------------------
-- md5 is 32 hex chars, a uuid is exactly 32 hex chars in 8-4-4-4-12 form, so the slices are
-- exact with no slack. Two nibbles are forced to make it a valid version-4 uuid:
--
--   group 3, char 13 -> '4' (version)
--   group 4, char 17 -> '8' (variant, `10xx`)
--
-- That means the output is deliberately NOT the full md5, and it cannot be verified by hashing by
-- hand. Determinism is the requirement; the format is only a side effect of it.
--
-- An earlier version of this function sliced group 4 as `substr(md5, 17, 3)` and group 5 as
-- `substr(md5, 20, 12)`, which is 3 + 12 = 15 characters for a 4 + 12 = 16 slot. One character is
-- lost and every group after it is shifted, so the assembled string is 31 characters and the cast
-- raises `22P02: invalid input syntax for type uuid` - on the FIRST call, with a hash line that
-- looks entirely plausible. The slices below are checked against the 8-4-4-4-12 layout.
create or replace function private.seed_uuid(p_key text)
returns uuid
language sql
immutable
set search_path to ''
as $$
  select (
      substr(md5('marketak-seed:' || p_key),  1,  8) || '-' ||   -- group 1: chars  1- 8
      substr(md5('marketak-seed:' || p_key),  9,  4) || '-' ||   -- group 2: chars  9-12
      '4' || substr(md5('marketak-seed:' || p_key), 14, 3) || '-' ||  -- group 3: version
      '8' || substr(md5('marketak-seed:' || p_key), 18, 3) || '-' ||  -- group 4: variant
      substr(md5('marketak-seed:' || p_key), 21, 12)                  -- group 5: chars 21-32
  )::uuid;
$$;

-- No grant to `authenticated`. `has_schema_privilege('authenticated','private','USAGE')` is false,
-- so such a grant would be unusable anyway - and it would be the wrong direction regardless: a
-- client that can mint a uuid for any string it likes has no business doing so. Tests run as the
-- migration role and call this directly.
revoke all on function private.seed_uuid(text) from public, anon;

-- ---------------------------------------------------------------------------
-- 1. city and areas
-- ---------------------------------------------------------------------------
insert into public.cities (id, code, name, name_ar, country_code, timezone,
                           center_lat, center_lng, currency, is_active, is_primary)
values (private.seed_uuid('city:cairo'), 'CAI', 'Cairo', 'القاهرة', 'EG', 'Africa/Cairo',
        30.0444, 31.2357, 'EGP', true, true)
on conflict (id) do update
  set name = excluded.name, name_ar = excluded.name_ar, is_active = excluded.is_active;

-- Three areas. `served` carries the live delivery zone; the other two exist so the
-- NO_DELIVERY_ZONE branch has real data to fail on.
insert into public.areas (id, city_id, slug, name, name_ar, geohash_prefix,
                          center_lat, center_lng, radius_km, is_active)
values
  (private.seed_uuid('area:maadi'),      private.seed_uuid('city:cairo'), 'maadi',
   'Maadi', 'المعادي', 'stq4', 30.0450, 31.2360, 5.0, true),
  (private.seed_uuid('area:zamalek'),    private.seed_uuid('city:cairo'), 'zamalek',
   'Zamalek', 'الزمالك', 'stq2', 30.0580, 31.2160, 4.0, true),
  (private.seed_uuid('area:unserved'),  private.seed_uuid('city:cairo'), 'unserved-quiet',
   'Unbuilt District', 'حي غير مخدوم', 'stq9', 30.1900, 31.4000, 3.0, true)
on conflict (id) do update
  set name = excluded.name, name_ar = excluded.name_ar, radius_km = excluded.radius_km,
      is_active = excluded.is_active;

-- One live zone on the served area, one inactive zone on the unserved one. The inactive one is
-- what makes `z.is_active` in compute_quote's zone lookup meaningful rather than decorative.
insert into public.delivery_zones (
  id, city_id, area_id, name, name_ar, currency,
  delivery_base_fee, free_radius_km, per_km_fee,
  max_vendors_per_order, min_order_value, max_distance_km, is_active
)
values
  (private.seed_uuid('zone:served'), private.seed_uuid('city:cairo'), private.seed_uuid('area:maadi'),
   'Maadi Zone', 'منطقة المعادي', 'EGP',
   2500, 5.0, 200, 3, 0, 12.0, true),
  (private.seed_uuid('zone:closed'), private.seed_uuid('city:cairo'), private.seed_uuid('area:unserved'),
   'Closed Zone', 'منطقة مغلقة', 'EGP',
   2500, 5.0, 200, 3, 0, 12.0, false)
on conflict (id) do update
  set delivery_base_fee = excluded.delivery_base_fee, per_km_fee = excluded.per_km_fee,
      max_vendors_per_order = excluded.max_vendors_per_order,
      max_distance_km = excluded.max_distance_km, is_active = excluded.is_active;

-- One fee tier per vendor count the cap allows. `compute_quote` looks up
-- `(zone_id, greatest(vendor_count, 1))`, so a missing tier is a hard failure - this is the row
-- that makes a 2-vendor and a 3-vendor order priceable at all.
--
-- The conflict target is spelled out as `(zone_id, vendor_count)` because `delivery_fee_tiers_pkey`
-- is a UNIQUE INDEX, not a named CONSTRAINT - Postgres rejects `on conflict on constraint` here
-- with "ON CONFLICT DO UPDATE requires inference specification or constraint name". Listing the
-- columns works for both shapes and needs no catalog lookup to stay correct.
insert into public.delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
values
  (private.seed_uuid('zone:served'), 1, 10000),
  (private.seed_uuid('zone:served'), 2, 10000),
  (private.seed_uuid('zone:served'), 3, 11000)
on conflict (zone_id, vendor_count) do update
  set multiplier_bps = excluded.multiplier_bps;

-- ---------------------------------------------------------------------------
-- 2. people: 1 admin, 3 customers, 3 riders, 3 merchant accounts
-- ---------------------------------------------------------------------------
-- `auth.users` rows are what `handle_new_user` reacts to, and `public.users` is what every
-- application query reads. Both are written, in that order, so the trigger fires and the
-- `public.users` insert is the trigger's - not a second competing write.
--
-- Emails are deterministic. These are NOT login credentials: Supabase Auth passwords are hashed
-- server-side and cannot be seeded this way, and forcing one would mean disabling the hashing the
-- platform relies on. To sign in as any of these, use Auth "Email" sign-in with a password you set
-- through the dashboard or the Auth admin API, then confirm the row below still matches.

do $$
declare
  v_rec record;
begin
  for v_rec in
    select * from (values
      ('admin@marketak.dev',      'admin'),
      ('customer1@marketak.dev',  'customer'),
      ('customer2@marketak.dev',  'customer'),
      ('customer3@marketak.dev',  'customer'),
      ('rider1@marketak.dev',     'rider'),
      ('rider2@marketak.dev',     'rider'),
      ('rider3@marketak.dev',     'rider'),
      ('merchant1@marketak.dev',  'vendor_staff'),
      ('merchant2@marketak.dev',  'vendor_staff'),
      ('merchant3@marketak.dev',  'vendor_staff')
    ) as t(email, kind)
  loop
    insert into auth.users (id, email, email_confirmed_at, aud, role)
    values (private.seed_uuid('auth:' || v_rec.email), v_rec.email, now(), 'authenticated', 'authenticated')
    on conflict (id) do update set email = excluded.email;
  end loop;
end $$;

-- `handle_new_user` gives every signup the `customer` role. The admin role and the vendor_staff
-- grants below are what make the admin console and the merchant dashboard reachable; a rider gets
-- the `rider` role from `admin_upsert_rider_v1` (migration 042), not from here, because that
-- function is the single writer of rider grants and a second writer would drift from it.
update public.users u
   set first_name = case u.email
                      when 'admin@marketak.dev'     then 'Platform'
                      when 'customer1@marketak.dev' then 'Nour'
                      when 'customer2@marketak.dev' then 'Omar'
                      when 'customer3@marketak.dev' then 'Laila'
                      when 'rider1@marketak.dev'    then 'Karim'
                      when 'rider2@marketak.dev'    then 'Mona'
                      when 'rider3@marketak.dev'    then 'Tarek'
                      when 'merchant1@marketak.dev' then 'Alaa'
                      when 'merchant2@marketak.dev' then 'Hoda'
                      when 'merchant3@marketak.dev' then 'Fady'
                    end,
       last_name = case u.email
                      when 'admin@marketak.dev'     then 'Admin'
                      when 'customer1@marketak.dev' then 'Hassan'
                      when 'customer2@marketak.dev' then 'Khalil'
                      when 'customer3@marketak.dev' then 'Nasser'
                      when 'rider1@marketak.dev'    then 'Sayed'
                      when 'rider2@marketak.dev'    then 'Fathy'
                      when 'rider3@marketak.dev'    then 'Zaki'
                      when 'merchant1@marketak.dev' then 'Fouad'
                      when 'merchant2@marketak.dev' then 'Sabry'
                      when 'merchant3@marketak.dev' then 'Gaber'
                    end,
       country_code = 'EG',
       preferred_language = 'ar',
       -- `phone_number` and `profile_completed_at` are written in the SAME statement, and that is
       -- not stylistic. `users.profile_phone_required` is
       -- `CHECK (profile_completed_at IS NULL OR phone_number IS NOT NULL)`, so completing the
       -- profile first and assigning a phone in a following UPDATE leaves a row that is briefly a
       -- completed profile with no phone - the constraint fires on the FIRST statement and the
       -- whole migration aborts. It is the same invariant `complete_profile_v1` enforces in
       -- migration 016, so the correct response is to satisfy it together, not to split it.
       --
       -- The phone is derived from `row_number() over (order by u.email)`. That lands in a CTE
       -- because Postgres forbids a window function directly in an UPDATE's SET clause
       -- (`42P20: window functions are not allowed in UPDATE`) - the ranking has to be materialised
       -- by a subquery before it can be joined against.
       phone_number = numbered.phone,
       profile_completed_at = coalesce(u.profile_completed_at, now())
  from (
    select u2.id,
           '+2010000' || lpad(row_number() over (order by u2.email)::text, 4, '0') as phone
      from public.users u2
     where u2.email in ('admin@marketak.dev','customer1@marketak.dev','customer2@marketak.dev',
                        'customer3@marketak.dev','rider1@marketak.dev','rider2@marketak.dev',
                        'rider3@marketak.dev','merchant1@marketak.dev','merchant2@marketak.dev',
                        'merchant3@marketak.dev')
       and u2.deleted_at is null
       -- Only seed a phone for accounts that do not already own one in this block. Re-running
       -- would otherwise renumber the survivors and leave orphans behind from the previous run.
        and (u2.phone_number is null or u2.phone_number not like '+2010000%')
  ) numbered
 where u.id = numbered.id
   and u.deleted_at is null;

-- The admin role. `user_roles_pkey` is (user_id, role), so this is a true upsert.
insert into public.user_roles (user_id, role)
select private.seed_uuid('auth:admin@marketak.dev'), 'admin'
on conflict on constraint user_roles_pkey do update set revoked_at = null;

-- ---------------------------------------------------------------------------
-- 3. vendors
-- ---------------------------------------------------------------------------
-- Three merchants, all approved and active so the quote path is reachable, spread across two areas
-- so a cross-area order is possible. `maadi-grill` and `maadi-pizza` share an area, which is what
-- makes a 2-vendor single-delivery order testable; `zamalek-sushi` is elsewhere.
insert into public.vendors (
  id, slug, name, name_ar, vertical_type, city_id, area_id,
  latitude, longitude, geohash_prefix, delivery_radius_km,
  is_open, is_busy, is_approved, is_active,
  prep_time_minutes, prep_time_max_minutes,
  minimum_order_value, description, description_ar
)
values
  (private.seed_uuid('vendor:grill'),  'maadi-grill',   'Maadi Grill',   'مشاوي المعادي',  'food',
   private.seed_uuid('city:cairo'), private.seed_uuid('area:maadi'),
   30.0455, 31.2365, 'stq4', 8, true, false, true, true, 15, 25, 0,
   'Charcoal grill by the canal', 'مشاوي على Canal',
   private.seed_uuid('vendor:pizza'),  'maadi-pizza',   'Maadi Pizza',   'بيتزا المعادي',  'food',
   private.seed_uuid('city:cairo'), private.seed_uuid('area:maadi'),
   30.0440, 31.2380, 'stq4', 8, true, false, true, true, 20, 30, 0,
   'Wood-fired pizza', 'بيتزا على الحطب',
   private.seed_uuid('vendor:sushi'),  'zamalek-sushi', 'Zamalek Sushi', 'سوشي Zamalek',  'food',
   private.seed_uuid('city:cairo'), private.seed_uuid('area:zamalek'),
   30.0585, 31.2165, 'stq2', 6, false, false, true, true, 25, 40, 0,
   'Sushi and bowls', 'سوشي وأطباق',
   private.seed_uuid('vendor:shut'),   'shut-diner',    'Shawarma Street','شاورما الشارع',  'food',
   private.seed_uuid('city:cairo'), private.seed_uuid('area:maadi'),
   30.0430, 31.2340, 'stq4', 8, false, false, false, true, 10, 15, 0,
    'Unapproved shawarma cart', 'عربة شاورما غير معتمدة')
on conflict (id) do update
  set name = excluded.name, name_ar = excluded.name_ar,
      is_open = excluded.is_open, is_approved = excluded.is_approved,
      is_active = excluded.is_active, delivery_radius_km = excluded.delivery_radius_km;
-- `is_approved = false, is_open = false` on shut-diner is the point of the row: it is what makes
-- VENDOR_UNAVAILABLE reachable through a real vendor rather than a synthetic fixture, and it is set
-- inline rather than in a follow-up UPDATE so a single statement describes the whole row.

-- Opening hours: every vendor, all seven days, 09:00-23:00. One day per vendor is closed, so
-- `is_closed` is exercised by data.
--
-- The conflict target is the real unique index, `vendor_schedules (vendor_id, day_of_week, slot)` -
-- NOT `(vendor_id, day_of_week)`. A vendor may legitimately have several slots a day (lunch and
-- dinner), so collapsing to two columns would make this seed wrong the moment a second slot is
-- added, and the insert would fail with 23505 rather than creating it.
-- Opening hours: every vendor, all seven days, 09:00-23:00. One day per vendor is closed, so
-- `is_closed` is exercised by data.
--
-- `slot` is a SMALLINT, not a named string - "all_day" raises `22P02: invalid input syntax for type
-- smallint` on the first row. It is a slot INDEX, so one row per day is slot 1. A vendor that opens
-- twice a day uses slot 2 (lunch) and slot 3 (dinner), which is the whole reason the unique
-- constraint is `(vendor_id, day_of_week, slot)` rather than two columns.
--
-- The conflict target is that real index. Collapsing it to `(vendor_id, day_of_week)` would fail
-- with 23505 the moment a vendor adds a second slot, because the upsert would try to overwrite the
-- lunch row with the dinner row.
--
-- `closes_at > opens_at` is `vendor_schedules_check`, and a closed day leaves both NULL. A CHECK
-- constraint only rejects when its expression evaluates to FALSE; `NULL > NULL` evaluates to
-- NULL, which passes. So a closed day is representable without adding an exception clause.
-- `opens_at` and `closes_at` are both NOT NULL, so a closed day cannot be modelled with NULL times.
-- `is_closed` is the flag that says "ignore this row", and the times are carried as a valid,
-- unused window. Using 00:00-23:59 satisfies `vendor_schedules_check (closes_at > opens_at)`
-- without pretending the shop is open.
--
-- A closed day genuinely inspectable as "opens_at is null" would be a nicer shape, but it would
-- need a schema change and this migration does not need one to be correct.
insert into public.vendor_schedules (vendor_id, day_of_week, slot, opens_at, closes_at, is_closed)
select v.id, d.day_of_week, 1,
       case when d.day_of_week = 4 then '00:00'::time else '09:00'::time end,
       case when d.day_of_week = 4 then '23:59'::time else '23:00'::time end,
       d.day_of_week = 4
  from public.vendors v
 cross join (values (0),(1),(2),(3),(4),(5),(6)) as d(day_of_week)
 where v.slug in ('maadi-grill','maadi-pizza','zamalek-sushi','shut-diner')
on conflict on constraint vendor_schedules_vendor_id_day_of_week_slot_key do update
  set opens_at = excluded.opens_at,
      closes_at = excluded.closes_at, is_closed = excluded.is_closed;

-- Staff links, so `private.vendor_ids_for` resolves a merchant account to its vendor.
insert into public.vendor_staff (id, user_id, vendor_id, staff_role, can_edit_menu, can_manage_orders)
select private.seed_uuid('staff:' || u.email), u.id, v.id, 'owner', true, true
  from public.users u
  join public.vendors v on v.slug = case u.email
      when 'merchant1@marketak.dev' then 'maadi-grill'
      when 'merchant2@marketak.dev' then 'maadi-pizza'
      when 'merchant3@marketak.dev' then 'zamalek-sushi'
    end
 where u.email in ('merchant1@marketak.dev','merchant2@marketak.dev','merchant3@marketak.dev')
on conflict on constraint vendor_staff_user_id_vendor_id_key do update
  set staff_role = excluded.staff_role, can_edit_menu = excluded.can_edit_menu,
      can_manage_orders = excluded.can_manage_orders, deleted_at = null;

-- ---------------------------------------------------------------------------
-- 3b. vendor_areas — the row that makes discovery work
-- ---------------------------------------------------------------------------
-- `get_vendor_feed_v1` and `search_catalog_v1` both filter vendors with
-- `exists (select 1 from public.vendor_areas va where va.vendor_id = … and va.area_id = …)`.
-- Setting `vendors.area_id` is NOT enough: that column is the vendor's home area, while
-- `vendor_areas` is the many-to-many "serves this area" table the discovery RPCs read.
--
-- The first version of this seed wrote only `vendors.area_id`, so `vendor_areas` stayed empty and
-- discovery returned 1 vendor in Maadi and 0 search hits. A mobile agent building the home screen
-- would have concluded the RPCs were broken.
--
-- The rows below are deliberately a superset of each vendor's home area, for two reasons:
--
--   1. `maadi-grill` and `maadi-pizza` serve Maadi, their own area.
--   2. `zamalek-sushi` serves Zamalek (home) AND Maadi.
--
-- Point 2 is what makes the 3-vendor cap testable. `VENDOR_LIMIT_EXCEEDED` needs three vendors
-- reachable from ONE address, and every seeded customer address is in Maadi. Without sushi in
-- Maadi a Maadi shopper could only ever reach two vendors, so the cap could never be hit.
--
-- This is legitimate rather than a fudge: a vendor serving an area beyond its home area is exactly
-- what the many-to-many table is for, and `vendors.area_id` is untouched.
do $$
declare
  v_admin constant uuid := private.seed_uuid('auth:admin@marketak.dev');
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  perform public.admin_upsert_vendor_area_v1(jsonb_build_object('is_active', true),
    private.seed_uuid('vendor:grill'), private.seed_uuid('area:maadi'));
  perform public.admin_upsert_vendor_area_v1(jsonb_build_object('is_active', true),
    private.seed_uuid('vendor:pizza'), private.seed_uuid('area:maadi'));
  perform public.admin_upsert_vendor_area_v1(jsonb_build_object('is_active', true),
    private.seed_uuid('vendor:sushi'), private.seed_uuid('area:zamalek'));
  -- sushi also serves Maadi, so the 3-vendor cap is reachable from a seeded address
  perform public.admin_upsert_vendor_area_v1(jsonb_build_object('is_active', true),
    private.seed_uuid('vendor:sushi'), private.seed_uuid('area:maadi'));

  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- 4. categories and items
-- ---------------------------------------------------------------------------
-- 2-3 categories per vendor, 2-3 items per category. `sync_menu_item_vendor` overwrites
-- `menu_items.vendor_id` from the category on every insert, so the value written here is only a
-- placeholder; the trigger makes it true. That is why a test asserting "item belongs to its
-- category's vendor" is testing the trigger rather than the seed.
insert into public.menu_categories (id, vendor_id, name, name_ar, display_order, is_available)
values
  (private.seed_uuid('cat:grill:mains'),   private.seed_uuid('vendor:grill'), 'Mains',    'الأطباق الرئيسية', 1, true),
  (private.seed_uuid('cat:grill:side'),   private.seed_uuid('vendor:grill'), 'Sides',    'الإضافات الجانبية', 2, true),
  (private.seed_uuid('cat:grill:drinks'),  private.seed_uuid('vendor:grill'), 'Drinks',   'المشروبات',         3, true),
  (private.seed_uuid('cat:pizza:pizza'),   private.seed_uuid('vendor:pizza'), 'Pizza',    'البيتزا',           1, true),
  (private.seed_uuid('cat:pizza:sides'),   private.seed_uuid('vendor:pizza'), 'Sides',    'الإضافات',          2, true),
  (private.seed_uuid('cat:sushi:rolls'),   private.seed_uuid('vendor:sushi'), 'Rolls',    'اللفائف',           1, true),
  (private.seed_uuid('cat:sushi:bowls'),   private.seed_uuid('vendor:sushi'), 'Bowls',    'الأطباق',           2, true),
  (private.seed_uuid('cat:shut:shawarma'), private.seed_uuid('vendor:shut'),  'Shawarma', 'الشاورما',          1, true)
on conflict (id) do update
  set name = excluded.name, name_ar = excluded.name_ar, display_order = excluded.display_order,
      is_available = excluded.is_available;

-- Fixed-priced and sized items both exist, because `upsert_cart_item_v1` has separate branches
-- for them and both must be exercised. `stock_count` is set explicitly so the `OUT_OF_STOCK`
-- rejection is reachable from real data — but it is display data. Nothing decrements it, so a
-- sold-out item has to be sold out by hand, which is what the quote-time check asserts against.
insert into public.menu_items (
  id, category_id, vendor_id, name, name_ar, description, description_ar,
  pricing_mode, base_price, is_available, stock_count, preparation_time_minutes,
  display_order, calories, is_spicy, is_vegetarian, is_featured, is_new
)
values
  -- maadi-grill / mains
  (private.seed_uuid('item:grill:mixed'),  private.seed_uuid('cat:grill:mains'),  private.seed_uuid('vendor:grill'),
   'Mixed Grill', 'مشاوي مشكولة', 'Lamb and chicken skewers with rice', 'مشاوي لحم ودجاج مع أرز',
   'fixed', 18500, true, 40, 20, 1, 750, false, false, true, false),
  (private.seed_uuid('item:grill:kofta'),  private.seed_uuid('cat:grill:mains'),  private.seed_uuid('vendor:grill'),
   'Kofta', 'كفتة', 'Beef kofta with tahini', 'كفتة لحم معطحنة',
   'fixed', 15000, true, 60, 18, 2, 680, false, false, false, false),
  -- maadi-grill / sides
  (private.seed_uuid('item:grill:hummus'), private.seed_uuid('cat:grill:side'),  private.seed_uuid('vendor:grill'),
   'Hummus', 'حمص', 'Classic chickpea dip', 'حمص بالطحينة',
   'fixed', 6000, true, 100, 8, 1, 220, false, true, false, false),
  -- maadi-grill / drinks - sized, so the size branch has coverage
  (private.seed_uuid('item:grill:lemonade'), private.seed_uuid('cat:grill:drinks'), private.seed_uuid('vendor:grill'),
   'Lemonade', 'ليموناضة', 'Fresh lemonade', 'ليموناضة طازجة',
   'sized', null, true, 200, 5, 1, 120, false, true, false, true),
  -- maadi-pizza / pizza
  (private.seed_uuid('item:pizza:margherita'), private.seed_uuid('cat:pizza:pizza'), private.seed_uuid('vendor:pizza'),
   'Margherita', 'مارجريتا', 'Tomato, mozzarella, basil', 'طماطم وموزاريلا وريحان',
   'fixed', 14000, true, 50, 22, 1, 820, false, true, true, false),
  (private.seed_uuid('item:pizza:pepperoni'), private.seed_uuid('cat:pizza:pizza'), private.seed_uuid('vendor:pizza'),
   'Pepperoni', 'بيبروني', 'Spicy pepperoni', 'بيبروني حار',
   'fixed', 16500, true, 50, 22, 2, 950, true, false, false, false),
  -- maadi-pizza / sides
  (private.seed_uuid('item:pizza:garlic'), private.seed_uuid('cat:pizza:sides'), private.seed_uuid('vendor:pizza'),
   'Garlic Bread', 'عيش بالثوم', 'Oven baked', 'مخبوز في الفرن',
   'fixed', 7000, true, 80, 10, 1, 300, false, true, false, false),
  -- zamalek-sushi / rolls
  (private.seed_uuid('item:sushi:california'), private.seed_uuid('cat:sushi:rolls'), private.seed_uuid('vendor:sushi'),
   'California Roll', 'رول كاليفورنيا', 'Crab, avocado, cucumber', 'سلطعون وأفوكادو وخيار',
   'fixed', 21000, true, 30, 25, 1, 320, false, false, true, true),
  -- zamalek-sushi / bowls
  (private.seed_uuid('item:sushi:teriyaki'), private.seed_uuid('cat:sushi:bowls'), private.seed_uuid('vendor:sushi'),
   'Teriyaki Bowl', 'طبق تيرياكي', 'Grilled chicken over rice', 'دجاج مشوي على أرز',
   'fixed', 19000, true, 30, 25, 1, 640, false, false, false, false),
  -- shut-diner: unapproved vendor, so its items must be rejected at quote time
  (private.seed_uuid('item:shut:shawarma'), private.seed_uuid('cat:shut:shawarma'), private.seed_uuid('vendor:shut'),
   'Shawarma', 'شاورما', 'Unapproved vendor item', 'صنف من بائع غير معتمد',
   'fixed', 9000, true, 999, 12, 1, 500, false, false, false, false)
on conflict (id) do update
  set name = excluded.name, name_ar = excluded.name_ar, base_price = excluded.base_price,
      is_available = excluded.is_available, stock_count = excluded.stock_count,
      pricing_mode = excluded.pricing_mode, display_order = excluded.display_order;

-- Sizes for the one sized item. `assert_item_has_sizes` is a DEFERRABLE constraint trigger, so a
-- sized item with no sizes fails at COMMIT, not at insert - which is why 029 validates the size in
-- the RPC instead. `menu_item_sizes` has no stock_count, so sized stock is tracked at item level.
insert into public.menu_item_sizes (id, item_id, name, name_ar, price, is_default, is_available, display_order)
values
  (private.seed_uuid('size:lemonade:s'),  private.seed_uuid('item:grill:lemonade'), 'Small',  'صغير',  4500, true,  true, 1),
  (private.seed_uuid('size:lemonade:m'),  private.seed_uuid('item:grill:lemonade'), 'Medium', 'وسط',   7000, false, true, 2),
  (private.seed_uuid('size:lemonade:l'),  private.seed_uuid('item:grill:lemonade'), 'Large',  'كبير',  9500, false, true, 3)
on conflict (id) do update
  set name = excluded.name, name_ar = excluded.name_ar, price = excluded.price,
      is_default = excluded.is_default, is_available = excluded.is_available;

-- ---------------------------------------------------------------------------
-- 5. riders
-- ---------------------------------------------------------------------------
-- Created through `admin_upsert_rider_v1`, the same function the admin console calls (042). Writing
-- `riders` directly here would bypass the `user_roles` grant that function makes, and the seeded
-- riders would be unable to register a device token or claim an order.
--
-- Two online, one offline: `status` and `is_online` are bound by
-- `riders_is_online_consistent (is_online = (status <> 'offline'))`, so they are set together and
-- never independently. `is_verified = true` on all three, because `claim_order_v1` refuses
-- `RIDER_NOT_ELIGIBLE` otherwise and the order examples need a claim to succeed.
do $$
declare
  v_admin constant uuid := private.seed_uuid('auth:admin@marketak.dev');
  v_rid   uuid;
begin
  -- The admin gate reads `user_roles`, not a JWT claim, so this block impersonates an admin.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  v_rid := public.admin_upsert_rider_v1(jsonb_build_object(
    'email', 'rider1@marketak.dev', 'vehicle_type', 'motorcycle', 'vehicle_plate', 'EG-1-ABC',
    'home_area_id', private.seed_uuid('area:maadi'), 'is_verified', true,
    'max_cash_held', 300000), null);
  v_rid := public.admin_upsert_rider_v1(jsonb_build_object(
    'email', 'rider2@marketak.dev', 'vehicle_type', 'bicycle', 'vehicle_plate', 'EG-2-DEF',
    'home_area_id', private.seed_uuid('area:maadi'), 'is_verified', true,
    'max_cash_held', 150000), null);
  v_rid := public.admin_upsert_rider_v1(jsonb_build_object(
    'email', 'rider3@marketak.dev', 'vehicle_type', 'car', 'vehicle_plate', 'EG-3-GHI',
    'home_area_id', private.seed_uuid('area:zamalek'), 'is_verified', true,
    'max_cash_held', 500000), null);

  perform set_config('request.jwt.claims', '', true);
end $$;

-- `is_online` has no client-writable path anywhere in the database - 042 deliberately omitted a
-- setter - so availability is set here as the database operator, in one statement, with both
-- columns derived from the same CASE so `riders_is_online_consistent` cannot be violated.
--
-- `current_latitude/longitude` and `last_location_at` are set together because
-- `riders_location_has_time` requires all three or none. Coordinates sit inside Maadi and Zamalek
-- respectively, so `get_available_orders_v1` can find them without a location-ping RPC.
update public.riders r
   set status = case r.vehicle_type when 'car' then 'offline' else 'available' end,
       is_online = (case r.vehicle_type when 'car' then 'offline' else 'available' end <> 'offline'),
       current_latitude = case r.vehicle_type
                            when 'car' then 30.0580 else 30.0455 end,
       current_longitude = case r.vehicle_type
                            when 'car' then 31.2165 else 31.2365 end,
       current_geohash = case r.vehicle_type
                           when 'car' then 'stq2' else 'stq4' end,
       last_location_at = now()
 where r.user_id in (private.seed_uuid('auth:rider1@marketak.dev'),
                     private.seed_uuid('auth:rider2@marketak.dev'),
                     private.seed_uuid('auth:rider3@marketak.dev'));

-- ---------------------------------------------------------------------------
-- 6. addresses
-- ---------------------------------------------------------------------------
-- Through `upsert_my_address_v1` (041), so the first-address-becomes-default rule and the
-- server-computed geohash both apply.
--
-- Customer 3 gets NO address here. `upsert_my_address_v1` refuses an area without an active
-- delivery zone with NO_DELIVERY_ZONE, and the unserved area is deliberately without one - that is
-- its entire purpose. Seeding a row there is impossible by construction, which is the correct
-- outcome: a shopper who tries to save an address outside the covered city gets a named error
-- before they ever reach checkout.
--
-- So customer 3's address must be created either by the app once an active zone covers the area,
-- or by an admin activating the zone. It is left uncreated on purpose, and the
-- NO_DELIVERY_ZONE test in `scripts/db-tests.sql` uses it.
do $$
declare
  v_rec record;
begin
  for v_rec in
    select * from (values
      ('customer1@marketak.dev', 'home', 30.0450, 31.2360, private.seed_uuid('area:maadi')),
      ('customer1@marketak.dev', 'work', 30.0470, 31.2390, private.seed_uuid('area:maadi')),
      ('customer2@marketak.dev', 'home', 30.0440, 31.2380, private.seed_uuid('area:maadi')),
      ('customer2@marketak.dev', 'work', 30.0490, 31.2330, private.seed_uuid('area:maadi'))
    ) as t(email, label, lat, lng, area_id)
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', private.seed_uuid('auth:' || v_rec.email)::text,
                        'role', 'authenticated')::text, true);

    if not exists (select 1 from public.addresses a
                    where a.user_id = private.seed_uuid('auth:' || v_rec.email)
                      and a.label = v_rec.label
                      and a.deleted_at is null) then
      perform public.upsert_my_address_v1(jsonb_build_object(
        'label', v_rec.label, 'area_id', v_rec.area_id,
        'latitude', v_rec.lat, 'longitude', v_rec.lng,
        'building', '12', 'floor', '3', 'apartment', '7',
        'delivery_instructions', 'Ring the bell'), null);
    end if;
  end loop;

  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- 7. vouchers
-- ---------------------------------------------------------------------------
-- Three codes covering the three states the app must distinguish. `valid_until > valid_from` is
-- `vouchers_window_valid`, so the expired row's window is internally consistent - it is expired by
-- being in the past, not by being malformed.
insert into public.vouchers (
  id, code, discount_type, discount_value, max_discount_cap, min_order_value,
  usage_limit_total, usage_count, valid_from, valid_until, is_active, first_order_only
)
values
  (private.seed_uuid('voucher:valid'),
   'SAVE10', 'percentage', 1000, 5000, 10000, 1000, 0,
   now() - interval '7 days', now() + interval '30 days', true, false),
  (private.seed_uuid('voucher:expired'),
   'OLD25', 'percentage', 2500, 8000, 10000, 1000, 1000,
   now() - interval '60 days', now() - interval '30 days', true, false),
  (private.seed_uuid('voucher:future'),
   'SOON50', 'fixed_amount', 5000, 5000, 5000, 100, 0,
   now() + interval '10 days', now() + interval '40 days', true, false)
on conflict (code) do update
  set discount_type = excluded.discount_type, discount_value = excluded.discount_value,
      max_discount_cap = excluded.max_discount_cap, min_order_value = excluded.min_order_value,
      valid_from = excluded.valid_from, valid_until = excluded.valid_until,
      is_active = excluded.is_active;

-- ---------------------------------------------------------------------------
-- 8. money configuration
-- ---------------------------------------------------------------------------
-- `rider_pay_rules` was empty, so `resolve_pay` fell back to commission rules and every claim
-- produced `rider_pay_total = 0` - verified in a live loop on 2026-10-09. A rider pay rule makes the
-- payout figures real, which is what the settlement and earnings assertions need.
insert into public.rider_pay_rules (
  id, city_id, per_trip_amount, per_km_amount, pct_of_delivery_fee_bps, bonus_per_leg,
  effective_from, is_active
)
values (
  private.seed_uuid('payrule:cairo'), private.seed_uuid('city:cairo'),
  3000, 150, 2000, 1000, now() - interval '30 days', true
)
on conflict (id) do update
  set per_trip_amount = excluded.per_trip_amount, per_km_amount = excluded.per_km_amount,
      pct_of_delivery_fee_bps = excluded.pct_of_delivery_fee_bps,
      bonus_per_leg = excluded.bonus_per_leg, is_active = excluded.is_active;

-- Vendor commission. `vendor_commission_enabled` is false in settings, so `compute_quote` currently
-- reports zero commission; the rule exists so enabling it is a settings change, not a schema one.
insert into public.commission_rules (id, scope, commission_type, applies_to, value, effective_from, is_active)
values
  (private.seed_uuid('cr:vendor'), 'vendor', 'percentage', 'subtotal', 1500, now() - interval '30 days', true),
  (private.seed_uuid('cr:rider'), 'rider',  'percentage', 'delivery_fee', 2000, now() - interval '30 days', true)
on conflict (id) do update
  set value = excluded.value, is_active = excluded.is_active;

-- ---------------------------------------------------------------------------
-- 9. repeatability assertion
-- ---------------------------------------------------------------------------
-- Runs inside the migration, so a second `supabase db reset` or a second apply proves idempotency
-- rather than leaving it to be discovered. Counts are asserted against the seeded identities, not
-- against totals, because other rows may legitimately exist.
do $$
declare
  v_seed_users  integer;
  v_seed_riders integer;
  v_seed_items  integer;
  v_dupes       integer;
begin
  select count(*) into v_seed_users
    from public.users
   where email like '%@marketak.dev';

  select count(*) into v_dupes from (
    select email from public.users where email like '%@marketak.dev'
     group by email having count(*) > 1) d;

  if v_dupes > 0 then
    raise exception 'SEED NOT IDEMPOTENT: % duplicate seeded emails', v_dupes;
  end if;

  select count(*) into v_seed_riders
    from public.riders
   where user_id in (select private.seed_uuid('auth:' || e) from unnest(array[
       'rider1@marketak.dev','rider2@marketak.dev','rider3@marketak.dev']) e);

  if v_seed_riders <> 3 then
    raise exception 'SEED BROKEN: expected 3 seeded riders, found %', v_seed_riders;
  end if;

  -- One rider row per account. `riders_user_id` is a partial index, not a unique constraint, so
  -- nothing in the schema prevents a duplicate - this is the assertion that does.
  select count(*) into v_dupes from (
    select user_id from public.riders
     where user_id is not null group by user_id having count(*) > 1) d;

  if v_dupes > 0 then
    raise exception 'SEED BROKEN: % users have more than one rider row', v_dupes;
  end if;

  select count(*) into v_seed_items
    from public.menu_items
   where id in (select private.seed_uuid(k) from unnest(array[
       'item:grill:mixed','item:grill:kofta','item:grill:hummus','item:grill:lemonade',
       'item:pizza:margherita','item:pizza:pepperoni','item:pizza:garlic',
       'item:sushi:california','item:sushi:teriyaki','item:shut:shawarma']) k);

  if v_seed_items <> 10 then
    raise exception 'SEED BROKEN: expected 10 seeded items, found %', v_seed_items;
  end if;

  raise notice 'seed ok: % users, % riders, % items, no duplicates',
    v_seed_users, v_seed_riders, v_seed_items;
end $$;
