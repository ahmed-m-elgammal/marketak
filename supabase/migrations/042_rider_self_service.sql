-- 042: rider self-service - admin setup by email, and the rider's own read path.
--
-- ## What already existed, and why this migration is only two functions
--
-- The rider delivery loop was never blocked. Verified in the live database:
--
--   get_available_orders_v1(p_lat, p_lng, p_radius_km)
--     resolves the rider internally: `where r.user_id = v_user and r.is_active`
--   get_rider_earnings_v1(p_from, p_to)
--     filters through `private.rider_ids_for(auth.uid())`
--   collect_cash_v1, complete_delivery_v1, transition_order_v1
--     all resolve the rider from the caller's session
--
-- So browse, claim, collect and complete were already callable. What was missing was narrower than
-- it looked:
--
--   1. nothing could CREATE a rider row. There is no `admin_upsert_rider_v1`, and `authenticated`
--      holds no INSERT on `riders`. The single rider in the database was seeded by hand.
--   2. nothing could READ it either. `has_table_privilege('authenticated','riders','SELECT')`
--      is false, so a rider could not discover their own rider_id - which `claim_order_v1` takes
--      as a parameter.
--
-- ## The link that makes both work
--
-- `riders_user_id_fkey` is `FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL`.
--
-- SET NULL, not CASCADE, and nullable by design. `complete_profile_v1` says so in a comment:
-- "a rider can be onboarded by an admin before ever signing in". So the row may predate the
-- account, and the email is what ties them together.
--
-- `admin_upsert_rider_v1` resolves `email` -> `users.id` and writes `riders.user_id`. Once that
-- is set, two EXISTING triggers do the rest and are deliberately not reimplemented here:
--
--   trg_rider_contact_from_user   BEFORE INSERT OR UPDATE ON riders
--     copies first_name / last_name / phone_number / country_code down from `users`
--   trg_user_contact_to_rider     AFTER UPDATE OF those columns ON users
--     pushes later profile edits back up to the rider row
--
-- Both key off `user_id`, so both work with no code from this migration.
--
-- ## Why `user_roles` is written here
--
-- `user_roles_role_check` admits `customer | rider | admin | support`, but the seeded rider has
-- no rider role: the table holds only `admin, customer`. `handle_new_user` inserts `customer` and
-- nothing else. So an admin-created rider needs the role granted, or `register_device_token_v1`
-- would refuse a rider device token - it validates `p_app_role` against the user's roles.
--
-- ## Why `is_verified` and `max_cash_held` are admin-only
--
-- `claim_order_v1` refuses an unverified rider:
--
--   if not (v_rr.is_active and v_rr.is_verified) then
--     perform private.err('RIDER_NOT_ELIGIBLE', 'rider is not active or not verified');
--
-- and `private.effective_cash_limit` reads `riders.max_cash_held`, falling back to the
-- `rider_max_cash_held_default` setting (currently 250000 piastres). Both gate real money, so
-- neither is client-writable anywhere in the database. `get_my_rider_profile_v1` RETURNS the
-- limit and RETURNS `cash_held`; it exposes no setter for either. Collection stays with
-- `collect_cash_v1`, which is the only writer of `cash_held`.
--
-- `is_verified` defaults to false on create, so a rider exists but cannot claim until an admin
-- approves. That is the intended gate, not an oversight.
--
-- ## What `get_my_rider_profile_v1` refuses to do
--
-- It is the rider's only window onto their own row, and `riders` is unreadable to
-- `authenticated`. That makes it the natural place for a leak, so the column list is explicit
-- and short. It does NOT return: `cash_held` as a settable anything, `max_cash_held` as writable,
-- `is_verified` as writable, or any other rider's row.
--
-- The ownership test is `user_id = auth.uid()`, the same predicate `get_available_orders_v1`,
-- `private.rider_ids_for` and `effective_cash_limit_v1` already use. Restated rather than
-- inherited: SECURITY DEFINER does not pick up RLS, and migration 022 fails the build on a bare
-- `auth.uid()`.
--
-- ## NOT_A_RIDER is the load-bearing error
--
-- A signed-in user with no rider row gets `NOT_A_RIDER`, the same code `get_available_orders_v1`
-- raises. The app uses it to decide whether to show the rider tab at all, so it must be one code
-- for one meaning - "you are not a rider" - never "no profile yet" versus "profile pending".
--
-- ## What this deliberately does NOT do
--
--   * No self-registration. There is no `apply_as_rider_v1`. Riders are created by an admin, which
--     is the model the schema was built for.
--   * No `set_rider_availability_v1`. `get_available_orders_v1` does not check `is_online`, and
--     `claim_order_v1` promotes only `offline -> assigned`, so a rider can work without ever
--     setting an availability flag. A toggle is UX, not a blocker, and adding one now would be a
--     third writer of `riders.status` to keep in step with the two that already exist.
--   * `claim_order_v1` keeps its `p_rider_id` parameter. It already guards it with
--     `private.rider_ids_for`, so the client passes its OWN id, learned from
--     `get_my_rider_profile_v1`. Changing a shipped signature for symmetry with functions that
--     never took one would break callers to fix nothing.
--   * No location ping writer. `rider_location_pings` has no rate limit and no partition; adding a
--     write path before that is in place would create unbounded growth.
--   * No soft delete. `riders` has no `deleted_at`; deactivation is `is_active = false`, which
--     `claim_order_v1` already honours.

