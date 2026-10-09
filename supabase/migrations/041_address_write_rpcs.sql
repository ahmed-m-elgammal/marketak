-- 041: address write RPCs.
--
-- ## The gap this closes
--
-- Checkout has never been completable. `private.compute_quote` requires `p_address_id` and
-- resolves it as:
--
--   select * into v_addr from public.addresses a
--    where a.id = p_address_id and a.user_id = v_user and a.deleted_at is null;
--   if not found then
--     perform private.err('ADDRESS_NOT_FOUND', 'address not found');
--   end if;
--
--   -- constitution 7: the entire fee falls out of this row.
--   select * into v_zone from public.delivery_zones z
--    where z.area_id = v_addr.area_id and z.is_active;
--   if not found then
--     perform private.err('NO_DELIVERY_ZONE', 'no active delivery zone covers this address');
--   end if;
--
-- and `place_order_v1` copies `v_cart.quote_address_id` into `orders.address_id` and snapshots
-- its columns. So an `addresses` row is on the critical path of the entire revenue flow.
--
-- Yet `authenticated` holds SELECT on `addresses` and nothing else:
--
--   has_table_privilege('authenticated','public.addresses','INSERT') = false
--   has_table_privilege('authenticated','public.addresses','UPDATE') = false
--
-- and no function in the database inserted into it. `complete_profile_v1` even reports
-- `has_address`, a flag nothing can set true. The single seeded row was created by an admin
-- script, not by any client path.
--
-- ## What this migration adds
--
--   1. `private.geohash_encode` - there was no geohash encoder anywhere in the database
--   2. `public.upsert_my_address_v1` - create or amend one of the caller's addresses
--   3. `public.list_my_addresses_v1` - the caller's address book, for the checkout picker
--   4. `public.set_default_address_v1` - promote one address, demoting the rest
--   5. `public.delete_address_v1` - soft delete, so a deleted address drops out of quoting
--   6. `EXECUTE` grants, the revokes that must precede them, and a compile probe per function
--
-- ## Why a geohash encoder had to be written
--
-- `addresses.geohash` and `addresses.geohash_prefix` are both `NOT NULL` with no default, and
-- `areas.geohash_prefix` is how an address is matched to a delivery zone. Nothing could write a
-- row without a hash, so an encoder was unavoidable - and the alternative, accepting a
-- client-supplied geohash, would put a money-path identifier under client control.
--
-- The encoder is verified against the canonical geohash vector, which is not a property I can
-- assert from memory but is reproducible:
--
--   private.geohash_encode(57.64911, 10.40744, 7) = 'u4pruyd'   -- published vector
--   private.geohash_encode(0, 0, 7)                 = 's00000...' -- null island
--
-- ## A real bug this found in the seed data
--
-- Every geohash in the database is the published example vector, not a hash of the coordinates
-- it sits next to. The live area is centred on Cairo (30.0444, 31.2357) but carries
-- `geohash_prefix = 'u4pr'`, which is the vector for 57.64911, 10.40744. The seeded address is
-- the same, and both seeded vendors share it.
--
--   areas_bad_prefix     = 1   (of 1)
--   vendors_bad_prefix   = 2
--   addresses_bad_prefix = 1
--
-- It is currently harmless because no function filters on geohash equality: the three functions
-- that mention the column either write it (`admin_upsert_area_v1`, `admin_upsert_vendor_v1`) or
-- copy it into the order snapshot (`place_order_v1`). Area-to-zone matching goes through
-- `addresses.area_id` -> `delivery_zones.area_id`, never through the hash. So the wrong value
-- is inert, and this migration does NOT rewrite existing rows - correcting seed data is a
-- separate decision, and the correct values depend on areas the operator has not defined yet.
--
-- New rows written by this migration carry a true hash, computed here and never taken from the
-- client. If a future feature filters on `geohash_prefix`, the existing rows must be recomputed
-- first; that is recorded in specs-mobile/README.md rather than silently fixed here.
--
-- ## Why the area is validated but not trusted
--
-- `p_area_id` is resolved through a live `areas` row, because that row is what
-- `delivery_zones` joins on. But the coordinates are not required to fall inside that area's
-- radius. An area is a service region, and the server has no basis to override a shopper's
-- pin: a legitimately long walk, a new subdivision, or a landmark the radius understates are
-- all real. The area decides which fee table applies; the pin decides where the rider goes.
-- Making the radius authoritative would reject valid addresses silently, and the shopper would
-- have no way to correct it.
--
-- What IS enforced is that `p_area_id` names a live area, and that an active delivery zone
-- covers it. A shopper outside the launch city must be told, at address-entry time, rather than
-- discovering it at checkout as `NO_DELIVERY_ZONE`.
--
-- ## What this deliberately does NOT do
--
--   * No geocoding. `lat`/`lng` arrive from the device's map picker; the server does not resolve
--     an address string to coordinates. Reverse geocoding is a paid third-party dependency and
--     is not required by anything in this schema.
--   * No `is_default` handling in the upsert. Promotion is a separate function so that the
--     "one default per user" index (`addresses_one_default`) has exactly one writer, instead of
--     two functions that must agree on the same demotion rule.
--   * No address count limit. The constitution bounds cart quantity, not the address book, and
--     inventing a cap here would be a business rule nobody approved.
--   * `area_name` is derived from `areas.name`, never taken from the client, because
--     `place_order_v1` copies it into `orders.address_snapshot` and it is shopper-visible text.
--
-- ## The one-default rule
--
-- `addresses_one_default` is `unique (user_id) where is_default and deleted_at is null`. The
-- first address a shopper saves becomes the default automatically, because a shopper with
-- addresses but no default cannot be given a pre-selected address at checkout, and the app would
-- have to invent a choice. Explicit promotion afterwards goes through `set_default_address_v1`,
-- which demotes the incumbent in the same transaction, so the partial unique index is never
-- momentarily violated and never has to be caught.

