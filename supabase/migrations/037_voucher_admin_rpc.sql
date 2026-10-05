-- 037: vouchers had no admin write path at all.
--
-- `select count(*) from pg_proc where proname ilike '%voucher%'` in `public` returned 0 before this
-- file. Every admin surface in this schema has an upsert plus a soft-delete plus a restore, each
-- `security definer`, each gated on `private.is_admin()`, each emitting an `events` row in the same
-- transaction as the state change. Vouchers had none of it, so a discount code could only be
-- created by writing SQL by hand, which means no audit trail and no `created_by`.
--
-- 036 made the vendor scope usable. Without this file there is still no way to reach it from a
-- dashboard, so 036 was necessary and not sufficient.
--
-- Conventions copied from `admin_upsert_area_v1` / `admin_delete_area_v1` / `admin_restore_area_v1`
-- rather than invented:
--
--   * signature shape: `(p_patch jsonb, p_id uuid)` for upsert, `(p_id uuid, p_reason text)` for
--     delete and restore.
--   * `private.err(code, message)` for every refusal, so the client sees a contracts code rather
--     than a raw Postgres error.
--   * an allow-list of patch keys, rejected with UNKNOWN_KEY. This is what caught the dead
--     `vendor_id` key in `027`.
--   * create path checks required values up front; update path uses `coalesce` for LEAVE ALONE and
--     an explicit `case` where jsonb `'null'` means CLEAR and an absent key means LEAVE ALONE.
--   * one `events` row per mutation, in the same transaction.
--   * soft delete always requires a non-empty reason, and restore always re-enables nothing: it
--     only clears `deleted_at`, leaving `is_active` as the admin left it.
--
-- Three voucher-specific hazards this file has to handle, none of which the CHECK constraints
-- explain:
--
-- 1. `vouchers_discount_value_check` is `discount_value > 0`, so a `free_delivery` voucher needs a
--    positive value even though the number is never read for that type. Passing 0 would be refused
--    by the table, so the function substitutes 1 and says so.
--
-- 2. `percentage` values are BASIS POINTS, not percent. 1000 = 10.0%. The upper bound of 10000 is
--    the `vouchers_percentage_sane` check, and this function repeats it so the caller gets a
--    contracts code instead of a constraint violation.
--
-- 3. `usage_count` is system state and is deliberately NOT in the allow-list. Letting a dashboard
--    write it would let anyone reset a usage limit by posting `{"usage_count":0}`.
--
-- `applies_to_vendor_ids` accepts the string token `"ALL_VENDORS"` and stores the empty array,
-- because 036 established that empty means every vendor. A dashboard therefore has a way to say
-- "all shops" without enumerating uuids, which was the gap 036 could not close on its own.
--
-- No data migration. `public.vouchers` is empty on this project, and every function here is new.

