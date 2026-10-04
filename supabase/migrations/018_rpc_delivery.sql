-- 018_rpc_delivery.sql
-- get_available_orders_v1, claim_order_v1, begin_collection_v1,
-- collect_cash_v1, collect_wallet_v1, complete_delivery_v1
--
-- Constitution invariants this file exists to hold:
--   I.1   rider pay and platform revenue computed here, never in the app
--   I.3   integer piastres; multipliers in basis points
--   I.4   the ledger is append-only; corrections are reversing entries
--   I.5   every idempotency_key is unique
--   I.6   the platform holds no customer money
--   I.7   every money constant read from configuration
--   I.8   fee inputs frozen at checkout, so pay is computed from frozen values
--   I.9   launch revenue is the rider's cut of the delivery fee
--   I.10  cash in transit is reconciled daily and visible
--   II.15 status changes only through transition_order_v1
--   II.16 every state change writes its events row in the same transaction
--
-- ---------------------------------------------------------------------------
-- Decisions (open-questions.md 3.27 - 3.29)
-- ---------------------------------------------------------------------------
-- 3.27 get_available_orders_v1 materializes the offer pool lazily, with
--      INSERT ... ON CONFLICT DO NOTHING. Nothing else in the migration chain
--      creates delivery_assignments rows, and 021 owns only cron, so without
--      this the pool is permanently empty and 018 cannot be exercised end to
--      end.
--      The cost is real and is accepted deliberately: a function whose name
--      says "get" writes, and every call takes row locks on
--      delivery_assignments. Callers must treat it as a poll, not a free read.
--      Idempotent, so a rider polling every few seconds is harmless.
--
-- 3.28 platform_revenue is a commission ON the delivery fee, taken from
--      commission_rules(scope=rider, applies_to=delivery_fee), NOT
--      delivery_fee - rider_pay_total. spec 3.2 line 278 states the latter,
--      and it is arithmetically impossible: with the shipped seed values a
--      2500 fee against a 2000 per_trip and a 500 leg bonus yields
--      2500 - 4500 = -2000 of "revenue". The resolution is not a preference:
--      per_trip and bonus_per_leg are additive rider costs the platform bears
--      from its own margin, while the delivery fee itself is split between
--      rider and platform. Reading the two configuration tables for their own
--      concerns - rider_pay_rules pays the rider, commission_rules books the
--      revenue line - also matches constitution 9, which defines revenue as
--      "a cut of the delivery fee taken from the rider" rather than a
--      residual after every rider cost.
--
-- 3.29 The rider_cut ledger entry is written by collect_cash_v1 and
--      collect_wallet_v1, following spec 3.2, which places both ledger writes
--      under COLLECTION. contracts 1.7 instead credits it to
--      complete_delivery_v1. Both cannot own it: ledger_entries has UNIQUE
--      idempotency_key, so the second write would raise. complete_delivery_v1
--      therefore issues the same insert with ON CONFLICT DO NOTHING, which
--      makes it correct on either path and impossible to double-book. The
--      unique index is what makes that a guarantee rather than a hope.
--
-- ---------------------------------------------------------------------------
-- Assumptions NOT yet ratified by a human
-- ---------------------------------------------------------------------------
-- A1. Rider pay resolves per spec 3.3: a rule for this rider, else the active
--     city-wide rule, else an explicit error rather than zero. spec 3.3 says
--     "else zero, which surfaces as an admin error", so zero is returned
--     alongside a NO_PAY_RULE flag rather than raising - a missing rule must
--     not stop a delivery that is already physically happening.
-- A2. One delivery_assignments row per ORDER, not per sub_order.
--     delivery_assignments_one_active is UNIQUE (order_id) where status is not
--     delivered/failed/cancelled, which permits exactly one active trip, and
--     spec 25 is "one rider, one trip, N vendor pickups, one drop-off". The
--     per-leg sequence lives in stop_sequence jsonb.
-- A3. bonus_per_leg is multiplied by the vendor count, so a 3-vendor trip
--     earns more than a 1-vendor one, per spec 3.3.
-- A4. begin_collection_v1 refuses wallet payments a second time. A cash
--     collection followed by a wallet collection on the same order would
--     double the recorded amount, and nothing else in the schema prevents it.
-- A5. Availability is judged on distance from the rider to the FURTHEST
--     vendor, not to the customer. The rider must reach every pickup, and a
--     rider can be close to the customer while far from the kitchen.
-- A6. leg_km, the distance the rider actually drives, is
--     haversime(rider -> first vendor) + sum(vendor -> vendor) +
--     haversime(last vendor -> customer). Straight-line, not routed: the maps
--     adapter is out of scope for v1 and a routed figure would be an
--     unsourced number. Recorded because per_km_amount is paid on it.