-- ---------------------------------------------------------------------------
-- 1. geohash encoder
-- ---------------------------------------------------------------------------
-- Standard base-32 geohash. Immutable, no table access, safe to call from anything.
--
-- The `>=` comparison on the midpoint is load-bearing. Treating the midpoint as belonging to
-- the lower half is the classic off-by-one, and it is invisible except at exact boundaries: it
-- makes geohash_encode(0, 0, 5) return '7zzzz' instead of 's0000'. Null island is the cheapest
-- possible test of it, which is why it is asserted at the bottom of this file.
create or replace function private.geohash_encode(
  p_lat        numeric,
  p_lng        numeric,
  p_precision  integer default 7
)
returns text
language plpgsql
immutable
set search_path to ''
as $$
declare
  v_alphabet constant text := '0123456789bcdefghjkmnpqrstuvwxyz';
  v_lat_lo   numeric := -90;
  v_lat_hi   numeric := 90;
  v_lng_lo   numeric := -180;
  v_lng_hi   numeric := 180;
  v_even     boolean := true;
  v_mid      numeric;
  v_bit      integer;
  v_char     integer := 0;
  v_bits     integer := 0;
  v_out      text := '';
  v_i        integer;
begin
  if p_lat is null or p_lat < -90 or p_lat > 90
     or p_lng is null or p_lng < -180 or p_lng > 180 then
    raise exception 'geohash: coordinate out of range';
  end if;

  -- Longitude first, then latitude, alternating, five bits to a character.
  for v_i in 1 .. greatest(coalesce(p_precision, 7), 1) * 5 loop
    if v_even then
      v_mid := (v_lng_lo + v_lng_hi) / 2;
      if p_lng >= v_mid then v_bit := 1; v_lng_lo := v_mid; else v_bit := 0; v_lng_hi := v_mid; end if;
    else
      v_mid := (v_lat_lo + v_lat_hi) / 2;
      if p_lat >= v_mid then v_bit := 1; v_lat_lo := v_mid; else v_bit := 0; v_lat_hi := v_mid; end if;
    end if;
    v_even := not v_even;

    v_char := v_char * 2 + v_bit;
    v_bits := v_bits + 1;

    if v_bits = 5 then
      v_out := v_out || substr(v_alphabet, v_char + 1, 1);
      v_char := 0;
      v_bits := 0;
    end if;
  end loop;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. create or amend one of the caller's addresses