-- =============================================================================================
-- 1. admin_upsert_voucher_v1
-- =============================================================================================
create or replace function public.admin_upsert_voucher_v1(p_patch jsonb, p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid;
  v_unknown text;
  v_exists boolean;
  v_soft timestamptz;

  v_allowed constant text[] := array[
    'code','name','discount_type','discount_value','min_order_value','max_discount_cap',
    'usage_limit_total','usage_limit_per_user','applies_to_vendor_ids','vertical_type',
    'first_order_only','valid_from','valid_until','is_active'
  ];

  v_type text;
  v_value integer;
  v_scope uuid[];
  v_from timestamptz;
  v_until timestamptz;
  v_new_scope uuid[];
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vouchers are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a vouchers column: ' || v_unknown);
  end if;

  ----------------------------------------------------------------- scope
  -- "ALL_VENDORS" is the dashboard-facing spelling of 036's empty-array-means-everything. Absent
  -- key means LEAVE ALONE on update, so this is inside the `if` rather than defaulted globally.
  if p_patch ? 'applies_to_vendor_ids' then
    -- Compared as TEXT, not as `'ALL_VENDORS'::jsonb`. A bare word is not valid JSON, so the cast
    -- raised 22P02 on the first call that actually used the token - the dry run caught it.
    if p_patch->>'applies_to_vendor_ids' = 'ALL_VENDORS' then
      v_new_scope := '{}'::uuid[];
    else
-- A non-array, non-token value must be refused here rather than reaching
      -- jsonb_array_elements_text and raising 22P02 as a raw driver error.
      if jsonb_typeof(p_patch->'applies_to_vendor_ids') <> 'array' then
        perform private.err('PATCH_INVALID',
          'applies_to_vendor_ids must be an array of vendor uuids, or the string "ALL_VENDORS"');
      end if;
      begin
        v_new_scope := array(select private.try_uuid(x)
                               from jsonb_array_elements_text(p_patch->'applies_to_vendor_ids') x);
      exception when others then
        perform private.err('PATCH_INVALID','applies_to_vendor_ids must be an array of vendor uuids, or the string "ALL_VENDORS"');
      end;
      if exists (select 1 from unnest(v_new_scope) s
                  where not exists (select 1 from public.vendors v where v.id = s)) then
        perform private.err('VENDOR_NOT_FOUND', 'applies_to_vendor_ids names a vendor that does not exist');
      end if;
    end if;
  end if;

  ----------------------------------------------------------------- create
  if p_id is null then
    if (p_patch->>'code') is null or btrim(p_patch->>'code') = '' then
      perform private.err('KEY_REQUIRED', 'code is required to create a voucher');
    end if;
    if (p_patch->>'discount_type') is null then
      perform private.err('KEY_REQUIRED', 'discount_type is required to create a voucher');
    end if;
    if (p_patch->>'discount_value') is null then
      perform private.err('KEY_REQUIRED', 'discount_value is required to create a voucher');
    end if;

    v_type  := p_patch->>'discount_type';
    v_value := (p_patch->>'discount_value')::integer;

    if v_type not in ('percentage','fixed_amount','free_delivery') then
      perform private.err('DISCOUNT_TYPE_INVALID',
        'discount_type must be percentage, fixed_amount or free_delivery');
    end if;
    -- See header note 2: percentage is basis points.
    if v_type = 'percentage' and (v_value < 1 or v_value > 10000) then
      perform private.err('DISCOUNT_PERCENTAGE_INVALID',
        'a percentage voucher takes BASIS POINTS from 1 to 10000, so 1000 means 10%');
    end if;
    -- See header note 1: the column is NOT NULL and CHECK (> 0) even for free_delivery.
    if v_type <> 'percentage' and v_value < 1 then
      perform private.err('DISCOUNT_VALUE_INVALID', 'discount_value must be at least 1');
    end if;

    -- Codes are matched case-insensitively by compute_quote (`upper(v.code) = upper(...)`), so the
    -- uniqueness check has to be case-insensitive too. Otherwise SAVE10 and save10 both insert and
    -- which one wins becomes a race.
    if exists (select 1 from public.vouchers v
                where upper(v.code) = upper(btrim(p_patch->>'code')) and v.deleted_at is null) then
      perform private.err('VOUCHER_CODE_TAKEN',
        'a live voucher already uses that code; codes are compared case-insensitively');
    end if;

    v_from  := coalesce((p_patch->>'valid_from')::timestamptz, now());
    v_until := (p_patch->>'valid_until')::timestamptz;
    if v_until is not null and v_until <= v_from then
      perform private.err('VOUCHER_WINDOW_INVALID', 'valid_until must be later than valid_from');
    end if;

    if (p_patch->>'usage_limit_per_user') is not null
       and (p_patch->>'usage_limit_per_user')::integer < 1 then
      perform private.err('VOUCHER_LIMIT_INVALID', 'usage_limit_per_user must be at least 1');
    end if;
    if (p_patch->>'usage_limit_total') is not null
       and (p_patch->>'usage_limit_total')::integer < 1 then
      perform private.err('VOUCHER_LIMIT_INVALID', 'usage_limit_total must be at least 1');
    end if;
    if p_patch ? 'max_discount_cap'
       and jsonb_typeof(p_patch->'max_discount_cap') <> 'null'
       and (p_patch->>'max_discount_cap')::integer < 0 then
      perform private.err('VOUCHER_CAP_INVALID', 'max_discount_cap cannot be negative');
    end if;
    if (p_patch->>'vertical_type') is not null
       and (p_patch->>'vertical_type') not in ('food','grocery','pharmacy','flowers','bakery','others') then
      perform private.err('VERTICAL_TYPE_INVALID', 'vertical_type must be one of food, grocery, pharmacy, flowers, bakery, others');
    end if;

    insert into public.vouchers (
      code, name, discount_type, discount_value, min_order_value, max_discount_cap,
      usage_limit_total, usage_limit_per_user, applies_to_vendor_ids, vertical_type,
      first_order_only, valid_from, valid_until, is_active, created_by)
    values (
      btrim(p_patch->>'code'), p_patch->>'name', v_type,
      -- free_delivery stores a dummy positive because the column is CHECK (> 0) and the number is
      -- never read for that type; compute_quote substitutes the actual delivery fee instead.
      case when v_type = 'free_delivery' then greatest(v_value, 1) else v_value end,
      coalesce((p_patch->>'min_order_value')::integer, 0),
      case when p_patch ? 'max_discount_cap'
                        and jsonb_typeof(p_patch->'max_discount_cap') <> 'null'
           then (p_patch->>'max_discount_cap')::integer end,
      (p_patch->>'usage_limit_total')::integer,
      (p_patch->>'usage_limit_per_user')::integer,
      coalesce(v_new_scope, '{}'::uuid[]),
      p_patch->>'vertical_type',
      coalesce((p_patch->>'first_order_only')::boolean, false),
      v_from, v_until,
      coalesce((p_patch->>'is_active')::boolean, true),
      v_user)
    returning id into v_id;

  ----------------------------------------------------------------- update
  else
    select v.deleted_at into v_soft from public.vouchers v where v.id = p_id;
    if not found then perform private.err('NOT_FOUND', 'no such voucher'); end if;
    if v_soft is not null then
      perform private.err('NOT_FOUND', 'this voucher is soft-deleted; restore it first');
    end if;

    if p_patch ? 'code' and exists (
         select 1 from public.vouchers v
          where upper(v.code) = upper(btrim(p_patch->>'code'))
            and v.id <> p_id and v.deleted_at is null) then
      perform private.err('VOUCHER_CODE_TAKEN',
        'another live voucher already uses that code; codes are compared case-insensitively');
    end if;

    -- Re-validate the pair as it will END UP, not as each key arrives, so an update cannot leave
    -- the row in a state the create path would have refused.
    v_type  := coalesce(p_patch->>'discount_type',
                        (select v.discount_type from public.vouchers v where v.id = p_id));
    v_value := coalesce((p_patch->>'discount_value')::integer,
                        case when v_type = 'free_delivery' then 1
                             else (select v.discount_value from public.vouchers v where v.id = p_id) end);
    if v_type not in ('percentage','fixed_amount','free_delivery') then
      perform private.err('DISCOUNT_TYPE_INVALID',
        'discount_type must be percentage, fixed_amount or free_delivery');
    end if;
    if v_type = 'percentage' and (v_value < 1 or v_value > 10000) then
      perform private.err('DISCOUNT_PERCENTAGE_INVALID',
        'a percentage voucher takes BASIS POINTS from 1 to 10000, so 1000 means 10%');
    end if;

    select v.valid_from, v.valid_until into v_from, v_until
      from public.vouchers v where v.id = p_id;
    v_from  := coalesce((p_patch->>'valid_from')::timestamptz, v_from);
-- Same absent-vs-null distinction as max_discount_cap below.
    v_until := case when not (p_patch ? 'valid_until') then v_until
                    when jsonb_typeof(p_patch->'valid_until') = 'null' then null
                    else (p_patch->>'valid_until')::timestamptz end;
    if v_until is not null and v_until <= v_from then
      perform private.err('VOUCHER_WINDOW_INVALID', 'valid_until must be later than valid_from');
    end if;

    if (p_patch->>'usage_limit_total') is not null
       and (p_patch->>'usage_limit_total')::integer
           < (select v.usage_count from public.vouchers v where v.id = p_id) then
      perform private.err('VOUCHER_LIMIT_INVALID',
        'usage_limit_total cannot be set below the uses already recorded');
    end if;

    update public.vouchers v set
      code           = coalesce(nullif(btrim(p_patch->>'code'), ''), v.code),
      name           = case when p_patch ? 'name' then p_patch->>'name' else v.name end,
      discount_type  = coalesce(p_patch->>'discount_type', v.discount_type),
      discount_value = case when v_type = 'free_delivery'
                            then greatest(v_value, 1)
                            else coalesce((p_patch->>'discount_value')::integer, v.discount_value) end,
      min_order_value = coalesce((p_patch->>'min_order_value')::integer, v.min_order_value),
-- Absent means LEAVE ALONE; an explicit jsonb null means CLEAR. `p_patch ? 'k'` is TRUE for both
      -- cases, and `jsonb_typeof('{}'->'k')` is SQL NULL rather than the string 'null', so the
      -- obvious `case when p_patch ? 'k' and jsonb_typeof(...) <> 'null'` conflates them and an
      -- explicit null silently keeps the old value. The three-way test below is the only form that
      -- distinguishes absent from null. The dry run caught this.
      max_discount_cap = case
                           when not (p_patch ? 'max_discount_cap') then v.max_discount_cap
                           when jsonb_typeof(p_patch->'max_discount_cap') = 'null' then null
                           else (p_patch->>'max_discount_cap')::integer
                         end,
      usage_limit_total   = coalesce((p_patch->>'usage_limit_total')::integer, v.usage_limit_total),
      usage_limit_per_user = coalesce((p_patch->>'usage_limit_per_user')::integer, v.usage_limit_per_user),
      applies_to_vendor_ids = coalesce(v_new_scope, v.applies_to_vendor_ids),
      vertical_type   = case when p_patch ? 'vertical_type'
                            then nullif(p_patch->>'vertical_type', '')
                            else v.vertical_type end,
      first_order_only = coalesce((p_patch->>'first_order_only')::boolean, v.first_order_only),
      valid_from      = v_from,
      valid_until     = v_until,
      is_active       = coalesce((p_patch->>'is_active')::boolean, v.is_active)
     where v.id = p_id
    returning v.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('voucher.updated', 'voucher', v_id,
          jsonb_build_object('actor', v_user,
            'created', p_id is null,
            'fields', (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));

  return v_id;
end;
$$;

-- =============================================================================================
-- 2. admin_delete_voucher_v1 / 3. admin_restore_voucher_v1
-- =============================================================================================
-- Shapes copied verbatim from admin_delete_area_v1 / admin_restore_area_v1, including the
-- mandatory reason and the three distinct refusals (NOT_FOUND / ALREADY_DELETED / NOT_DELETED).
create or replace function public.admin_delete_voucher_v1(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz; v_code text;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vouchers are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'voucher id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;

  select v.deleted_at, v.code into v_soft, v_code from public.vouchers v where v.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such voucher'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this voucher is already soft-deleted'); end if;

  update public.vouchers v set deleted_at = now() where v.id = p_id;

  -- The code is carried into the event payload. compute_quote matches on `upper(code)`, so an audit
  -- that only has the uuid cannot tell which code was pulled without a join against a deleted row.
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('voucher.deleted', 'voucher', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason), 'code', v_code));
end;
$$;

