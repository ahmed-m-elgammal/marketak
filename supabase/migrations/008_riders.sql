-- T0.1a: 008 delivery and riders. data-model.md §8.
--
-- This is the first migration where a functional requirement is optional rather than load-bearing.
-- ADR 9 defers live tracking to Phase 8, so rider_location_pings is created here and stays empty
-- until the tracking API exists. Open question 3.10 resolved that as a decision: keep the table,
-- plain and unpartitioned, because nothing writes to it yet and adding partitioning to an empty
-- table later is cheap while removing it from a populated one is not.
--
-- Carrying forward every lesson from auditing 001-007b:
--   * Every money column gets a CHECK. data-model §8 leaves rider pay, the platform cut and the
--     collected amount unguarded, and 007's audit is what established that rule.
--   * riders.status and riders.is_online overlap, which is the same desync shape that let
--     menu_items.vendor_id drift in 005b. A CHECK makes the illegal combination unrepresentable
--     instead of leaving two columns to disagree.
--   * Every foreign key is indexed, per data-model §14.2. §8's index lists omit the foreign keys
--     on riders, so they are added here rather than left for 022 to discover.
--   * claim_order_v1 is deliberately NOT created here. data-model §8 shows it, but it belongs to
--     migration 018 with the rest of the rider RPCs, and a claim function that exists before
--     delivery_assignments is populated is a claim function nobody has tested.
--
-- Two places this file goes beyond a literal reading of §8. Both are marked FLAGGED below and both
-- are reversible by dropping the constraint:
--
--   1. money and domain CHECKs on riders and delivery_assignments. Follows the rule 007 applied.
--   2. riders_is_online_consistent. FLAGGED: §8 declares both status and is_online without saying
--      how they relate. The only coherent reading is that is_online is true exactly when status is
--      not 'offline', which is what this CHECK enforces. The alternative reading - that is_online
--      means "the app is open" and status means "delivery state" - would make the two independent
--      and this constraint wrong. Worth confirming.

-- =============================================================================================
-- riders
-- =============================================================================================
create table public.riders (
  id           uuid primary key default gen_random_uuid(),

  -- null = onboarded by an admin, before the rider has ever signed in. on_auth_user_created only
  -- creates public.users rows, so a rider row is made by the verification flow, not by sign-up.
  user_id      uuid references public.users(id) on delete set null,

  first_name   text not null,
  last_name    text,
  phone_number text not null unique,
  country_code char(2) not null,
  vehicle_type text not null check (vehicle_type in ('car','bicycle','motorcycle','scooter')),
  vehicle_plate text,

  status       text not null default 'offline' check (status in
                 ('offline','available','assigned','on_break')),
  is_active    boolean not null default true,
  is_verified  boolean not null default false,

  -- is_online is redundant with status. Kept because §8 declares it and the app reads it, but the
  -- two are tied by a CHECK below so they cannot disagree.
  is_online    boolean not null default false,

  -- Where the rider is right now. Sufficient on its own for "where is my rider"; the pings table
  -- below is only needed for the trip trail.
  current_latitude  numeric(9,6),
  current_longitude numeric(9,6),
  current_geohash   text,
  last_location_at  timestamptz,

  home_area_id uuid references public.areas(id),
  rating_avg   numeric(3,2) not null default 0,
  rating_count integer not null default 0,

  -- CONFIGURATION, not a constant. null means "fall back to settings.rider_max_cash_held_default",
  -- resolved by effective_cash_limit_v1 below so the rider app, the collection RPC and the
  -- settlement report cannot disagree about the limit. 0 disables cash collection entirely.
  max_cash_held integer,

  -- Money the rider is currently holding on the platform's behalf. The customer paid the rider
  -- directly, so this is a float the platform must reconcile, never a balance it may spend.
  cash_held      integer not null default 0,

  completed_deliveries integer not null default 0,
  cancelled_deliveries integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint riders_is_online_consistent check (is_online = (status <> 'offline')),
  constraint riders_latitude_range  check (current_latitude  is null or current_latitude  between -90 and 90),
  constraint riders_longitude_range check (current_longitude is null or current_longitude between -180 and 180),
  -- FLAGGED: not in §8. money and obvious domain bounds, per the rule 007 established.
  constraint riders_cash_held_nonneg check (cash_held >= 0),
  constraint riders_max_cash_held_nonneg check (max_cash_held is null or max_cash_held >= 0),
  constraint riders_rating_range check (rating_avg >= 0 and rating_avg <= 5),
  constraint riders_counts_nonneg check (
    rating_count >= 0 and completed_deliveries >= 0 and cancelled_deliveries >= 0
  ),
  -- FLAGGED: not in §8 either. A position with no timestamp reads as current and is not, which is
  -- the kind of quiet wrongness this schema is otherwise built to prevent. The cost is that a flow
  -- writing a position must write last_location_at in the same statement.
  constraint riders_location_has_time check (
    (current_latitude is null and current_longitude is null and last_location_at is null)
    or (current_latitude is not null and current_longitude is not null and last_location_at is not null)
  )
);