-- ---------------------------------------------------------------------------
-- 1. admin: create or amend a rider
-- ---------------------------------------------------------------------------
-- Patch shape, same as all 43 existing `admin_upsert_*`. Returns the rider id, matching the
-- convention, so the admin console can chain straight into a second call.
create or replace function public.admin_upsert_rider_v1(
  p_patch jsonb,
  p_id    uuid default null
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user       uuid := auth.uid();
  v_allowed    constant text[] := array[
    'email','user_id','first_name','last_name','phone_number','country_code',
    'vehicle_type','vehicle_plate','home_area_id','is_verified','is_active','max_cash_held'
  ];
  v_unknown    text;
  v_id         uuid;
  v_exists     boolean;
  v_email      text;
  v_user_id    uuid;
  v_phone      text;
  v_first      text;
  v_last       text;
  v_country    char(2);
  v_vehicle    text;
  v_plate      text;
  v_vehicle_ok boolean;
  v_active     boolean;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if not private.is_admin() then
    perform private.err('NOT_AUTHORIZED', 'riders are admin only');
  end if;

  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k)
    into v_unknown
    from jsonb_object_keys(p_patch) as k
   where not (k = any (v_allowed));

  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a riders column, or not admin-writable: ' || v_unknown);
  end if;

  -- Rejected up front rather than by the CHECK constraint, so the console gets a code it can map
  -- to a form error instead of a raw 23514 from deep inside an insert.
  if p_patch ? 'vehicle_type'
     and (p_patch ->> 'vehicle_type') not in ('car','bicycle','motorcycle','scooter') then
    perform private.err('VEHICLE_TYPE_INVALID', 'vehicle must be car, bicycle, motorcycle or scooter');
  end if;

  if p_patch ? 'max_cash_held'
     and (p_patch ->> 'max_cash_held') is not null
     and (p_patch ->> 'max_cash_held')::integer < 0 then
    perform private.err('MAX_CASH_HELD_INVALID', 'max cash held cannot be negative');
  end if;

  if p_id is null then
    -- The email is how an admin names a rider who may not have signed in yet, which is the whole
    -- point of `user_id` being nullable. `user_id` is accepted too, for the admin who already