create or replace function private.pay_rule_for(p_rider_id uuid, p_city_id uuid)
returns public.rider_pay_rules
language plpgsql
stable
set search_path to ''
as $$
declare
  v_rule public.rider_pay_rules;
begin
  select * into v_rule
    from public.rider_pay_rules r
   where r.rider_id = p_rider_id and r.is_active
     and r.effective_from <= now()
     and (r.effective_until is null or r.effective_until > now())
   order by r.effective_from desc
   limit 1;

  if not found then
    select * into v_rule
      from public.rider_pay_rules r
     where r.city_id = p_city_id and r.rider_id is null and r.is_active
       and r.effective_from <= now()
       and (r.effective_until is null or r.effective_until > now())
     order by r.effective_from desc
     limit 1;
  end if;

  return v_rule;
end;
$$;

-- Frozen pay for one trip. Split from the RPCs so claim_order_v1 and the
-- settlement path cannot disagree about what a rider earned.
create or replace function private.resolve_pay(
  p_rider_id     uuid,
  p_city_id      uuid,
  p_delivery_fee int,
  p_leg_km       numeric,
  p_legs         int
)
returns table (
  rider_pay_base     int,
  rider_pay_distance int,
  rider_pay_bonus    int,
  rider_pay_total    int,
  platform_revenue   int,
  has_rule           boolean
)
language plpgsql
stable
set search_path to ''
as $$
declare
  v_rule public.rider_pay_rules;
  v_hit  boolean := false;
begin
  v_rule := private.pay_rule_for(p_rider_id, p_city_id);
  -- `found` refers to the LAST statement executed inside pay_rule_for, not to
  -- whether the function returned a row. A function that assigns to an OUT
  -- parameter and returns it leaves FOUND unreliable, so the NULL test is the
  -- only trustworthy signal that no rule matched.
  v_hit := (v_rule.id is not null);

  if not v_hit then
    -- A1: never block a delivery that is already happening. Zero pay with an
    -- explicit flag is an admin-visible fault, not a silent one.
    return query
      select coalesce(null::int,0), 0, 0, 0,
             coalesce((select cr.value from public.commission_rules cr
                        where cr.scope = 'rider' and cr.applies_to = 'delivery_fee'
                          and cr.is_active and cr.effective_from <= now()
                          and (cr.effective_until is null or cr.effective_until > now())
                        order by cr.effective_from desc limit 1), 0),
             false;
    return;
  end if;

  return query
    select coalesce(v_rule.per_trip_amount, 0),
           round(coalesce(v_rule.per_km_amount, 0) * coalesce(p_leg_km, 0))::int,
           coalesce(v_rule.bonus_per_leg, 0) * greatest(coalesce(p_legs, 1), 1),
           coalesce(v_rule.per_trip_amount, 0)
             + round(coalesce(v_rule.per_km_amount, 0) * coalesce(p_leg_km, 0))::int
             + coalesce(v_rule.bonus_per_leg, 0) * greatest(coalesce(p_legs, 1), 1),
           coalesce((select round(p_delivery_fee::numeric * cr.value / 10000)::int
                       from public.commission_rules cr
                      where cr.scope = 'rider' and cr.applies_to = 'delivery_fee'
                        and cr.is_active and cr.effective_from <= now()
                        and (cr.effective_until is null or cr.effective_until > now())
                      order by cr.effective_from desc limit 1), 0),
           true;
end;
$$;

-- Straight-line route length: rider -> vendors in sequence -> customer. A6.
create or replace function private.trip_distance_km(
  p_rider_lat numeric, p_rider_lng numeric,
  p_vendor    jsonb,
  p_cust_lat  numeric, p_cust_lng  numeric
)
returns numeric
language plpgsql
immutable
set search_path to ''
as $$
declare
  v_total numeric := 0;
  v_prev_lat numeric := p_rider_lat;
  v_prev_lng numeric := p_rider_lng;
  v_stop    jsonb;
  v_lat numeric;
  v_lng numeric;
begin
  for v_stop in select * from jsonb_array_elements(coalesce(p_vendor, '[]'::jsonb))
  loop
    v_lat := (v_stop ->> 'latitude')::numeric;
    v_lng := (v_stop ->> 'longitude')::numeric;
    v_total := v_total + public.haversine_km(v_prev_lat, v_prev_lng, v_lat, v_lng);
    v_prev_lat := v_lat;
    v_prev_lng := v_lng;
  end loop;

  v_total := v_total + public.haversine_km(v_prev_lat, v_prev_lng, p_cust_lat, p_cust_lng);
  return round(v_total::numeric, 3);
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
-- The pool scan filters on status, and the existing partial indexes are keyed
-- on rider_id or sub_order_id, neither of which helps find unclaimed offers.
create index if not exists delivery_assignments_offer_pool
  on public.delivery_assignments (assigned_at)
  where rider_id is null and status = 'unassigned';

create index if not exists ledger_entries_order
  on public.ledger_entries (order_id)
  where order_id is not null;