create or replace function public.admin_restore_voucher_v1(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz; v_active boolean; v_code text;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'vouchers are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'voucher id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;

  select v.deleted_at, v.is_active, v.code into v_soft, v_active, v_code
    from public.vouchers v where v.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such voucher'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this voucher is not soft-deleted'); end if;

  -- Deliberately does NOT flip is_active. Delete and disable are different acts; a restore that
  -- silently re-enabled a voucher an admin had already switched off would undo the second decision.
  update public.vouchers v set deleted_at = null where v.id = p_id;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('voucher.restored', 'voucher', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason),
                             'code', v_code, 'is_active', v_active));
end;
$$;

comment on function public.admin_upsert_voucher_v1(jsonb,uuid) is
  'Create or update a voucher. discount_value is basis points for percentage (1000 = 10%). applies_to_vendor_ids accepts the string "ALL_VENDORS", stored as the empty array, which since 036 means every vendor.';
comment on function public.admin_delete_voucher_v1(uuid,text) is
  'Soft-delete a voucher. Reason mandatory. The code is copied into the event payload.';
comment on function public.admin_restore_voucher_v1(uuid,text) is
  'Clear deleted_at on a soft-deleted voucher. Reason mandatory. Does not change is_active.';

-- Same grants as the existing admin surface: authenticated may call, and the admin gate inside is
-- what actually decides. anon is refused outright.
--
-- ORDER MATTERS, and getting it wrong is silent. This project's `pg_default_acl` for
-- `public` functions is:
--
--   postgres=X | anon=X | authenticated=X | service_role=X
--
-- so CREATE OR REPLACE grants EXECUTE to anon automatically, and a `revoke` written BEFORE the
-- create is undone by the create. The first run of this file left all three callable by anon:
--
--   has_function_privilege('anon','public.admin_upsert_voucher_v1(jsonb,uuid)','EXECUTE') = true
--
-- Every pre-existing RPC is correctly denied to anon (admin_upsert_area_v1, quote_order_v1,
-- search_catalog_v1, place_order_v1 all = false), so these three would have been the only
-- anonymous entry points into the admin surface. The admin gate inside the function still refuses
-- them at run time, so this was defence in depth rather than a live hole, but a granted EXECUTE on
-- a `security definer` function is the thing to never leave lying around.
--
-- Hence: revoke AFTER the create, and the `alter default privileges` below so the next function
-- created in this schema does not inherit the same grant.
revoke execute on function public.admin_upsert_voucher_v1(jsonb,uuid) from public, anon;
revoke execute on function public.admin_delete_voucher_v1(uuid,text) from public, anon;
revoke execute on function public.admin_restore_voucher_v1(uuid,text) from public, anon;

