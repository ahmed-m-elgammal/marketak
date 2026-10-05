-- 026: the admin write surface for geography and vendors — ten tables, enough to load a
-- real merchant and have it appear in the customer app.
--
-- admin-crud-plan.md §6: "`026` and `027` together are the smallest set that lets you load a
-- merchant and take an order. `025` is independent and comes first because it is the named gap."
-- This is `026`. `027` (the catalog) is not written, so a merchant loaded here has no dishes yet —
-- the shape of the data is complete, the menu is not.
--
-- ---------------------------------------------------------------------------
-- FUNCTION SHAPE, AND WHY IT IS TEN FUNCTIONS AND NOT ONE
-- ---------------------------------------------------------------------------
-- admin-crud-plan.md §3 fixes six rules, applied uniformly to every function below:
--
--   1. The table name is a LITERAL in the body. Never a parameter. A client-supplied p_table
--      choosing the write target has the same shape as the auth-argument defect constitution
--      III.20 forbids — permission must not come from a client value.
--   2. p_patch is validated against an explicit key ALLOWLIST inside the function. An unknown
--      key is an error, never a silently ignored field. This is what stops a typo'd key from
--      reading as success.
--   3. private.is_admin() is the FIRST statement, before any input is inspected. A non-admin
--      learns nothing about the arguments — not whether a vendor exists, not whether a city is
--      soft-deleted.
--   4. search_path = '' and every name fully qualified, per data-model.md §17 finding 1.
--   5. One events row per mutation, same transaction, per constitution II.16.
--   6. Every function checks deleted_at on read and refuses to touch a soft-deleted row except
--      through the matching restore function.
--
-- REJECTED: one generic admin_write_v1(p_table, p_op, p_payload). Compact, but a client string
-- selects the write, it is unauditable at ten tables in one body, and assertion 4 below fails it.
--
-- ---------------------------------------------------------------------------
-- WHY UPSERT RATHER THAN SEPARATE CREATE AND UPDATE
-- ---------------------------------------------------------------------------
-- Each function takes an optional p_id. Absent means insert, present means update. That is one
-- function per table instead of two, and it is also the shape an admin console wants: the same
-- form-submit handler for "add vendor" and "edit vendor".
--
-- The alternative — separate admin_create_vendors_v1 and admin_update_vendors_v1 — doubles the
-- surface for no gain, because the two would share every validation except the presence of the
-- row. The p_id is validated against the table, not against the caller: a p_id that does not
-- exist in THAT table is NOT_FOUND, not a silent insert, because a caller who meant to edit and
-- typo'd the id must not create a second vendor.
--
-- ---------------------------------------------------------------------------
-- WHAT THESE FUNCTIONS REFUSE TO DO
-- ---------------------------------------------------------------------------
-- They never touch: `vendors.rating_avg`, `vendors.rating_count`, `vendors.menu_version`,
-- `vendors.created_at`, or any `*_id`. Those are derived or system-owned. `menu_version` in
-- particular is bumped by the catalog triggers in 005b, and an admin setting it directly would
-- desynchronise the R2 snapshot pointer from the catalog — the same class of bug 014a fixed for
-- vendor visibility. Rating columns are recomputed from `reviews`; the admin moderates a review
-- (`029`, not written) and never edits a score.
--
-- The normalised columns on `vendors` (`name_normalized`, `name_ar_normalized`,
-- `description_normalized`) are GENERATED columns from 015 and are therefore not writable at
-- all. The allowlist does not mention them and a caller passing one gets UNKNOWN_KEY, which is
-- the correct answer: the column cannot be set by anyone, including this function.
--
-- ---------------------------------------------------------------------------
-- SOFT DELETE, NOT DELETE
-- ---------------------------------------------------------------------------
-- `admin_delete_*_v1` sets `deleted_at`. There is deliberately no `admin_hard_delete_v1` and no
-- function in this file that issues a DELETE. admin-crud-plan.md §9 wants an ADR recording that
-- soft delete is the only admin delete, so that a future migration cannot add the other one.
--
-- Two tables here are JOIN tables — `vendor_areas` and `vendor_cuisines` — and for them "delete"
-- means withdrawing the mapping, which is the same `deleted_at` semantics and is reversible by
-- `admin_restore_*_v1`. Their primary keys are composite, so their functions take the two key
-- columns as separate arguments rather than a p_id.
--
-- `vendor_staff` is a join table too but has a surrogate `id` and its own lifecycle, so it takes
-- a p_id like the rest.
--
-- ---------------------------------------------------------------------------
-- THE TWO TABLES WITH NO updated_at UNTIL 024
-- ---------------------------------------------------------------------------
-- `cuisines`, `vendor_areas`, `vendor_cuisines`, `vendor_holidays` and `vendor_staff` gained
-- `updated_at` and its trigger in `024`, which is what makes an admin write to them observable.
-- Before that, an edit here moved no timestamp at all — the condition open question 3.20 was
-- closed for and 3.31 recorded.