create index if not exists platform_float_date
  on public.platform_float (business_date);

-- ---------------------------------------------------------------------------
-- 2. get_available_orders_v1
-- ---------------------------------------------------------------------------
-- Never returns menus or items: free-tier-plan 200 prices this call at 4 per
-- checkout and 17 MB with a 3 KB response trimmed to 1 KB. An availability
-- poll that returned a menu would undo that on the hottest path in the app.
-- A7. The candidate scan runs over a CTE rather than over delivery_assignments.
--     Assigning inside SECURITY DEFINER needs no client INSERT (verified: anon
--     and authenticated both hold false), and scanning orders directly is both
--     cheaper and self-healing, since it needs no stored offer row to exist.
create or replace function public.get_available_orders_v1(
  p_lat       numeric,
  p_lng       numeric,
  p_radius_km numeric default null
)
returns table (
  assignment_id uuid,
  order_id      uuid,
  order_number  text,
  vendor_count  int,
  area_id       uuid,
  pickup_km     numeric,
  dropoff_km    numeric,
  est_pickup_minutes int,
  total         int,
  currency      char(3),
  placed_at     timestamptz
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user   uuid := auth.uid();
  v_rider  public.riders%rowtype;
  v_lat    numeric;
  v_lng    numeric;
  v_radius numeric;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  -- riders has no deleted_at; is_active is the soft-delete flag here.
  select * into v_rider
    from public.riders r
   where r.user_id = v_user and r.is_active;
  if not found then
    perform private.err('NOT_A_RIDER', 'no active rider profile');
  end if;
  if not v_rider.is_verified then
    perform private.err('RIDER_NOT_VERIFIED', 'rider account is not verified');
  end if;

  -- A rider with no position cannot be offered anything. Defaulting a position
  -- would invent work they cannot reach.
  v_lat := coalesce(p_lat, v_rider.current_latitude);
  v_lng := coalesce(p_lng, v_rider.current_longitude);
  if v_lat is null or v_lng is null then
    perform private.err('RIDER_LOCATION_REQUIRED', 'share your location to see available orders');
  end if;

  v_radius := coalesce(p_radius_km, 25);
  if v_radius <= 0 then
    perform private.err('RADIUS_INVALID', 'radius must be positive');
  end if;

  -- Offers are materialized lazily (3.27). ON CONFLICT DO NOTHING relies on
  -- delivery_assignments_one_active, which is UNIQUE (order_id) where the
  -- status is not terminal, so a rider polling repeatedly inserts nothing new.
  insert into public.delivery_assignments (order_id, status, assigned_by, stop_sequence, distance_km)
  select o.id, 'unassigned', 'system',
         (select jsonb_agg(jsonb_build_object(
                   'sub_order_id', so.id, 'vendor_id', so.vendor_id,
                   'latitude', v.latitude, 'longitude', v.longitude,
                   'sequence', so.sequence)
                 order by so.sequence)
            from public.sub_orders so
            join public.vendors v on v.id = so.vendor_id
           where so.order_id = o.id),
         o.distance_km
    from public.orders o
   where o.status in ('pending','partially_confirmed','preparing','ready')
     and o.delivery_type = 'delivery'
     and o.cancelled_at is null
     and exists (select 1 from public.sub_orders so
                  where so.order_id = o.id
                    and so.status in ('pending','accepted','preparing','ready'))
     and not exists (
       select 1 from public.sub_orders so
        join public.vendors v on v.id = so.vendor_id
       where so.order_id = o.id
         and not (v.is_active and v.is_approved)
         and so.status not in ('delivered','cancelled','rejected'))
  on conflict do nothing;

  -- Feasibility is judged on the FURTHEST vendor (A5): a rider can stand next
  -- to the customer and still be an hour from the kitchen.
  return query
  select da.id,
         o.id,
         o.order_number,
         o.vendor_count,
         o.area_id,
         round(agg_pickup.pickup_km::numeric, 2),
         round(coalesce(public.haversine_km(v_lat, v_lng,
                                            o.delivery_latitude, o.delivery_longitude), 0)::numeric, 2),
         coalesce(agg_pickup.prep_minutes, 0)
           + greatest(5, round(agg_pickup.pickup_km * 2)::int),
         o.total,
         o.currency,
         o.placed_at
    from public.delivery_assignments da
    join public.orders o on o.id = da.order_id
    cross join lateral (
      select max(public.haversine_km(v_lat, v_lng, v.latitude, v.longitude)) as pickup_km,
             (select coalesce(max(m.preparation_time_minutes), 0)
                from public.sub_orders so
                join public.order_items oi on oi.sub_order_id = so.id
                join public.menu_items m on m.id = oi.menu_item_id
               where so.order_id = o.id) as prep_minutes
        from public.sub_orders so
        join public.vendors v on v.id = so.vendor_id
       where so.order_id = o.id
    ) agg_pickup
   where da.status = 'unassigned'
     and da.rider_id is null
     and o.status in ('pending','partially_confirmed','preparing','ready')
     and o.delivery_type = 'delivery'
     and o.cancelled_at is null
     and agg_pickup.pickup_km <= v_radius
     and coalesce(public.haversine_km(v_lat, v_lng,
                                      o.delivery_latitude, o.delivery_longitude), 0) <= v_radius
   order by agg_pickup.pickup_km
   limit 10;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. claim_order_v1
-- ---------------------------------------------------------------------------
-- Atomic. Two riders racing for the same offer must produce one winner and one
-- ORDER_ALREADY_CLAIMED, which is why the row is locked FOR UPDATE before the
-- claimed check rather than after.
create or replace function public.claim_order_v1(
  p_assignment_id uuid,
  p_rider_id      uuid
)
returns table (
  order_id          uuid,
  assignment_id     uuid,
  rider_id          uuid,
  rider_pay_base    int,
  rider_pay_distance int,
  rider_pay_bonus   int,
  rider_pay_total   int,
  platform_revenue  int,
  distance_km       numeric,
  eta_minutes       int,
  has_pay_rule      boolean
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user     uuid := auth.uid();
  v_is_admin boolean;
  v_rider    uuid;
  v_da       public.delivery_assignments%rowtype;
  v_order    public.orders%rowtype;
  v_rr       public.riders%rowtype;
  v_legs     int;
  v_leg_km   numeric;
  v_pay      record;
  v_stops    jsonb;
  v_lat      numeric;
  v_lng      numeric;
  v_city     uuid;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  v_is_admin := private.is_admin();

  -- constitution 20: a client-supplied rider id is never trusted. A non-admin
  -- may only ever claim as themselves.
  if p_rider_id is null then
    perform private.err('RIDER_REQUIRED', 'rider_id is required');
  end if;
  if not v_is_admin and not exists (select 1 from private.rider_ids_for(v_user) r
                                     where r = p_rider_id) then
    perform private.err('NOT_AUTHORIZED', 'cannot claim as another rider');
  end if;

  select * into v_rr from public.riders r where r.id = p_rider_id;
  if not found then
    perform private.err('RIDER_NOT_FOUND', 'rider not found');
  end if;
  if not (v_rr.is_active and v_rr.is_verified) then
    perform private.err('RIDER_NOT_ELIGIBLE', 'rider is not active or not verified');
  end if;

  -- The lock is what makes claiming atomic. Everything after this point is
  -- safe to read as settled.
  select * into v_da from public.delivery_assignments da
   where da.id = p_assignment_id
   for update;
  if not found then
    perform private.err('ASSIGNMENT_NOT_FOUND', 'assignment not found');
  end if;

  if v_da.rider_id is not null then
    perform private.err('ORDER_ALREADY_CLAIMED', 'this order was already claimed');
  end if;
  if v_da.status <> 'unassigned' then
    perform private.err('ORDER_NOT_CLAIMABLE', 'assignment is ' || v_da.status);
  end if;

  select * into v_order from public.orders o where o.id = v_da.order_id;
  if not found then
    perform private.err('ORDER_NOT_FOUND', 'order not found');
  end if;
  if v_order.status in ('delivered','cancelled') or v_order.cancelled_at is not null then
    perform private.err('ORDER_NOT_CLAIMABLE', 'order is ' || v_order.status);
  end if;

  select count(*) into v_legs from public.sub_orders so
   where so.order_id = v_order.id
     and so.status not in ('cancelled','rejected');

  v_stops := v_da.stop_sequence;

  -- Prefer the rider's live position; fall back to the stored one.
  v_lat := coalesce(v_rr.current_latitude, 0);
  v_lng := coalesce(v_rr.current_longitude, 0);

  v_leg_km := private.trip_distance_km(v_lat, v_lng, v_stops,
                                       v_order.delivery_latitude, v_order.delivery_longitude);

  -- rider_pay_rules is keyed by city and orders carry no city_id, so the city
  -- comes from the vendor's own row via the sub-orders. Every vendor in a city
  -- shares one city_id, so any leg resolves the same city.
  select v.city_id into v_city
    from public.sub_orders so
    join public.vendors v on v.id = so.vendor_id
   where so.order_id = v_order.id
   limit 1;

  select * into v_pay from private.resolve_pay(
    v_rr.id, v_city, v_order.delivery_fee, v_leg_km, v_legs);

  update public.delivery_assignments da
     set rider_id = v_rr.id,
         status = 'assigned',
         assigned_by = 'rider_claim',
         assigned_at = now(),
         claimed_at = now(),
         distance_km = v_leg_km,
         eta_minutes = greatest(5, round(v_leg_km * 2)::int),
         rider_pay_base = v_pay.rider_pay_base,
         rider_pay_distance = v_pay.rider_pay_distance,
         rider_pay_bonus = v_pay.rider_pay_bonus,
         rider_pay_total = v_pay.rider_pay_total,
         platform_revenue = v_pay.platform_revenue
   where da.id = p_assignment_id;

  -- The obligation 017 recorded as open question 3.26: placement left these at
  -- 0 because no rider existed yet. Now one does, so the authoritative figures
  -- are mirrored here and the order stops saying "not yet determined".
  update public.orders o
     set rider_pay_total = v_pay.rider_pay_total,
         platform_revenue = v_pay.platform_revenue
   where o.id = v_order.id;

  update public.riders r
     set status = case when r.status = 'offline' then 'assigned' else r.status end,
         updated_at = now()
   where r.id = v_rr.id;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('order.claimed', 'order', v_order.id,
          jsonb_build_object('order_id', v_order.id, 'rider_id', v_rr.id,
                             'assignment_id', p_assignment_id,
                             'rider_pay_total', v_pay.rider_pay_total,
                             'platform_revenue', v_pay.platform_revenue,
                             'distance_km', v_leg_km,
                             'has_pay_rule', v_pay.has_rule));

  return query
    select v_order.id, p_assignment_id, v_rr.id,
           v_pay.rider_pay_base, v_pay.rider_pay_distance, v_pay.rider_pay_bonus,
           v_pay.rider_pay_total, v_pay.platform_revenue, v_leg_km,
           greatest(5, round(v_leg_km * 2)::int), v_pay.has_rule;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. begin_collection_v1
-- ---------------------------------------------------------------------------
create or replace function public.begin_collection_v1(
  p_order_id        uuid,
  p_payment_method  text,
  p_channel         text
)
returns table (
  amount_due        int,
  can_collect_cash  boolean,
  can_collect_wallet boolean,
  cash_held         int,
  effective_cash_limit int,
  currency          char(3),
  already_collected boolean
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user   uuid := auth.uid();
  v_rider  uuid;
  v_order  public.orders%rowtype;
  v_da     public.delivery_assignments%rowtype;
  v_limit  int;
  v_held   int;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  select * into v_da from public.delivery_assignments da where da.order_id = p_order_id;
  if not found then
    perform private.err('ORDER_NOT_ASSIGNED', 'no delivery assignment for this order');
  end if;
  if not exists (select 1 from private.rider_ids_for(v_user) r where r = v_da.rider_id) then
    perform private.err('NOT_AUTHORIZED', 'not your trip');
  end if;
  v_rider := v_da.rider_id;

  if p_payment_method not in ('cash','wallet') then
    perform private.err('PAYMENT_METHOD_INVALID', 'payment method must be cash or wallet');
  end if;
  if p_channel not in ('cod','vodafone_cash','instapay') then
    perform private.err('PAYMENT_CHANNEL_INVALID', 'channel must be cod, vodafone_cash or instapay');
  end if;
  if p_payment_method = 'cash' and p_channel <> 'cod' then
    perform private.err('PAYMENT_CHANNEL_MISMATCH', 'cash payments use cod');
  end if;
  if p_payment_method = 'wallet' and p_channel = 'cod' then
    perform private.err('PAYMENT_CHANNEL_MISMATCH', 'wallet payments use vodafone_cash or instapay');
  end if;

  select * into v_order from public.orders o where o.id = p_order_id;
  if not found then
    perform private.err('ORDER_NOT_FOUND', 'order not found');
  end if;

  -- OUT params shadow table columns, so alias rather than repeat cash_held.
  v_held := coalesce((select r.cash_held from public.riders r where r.id = v_rider), 0);
  v_limit := private.effective_cash_limit(v_rider);

  return query
    select v_order.total,
           p_payment_method = 'cash',
           p_payment_method = 'wallet',
           v_held,
           v_limit,
           v_order.currency,
           -- A4: a second collection on the same order would double the
           -- recorded amount and nothing else in the schema prevents it.
           v_da.collected_amount is not null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. collect_cash_v1
-- ---------------------------------------------------------------------------
create or replace function public.collect_cash_v1(
  p_order_id    uuid,
  p_amount      int,
  p_reference   text default null,
  p_proof_path  text default null
)
returns table (
  order_id       uuid,
  collected_amount int,
  cash_held      int,
  ledger_entry_id uuid,
  reference      text,
  currency       char(3)
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user  uuid := auth.uid();
  v_da    public.delivery_assignments%rowtype;
  v_order public.orders%rowtype;
  v_rider uuid;
  v_held  int;
  v_limit int;
  v_ledger uuid;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_amount is null or p_amount <= 0 then
    perform private.err('AMOUNT_INVALID', 'amount must be positive');
  end if;

  select * into v_da from public.delivery_assignments da
   where da.order_id = p_order_id for update;
  if not found then
    perform private.err('ORDER_NOT_ASSIGNED', 'no delivery assignment for this order');
  end if;
  if not exists (select 1 from private.rider_ids_for(v_user) r where r = v_da.rider_id) then
    perform private.err('NOT_AUTHORIZED', 'not your trip');
  end if;
  v_rider := v_da.rider_id;

  if v_da.collection_method is not null then
    perform private.err('ALREADY_COLLECTED', 'this order was already collected');
  end if;

  select * into v_order from public.orders o where o.id = p_order_id;
  if not found then
    perform private.err('ORDER_NOT_FOUND', 'order not found');
  end if;

  -- constitution I.3: the amount is integer piastres and must equal the order
  -- total exactly. A short collection is a different event (a dispute), not a
  -- partial success, and silently accepting one would leave platform_float
  -- permanently out by the difference.
  if p_amount <> v_order.total then
    perform private.err('AMOUNT_MISMATCH',
      'expected ' || v_order.total || ' piastres, got ' || p_amount);
  end if;

  v_held := coalesce((select r.cash_held from public.riders r where r.id = v_rider), 0);
  v_limit := private.effective_cash_limit(v_rider);

  -- I.10: cash in transit is the single exposure, and it is capped per rider.
  if v_held + p_amount > v_limit then
    perform private.err('CASH_LIMIT_EXCEEDED',
      'holding ' || v_held || ' plus ' || p_amount || ' exceeds the limit of ' || v_limit);
  end if;

  update public.delivery_assignments da
     set collected_amount = p_amount,
         collection_method = 'cash',
         collection_channel = 'cod',
         collection_reference = p_reference,
         proof_path = p_proof_path
   where da.id = v_da.id;

  update public.riders r set cash_held = v_held + p_amount, updated_at = now()
   where r.id = v_rider;

  -- payment_collected_by references users(id), not riders(id). The rider's user
  -- id is the person who physically took the money, which is what an audit of
  -- this column needs to name.
  update public.orders o
     set payment_status = 'collected',
         payment_collected_at = now(),
         payment_collected_by = (select r.user_id from public.riders r where r.id = v_rider),
         payment_reference = p_reference
   where o.id = p_order_id;

  -- I.4: append-only. cash_collected is platform cash in transit; rider_cut is
  -- the revenue line from open question 3.28.
  insert into public.ledger_entries
    (account_type, account_id, entry_type, signed_amount, currency, order_id, idempotency_key, note)
  values ('platform', null, 'cash_collected', p_amount, v_order.currency, p_order_id,
          'collect_cash:' || p_order_id::text, 'cash collected by rider at delivery')
  returning id into v_ledger;

  -- NOT ON CONFLICT. constitution 4 gives ledger_entries DO INSTEAD NOTHING
  -- rules on UPDATE and DELETE, and Postgres refuses any INSERT ... ON CONFLICT
  -- against a table that has rules at all -- the guard that makes the ledger
  -- append-only also disables the upsert syntax. The UNIQUE index on
  -- idempotency_key is still the real guarantee; this is the guarded form of it.
  insert into public.ledger_entries
    (account_type, account_id, entry_type, signed_amount, currency, order_id, idempotency_key, note)
  select 'platform_earnings', null, 'rider_cut', coalesce(v_da.platform_revenue, 0),
         v_order.currency, p_order_id, 'rider_cut:' || p_order_id::text,
         'platform cut of the delivery fee'
   where not exists (select 1 from public.ledger_entries le
                      where le.idempotency_key = 'rider_cut:' || p_order_id::text);

  -- I.10: float tracks the exposure the moment it exists.
  -- variance is NOT NULL and CHECK (variance = cash_expected - cash_remitted),
  -- so a new day's row must seed cash_remitted = 0 for the constraint to hold.
  -- cash_remitted is written by the settlement sweep in 021, never here.
  insert into public.platform_float
    (business_date, cash_expected, cash_remitted, variance,
     delivery_fees, rider_cuts, external_cash_orders)
  values (current_date, p_amount, 0, p_amount,
          v_order.delivery_fee, coalesce(v_da.platform_revenue, 0), 1)
  on conflict (business_date) do update
    set cash_expected = platform_float.cash_expected + excluded.cash_expected,
        variance      = (platform_float.cash_expected + excluded.cash_expected)
                        - platform_float.cash_remitted,
        delivery_fees = platform_float.delivery_fees + excluded.delivery_fees,
        rider_cuts    = platform_float.rider_cuts + excluded.rider_cuts,
        external_cash_orders = platform_float.external_cash_orders + 1;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('order.collected', 'order', p_order_id,
          jsonb_build_object('order_id', p_order_id, 'rider_id', v_rider,
                             'amount', p_amount, 'channel', 'cod',
                             'method', 'cash', 'cash_held', v_held + p_amount));

  return query
    select p_order_id, p_amount, v_held + p_amount, v_ledger,
           p_reference, v_order.currency;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. collect_wallet_v1
-- ---------------------------------------------------------------------------
-- The customer already transferred to the rider. The platform records that it
-- happened and moves no money: no cash_held, no cash_collected entry.
create or replace function public.collect_wallet_v1(
  p_order_id  uuid,
  p_channel   text,
  p_reference text default null
)
returns table (
  order_id       uuid,
  collected_amount int,
  cash_held      int,
  channel        text,
  reference      text,
  currency       char(3),
  platform_cash_moved int
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user  uuid := auth.uid();
  v_da    public.delivery_assignments%rowtype;
  v_order public.orders%rowtype;
  v_rider uuid;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_channel not in ('vodafone_cash','instapay') then
    perform private.err('PAYMENT_CHANNEL_INVALID', 'channel must be vodafone_cash or instapay');
  end if;

  select * into v_da from public.delivery_assignments da
   where da.order_id = p_order_id for update;
  if not found then
    perform private.err('ORDER_NOT_ASSIGNED', 'no delivery assignment for this order');
  end if;
  if not exists (select 1 from private.rider_ids_for(v_user) r where r = v_da.rider_id) then
    perform private.err('NOT_AUTHORIZED', 'not your trip');
  end if;
  if v_da.collection_method is not null then
    perform private.err('ALREADY_COLLECTED', 'this order was already collected');
  end if;
  v_rider := v_da.rider_id;

  select * into v_order from public.orders o where o.id = p_order_id;
  if not found then
    perform private.err('ORDER_NOT_FOUND', 'order not found');
  end if;

  update public.delivery_assignments da
     set collected_amount = v_order.total,
         collection_method = 'wallet',
         collection_channel = p_channel,
         collection_reference = p_reference
   where da.id = v_da.id;

  -- See collect_cash_v1: this column is a users(id) reference.
  update public.orders o
     set payment_status = 'collected',
         payment_collected_at = now(),
         payment_collected_by = (select r.user_id from public.riders r where r.id = v_rider),
         payment_channel = p_channel,
         payment_reference = p_reference
   where o.id = p_order_id;

  -- 3.29: revenue is recognised on collection regardless of method, because
  -- the platform earned the cut whether the customer handed over cash or
  -- transferred to the rider directly. NOT ON CONFLICT: see collect_cash_v1
  -- for why the append-only rules forbid upsert syntax on this table.
  insert into public.ledger_entries
    (account_type, account_id, entry_type, signed_amount, currency, order_id, idempotency_key, note)
  select 'platform_earnings', null, 'rider_cut', coalesce(v_da.platform_revenue, 0),
         v_order.currency, p_order_id, 'rider_cut:' || p_order_id::text,
         'platform cut of the delivery fee'
   where not exists (select 1 from public.ledger_entries le
                      where le.idempotency_key = 'rider_cut:' || p_order_id::text);

-- See collect_cash_v1: variance is a derived column and cash_remitted belongs
  -- to the settlement sweep, so a first wallet order must seed both as 0 to
  -- satisfy CHECK (variance = cash_expected - cash_remitted).
  insert into public.platform_float
         (business_date, cash_expected, cash_remitted, variance,
          rider_cuts, external_wallet_orders)
       values (current_date, 0, 0, 0, coalesce(v_da.platform_revenue, 0), 1)
       on conflict (business_date) do update
         set rider_cuts = platform_float.rider_cuts + excluded.rider_cuts,
             external_wallet_orders = platform_float.external_wallet_orders + 1;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('order.collected', 'order', p_order_id,
          jsonb_build_object('order_id', p_order_id, 'rider_id', v_rider,
                             'amount', v_order.total, 'channel', p_channel,
                             'method', 'wallet'));

  return query
    select p_order_id, v_order.total,
           coalesce((select r.cash_held from public.riders r where r.id = v_rider), 0),
           p_channel, p_reference, v_order.currency, 0;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. complete_delivery_v1
-- ---------------------------------------------------------------------------
create or replace function public.complete_delivery_v1(
  p_order_id   uuid,
  p_proof_path text default null,
  p_lat        numeric default null,
  p_lng        numeric default null
)
returns table (
  order_id          uuid,
  delivered_at      timestamptz,
  rider_pay_total   int,
  platform_revenue  int,
  tips              int,
  rider_gross_total int,
  vendor_payable    int,
  currency          char(3)
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user  uuid := auth.uid();
  v_da    public.delivery_assignments%rowtype;
  v_order public.orders%rowtype;
  v_rider uuid;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  select * into v_da from public.delivery_assignments da
   where da.order_id = p_order_id for update;
  if not found then
    perform private.err('ORDER_NOT_ASSIGNED', 'no delivery assignment for this order');
  end if;
  if not exists (select 1 from private.rider_ids_for(v_user) r where r = v_da.rider_id) then
    perform private.err('NOT_AUTHORIZED', 'not your trip');
  end if;
  v_rider := v_da.rider_id;

  if v_da.status = 'delivered' then
    perform private.err('ALREADY_DELIVERED', 'order already delivered');
  end if;

  -- II.15: status moves through transition_order_v1. This only records the
  -- trip-level fact, it does not reach around the state machine.
  if exists (select 1 from public.sub_orders so
              where so.order_id = p_order_id
                and so.status not in ('delivered','cancelled','rejected')) then
    perform private.err('SUB_ORDERS_INCOMPLETE',
      'every vendor part must be delivered or cancelled first');
  end if;

  select * into v_order from public.orders o where o.id = p_order_id;
  if not found then
    perform private.err('ORDER_NOT_FOUND', 'order not found');
  end if;

  update public.delivery_assignments da
     set status = 'delivered',
         delivered_at = now(),
         proof_path = coalesce(p_proof_path, da.proof_path)
   where da.id = v_da.id;

  -- 3.29: idempotent backstop for the revenue entry, so this path is correct
  -- whether or not collection already wrote it. NOT ON CONFLICT: see
  -- collect_cash_v1 for why the append-only rules forbid upsert syntax here.
  insert into public.ledger_entries
    (account_type, account_id, entry_type, signed_amount, currency, order_id, idempotency_key, note)
  select 'platform_earnings', null, 'rider_cut', coalesce(v_da.platform_revenue, 0),
         v_order.currency, p_order_id, 'rider_cut:' || p_order_id::text,
         'platform cut of the delivery fee'
   where not exists (select 1 from public.ledger_entries le
                      where le.idempotency_key = 'rider_cut:' || p_order_id::text);

  update public.riders r
     set status = 'available',
         completed_deliveries = coalesce(completed_deliveries, 0) + 1,
         cash_held = coalesce(cash_held, 0),
         updated_at = now()
   where r.id = v_rider;

-- See collect_cash_v1: seed the derived variance columns as 0 so the CHECK
  -- holds even when this is the first row written for the day.
  insert into public.platform_float
         (business_date, cash_expected, cash_remitted, variance,
          vendor_payable, rider_payable)
       values (current_date, 0, 0, 0,
               coalesce((select sum(so.vendor_net_payout) from public.sub_orders so
                           where so.order_id = p_order_id
                             and so.settlement_status = 'payable'), 0),
               coalesce(v_da.rider_pay_total, 0))
       on conflict (business_date) do update
         set vendor_payable = platform_float.vendor_payable + excluded.vendor_payable,
             rider_payable  = platform_float.rider_payable + excluded.rider_payable;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('order.delivered', 'order', p_order_id,
          jsonb_build_object('order_id', p_order_id, 'rider_id', v_rider,
                             'rider_pay_total', coalesce(v_da.rider_pay_total, 0),
                             'platform_revenue', coalesce(v_da.platform_revenue, 0),
                             'tips', v_order.rider_tip));

  return query
    select p_order_id, now(),
           coalesce(v_da.rider_pay_total, 0),
           coalesce(v_da.platform_revenue, 0),
           v_order.rider_tip,
           coalesce(v_da.rider_pay_total, 0) + v_order.rider_tip,
-- sum() returns bigint and the OUT params are int, so cast
              -- explicitly rather than relying on an assignment Postgres will
              -- not make for a bare expression.
              coalesce((select sum(so.vendor_net_payout) from public.sub_orders so
                         where so.order_id = p_order_id
                           and so.settlement_status = 'payable'), 0)::int,
              v_order.currency;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.get_available_orders_v1(numeric,numeric,numeric) from public, anon;
revoke all on function public.claim_order_v1(uuid,uuid)                      from public, anon;
revoke all on function public.begin_collection_v1(uuid,text,text)             from public, anon;
revoke all on function public.collect_cash_v1(uuid,int,text,text)            from public, anon;
revoke all on function public.collect_wallet_v1(uuid,text,text)               from public, anon;
revoke all on function public.complete_delivery_v1(uuid,text,numeric,numeric) from public, anon;

grant execute on function public.get_available_orders_v1(numeric,numeric,numeric) to authenticated;
grant execute on function public.claim_order_v1(uuid,uuid)                       to authenticated;
grant execute on function public.begin_collection_v1(uuid,text,text)              to authenticated;
grant execute on function public.collect_cash_v1(uuid,int,text,text)             to authenticated;
grant execute on function public.collect_wallet_v1(uuid,text,text)                to authenticated;
grant execute on function public.complete_delivery_v1(uuid,text,numeric,numeric)  to authenticated;

revoke all on function private.pay_rule_for(uuid,uuid)          from public, anon, authenticated;
revoke all on function private.resolve_pay(uuid,uuid,int,numeric,int) from public, anon, authenticated;
revoke all on function private.trip_distance_km(numeric,numeric,jsonb,numeric,numeric)
  from public, anon, authenticated;