grant execute on function public.admin_upsert_voucher_v1(jsonb,uuid) to authenticated, service_role;
grant execute on function public.admin_delete_voucher_v1(uuid,text) to authenticated, service_role;
grant execute on function public.admin_restore_voucher_v1(uuid,text) to authenticated, service_role;

alter default privileges in schema public revoke execute on functions from anon;

-- Asserted, not assumed. A grant that merely looks right in the migration text is exactly the class
-- of defect `027` shipped, so the privilege is read back from the catalog.
do $$
declare
  v_leaked text;
begin
  select string_agg(r, ', ' order by r) into v_leaked
    from unnest(array[
      'public.admin_upsert_voucher_v1(jsonb,uuid)',
      'public.admin_delete_voucher_v1(uuid,text)',
      'public.admin_restore_voucher_v1(uuid,text)']) as x(r)
   where has_function_privilege('anon', r, 'EXECUTE');

  if v_leaked is not null then
    raise exception
      'FAIL CLOSED: anon can EXECUTE % on a security definer admin function. Revoke after create, not before.', v_leaked;
  end if;
end;
$$;

-- =============================================================================================
-- Assertions. These EXECUTE the three functions. `027` shipped green with a dead function because
-- all thirteen of its assertions read `pg_proc` as text and none ran a mutation, so nothing in
-- this block inspects source.
--
-- Everything runs inside a `begin ... exception` subtransaction that is rolled back by a sentinel,
-- the same pattern `027a`, `033`, `034` and `036` use. `auth.users` is referenced by fifteen foreign
-- keys, so a migration must never contain an explicit `delete from auth.users` even when scoped to
-- known uuids. Rolling the subtransaction back removes the need for every cleanup statement.