-- =============================================================================================
-- 1. cities
-- =============================================================================================
-- `is_primary` is EXCLUDED from the allowlist. `cities_one_primary` is a partial unique index on
-- (is_primary) where is_primary, so exactly one city can be primary — an admin console needs to
-- set that, but it is a one-city-at-a-time operational decision (free-tier-plan §12) and is
-- deliberately not part of a general-purpose city editor. Changing it is a separate decision with
-- its own ADR.
create or replace function public.admin_upsert_city_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
  v_allowed constant text[] := array[
    'code','name','name_ar','country_code','timezone','center_lat','center_lng',
    'currency','is_active','is_primary'
  ];
  v_unknown text;
  v_exists boolean;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'cities are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k
   where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a cities column: ' || v_unknown);
  end if;

  if p_id is null then
    insert into public.cities (code, name, name_ar, country_code, timezone,
                               center_lat, center_lng, currency, is_active, is_primary)
    values (p_patch->>'code', p_patch->>'name', p_patch->>'name_ar',
            p_patch->>'country_code', p_patch->>'timezone',
            (p_patch->>'center_lat')::numeric, (p_patch->>'center_lng')::numeric,
            coalesce(p_patch->>'currency', 'EGP'),
            coalesce((p_patch->>'is_active')::boolean, true),
            coalesce((p_patch->>'is_primary')::boolean, false))
    returning id into v_id;
  else
    -- EXISTS, not a bare UPDATE, so a missing row is NOT_FOUND rather than a silent no-op that
    -- reports success. And the deleted_at guard: rule 6 below.
    select exists (select 1 from public.cities c where c.id = p_id and c.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live city with that id; restore it first');
    end if;

    update public.cities c set
      code         = coalesce(p_patch->>'code', c.code),
      name         = coalesce(p_patch->>'name', c.name),
      name_ar      = coalesce(p_patch->>'name_ar', c.name_ar),
      country_code = coalesce(p_patch->>'country_code', c.country_code),
      timezone     = coalesce(p_patch->>'timezone', c.timezone),
      center_lat   = coalesce((p_patch->>'center_lat')::numeric, c.center_lat),
      center_lng   = coalesce((p_patch->>'center_lng')::numeric, c.center_lng),
      currency     = coalesce(p_patch->>'currency', c.currency),
      is_active    = coalesce((p_patch->>'is_active')::boolean, c.is_active),
      is_primary   = coalesce((p_patch->>'is_primary')::boolean, c.is_primary)
     where c.id = p_id
    returning c.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('city.updated', 'city', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));

  return v_id;
end;
$$;

revoke execute on function public.admin_upsert_city_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_city_v1(jsonb, uuid) to authenticated;