-- ---------------------------------------------------------------------------
-- Patch shape, not a column list, for the same reason `admin_upsert_area_v1` is: a screen
-- submits only the fields the shopper changed, and an unknown key must be a named error rather
-- than a silently ignored typo.
--
-- Returns the full row so the caller can render the saved address without a second round trip.
create or replace function public.upsert_my_address_v1(
  p_patch jsonb,
  p_id    uuid default null
)
returns public.addresses
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user       uuid := (select auth.uid());
  v_allowed    constant text[] := array[
    'label','area_id','latitude','longitude','area_name',
    'building','floor','apartment','landmark','delivery_instructions'
  ];
  v_unknown    text;
  v_row        public.addresses%rowtype;
  v_area       public.areas%rowtype;
  v_lat        numeric;
  v_lng        numeric;
  v_area_id    uuid;
  v_label      text;
  v_building   text;
  v_floor      text;
  v_apartment  text;
  v_landmark   text;
  v_instructions text;
  v_count      integer;
  v_result     public.addresses;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k)
    into v_unknown
    from jsonb_object_keys(p_patch) as k
   where not (k = any (v_allowed));

  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not an addresses column: ' || v_unknown);
  end if;

  -- Coordinates default to the existing row's, so a partial patch that only edits the apartment
  -- does not need to resend the pin. On insert they are required, and saying so explicitly beats
  -- letting a NOT NULL violation surface as 23502.
  if p_id is not null then
    select * into v_row
      from public.addresses a
     where a.id = p_id
       and a.user_id = v_user
       and a.deleted_at is null;

    if not found then
      perform private.err('ADDRESS_NOT_FOUND', 'no such address');
    end if;
  end if;

  v_lat     := coalesce((p_patch ->> 'latitude')::numeric,  v_row.latitude);
  v_lng     := coalesce((p_patch ->> 'longitude')::numeric, v_row.longitude);
  v_area_id := coalesce((p_patch ->> 'area_id')::uuid,       v_row.area_id);
  -- The trailing 'home' is not a redundant default. `addresses.label` is NOT NULL DEFAULT 'home',
  -- but a column default only applies when the column is omitted from the INSERT, and this
  -- function always supplies it. Without the third argument an insert that omits `label` would
  -- write NULL and fail 23502 instead of defaulting.
  v_label   := coalesce(p_patch ->> 'label',                 v_row.label, 'home');

  if v_lat is null or v_lng is null then
    perform private.err('ADDRESS_COORDS_REQUIRED', 'a pin on the map is required');
  end if;

  -- Checked here rather than left to the column types, so the shopper gets a code the app can
  -- map to a message instead of a raw 22003 numeric overflow.
  if v_lat < -90 or v_lat > 90 or v_lng < -180 or v_lng > 180 then
    perform private.err('ADDRESS_COORDS_INVALID', 'that pin is outside the world');
  end if;

  if v_label not in ('home', 'work', 'other') then
    perform private.err('ADDRESS_LABEL_INVALID', 'label must be home, work or other');
  end if;

  if v_area_id is null then
    perform private.err('AREA_REQUIRED', 'choose the area you are in');
  end if;

  -- The area decides the fee table, so it must be real and live.
  select * into v_area
    from public.areas a
   where a.id = v_area_id
     and a.is_active
     and a.deleted_at is null;

  if not found then
    perform private.err('AREA_UNAVAILABLE', 'that area is not served');
  end if;

  -- An area with no active zone cannot be quoted at all. Surfacing it here means the shopper
  -- hears it while choosing an area, not as a failed checkout.
  if not exists (select 1 from public.delivery_zones z
                  where z.area_id = v_area_id and z.is_active) then
    perform private.err('NO_DELIVERY_ZONE', 'no active delivery zone covers this area');
  end if;

  v_building    := coalesce(p_patch ->> 'building',    v_row.building);
  v_floor       := coalesce(p_patch ->> 'floor',       v_row.floor);
  v_apartment   := coalesce(p_patch ->> 'apartment',   v_row.apartment);
  v_landmark    := coalesce(p_patch ->> 'landmark',    v_row.landmark);
  v_instructions := coalesce(p_patch ->> 'delivery_instructions', v_row.delivery_instructions);

  -- A first address is the default by construction: a shopper with an address book but no
  -- default has nothing for checkout to pre-select.
  select count(*) into v_count
    from public.addresses a
   where a.user_id = v_user
     and a.deleted_at is null;

  if p_id is null then
    insert into public.addresses (
      user_id, label, area_id, geohash, geohash_prefix,
      latitude, longitude, area_name,
      building, floor, apartment, landmark, delivery_instructions,
      is_default
    )
    values (
      v_user, v_label, v_area_id,
      private.geohash_encode(v_lat, v_lng, 7),
      private.geohash_encode(v_lat, v_lng, 4),
      v_lat, v_lng, v_area.name,
      v_building, v_floor, v_apartment, v_landmark, v_instructions,
      v_count = 0
    )
    returning * into v_result;
  else
    update public.addresses a
       set label        = v_label,
           area_id      = v_area_id,
           geohash      = private.geohash_encode(v_lat, v_lng, 7),
           geohash_prefix = private.geohash_encode(v_lat, v_lng, 4),
           latitude     = v_lat,
           longitude    = v_lng,
           area_name    = v_area.name,
           building     = v_building,
           floor        = v_floor,
           apartment    = v_apartment,
           landmark     = v_landmark,
           delivery_instructions = v_instructions
     where a.id = p_id
       and a.user_id = v_user
       and a.deleted_at is null
    returning * into v_result;
  end if;

  -- II.16: events carries no actor column, so the actor lives in the payload, as in 016.
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values (
    case when p_id is null then 'address.created' else 'address.updated' end,
    'address', v_result.id,
    jsonb_build_object('actor', v_user, 'area_id', v_area_id, 'fields',
                       (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k))
  );

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. the caller's address book
-- ---------------------------------------------------------------------------
-- Default first, then most recently used. The UI renders this list directly, so the ordering is
-- part of the contract rather than a presentation detail.
create or replace function public.list_my_addresses_v1()
returns setof public.addresses
language plpgsql
security definer
set search_path to ''
as $$
begin
  if (select auth.uid()) is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  return query
    select a.*
      from public.addresses a
     where a.user_id = (select auth.uid())
       and a.deleted_at is null
     order by a.is_default desc, a.last_used_at desc nulls last, a.created_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. promote one address to default