do $probe$
declare
  v_admin  uuid := '00000000-0000-0000-0000-000000000001';
  v_plain  uuid := '00000000-0000-0000-0000-000000000002';
  v_city   uuid;
  v_area   uuid;
  v_v1     uuid;
  v_v2     uuid;
  v_id     uuid;
  v_second uuid;
  v_code   text;
  v_scope  uuid[];
  v_created_by uuid;
  v_usage  integer;
  v_active boolean;
  v_cap    integer;
  v_soft   timestamptz;
  v_n      integer;
begin
  ----------------------------------------------------------------- actors
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  insert into auth.users (id,email,raw_user_meta_data,created_at)
  values (v_admin,'037-admin@probe.local','{}'::jsonb,now());
  insert into public.user_roles (user_id,role) values (v_admin,'admin');

  v_city := public.admin_upsert_city_v1(
    '{"code":"037C","name":"Probe","name_ar":"م","country_code":"EG","timezone":"Africa/Cairo",
      "center_lat":30.0444,"center_lng":31.2357,"is_primary":true}'::jsonb,null);
  v_area := public.admin_upsert_area_v1(jsonb_build_object(
    'city_id',v_city,'slug','probe','name','Probe','name_ar','م','geohash_prefix','u4pr',
    'center_lat',30.0444,'center_lng',31.2357,'radius_km',3.0),null);
  v_v1 := public.admin_upsert_vendor_v1(jsonb_build_object(
    'slug','probe-a','name','A','name_ar','ا','vertical_type','food','city_id',v_city,
    'area_id',v_area,'latitude',30.0444,'longitude',31.2357,'geohash_prefix','u4pr',
    'is_open',true,'is_approved',true,'contact_phone','+201000000001'),null);
  v_v2 := public.admin_upsert_vendor_v1(jsonb_build_object(
    'slug','probe-b','name','B','name_ar','ب','vertical_type','food','city_id',v_city,
    'area_id',v_area,'latitude',30.045,'longitude',31.236,'geohash_prefix','u4pr',
    'is_open',true,'is_approved',true,'contact_phone','+201000000002'),null);

  ----------------------------------------------------------------- 1. a non-admin is refused
  -- The admin gate is proven by RUNNING it, not by reading it.
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
  insert into auth.users (id,email,phone,raw_user_meta_data,created_at)
  values (v_plain,'037-cust@probe.local','+20111110001','{}'::jsonb,now());

  begin
    perform public.admin_upsert_voucher_v1(
      '{"code":"HACK","discount_type":"percentage","discount_value":10000}'::jsonb,null);
    raise exception 'FAIL CLOSED: a non-admin created a voucher';
  exception when others then
    if sqlerrm not like 'NOT_AUTHORIZED%' then
      raise exception 'FAIL CLOSED: non-admin upsert raised "%", expected NOT_AUTHORIZED', sqlerrm;
    end if;
  end;

  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

  if exists (select 1 from public.vouchers where code = 'HACK') then
    raise exception 'FAIL CLOSED: the refused create left a row behind';
  end if;

  ----------------------------------------------------------------- 2. create, ALL_VENDORS token
  v_id := public.admin_upsert_voucher_v1(
    '{"code":"  WELCOME10  ","name":"Welcome 10","discount_type":"percentage",
      "discount_value":1000,"usage_limit_total":100,"usage_limit_per_user":1,
      "applies_to_vendor_ids":"ALL_VENDORS","max_discount_cap":5000}'::jsonb,null);

  select v.code, v.applies_to_vendor_ids, v.created_by, v.usage_count, v.is_active,
         v.max_discount_cap, v.discount_value, v.first_order_only
    into v_code, v_scope, v_created_by, v_usage, v_active, v_cap, v_n, v_soft
    from public.vouchers v where v.id = v_id;

  if v_code <> 'WELCOME10' then
    raise exception 'FAIL CLOSED: code is % after create, expected WELCOME10 (it must be trimmed)', v_code;
  end if;
  if cardinality(v_scope) <> 0 then
    raise exception
      'FAIL CLOSED: "ALL_VENDORS" must store the empty array, got % elements', cardinality(v_scope);
  end if;
  if v_created_by is distinct from v_admin then
    raise exception 'FAIL CLOSED: created_by is %, expected the acting admin', v_created_by;
  end if;
  if v_usage <> 0 then
    raise exception 'FAIL CLOSED: usage_count must start at 0, got %', v_usage;
  end if;
  if not v_active then
    raise exception 'FAIL CLOSED: is_active should default to true';
  end if;
  if v_cap <> 5000 then
    raise exception 'FAIL CLOSED: max_discount_cap is %, expected 5000', v_cap;
  end if;
  if v_n <> 1000 then
    raise exception 'FAIL CLOSED: discount_value is %, expected 1000 basis points', v_n;
  end if;
  if v_soft then
    raise exception 'FAIL CLOSED: first_order_only should default to false';
  end if;

  ----------------------------------------------------------------- 3. create, explicit vendor list
  v_second := public.admin_upsert_voucher_v1(
    '{"code":"PIZZAONLY","discount_type":"percentage","discount_value":1500,
      "applies_to_vendor_ids":["' || v_v1::text || '"]}'::jsonb,null);

  select v.applies_to_vendor_ids into v_scope
    from public.vouchers v where v.id = v_second;
  if cardinality(v_scope) <> 1 or v_scope[1] is distinct from v_v1 then
    raise exception 'FAIL CLOSED: explicit vendor scope was not stored: %', v_scope;
  end if;

  -- Both vendors at once, which is the case 036 had to keep working.
  perform public.admin_upsert_voucher_v1(
    '{"applies_to_vendor_ids":["' || v_v1::text || '","' || v_v2::text || '"]}'::jsonb, v_second);
  select v.applies_to_vendor_ids into v_scope
    from public.vouchers v where v.id = v_second;
  if cardinality(v_scope) <> 2 then
    raise exception 'FAIL CLOSED: two-vendor scope stored % elements, expected 2', cardinality(v_scope);
  end if;

  ----------------------------------------------------------------- 4. free_delivery survives the >0 CHECK
  v_id := public.admin_upsert_voucher_v1(
    '{"code":"FREEDEL","discount_type":"free_delivery","discount_value":1,
      "applies_to_vendor_ids":"ALL_VENDORS"}'::jsonb,null);
  select v.discount_value into v_n from public.vouchers v where v.id = v_id;
  if v_n < 1 then
    raise exception 'FAIL CLOSED: free_delivery stored discount_value %, which the table CHECK (>0) forbids', v_n;
  end if;

  ----------------------------------------------------------------- 5. refusals
  begin
    perform public.admin_upsert_voucher_v1('{"usage_count":0}'::jsonb,null);
    raise exception 'FAIL CLOSED: usage_count must not be writable';
  exception when others then
    if sqlerrm not like 'UNKNOWN_KEY%' then
      raise exception 'FAIL CLOSED: writing usage_count raised "%", expected UNKNOWN_KEY', sqlerrm;
    end if;
  end;

  begin
    perform public.admin_upsert_voucher_v1('{}'::jsonb,null);
    raise exception 'FAIL CLOSED: an empty patch must be refused';
  exception when others then
    if sqlerrm not like 'PATCH_EMPTY%' then
      raise exception 'FAIL CLOSED: empty patch raised "%", expected PATCH_EMPTY', sqlerrm;
    end if;
  end;

  -- Header note 2: percentage is basis points, so 1500% must be refused before the CHECK fires.
  begin
    perform public.admin_upsert_voucher_v1(
      '{"code":"TOOBIG","discount_type":"percentage","discount_value":15000}'::jsonb,null);
    raise exception 'FAIL CLOSED: 15000 basis points must be refused';
  exception when others then
    if sqlerrm not like 'DISCOUNT_PERCENTAGE_INVALID%' then
      raise exception 'FAIL CLOSED: 15000bps raised "%", expected DISCOUNT_PERCENTAGE_INVALID', sqlerrm;
    end if;
  end;

  -- Case-insensitive uniqueness, because compute_quote matches with upper().
  begin
    perform public.admin_upsert_voucher_v1(
      '{"code":"welcome10","discount_type":"percentage","discount_value":500}'::jsonb,null);
    raise exception 'FAIL CLOSED: a case-variant duplicate code was accepted';
  exception when others then
    if sqlerrm not like 'VOUCHER_CODE_TAKEN%' then
      raise exception 'FAIL CLOSED: duplicate code raised "%", expected VOUCHER_CODE_TAKEN', sqlerrm;
    end if;
  end;

  begin
    perform public.admin_upsert_voucher_v1(
      '{"code":"BADSCOPE","discount_type":"percentage","discount_value":100,
        "applies_to_vendor_ids":["00000000-0000-0000-0000-000000009999"]}'::jsonb,null);
    raise exception 'FAIL CLOSED: a nonexistent vendor uuid was accepted';
  exception when others then
    if sqlerrm not like 'VENDOR_NOT_FOUND%' then
      raise exception 'FAIL CLOSED: bad scope raised "%", expected VENDOR_NOT_FOUND', sqlerrm;
    end if;
  end;

  begin
    perform public.admin_upsert_voucher_v1(
      '{"code":"BADWIN","discount_type":"percentage","discount_value":100,
        "valid_from":"2026-01-01T00:00:00Z","valid_until":"2025-01-01T00:00:00Z"}'::jsonb,null);
    raise exception 'FAIL CLOSED: an inverted validity window was accepted';
  exception when others then
    if sqlerrm not like 'VOUCHER_WINDOW_INVALID%' then
      raise exception 'FAIL CLOSED: bad window raised "%", expected VOUCHER_WINDOW_INVALID', sqlerrm;
    end if;
  end;

  ----------------------------------------------------------------- 6. update leaves alone vs clears
  v_id := public.admin_upsert_voucher_v1(
    '{"code":"EDITME","discount_type":"percentage","discount_value":2000,
      "max_discount_cap":9000,"applies_to_vendor_ids":"ALL_VENDORS"}'::jsonb,null);

  -- An absent key must not wipe anything. This is the same class of bug as `027`'s tags coalesce,
  -- where an unrelated edit cleared a field.
  perform public.admin_upsert_voucher_v1('{"name":"Renamed"}'::jsonb, v_id);
  select v.name, v.discount_value, v.max_discount_cap, v.applies_to_vendor_ids
    into v_code, v_n, v_cap, v_scope
    from public.vouchers v where v.id = v_id;
  if v_code <> 'Renamed' then raise exception 'FAIL CLOSED: name did not update'; end if;
  if v_n <> 2000 then
    raise exception 'FAIL CLOSED: an unrelated edit changed discount_value to %', v_n;
  end if;
  if v_cap <> 9000 then
    raise exception 'FAIL CLOSED: an unrelated edit changed max_discount_cap to %', v_cap;
  end if;
  if cardinality(v_scope) <> 0 then
    raise exception 'FAIL CLOSED: an unrelated edit changed the vendor scope';
  end if;

  -- Explicit null means CLEAR, which is different from leave alone.
  perform public.admin_upsert_voucher_v1('{"max_discount_cap":null}'::jsonb, v_id);
  select v.max_discount_cap into v_cap from public.vouchers v where v.id = v_id;
  if v_cap is not null then
    raise exception 'FAIL CLOSED: jsonb null must clear max_discount_cap, got %', v_cap;
  end if;

  -- Switching type to free_delivery must not leave an illegal value behind.
  perform public.admin_upsert_voucher_v1('{"discount_type":"free_delivery"}'::jsonb, v_id);
  select v.discount_value into v_n from public.vouchers v where v.id = v_id;
  if v_n < 1 then
    raise exception 'FAIL CLOSED: switching to free_delivery left discount_value %, which violates CHECK (>0)', v_n;
  end if;

  perform public.admin_upsert_voucher_v1('{"discount_type":"percentage","discount_value":2000}'::jsonb, v_id);

  -- A usage floor cannot be pushed under what is already recorded.
  update public.vouchers v set usage_count = 7 where v.id = v_id;
  begin
    perform public.admin_upsert_voucher_v1('{"usage_limit_total":3}'::jsonb, v_id);
    raise exception 'FAIL CLOSED: usage_limit_total was set below usage_count';
  exception when others then
    if sqlerrm not like 'VOUCHER_LIMIT_INVALID%' then
      raise exception 'FAIL CLOSED: lowering the usage floor raised "%", expected VOUCHER_LIMIT_INVALID', sqlerrm;
    end if;
  end;
  update public.vouchers v set usage_count = 0 where v.id = v_id;

  ----------------------------------------------------------------- 7. delete and restore
  perform public.admin_delete_voucher_v1(v_id, 'superseded campaign');
  select v.deleted_at into v_soft from public.vouchers v where v.id = v_id;
  if v_soft is null then
    raise exception 'FAIL CLOSED: delete did not set deleted_at';
  end if;

  -- A soft-deleted voucher must not be quotable.
  begin
    perform public.admin_upsert_voucher_v1('{"name":"zombie"}'::jsonb, v_id);
    raise exception 'FAIL CLOSED: a soft-deleted voucher was editable';
  exception when others then
    if sqlerrm not like 'NOT_FOUND%' then
      raise exception 'FAIL CLOSED: editing a deleted voucher raised "%", expected NOT_FOUND', sqlerrm;
    end if;
  end;

  begin
    perform public.admin_delete_voucher_v1(v_id, 'again');
    raise exception 'FAIL CLOSED: double delete was accepted';
  exception when others then
    if sqlerrm not like 'ALREADY_DELETED%' then
      raise exception 'FAIL CLOSED: double delete raised "%", expected ALREADY_DELETED', sqlerrm;
    end if;
  end;

  -- The code is released once deleted, so the same code can be recreated.
  perform public.admin_upsert_voucher_v1(
    '{"code":"EDITME","discount_type":"percentage","discount_value":100}'::jsonb,null);

  -- Restore must not resurrect a voucher the admin had also disabled.
  update public.vouchers v set is_active = false where v.id = v_id;
  perform public.admin_restore_voucher_v1(v_id, 'campaign resumed');
  select v.deleted_at, v.is_active into v_soft, v_active from public.vouchers v where v.id = v_id;
  if v_soft is not null then
    raise exception 'FAIL CLOSED: restore did not clear deleted_at';
  end if;
  if v_active then
    raise exception
      'FAIL CLOSED: restore re-enabled a disabled voucher. Delete and disable are different acts.';
  end if;

  begin
    perform public.admin_restore_voucher_v1(v_id, 'again');
    raise exception 'FAIL CLOSED: double restore was accepted';
  exception when others then
    if sqlerrm not like 'NOT_DELETED%' then
      raise exception 'FAIL CLOSED: double restore raised "%", expected NOT_DELETED', sqlerrm;
    end if;
  end;

  begin
    perform public.admin_delete_voucher_v1(gen_random_uuid(), 'no such row');
    raise exception 'FAIL CLOSED: deleting a nonexistent voucher was accepted';
  exception when others then
    if sqlerrm not like 'NOT_FOUND%' then
      raise exception 'FAIL CLOSED: deleting a ghost raised "%", expected NOT_FOUND', sqlerrm;
    end if;
  end;

  begin
    perform public.admin_delete_voucher_v1(v_id, '   ');
    raise exception 'FAIL CLOSED: a blank reason was accepted for delete';
  exception when others then
    if sqlerrm not like 'REASON_REQUIRED%' then
      raise exception 'FAIL CLOSED: blank reason raised "%", expected REASON_REQUIRED', sqlerrm;
    end if;
  end;

  ----------------------------------------------------------------- 8. audit trail
  -- One event per mutation, same transaction, and the delete payload carries the code.
  select count(*) into v_n from public.events e
   where e.aggregate_type = 'voucher'
     and e.aggregate_id = v_id
     and e.type in ('voucher.updated','voucher.deleted','voucher.restored');
  if v_n <> 3 then
    raise exception
      'FAIL CLOSED: expected updated+deleted+restored = 3 audit rows for the voucher, got %', v_n;
  end if;

  if not exists (select 1 from public.events e
                  where e.aggregate_id = v_id and e.type = 'voucher.deleted'
                    and e.payload->>'code' = 'EDITME'
                    and e.payload->>'reason' = 'superseded campaign') then
    raise exception 'FAIL CLOSED: the delete event does not carry the code and reason';
  end if;

  ----------------------------------------------------------------- rollback
  raise exception 'ROLLBACK_PROBE';
exception when others then
  if sqlerrm <> 'ROLLBACK_PROBE' then
    raise;
  end if;
end;
$probe$;