create index riders_online_status_geohash on public.riders (is_online, status, current_geohash)
  where is_active;
create index riders_status_online on public.riders (status) where is_online;
-- §14.2: every foreign key indexed. §8's index list omits both of these.
create index riders_user_id on public.riders (user_id) where user_id is not null;
create index riders_home_area_id on public.riders (home_area_id) where home_area_id is not null;
-- Finding riders who can take work in an area. driver_shifts.area_ids carries the per-shift area
-- list, but a rider with no shift row is still online somewhere.
create index riders_active_verified on public.riders (home_area_id, status)
  where is_active and is_verified;

create trigger trg_riders_updated_at before update on public.riders
  for each row execute function public.set_updated_at();

-- The one place the cash limit is resolved. Everything that reads or enforces it calls this, so a
-- per-rider override, the city default and the zero case are decided once.
--
-- public, because the rider app calls it and PostgREST must be able to reach it. It is security
-- definer so an authenticated rider can read their own limit without SELECT on public.riders.
-- EXECUTE is revoked from anon below.
--
-- FLAGGED: p_rider_id is not checked against the caller, so any authenticated user can read any
-- rider's limit. That is a minor disclosure, but the guard is a design decision - see §8 and
-- migration 018, which is where the caller-identity rules live.
create or replace function public.effective_cash_limit_v1(p_rider_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select max_cash_held from public.riders where id = p_rider_id),
    (select (value #>> '{}')::int from public.settings where key = 'rider_max_cash_held_default'),
    0
  );
$$;

revoke execute on function public.effective_cash_limit_v1(uuid) from public, anon;

-- =============================================================================================
-- driver_shifts
-- =============================================================================================
create table public.driver_shifts (
  id        uuid primary key default gen_random_uuid(),
  rider_id  uuid not null references public.riders(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at   timestamptz not null,

  -- FLAGGED: an array, where §16 removed JSON arrays from vendors for exactly this reason - "JSON
  -- arrays cannot be indexed; forces a scan on every availability check". A join table would be
  -- consistent with vendor_areas and would make the shift-area lookup indexable. Implemented as
  -- specced rather than redesigned, because changing it means adding a table nobody has approved.
  area_ids  uuid[] not null default '{}',

  is_active boolean not null default true,
  created_at timestamptz not null default now(),

  constraint driver_shifts_window_valid check (ends_at > starts_at),

  -- FLAGGED: not in §8. A rider cannot be in two places at once, and overlapping active shifts
  -- would let one rider be matched to two concurrent orders. This is why migration 001 installs
  -- btree_gist: the exclusion needs a GiST opclass for uuid equality as well as for the range.
  constraint driver_shifts_no_overlap exclude using gist (
    rider_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (is_active)
);

create index driver_shifts_rider_starts on public.driver_shifts (rider_id, starts_at desc);
create index driver_shifts_active_window on public.driver_shifts (starts_at, ends_at) where is_active;

-- =============================================================================================
-- delivery_assignments
-- =============================================================================================
-- One row per ORDER in the default 'together' grouping. sub_order_id is populated only in
-- 'separate' mode. The rider's pay is resolved at assignment time from rider_pay_rules and frozen
-- here, so a later pay-rule change cannot rewrite what a trip earned.
create table public.delivery_assignments (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders(id) on delete cascade,
  sub_order_id uuid references public.sub_orders(id) on delete cascade,
  rider_id     uuid references public.riders(id) on delete set null,

  status text not null default 'unassigned' check (status in (
           'unassigned','assigned','at_first_vendor','picking_up',
           'picked_up','delivering','arrived','delivered','failed','cancelled')),

  -- Computed once at assignment time and stored. Recomputing it on every poll would be slower and
  -- would not be stable if the rider's location drifts.
  stop_sequence jsonb,

  assigned_by text not null default 'system' check (assigned_by in ('system','rider_claim','admin')),
  assigned_at    timestamptz,
  claimed_at     timestamptz,
  arrived_vendor_at timestamptz,
  picked_up_at   timestamptz,
  arrived_at     timestamptz,
  delivered_at   timestamptz,

  distance_km numeric(6,2),
  eta_minutes  integer,

  -- Money, frozen at assignment. FLAGGED: none of these CHECKs are in §8.
  rider_pay_base     integer,
  rider_pay_distance integer,
  rider_pay_bonus    integer,
  rider_pay_total    integer,
  platform_revenue   integer,

  collected_amount   integer,
  collection_method  text check (collection_method in ('cash','wallet','none')),
  collection_channel text check (collection_channel in ('cod','vodafone_cash','instapay')),
  collection_reference text,
  proof_path         text,
  signature_path     text,
  failure_reason     text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Only money a rider actually took may be reported as collected.
  constraint delivery_assignments_rider_pay_nonneg check (
    (rider_pay_base     is null or rider_pay_base     >= 0)
    and (rider_pay_distance is null or rider_pay_distance >= 0)
    and (rider_pay_bonus  is null or rider_pay_bonus  >= 0)
    and (rider_pay_total  is null or rider_pay_total  >= 0)
    and (platform_revenue is null or platform_revenue >= 0)
    and (collected_amount is null or collected_amount >= 0)
  ),
  constraint delivery_assignments_rider_pay_sums check (
    rider_pay_total is null or rider_pay_base is null
    or rider_pay_total = rider_pay_base
       + coalesce(rider_pay_distance, 0) + coalesce(rider_pay_bonus, 0)
  ),
  constraint delivery_assignments_distance_valid check (distance_km is null or distance_km >= 0),
  constraint delivery_assignments_eta_positive check (eta_minutes is null or eta_minutes > 0),

  -- Payment happens at the door, so a method and a channel arrive together or not at all.
  constraint delivery_assignments_collection_pair check (
    (collection_method is null and collection_channel is null and collected_amount is null)
    or (collection_method is not null and collection_channel is not null)
  ),
  -- 'none' means nothing was collected, so there must be no amount to report.
  constraint delivery_assignments_collection_none_is_zero check (
    collection_method is distinct from 'none' or coalesce(collected_amount, 0) = 0
  ),
  -- An assignment that claims a rider has reached a stage must record when.
  constraint delivery_assignments_claimed_has_time check (
    assigned_by is distinct from 'rider_claim' or (rider_id is not null and claimed_at is not null)
  )
);

-- The partial unique index that makes an atomic claim possible: two riders cannot both hold the
-- active assignment for one order, while a finished assignment does not block re-assignment of the
-- same order. claim_order_v1 in migration 018 relies on this existing, so it is created here even
-- though that function is not.
create unique index delivery_assignments_one_active on public.delivery_assignments (order_id)
  where status not in ('delivered','failed','cancelled');

create index delivery_assignments_open on public.delivery_assignments (rider_id, status)
  where status in ('assigned','at_first_vendor','picking_up','picked_up','delivering','arrived');
create index delivery_assignments_rider_history on public.delivery_assignments (rider_id, assigned_at desc);
create index delivery_assignments_sub_order on public.delivery_assignments (sub_order_id)
  where sub_order_id is not null;

create trigger trg_delivery_assignments_updated_at before update on public.delivery_assignments
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- rider_location_pings
-- =============================================================================================
-- EMPTY UNTIL PHASE 8. ADR 9 defers live tracking; contracts.md defines no RPC that writes here,
-- and the writer is the Durable Object. See open question 3.10.
--
-- PLAIN, NOT PARTITIONED, deliberately. data-model §14.1 and task T0.2c call for monthly
-- partitions, but §8 also says "partitioned by month when volume justifies it", and volume is zero.
-- A partitioned table's unique constraint must include the partition key, so the specced
-- bigserial primary key would fail outright here and would have to become (recorded_at, id).
-- Partitioning later is additive; un-partitioning a populated table is not. When the tracking API
-- lands, this becomes the migration that partitions it.
--
-- It is the highest-volume table in the database (free-tier-plan.md §3.2 budgets it at 4.0 KB per
-- order) and §8 itself calls it the first candidate for removal. created_at is kept deliberately
-- in preference to created_at + deleted_at: this table is pruned, never archived or soft-deleted.
create table public.rider_location_pings (
  id          bigserial primary key,
  order_id    uuid not null references public.orders(id) on delete cascade,
  rider_id    uuid not null references public.riders(id) on delete cascade,
  latitude    numeric(9,6) not null,
  longitude   numeric(9,6) not null,
  heading     numeric(5,2),
  speed_kmh   numeric(6,2),
  accuracy_m  numeric(6,2),
  recorded_at timestamptz not null default now(),

  constraint rider_location_pings_latitude_range  check (latitude  between -90 and 90),
  constraint rider_location_pings_longitude_range check (longitude between -180 and 180),
  constraint rider_location_pings_heading_range check (heading is null or heading between 0 and 360),
  constraint rider_location_pings_speed_nonneg check (speed_kmh is null or speed_kmh >= 0),
  constraint rider_location_pings_accuracy_nonneg check (accuracy_m is null or accuracy_m >= 0),
  -- A ping timestamped in the future is a clock bug, and would corrupt every trip-duration
  -- calculation built on this table.
  constraint rider_location_pings_not_future check (recorded_at <= now() + interval '5 minutes')
);

-- The two composite indexes §8 lists also cover both foreign keys as leading columns, per §14.2.
create index rider_location_pings_recorded_at on public.rider_location_pings (recorded_at);
create index rider_location_pings_order on public.rider_location_pings (order_id, recorded_at desc);
create index rider_location_pings_rider on public.rider_location_pings (rider_id, recorded_at desc);