-- ---------------------------------------------------------------------------
-- Demotion and promotion happen in one statement so `addresses_one_default` is never violated
-- even momentarily, and never needs an exception handler to recover from.
--
-- The first address promotes itself, which means a shopper can never be left with no default by
-- deleting or demoting the only one.
create or replace function public.set_default_address_v1(
  p_id uuid
)
returns public.addresses
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user   uuid := (select auth.uid());
  v_result public.addresses;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_id is null then
    perform private.err('ADDRESS_REQUIRED', 'an address must be named');
  end if;

  if not exists (select 1 from public.addresses a
                   where a.id = p_id
                     and a.user_id = v_user
                     and a.deleted_at is null) then
    perform private.err('ADDRESS_NOT_FOUND', 'no such address');
  end if;

  update public.addresses a
     set is_default = false
   where a.user_id = v_user
     and a.is_default
     and a.deleted_at is null
     and a.id <> p_id;

  update public.addresses a
     set is_default = true
   where a.id = p_id
     and a.user_id = v_user
     and a.deleted_at is null
  returning * into v_result;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('address.default_changed', 'address', p_id,
          jsonb_build_object('actor', v_user));

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. soft delete
-- ---------------------------------------------------------------------------
-- Soft, not hard: `addresses` has `deleted_at`, and `orders.address_snapshot` is a copy taken at
-- checkout time, so removing the row would not remove it from order history anyway. Soft delete
-- also means the address drops out of `compute_quote` without touching any order that used it.
create or replace function public.delete_address_v1(
  p_id uuid
)
returns boolean
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user     uuid := (select auth.uid());
  v_remaining integer;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_id is null then
    perform private.err('ADDRESS_REQUIRED', 'an address must be named');
  end if;

  -- `is_default` is cleared in the same statement as the delete, and this is not cosmetic.
  -- `addresses_one_default` is `unique (user_id) where is_default and deleted_at is null`, so a
  -- soft-deleted row still holding `is_default = true` keeps a slot in that index forever. It does
  -- not break the uniqueness itself - deleted rows are excluded - but it makes "does this shopper
  -- have a live default?" unanswerable from the row itself, and a shopper who deletes and
  -- re-adds an address ends up with two rows marked default. Clearing both flags together keeps
  -- the row's meaning unambiguous: a default address is a live default address.
  update public.addresses a
     set deleted_at = now(),
         is_default = false
   where a.id = p_id
     and a.user_id = v_user
     and a.deleted_at is null;

  if not found then
    perform private.err('ADDRESS_NOT_FOUND', 'no such address');
  end if;

  -- Never leave the shopper with an address book and no default. Promote the most recently used
  -- survivor, which is the one the app would have pre-selected anyway.
  --
  -- The `not exists` guard is what makes this idempotent: deleting a non-default address leaves
  -- the incumbent default alone and promotes nothing.
  select count(*) into v_remaining
    from public.addresses a
   where a.user_id = v_user
     and a.deleted_at is null;

  if v_remaining > 0 and not exists (
       select 1 from public.addresses a
        where a.user_id = v_user
          and a.is_default
          and a.deleted_at is null) then
    update public.addresses a
       set is_default = true
     where a.id = (
       select a2.id from public.addresses a2
        where a2.user_id = v_user
          and a2.deleted_at is null
        order by a2.last_used_at desc nulls last, a2.created_at
        limit 1);
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('address.deleted', 'address', p_id,
          jsonb_build_object('actor', v_user));

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. grants
-- ---------------------------------------------------------------------------
-- Functions are executable by PUBLIC by default. `anon` must hold nothing at all and
-- `authenticated` exactly these four, so the default is revoked before the grant is made.
-- Ordering matters: revoking after granting would undo the grant.
revoke all on function private.geohash_encode(numeric, numeric, integer) from public, anon;