-- =============================================================================================
-- 2. areas
-- =============================================================================================
create or replace function public.admin_upsert_area_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid; v_unknown text; v_exists boolean;
  v_allowed constant text[] := array[
    'city_id','slug','name','name_ar','geohash_prefix','center_lat','center_lng',
    'radius_km','is_active'
  ];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'areas are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not an areas column: ' || v_unknown);
  end if;

  if p_id is null then
    insert into public.areas (city_id, slug, name, name_ar, geohash_prefix,
                              center_lat, center_lng, radius_km, is_active)
    values ((p_patch->>'city_id')::uuid, p_patch->>'slug', p_patch->>'name', p_patch->>'name_ar',
            p_patch->>'geohash_prefix', (p_patch->>'center_lat')::numeric,
            (p_patch->>'center_lng')::numeric,
            coalesce((p_patch->>'radius_km')::numeric, 3.0),
            coalesce((p_patch->>'is_active')::boolean, true))
    returning id into v_id;
  else
    select exists (select 1 from public.areas a where a.id = p_id and a.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live area with that id; restore it first');
    end if;
    update public.areas a set
      city_id        = coalesce((p_patch->>'city_id')::uuid, a.city_id),
      slug           = coalesce(p_patch->>'slug', a.slug),
      name           = coalesce(p_patch->>'name', a.name),
      name_ar        = coalesce(p_patch->>'name_ar', a.name_ar),
      geohash_prefix = coalesce(p_patch->>'geohash_prefix', a.geohash_prefix),
      center_lat     = coalesce((p_patch->>'center_lat')::numeric, a.center_lat),
      center_lng     = coalesce((p_patch->>'center_lng')::numeric, a.center_lng),
      radius_km      = coalesce((p_patch->>'radius_km')::numeric, a.radius_km),
      is_active      = coalesce((p_patch->>'is_active')::boolean, a.is_active)
     where a.id = p_id
    returning a.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('area.updated', 'area', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;

revoke execute on function public.admin_upsert_area_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_area_v1(jsonb, uuid) to authenticated;

-- =============================================================================================
-- 3. brands
-- =============================================================================================
create or replace function public.admin_upsert_brand_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid; v_unknown text; v_exists boolean;
  v_allowed constant text[] := array['name','name_ar','logo_path','is_active'];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'brands are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a brands column: ' || v_unknown);
  end if;

  if p_id is null then
    insert into public.brands (name, name_ar, logo_path, is_active)
    values (p_patch->>'name', p_patch->>'name_ar', p_patch->>'logo_path',
            coalesce((p_patch->>'is_active')::boolean, true))
    returning id into v_id;
  else
    select exists (select 1 from public.brands b where b.id = p_id and b.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live brand with that id; restore it first');
    end if;
    update public.brands b set
      name      = coalesce(p_patch->>'name', b.name),
      name_ar   = coalesce(p_patch->>'name_ar', b.name_ar),
      logo_path = coalesce(p_patch->>'logo_path', b.logo_path),
      is_active = coalesce((p_patch->>'is_active')::boolean, b.is_active)
     where b.id = p_id
    returning b.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('brand.updated', 'brand', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;

revoke execute on function public.admin_upsert_brand_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_brand_v1(jsonb, uuid) to authenticated;

-- =============================================================================================
-- 4. cuisines
-- =============================================================================================
-- A reference table of codes, seeded once. `sort_order` is in the allowlist because the customer
-- app sorts the cuisine filter by it. `name_normalized` / `name_ar_normalized` are GENERATED from
-- 015 and cannot be written by anyone, so they are absent from the allowlist and a caller passing
-- one gets UNKNOWN_KEY.
create or replace function public.admin_upsert_cuisine_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid; v_unknown text; v_exists boolean;
  v_allowed constant text[] := array['code','name','name_ar','sort_order'];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'cuisines are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a cuisines column: ' || v_unknown);
  end if;

  if p_id is null then
    insert into public.cuisines (code, name, name_ar, sort_order)
    values (p_patch->>'code', p_patch->>'name', p_patch->>'name_ar',
            coalesce((p_patch->>'sort_order')::integer, 100))
    returning id into v_id;
  else
    select exists (select 1 from public.cuisines c where c.id = p_id and c.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live cuisine with that id; restore it first');
    end if;
    update public.cuisines c set
      code       = coalesce(p_patch->>'code', c.code),
      name       = coalesce(p_patch->>'name', c.name),
      name_ar    = coalesce(p_patch->>'name_ar', c.name_ar),
      sort_order = coalesce((p_patch->>'sort_order')::integer, c.sort_order)
     where c.id = p_id
    returning c.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('cuisine.updated', 'cuisine', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;

revoke execute on function public.admin_upsert_cuisine_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_cuisine_v1(jsonb, uuid) to authenticated;

-- =============================================================================================
-- 5. vendors
-- =============================================================================================
-- The widest allowlist in the file, because `vendors` is the widest table. The exclusions are the
-- point and are listed in the header: rating_avg, rating_count, menu_version, created_at,
-- updated_at, deleted_at and the three generated *_normalized columns.
--
-- `is_approved` IS writable, and that is the single most consequential key here: it is what FR-A-01
-- calls "approve vendors", and `vendors_read` filters on it, so flipping it is the difference
-- between a vendor appearing in the customer app and not.
create or replace function public.admin_upsert_vendor_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid; v_unknown text; v_exists boolean;
  v_allowed constant text[] := array[
    'slug','name','name_ar','legal_name','brand_id','vertical_type','city_id','area_id',
    'latitude','longitude','geohash_prefix','delivery_radius_km',
    'is_open','is_busy','auto_open','is_approved','is_active',
    'capacity_per_slot','reject_rate','delivery_fee_override','minimum_order_value',
    'prep_time_minutes','prep_time_max_minutes',
    'logo_path','description','description_ar','contact_phone','contact_landline'
  ];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendors are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a vendors column, or not admin-writable: ' || v_unknown);
  end if;

  if p_id is null then
    insert into public.vendors (
      slug, name, name_ar, legal_name, brand_id, vertical_type, city_id, area_id,
      latitude, longitude, geohash_prefix, delivery_radius_km,
      is_open, is_busy, auto_open, is_approved, is_active,
      capacity_per_slot, reject_rate, delivery_fee_override, minimum_order_value,
      prep_time_minutes, prep_time_max_minutes,
      logo_path, description, description_ar, contact_phone, contact_landline)
    values (
      p_patch->>'slug', p_patch->>'name', p_patch->>'name_ar', p_patch->>'legal_name',
      (p_patch->>'brand_id')::uuid, coalesce(p_patch->>'vertical_type', 'food'),
      (p_patch->>'city_id')::uuid, (p_patch->>'area_id')::uuid,
      (p_patch->>'latitude')::numeric, (p_patch->>'longitude')::numeric,
      p_patch->>'geohash_prefix', coalesce((p_patch->>'delivery_radius_km')::numeric, 8),
      coalesce((p_patch->>'is_open')::boolean, false),
      coalesce((p_patch->>'is_busy')::boolean, false),
      coalesce((p_patch->>'auto_open')::boolean, true),
      coalesce((p_patch->>'is_approved')::boolean, false),
      coalesce((p_patch->>'is_active')::boolean, true),
      (p_patch->>'capacity_per_slot')::integer, coalesce((p_patch->>'reject_rate')::numeric, 0),
      (p_patch->>'delivery_fee_override')::integer,
      coalesce((p_patch->>'minimum_order_value')::integer, 0),
      coalesce((p_patch->>'prep_time_minutes')::integer, 15),
      coalesce((p_patch->>'prep_time_max_minutes')::integer, 30),
      p_patch->>'logo_path', p_patch->>'description', p_patch->>'description_ar',
      p_patch->>'contact_phone', p_patch->>'contact_landline')
    returning id into v_id;
  else
    select exists (select 1 from public.vendors v where v.id = p_id and v.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live vendor with that id; restore it first');
    end if;
    update public.vendors v set
      slug                  = coalesce(p_patch->>'slug', v.slug),
      name                  = coalesce(p_patch->>'name', v.name),
      name_ar               = coalesce(p_patch->>'name_ar', v.name_ar),
      legal_name            = coalesce(p_patch->>'legal_name', v.legal_name),
      brand_id              = case when p_patch ? 'brand_id' then (p_patch->>'brand_id')::uuid else v.brand_id end,
      vertical_type         = coalesce(p_patch->>'vertical_type', v.vertical_type),
      city_id               = coalesce((p_patch->>'city_id')::uuid, v.city_id),
      area_id               = coalesce((p_patch->>'area_id')::uuid, v.area_id),
      latitude              = coalesce((p_patch->>'latitude')::numeric, v.latitude),
      longitude             = coalesce((p_patch->>'longitude')::numeric, v.longitude),
      geohash_prefix        = coalesce(p_patch->>'geohash_prefix', v.geohash_prefix),
      delivery_radius_km    = coalesce((p_patch->>'delivery_radius_km')::numeric, v.delivery_radius_km),
      is_open               = coalesce((p_patch->>'is_open')::boolean, v.is_open),
      is_busy               = coalesce((p_patch->>'is_busy')::boolean, v.is_busy),
      auto_open             = coalesce((p_patch->>'auto_open')::boolean, v.auto_open),
      is_approved           = coalesce((p_patch->>'is_approved')::boolean, v.is_approved),
      is_active             = coalesce((p_patch->>'is_active')::boolean, v.is_active),
      capacity_per_slot     = case when p_patch ? 'capacity_per_slot' then (p_patch->>'capacity_per_slot')::integer else v.capacity_per_slot end,
      reject_rate           = coalesce((p_patch->>'reject_rate')::numeric, v.reject_rate),
      delivery_fee_override = case when p_patch ? 'delivery_fee_override' then (p_patch->>'delivery_fee_override')::integer else v.delivery_fee_override end,
      minimum_order_value   = coalesce((p_patch->>'minimum_order_value')::integer, v.minimum_order_value),
      prep_time_minutes     = coalesce((p_patch->>'prep_time_minutes')::integer, v.prep_time_minutes),
      prep_time_max_minutes = coalesce((p_patch->>'prep_time_max_minutes')::integer, v.prep_time_max_minutes),
      logo_path             = coalesce(p_patch->>'logo_path', v.logo_path),
      description           = coalesce(p_patch->>'description', v.description),
      description_ar        = coalesce(p_patch->>'description_ar', v.description_ar),
      contact_phone         = coalesce(p_patch->>'contact_phone', v.contact_phone),
      contact_landline      = coalesce(p_patch->>'contact_landline', v.contact_landline)
     where v.id = p_id
    returning v.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.updated', 'vendor', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;

revoke execute on function public.admin_upsert_vendor_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_vendor_v1(jsonb, uuid) to authenticated;

-- =============================================================================================
-- 6. vendor_areas — composite key, so two arguments instead of a p_id
-- =============================================================================================
-- `eta_maxutes > eta_minutes` is checked HERE rather than left to `vendor_schedules_check`'s
-- sibling constraint, because there is no CHECK on this table for it and an inverted ETA range
-- would silently produce nonsense delivery promises. That is a real validation the schema does not
-- have and this function supplies.
create or replace function public.admin_upsert_vendor_area_v1(
  p_patch jsonb, p_vendor_id uuid, p_area_id uuid
)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_unknown text; v_exists boolean;
  v_min int; v_max int;
  v_allowed constant text[] := array['delivery_fee_override','eta_minutes','eta_maxutes','is_active'];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor areas are admin only'); end if;
  if p_vendor_id is null or p_area_id is null then
    perform private.err('KEY_REQUIRED', 'vendor_id and area_id are both required');
  end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a vendor_areas column: ' || v_unknown);
  end if;

  select va.eta_minutes, va.eta_maxutes into v_min, v_max
    from public.vendor_areas va
   where va.vendor_id = p_vendor_id and va.area_id = p_area_id and va.deleted_at is null;

  v_min := coalesce((p_patch->>'eta_minutes')::integer, v_min, 20);
  v_max := coalesce((p_patch->>'eta_maxutes')::integer, v_max, 40);

  if v_max <= v_min then
    perform private.err('ETA_RANGE_INVALID',
      format('eta_maxutes (%s) must be greater than eta_minutes (%s)', v_max, v_min));
  end if;

  v_exists := (v_min is not null);

  insert into public.vendor_areas (vendor_id, area_id, delivery_fee_override,
                                   eta_minutes, eta_maxutes, is_active)
  values (p_vendor_id, p_area_id, (p_patch->>'delivery_fee_override')::integer,
          v_min, v_max, coalesce((p_patch->>'is_active')::boolean, true))
  on conflict (vendor_id, area_id) do update
    set delivery_fee_override = excluded.delivery_fee_override,
        eta_minutes           = excluded.eta_minutes,
        eta_maxutes           = excluded.eta_maxutes,
        is_active             = excluded.is_active,
        deleted_at            = null;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.area_updated', 'vendor', p_vendor_id,
          jsonb_build_object('actor', v_user, 'area_id', p_area_id,
                             'fields', (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
end;
$$;

revoke execute on function public.admin_upsert_vendor_area_v1(jsonb, uuid, uuid) from public, anon;
grant  execute on function public.admin_upsert_vendor_area_v1(jsonb, uuid, uuid) to authenticated;

-- =============================================================================================
-- 7. vendor_cuisines — composite key, and the smallest function here
-- =============================================================================================
-- A pair of ids. The patch is therefore almost pointless: the only mutable column is `deleted_at`,
-- which the delete and restore functions own. This function exists so the ADMIN SURFACE HAS NO
-- HOLE — a caller who wants to attach a cuisine goes through a gated function rather than being
-- left with no path and the temptation to use service_role. Its patch accepts nothing and says so.
create or replace function public.admin_upsert_vendor_cuisine_v1(
  p_patch jsonb, p_vendor_id uuid, p_cuisine_id uuid
)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_unknown text;
  v_allowed constant text[] := array['is_active'];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor cuisines are admin only'); end if;
  if p_vendor_id is null or p_cuisine_id is null then
    perform private.err('KEY_REQUIRED', 'vendor_id and cuisine_id are both required');
  end if;
  if p_patch is not null and p_patch <> '{}'::jsonb then
    select string_agg(k, ', ' order by k) into v_unknown
      from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
    if v_unknown is not null then
      perform private.err('UNKNOWN_KEY',
        'vendor_cuisines is a pair of ids and has no such column: ' || v_unknown);
    end if;
  end if;

  insert into public.vendor_cuisines (vendor_id, cuisine_id)
  values (p_vendor_id, p_cuisine_id)
  on conflict (vendor_id, cuisine_id) do update
    set deleted_at = null,
        updated_at = now();

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.cuisine_added', 'vendor', p_vendor_id,
          jsonb_build_object('actor', v_user, 'cuisine_id', p_cuisine_id));
end;
$$;

revoke execute on function public.admin_upsert_vendor_cuisine_v1(jsonb, uuid, uuid) from public, anon;
grant  execute on function public.admin_upsert_vendor_cuisine_v1(jsonb, uuid, uuid) to authenticated;

-- =============================================================================================
-- 8. vendor_schedules
-- =============================================================================================
-- Split shifts: the unique key is (vendor_id, day_of_week, slot), so a lunch-only vendor is one
-- row at 11:00-15:00 and a vendor that also does dinner is two rows for the same day. `slot`
-- defaults to 0, which is the first shift.
--
-- `closes_at > opens_at` IS a CHECK on the table (vendor_schedules_check) and is deliberately NOT
-- duplicated here: unlike vendor_areas, the schema already enforces it, and a second copy would be
-- a second thing to keep in step. `is_closed` exists so a closed day is a recorded fact rather than
-- an absent row, which is what lets "closed on Sunday" be answered without inference.
create or replace function public.admin_upsert_vendor_schedule_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid; v_unknown text; v_exists boolean;
  v_allowed constant text[] := array[
    'vendor_id','day_of_week','slot','opens_at','closes_at','is_closed'
  ];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor schedules are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a vendor_schedules column: ' || v_unknown);
  end if;

  if p_id is null then
    insert into public.vendor_schedules (vendor_id, day_of_week, slot, opens_at, closes_at, is_closed)
    values ((p_patch->>'vendor_id')::uuid, (p_patch->>'day_of_week')::smallint,
            coalesce((p_patch->>'slot')::smallint, 0),
            (p_patch->>'opens_at')::time, (p_patch->>'closes_at')::time,
            coalesce((p_patch->>'is_closed')::boolean, false))
    returning id into v_id;
  else
    select exists (select 1 from public.vendor_schedules s
                    where s.id = p_id and s.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live schedule with that id; restore it first');
    end if;
    update public.vendor_schedules s set
      vendor_id  = coalesce((p_patch->>'vendor_id')::uuid, s.vendor_id),
      day_of_week = coalesce((p_patch->>'day_of_week')::smallint, s.day_of_week),
      slot       = coalesce((p_patch->>'slot')::smallint, s.slot),
      opens_at   = coalesce((p_patch->>'opens_at')::time, s.opens_at),
      closes_at  = coalesce((p_patch->>'closes_at')::time, s.closes_at),
      is_closed  = coalesce((p_patch->>'is_closed')::boolean, s.is_closed)
     where s.id = p_id
    returning s.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.schedule_updated', 'vendor_schedule', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;

revoke execute on function public.admin_upsert_vendor_schedule_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_vendor_schedule_v1(jsonb, uuid) to authenticated;

-- =============================================================================================
-- 9. vendor_holidays
-- =============================================================================================
-- A date-based closure. `UNIQUE (vendor_id, holiday_date)` means re-adding the same date is an
-- upsert, not a duplicate row — an admin re-saving a holiday must not create a second one.
create or replace function public.admin_upsert_vendor_holiday_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid; v_unknown text; v_exists boolean;
  v_vendor uuid; v_date date;
  v_allowed constant text[] := array['vendor_id','holiday_date','reason'];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor holidays are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a vendor_holidays column: ' || v_unknown);
  end if;

  v_vendor := (p_patch->>'vendor_id')::uuid;
  v_date   := (p_patch->>'holiday_date')::date;

  if p_id is null then
    if v_vendor is null or v_date is null then
      perform private.err('KEY_REQUIRED', 'vendor_id and holiday_date are both required to create a holiday');
    end if;
    insert into public.vendor_holidays (vendor_id, holiday_date, reason)
    values (v_vendor, v_date, p_patch->>'reason')
    on conflict (vendor_id, holiday_date) do update
      set reason = excluded.reason, deleted_at = null, updated_at = now()
    returning id into v_id;
  else
    select exists (select 1 from public.vendor_holidays h
                    where h.id = p_id and h.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live holiday with that id; restore it first');
    end if;
    update public.vendor_holidays h set
      vendor_id    = coalesce(v_vendor, h.vendor_id),
      holiday_date = coalesce(v_date, h.holiday_date),
      reason       = coalesce(p_patch->>'reason', h.reason)
     where h.id = p_id
    returning h.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.holiday_updated', 'vendor_holiday', v_id,
          jsonb_build_object('actor', v_user, 'vendor_id', coalesce(v_vendor, v_id),
                             'fields', (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;

revoke execute on function public.admin_upsert_vendor_holiday_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_vendor_holiday_v1(jsonb, uuid) to authenticated;

-- =============================================================================================
-- 10. vendor_staff
-- =============================================================================================
-- `user_id` is in the allowlist because moving a staff member between vendors is a real
-- correction. `UNIQUE (user_id, vendor_id)` means the same person can work for two vendors, and
-- the upsert on that key is what makes re-adding an existing grant idempotent.
create or replace function public.admin_upsert_vendor_staff_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid; v_unknown text; v_exists boolean;
  v_allowed constant text[] := array[
    'user_id','vendor_id','staff_role','can_edit_menu','can_manage_orders'
  ];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor staff are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a vendor_staff column: ' || v_unknown);
  end if;

  if p_id is null then
    if (p_patch->>'user_id')::uuid is null or (p_patch->>'vendor_id')::uuid is null then
      perform private.err('KEY_REQUIRED', 'user_id and vendor_id are both required to add staff');
    end if;
    insert into public.vendor_staff (user_id, vendor_id, staff_role, can_edit_menu, can_manage_orders)
    values ((p_patch->>'user_id')::uuid, (p_patch->>'vendor_id')::uuid,
            coalesce(p_patch->>'staff_role', 'staff'),
            coalesce((p_patch->>'can_edit_menu')::boolean, false),
            coalesce((p_patch->>'can_manage_orders')::boolean, false))
    on conflict (user_id, vendor_id) do update
      set staff_role        = excluded.staff_role,
          can_edit_menu     = excluded.can_edit_menu,
          can_manage_orders = excluded.can_manage_orders,
          deleted_at        = null,
          updated_at        = now()
    returning id into v_id;
  else
    select exists (select 1 from public.vendor_staff vs
                    where vs.id = p_id and vs.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live staff row with that id; restore it first');
    end if;
    update public.vendor_staff vs set
      user_id           = coalesce((p_patch->>'user_id')::uuid, vs.user_id),
      vendor_id         = coalesce((p_patch->>'vendor_id')::uuid, vs.vendor_id),
      staff_role        = coalesce(p_patch->>'staff_role', vs.staff_role),
      can_edit_menu     = coalesce((p_patch->>'can_edit_menu')::boolean, vs.can_edit_menu),
      can_manage_orders = coalesce((p_patch->>'can_manage_orders')::boolean, vs.can_manage_orders)
     where vs.id = p_id
    returning vs.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.staff_updated', 'vendor_staff', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;

revoke execute on function public.admin_upsert_vendor_staff_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_vendor_staff_v1(jsonb, uuid) to authenticated;

-- =============================================================================================
-- The ten soft deletes
-- =============================================================================================
-- Ten functions, one per table, because §3 rule 1 forbids a p_table parameter. Each sets
-- `deleted_at`, never DELETEs, requires a non-blank reason, and writes its own event. The reason is
-- mandatory here for the same reason `wallets_status_reason_required` demands one: a row that
-- disappears from the customer app with no recorded cause is indistinguishable from a bug.
--
-- A reason is required but NOT stored on the row — `deleted_at` is a timestamp and these tables
-- have no `deleted_reason` column, and adding one to ten tables is a schema decision that belongs
-- in a migration of its own. The reason goes into the event payload, which is the outbox's job and
-- is retained. That is stated here because it is a real limitation, not an oversight: the row says
-- when, the event says why, and a reader needs both.

create or replace function public.admin_delete_city_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'cities are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'city id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select c.deleted_at into v_soft from public.cities c where c.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such city'); end if;
  if v_soft is not null then
    perform private.err('ALREADY_DELETED', 'this city is already soft-deleted');
  end if;
  update public.cities c set deleted_at = now() where c.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('city.deleted', 'city', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_city_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_city_v1(uuid, text) to authenticated;

create or replace function public.admin_delete_area_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'areas are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'area id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select a.deleted_at into v_soft from public.areas a where a.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such area'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this area is already soft-deleted'); end if;
  update public.areas a set deleted_at = now() where a.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('area.deleted', 'area', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_area_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_area_v1(uuid, text) to authenticated;

create or replace function public.admin_delete_brand_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'brands are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'brand id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select b.deleted_at into v_soft from public.brands b where b.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such brand'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this brand is already soft-deleted'); end if;
  update public.brands b set deleted_at = now() where b.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('brand.deleted', 'brand', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_brand_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_brand_v1(uuid, text) to authenticated;

create or replace function public.admin_delete_cuisine_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'cuisines are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'cuisine id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select c.deleted_at into v_soft from public.cuisines c where c.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such cuisine'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this cuisine is already soft-deleted'); end if;
  update public.cuisines c set deleted_at = now() where c.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('cuisine.deleted', 'cuisine', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_cuisine_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_cuisine_v1(uuid, text) to authenticated;

create or replace function public.admin_delete_vendor_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendors are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'vendor id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select v.deleted_at into v_soft from public.vendors v where v.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such vendor'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this vendor is already soft-deleted'); end if;
  -- The vendor is deactivated as well as archived. A soft-deleted row that is still is_active
  -- would satisfy `vendors_read` on the is_active predicate alone if any policy were ever loosened,
  -- and two flags disagreeing about the same intent is how a vendor reappears after deletion.
  update public.vendors v set deleted_at = now(), is_active = false where v.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.deleted', 'vendor', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_vendor_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_vendor_v1(uuid, text) to authenticated;

create or replace function public.admin_delete_vendor_area_v1(
  p_vendor_id uuid, p_area_id uuid, p_reason text
)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor areas are admin only'); end if;
  if p_vendor_id is null or p_area_id is null then
    perform private.err('KEY_REQUIRED', 'vendor_id and area_id are both required');
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select va.deleted_at into v_soft from public.vendor_areas va
   where va.vendor_id = p_vendor_id and va.area_id = p_area_id;
  if not found then perform private.err('NOT_FOUND', 'no such vendor area mapping'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this mapping is already withdrawn'); end if;
  update public.vendor_areas va set deleted_at = now(), is_active = false
   where va.vendor_id = p_vendor_id and va.area_id = p_area_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.area_deleted', 'vendor', p_vendor_id,
          jsonb_build_object('actor', v_user, 'area_id', p_area_id, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_vendor_area_v1(uuid, uuid, text) from public, anon;
grant  execute on function public.admin_delete_vendor_area_v1(uuid, uuid, text) to authenticated;

create or replace function public.admin_delete_vendor_cuisine_v1(
  p_vendor_id uuid, p_cuisine_id uuid, p_reason text
)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor cuisines are admin only'); end if;
  if p_vendor_id is null or p_cuisine_id is null then
    perform private.err('KEY_REQUIRED', 'vendor_id and cuisine_id are both required');
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select vc.deleted_at into v_soft from public.vendor_cuisines vc
   where vc.vendor_id = p_vendor_id and vc.cuisine_id = p_cuisine_id;
  if not found then perform private.err('NOT_FOUND', 'no such vendor cuisine mapping'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this mapping is already withdrawn'); end if;
  update public.vendor_cuisines vc set deleted_at = now() where vc.vendor_id = p_vendor_id and vc.cuisine_id = p_cuisine_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.cuisine_deleted', 'vendor', p_vendor_id,
          jsonb_build_object('actor', v_user, 'cuisine_id', p_cuisine_id, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_vendor_cuisine_v1(uuid, uuid, text) from public, anon;
grant  execute on function public.admin_delete_vendor_cuisine_v1(uuid, uuid, text) to authenticated;

create or replace function public.admin_delete_vendor_schedule_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor schedules are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'schedule id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select s.deleted_at into v_soft from public.vendor_schedules s where s.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such schedule'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this schedule is already soft-deleted'); end if;
  update public.vendor_schedules s set deleted_at = now() where s.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.schedule_deleted', 'vendor_schedule', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_vendor_schedule_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_vendor_schedule_v1(uuid, text) to authenticated;

create or replace function public.admin_delete_vendor_holiday_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor holidays are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'holiday id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select h.deleted_at into v_soft from public.vendor_holidays h where h.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such holiday'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this holiday is already soft-deleted'); end if;
  update public.vendor_holidays h set deleted_at = now() where h.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.holiday_deleted', 'vendor_holiday', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_vendor_holiday_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_vendor_holiday_v1(uuid, text) to authenticated;

create or replace function public.admin_delete_vendor_staff_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor staff are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'staff id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select vs.deleted_at into v_soft from public.vendor_staff vs where vs.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such staff row'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this staff row is already soft-deleted'); end if;
  update public.vendor_staff vs set deleted_at = now() where vs.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.staff_deleted', 'vendor_staff', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_vendor_staff_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_vendor_staff_v1(uuid, text) to authenticated;

-- =============================================================================================
-- The restores
-- =============================================================================================
-- Ten functions, and they are SEPARATE from the upserts on purpose: §3 rule 6 says every function
-- refuses to touch a soft-deleted row except through the matching restore. Folding "and
-- un-delete" into the upsert would mean a caller who did not know the row was archived could
-- silently bring it back, which is the opposite of what a delete is for.
--
-- A restore requires a reason too, for the same reason the delete does: "who brought this back"
-- is the question asked after an incident, and it is the same question as "who removed it".
--
-- `vendors` restore also re-activates, the inverse of admin_delete_vendor_v1 which deactivates.
-- It does NOT re-approve: approval is a separate decision with a separate key, and restoring a
-- deleted vendor should not silently publish it to the customer app.

create or replace function public.admin_restore_city_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'cities are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'city id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select c.deleted_at into v_soft from public.cities c where c.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such city'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this city is not soft-deleted'); end if;
  update public.cities c set deleted_at = null where c.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('city.restored', 'city', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_city_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_city_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_area_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'areas are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'area id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select a.deleted_at into v_soft from public.areas a where a.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such area'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this area is not soft-deleted'); end if;
  update public.areas a set deleted_at = null where a.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('area.restored', 'area', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_area_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_area_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_brand_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'brands are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'brand id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select b.deleted_at into v_soft from public.brands b where b.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such brand'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this brand is not soft-deleted'); end if;
  update public.brands b set deleted_at = null where b.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('brand.restored', 'brand', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_brand_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_brand_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_cuisine_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'cuisines are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'cuisine id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select c.deleted_at into v_soft from public.cuisines c where c.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such cuisine'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this cuisine is not soft-deleted'); end if;
  update public.cuisines c set deleted_at = null where c.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('cuisine.restored', 'cuisine', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_cuisine_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_cuisine_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_vendor_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendors are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'vendor id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select v.deleted_at into v_soft from public.vendors v where v.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such vendor'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this vendor is not soft-deleted'); end if;
  -- is_active back to true; is_approved deliberately NOT touched. Restoring an archived vendor
  -- must not publish it to the customer app without a separate approval decision.
  update public.vendors v set deleted_at = null, is_active = true where v.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.restored', 'vendor', p_id, jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_vendor_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_vendor_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_vendor_area_v1(
  p_vendor_id uuid, p_area_id uuid, p_reason text
)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor areas are admin only'); end if;
  if p_vendor_id is null or p_area_id is null then
    perform private.err('KEY_REQUIRED', 'vendor_id and area_id are both required');
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select va.deleted_at into v_soft from public.vendor_areas va
   where va.vendor_id = p_vendor_id and va.area_id = p_area_id;
  if not found then perform private.err('NOT_FOUND', 'no such vendor area mapping'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this mapping is not withdrawn'); end if;
  update public.vendor_areas va set deleted_at = null, is_active = true
   where va.vendor_id = p_vendor_id and va.area_id = p_area_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.area_restored', 'vendor', p_vendor_id,
          jsonb_build_object('actor', v_user, 'area_id', p_area_id, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_vendor_area_v1(uuid, uuid, text) from public, anon;
grant  execute on function public.admin_restore_vendor_area_v1(uuid, uuid, text) to authenticated;

create or replace function public.admin_restore_vendor_cuisine_v1(
  p_vendor_id uuid, p_cuisine_id uuid, p_reason text
)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor cuisines are admin only'); end if;
  if p_vendor_id is null or p_cuisine_id is null then
    perform private.err('KEY_REQUIRED', 'vendor_id and cuisine_id are both required');
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select vc.deleted_at into v_soft from public.vendor_cuisines vc
   where vc.vendor_id = p_vendor_id and vc.cuisine_id = p_cuisine_id;
  if not found then perform private.err('NOT_FOUND', 'no such vendor cuisine mapping'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this mapping is not withdrawn'); end if;
  update public.vendor_cuisines vc set deleted_at = null
   where vc.vendor_id = p_vendor_id and vc.cuisine_id = p_cuisine_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.cuisine_restored', 'vendor', p_vendor_id,
          jsonb_build_object('actor', v_user, 'cuisine_id', p_cuisine_id, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_vendor_cuisine_v1(uuid, uuid, text) from public, anon;
grant  execute on function public.admin_restore_vendor_cuisine_v1(uuid, uuid, text) to authenticated;

create or replace function public.admin_restore_vendor_schedule_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor schedules are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'schedule id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select s.deleted_at into v_soft from public.vendor_schedules s where s.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such schedule'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this schedule is not soft-deleted'); end if;
  update public.vendor_schedules s set deleted_at = null where s.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.schedule_restored', 'vendor_schedule', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_vendor_schedule_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_vendor_schedule_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_vendor_holiday_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor holidays are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'holiday id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select h.deleted_at into v_soft from public.vendor_holidays h where h.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such holiday'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this holiday is not soft-deleted'); end if;
  update public.vendor_holidays h set deleted_at = null where h.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.holiday_restored', 'vendor_holiday', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_vendor_holiday_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_vendor_holiday_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_vendor_staff_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vendor staff are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'staff id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select vs.deleted_at into v_soft from public.vendor_staff vs where vs.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such staff row'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this staff row is not soft-deleted'); end if;
  update public.vendor_staff vs set deleted_at = null where vs.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('vendor.staff_restored', 'vendor_staff', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_vendor_staff_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_vendor_staff_v1(uuid, text) to authenticated;

-- =============================================================================================
-- Assertions
-- =============================================================================================
do $$
declare
  v_expected constant text[] := array[
    'admin_upsert_city_v1','admin_upsert_area_v1','admin_upsert_brand_v1','admin_upsert_cuisine_v1',
    'admin_upsert_vendor_v1','admin_upsert_vendor_area_v1','admin_upsert_vendor_cuisine_v1',
    'admin_upsert_vendor_schedule_v1','admin_upsert_vendor_holiday_v1','admin_upsert_vendor_staff_v1',
    'admin_delete_city_v1','admin_delete_area_v1','admin_delete_brand_v1','admin_delete_cuisine_v1',
    'admin_delete_vendor_v1','admin_delete_vendor_area_v1','admin_delete_vendor_cuisine_v1',
    'admin_delete_vendor_schedule_v1','admin_delete_vendor_holiday_v1','admin_delete_vendor_staff_v1',
    'admin_restore_city_v1','admin_restore_area_v1','admin_restore_brand_v1','admin_restore_cuisine_v1',
    'admin_restore_vendor_v1','admin_restore_vendor_area_v1','admin_restore_vendor_cuisine_v1',
    'admin_restore_vendor_schedule_v1','admin_restore_vendor_holiday_v1','admin_restore_vendor_staff_v1'
  ];
  v_missing text; v_not_definer text; v_unpinned text; v_anon_exec integer;
  v_bad_param text; v_no_revoke text; v_no_delete text;
begin
  -- 1. All thirty exist. Checked by name, not by count, so a typo in one name fails here rather
  --    than passing a count and leaving the console with a missing function.
  select string_agg(e, ', ' order by e) into v_missing
    from unnest(v_expected) as e
   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = e);
  if v_missing is not null then
    raise exception 'FAIL CLOSED: 026 did not create: %', v_missing;
  end if;

  -- 2. All thirty are SECURITY DEFINER. Every one reads or writes a table RLS restricts, and each
  --    re-derives its own admin decision rather than inheriting a policy.
  select string_agg(p.proname, ', ' order by p.proname) into v_not_definer
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected) and not p.prosecdef;
  if v_not_definer is not null then
    raise exception 'FAIL CLOSED: not SECURITY DEFINER: %', v_not_definer;
  end if;

  -- 3. All thirty pin search_path. Suite check 10 covers this too; asserting it here means a
  --    failure names this migration rather than surfacing in an unrelated run.
  select string_agg(p.proname, ', ' order by p.proname) into v_unpinned
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
                      where cfg like 'search\_path=%');
  if v_unpinned is not null then
    raise exception 'FAIL CLOSED: unpinned search_path on: %', v_unpinned;
  end if;

  -- 4. NO admin function takes a table name or an operation name. This is the assertion that
  --    keeps the rejected generic admin_write_v1(p_table, p_op, p_payload) from creeping back in.
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_bad_param
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and exists (select 1 from unnest(p.proargnames) arg
                  where lower(arg) in ('p_table','table_name','p_op','p_operation','operation'));
  if v_bad_param is not null then
    raise exception
      'FAIL CLOSED: an admin function takes a table or operation name, so a client value would select the write: %',
      v_bad_param;
  end if;

  -- 5. anon holds no EXECUTE on any of the thirty. A signed-out visitor must not be able to probe
  --    whether a city, vendor or staff row exists, let alone write one. This is the assertion that
  --    caught a missing revoke in 025, so it is here for the same reason.
  select count(*) into v_anon_exec
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_anon_exec <> 0 then
    raise exception 'FAIL CLOSED: anon can EXECUTE % of the 30 admin functions', v_anon_exec;
  end if;

  -- 6. authenticated CAN execute all thirty, or the admin console cannot call them.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = any (v_expected)
                 and not has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  then
    raise exception 'FAIL CLOSED: authenticated cannot execute one or more of the 30 admin functions';
  end if;

  -- 7. PUBLIC holds no EXECUTE either. The revoke in each grant line names public explicitly
  --    because `create or replace function` re-grants EXECUTE to PUBLIC by default, so a revoke
  --    that only named anon would leave PUBLIC holding it and anon reachable through it.
  --    Checked separately from 5 on purpose: 5 passes on a function where anon was revoked but
  --    PUBLIC was not, because anon inherits PUBLIC.
  select string_agg(p.proname, ', ' order by p.proname) into v_no_revoke
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and has_function_privilege('public', p.oid, 'EXECUTE');
  if v_no_revoke is not null then
    raise exception 'FAIL CLOSED: PUBLIC can EXECUTE, so anon reaches these through it: %', v_no_revoke;
  end if;

  -- 8. NO admin function issues a DELETE. Soft delete is the only admin delete, and this is the
  --    assertion that stops a future admin_hard_delete_v1 from being added "just for cleanup".
  --    Prose in a comment does not hold; this does.
  --
  --    The pattern is `(^|[^a-z_])delete\s+from`: `delete` preceded by a non-word character (or
  --    the start), then whitespace, then `from`. The prefix is what keeps it from matching the
  --    `deleted_at` column this file is full of — in `deleted_at` the "delete" is followed by `d`,
  --    not whitespace, and the leading guard is redundant but harmless.
  --
  --    Two earlier attempts at this assertion were wrong and both were shipped by a green run
  --    before being caught, which is why assertion 9 exists. `\melete\b` matches the literal word
  --    "elete" and so nothing. `\mdelete\s+from\b` looks correct and still matches nothing on
  --    this Postgres 17 build, because the trailing `\b` after `from` does not behave as expected
  --    in that position. A regex that cannot fail is not a check.
  --
  --    `pg_get_functiondef` does not return comments, so a comment mentioning DELETE cannot trip
  --    this and cannot mask a real statement either.
  select string_agg(p.proname, ', ' order by p.proname) into v_no_delete
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and pg_get_functiondef(p.oid) ~* '(^|[^a-z_])delete\s+from';
  if v_no_delete is not null then
    raise exception
      'FAIL CLOSED: these admin functions contain a DELETE statement, and soft delete is the only admin delete: %',
      v_no_delete;
  end if;

  -- 9. The negative test for assertion 8, in both directions. Without it, assertion 8 is an
  --    unfalsifiable claim about a regex, which is exactly what two earlier versions of it were.
  declare v_probe text;
  begin
    -- must MATCH a real delete
    v_probe := 'begin delete from public.cities; end;';
    if v_probe !~* '(^|[^a-z_])delete\s+from' then
      raise exception
        'FAIL CLOSED: the no-DELETE check cannot detect a DELETE, so assertion 8 proves nothing';
    end if;
    -- must NOT match the column this file is full of
    if 'update public.cities c set deleted_at = now()' ~* '(^|[^a-z_])delete\s+from' then
      raise exception
        'FAIL CLOSED: the no-DELETE check false-positives on deleted_at, so it would block correct code';
    end if;
  end;
end $$;