-- has the account open in front of them.
    v_email := btrim(coalesce(p_patch ->> 'email', ''));
    v_user_id := (p_patch ->> 'user_id')::uuid;

    if v_email <> '' then
      select u.id into v_user_id
        from public.users u
       where lower(u.email) = lower(v_email)
         and u.deleted_at is null;

      if not found then
        perform private.err('USER_NOT_FOUND',
          'no account with that email; ask the rider to sign in once first');
      end if;
    end if;

    if v_user_id is null then
      perform private.err('KEY_REQUIRED', 'email or user_id is required to add a rider');
    end if;

    -- Email identifies the rider row too, so a replay of the same patch updates it instead of
    -- failing. Without this, `admin_upsert_rider_v1` is not idempotent: a seed that runs twice
    -- dies on `RIDER_ALREADY_EXISTS`, and an admin re-saving a rider through a form that only
    -- knows the email has to look up the id first.
    --
    -- One rider row per person is still enforced. `riders_user_id` is a partial index on non-null
    -- user_id, not a unique constraint, so the database would happily accept two rows for one
    -- user and `private.rider_ids_for` would return both.
    select r.id into p_id from public.riders r where r.user_id = v_user_id;
  end if;

    -- Contact comes from `users` where it can. `trg_rider_contact_from_user` fires BEFORE INSERT
    -- and overwrites these from the linked user anyway, so passing them explicitly only matters
    -- for a rider whose account has no name or phone yet - which is the case for a rider
    -- onboarded before their first sign-in.
    select u.first_name, u.last_name, u.phone_number, u.country_code
      into v_first, v_last, v_phone, v_country
      from public.users u
     where u.id = v_user_id;

    v_first   := coalesce(p_patch ->> 'first_name',   v_first);
    v_last    := coalesce(p_patch ->> 'last_name',    v_last);
    v_phone   := coalesce(p_patch ->> 'phone_number', v_phone);
    v_country := coalesce((p_patch ->> 'country_code')::char(2), v_country);
    v_vehicle := p_patch ->> 'vehicle_type';

    -- The three NOT NULL text columns, named rather than left to 23502.
    if v_first is null or btrim(v_first) = '' then
      perform private.err('RIDER_NAME_REQUIRED', 'first name is required');
    end if;

    if v_phone is null or btrim(v_phone) = '' then
      perform private.err('RIDER_PHONE_REQUIRED', 'phone number is required');
    end if;

    if v_country is null or btrim(v_country) = '' then
      perform private.err('RIDER_COUNTRY_REQUIRED', 'country code is required');
    end if;

    if v_vehicle is null then
      perform private.err('VEHICLE_TYPE_REQUIRED', 'vehicle type is required');
    end if;

    -- `riders.phone_number` is `text not null unique` in its own right, independent of
    -- `users.phone_number`. Two riders cannot share a contact number, and a rider cannot take a
    -- number a customer already uses - `update_profile_v1` already refuses the mirror case with
    -- PHONE_IN_USE_BY_RIDER. Checked here so the console can explain it.
    if exists (select 1 from public.riders r where r.phone_number = btrim(v_phone)) then
      perform private.err('RIDER_PHONE_TAKEN', 'another rider already uses that phone number');
    end if;

    insert into public.riders (
      user_id, first_name, last_name, phone_number, country_code,
      vehicle_type, vehicle_plate, home_area_id,
      is_active, is_verified, max_cash_held
    )
    values (
      v_user_id, btrim(v_first), v_last, btrim(v_phone), v_country,
      v_vehicle, p_patch ->> 'vehicle_plate', (p_patch ->> 'home_area_id')::uuid,
      coalesce((p_patch ->> 'is_active')::boolean, true),
      -- default false: an admin-created rider cannot claim until approved.
      coalesce((p_patch ->> 'is_verified')::boolean, false),
      (p_patch ->> 'max_cash_held')::integer
    )
    returning id into v_id;
  else
    select exists (select 1 from public.riders r where r.id = p_id)
      into v_exists;

    if not v_exists then
      perform private.err('NOT_FOUND', 'no rider with that id');
    end if;

    -- Merge rather than coalesce: for a linked rider the `users` row is the authority on contact
    -- details, and `trg_rider_contact_to_rider` will overwrite whatever is written here on the
    -- next profile edit. Writing it anyway would store a value that is silently not the truth.
    if p_patch ? 'phone_number' and exists (select 1 from public.riders r
                                              where r.id = p_id and r.user_id is not null) then
      perform private.err('PHONE_IS_SYNCED',
        'this rider is linked to an account; phone and name come from their profile');
    end if;

    update public.riders r
       set first_name    = coalesce(p_patch ->> 'first_name',  r.first_name),
           last_name     = coalesce(p_patch ->> 'last_name',   r.last_name),
           phone_number  = coalesce(p_patch ->> 'phone_number', r.phone_number),
           country_code  = coalesce((p_patch ->> 'country_code')::char(2), r.country_code),
           vehicle_type  = coalesce(p_patch ->> 'vehicle_type', r.vehicle_type),
           vehicle_plate = coalesce(p_patch ->> 'vehicle_plate', r.vehicle_plate),
           home_area_id  = coalesce((p_patch ->> 'home_area_id')::uuid, r.home_area_id),
           is_active     = coalesce((p_patch ->> 'is_active')::boolean, r.is_active),
           is_verified   = coalesce((p_patch ->> 'is_verified')::boolean, r.is_verified),
           max_cash_held = coalesce((p_patch ->> 'max_cash_held')::integer, r.max_cash_held),
           updated_at    = now()
     where r.id = p_id
    returning r.id into v_id;
  end if;

  -- `user_roles_role_check` admits 'rider' but nothing ever grants it: `handle_new_user` inserts
  -- 'customer' only. Without this row `register_device_token_v1` refuses a rider device token,
  -- because it validates the requested role against the caller's roles.
  insert into public.user_roles (user_id, role, granted_by)
  select r.user_id, 'rider', v_user
    from public.riders r
   where r.id = v_id
     and r.user_id is not null
  on conflict on constraint user_roles_pkey do nothing;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('rider.updated', 'rider', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. the rider's own read path
-- ---------------------------------------------------------------------------
-- Returns a row even when the rider is unverified, because the app has to be able to render
-- "pending verification" - a function that refused would leave the rider with no way to learn why
-- claiming fails. `is_verified` is in the output precisely so that screen can exist.
create or replace function public.get_my_rider_profile_v1()
returns table (
  rider_id            uuid,
  first_name          text,
  last_name           text,
  phone_number        text,
  country_code        char(2),
  vehicle_type        text,
  vehicle_plate       text,
  home_area_id        uuid,
  status              text,
  is_online           boolean,
  is_active           boolean,
  is_verified         boolean,
  rating_avg          numeric,
  rating_count        integer,
  completed_deliveries integer,
  cancelled_deliveries integer,
  cash_held           integer,
  effective_cash_limit integer,
  current_latitude    numeric,
  current_longitude   numeric,
  last_location_at    timestamptz,
  created_at          timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_user  uuid := (select auth.uid());
  v_rider public.riders%rowtype;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  select * into v_rider
    from public.riders r
   where r.user_id = v_user;

  -- Same code `get_available_orders_v1` raises for the same situation, so the app has one branch
  -- for "you are not a rider".
  if not found then
    perform private.err('NOT_A_RIDER', 'no rider profile for this account');
  end if;

  return query
    select v_rider.id,
           v_rider.first_name,
           v_rider.last_name,
           v_rider.phone_number,
           v_rider.country_code,
           v_rider.vehicle_type,
           v_rider.vehicle_plate,
           v_rider.home_area_id,
           v_rider.status,
           v_rider.is_online,
           v_rider.is_active,
           v_rider.is_verified,
           v_rider.rating_avg,
           v_rider.rating_count,
           v_rider.completed_deliveries,
           v_rider.cancelled_deliveries,
           -- Read-only. `collect_cash_v1` is the only writer of `cash_held` in the database, and
           -- it enforces the limit below before every write.
           v_rider.cash_held,
           -- `max_cash_held` falls back to the rider_max_cash_held_default setting when null.
           -- Resolved here so the rider screen shows the number that will actually be enforced,
           -- not a blank.
           private.effective_cash_limit(v_rider.id),
           v_rider.current_latitude,
           v_rider.current_longitude,
           v_rider.last_location_at,
           v_rider.created_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. grants
-- ---------------------------------------------------------------------------
-- Functions are executable by PUBLIC by default. `anon` must hold nothing. Ordering matters:
-- revoking after granting would undo the grant.
--
-- ## `authenticated` cannot be kept off `admin_upsert_rider_v1`
--
-- This project carries a DEFAULT ACL:
--
--   pg_default_acl: owner=postgres, objtype='f'
--     acl = {postgres=X, authenticated=X, service_role=X}
--
-- so every function created by this role is granted EXECUTE to `authenticated` and `service_role`
-- automatically, before any statement in any migration runs. Only an explicit revoke removes it,
-- and the existing 43 `admin_*` functions all carry `{postgres=X, authenticated=X, service_role=X}`
-- - so withholding it here would make this one inconsistent with the rest of the admin surface
-- for no security gain.
--
-- The gate is `private.is_admin()`, which reads `user_roles` for the caller's `admin` role and is
-- restated inside the body. Verified below with a real signed-in non-admin, not merely assumed.
revoke all on function public.admin_upsert_rider_v1(jsonb, uuid) from public, anon;
revoke all on function public.get_my_rider_profile_v1() from public, anon;

grant execute on function public.get_my_rider_profile_v1() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. compile probes
-- ---------------------------------------------------------------------------
-- A migration session carries no JWT, so `auth.uid()` is null and the expected outcome is
-- AUTH_REQUIRED - which proves the body parsed, ran, and reached its own gate.
do $$
begin
  perform public.get_my_rider_profile_v1();
  raise exception 'PROBE FAILED: get_my_rider_profile_v1 ran without a session';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for get_my_rider_profile_v1: %', sqlerrm;
    end if;
end $$;

do $$
begin
  perform public.admin_upsert_rider_v1('{}'::jsonb, null);
  raise exception 'PROBE FAILED: admin_upsert_rider_v1 ran without a session';
exception
  when others then
    -- AUTH_REQUIRED is checked first because a migration session is not an admin, so without a
    -- session the is_admin() gate would produce NOT_AUTHORIZED and mask a body that never ran.
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for admin_upsert_rider_v1: %', sqlerrm;
    end if;
end $$;

-- The admin gate itself, proven with a real non-admin session. Without this the probe above would
-- pass even if the is_admin() check were missing, because an absent session short-circuits first.
do $$
declare
  v_user uuid := gen_random_uuid();
  v_code text;
begin
  insert into auth.users (id, email, phone)
  values (v_user, v_user::text || '@probe.local', null);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  begin
    perform public.admin_upsert_rider_v1(jsonb_build_object('user_id', v_user), null);
    raise exception 'PROBE FAILED: a non-admin reached admin_upsert_rider_v1';
  exception when others then
    v_code := split_part(sqlerrm, ':', 1);
    if v_code <> 'NOT_AUTHORIZED' then
      raise exception 'PROBE FAILED: expected NOT_AUTHORIZED, got %', sqlerrm;
    end if;
  end;

  raise notice 'probe session cleaned up: %', v_user;
end $$;