revoke all on function public.upsert_my_address_v1(jsonb, uuid)  from public, anon;
revoke all on function public.list_my_addresses_v1()             from public, anon;
revoke all on function public.set_default_address_v1(uuid)        from public, anon;
revoke all on function public.delete_address_v1(uuid)             from public, anon;

grant execute on function public.upsert_my_address_v1(jsonb, uuid)  to authenticated;
grant execute on function public.list_my_addresses_v1()             to authenticated;
grant execute on function public.set_default_address_v1(uuid)        to authenticated;
grant execute on function public.delete_address_v1(uuid)             to authenticated;

-- ---------------------------------------------------------------------------
-- 7. compile probe and geohash assertions
-- ---------------------------------------------------------------------------
-- Repo rule: every migration touching a plpgsql function ends with a call to it, because Postgres
-- validates a function body lazily and a migration that applied cleanly can still ship a
-- function that cannot run. A migration session carries no JWT, so `auth.uid()` is null and the
-- expected outcome is AUTH_REQUIRED - which proves the body parsed, ran, and reached its own gate.

do $$
begin
  perform public.upsert_my_address_v1('{}'::jsonb, null);
  raise exception 'PROBE FAILED: upsert_my_address_v1 ran without a session';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for upsert_my_address_v1: %', sqlerrm;
    end if;
end $$;

do $$
begin
  perform public.list_my_addresses_v1();
  raise exception 'PROBE FAILED: list_my_addresses_v1 ran without a session';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for list_my_addresses_v1: %', sqlerrm;
    end if;
end $$;

do $$
begin
  perform public.set_default_address_v1(gen_random_uuid());
  raise exception 'PROBE FAILED: set_default_address_v1 ran without a session';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for set_default_address_v1: %', sqlerrm;
    end if;
end $$;

do $$
begin
  perform public.delete_address_v1(gen_random_uuid());
  raise exception 'PROBE FAILED: delete_address_v1 ran without a session';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for delete_address_v1: %', sqlerrm;
    end if;
end $$;

-- The encoder is new infrastructure on a money-path identifier, so it is asserted against the
-- published geohash vector and against null island. The null-island case is not decoration: it
-- is the cheapest detector of the midpoint off-by-one that `>=` exists to prevent, and a
-- regression there would silently shift every boundary by one cell.
do $$
begin
  if private.geohash_encode(57.64911, 10.40744, 7) <> 'u4pruyd' then
    raise exception 'PROBE FAILED: geohash_encode disagrees with the published vector';
  end if;

  if private.geohash_encode(0, 0, 7) <> 's000000' then
    raise exception 'PROBE FAILED: geohash_encode mishandles the midpoint boundary';
  end if;

  if private.geohash_encode(51.5074, -0.1278, 5) <> 'gcpvj' then
    raise exception 'PROBE FAILED: geohash_encode disagrees on a known city';
  end if;
end $$;
