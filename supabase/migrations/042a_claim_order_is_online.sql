-- 042a: fix `claim_order_v1`.
--
-- Two defects, both latent in 017/018, both found by running migration 042's rider loop
-- end-to-end against the live database.
--
-- ## Defect 1: `v_rider_id` does not exist (fatal, any claim)
--
-- Migration 018 declares `v_rider`, not `v_rider_id`, and the UPDATE that assigns the rider reads
-- `v_rider_id`:
--
--   update public.delivery_assignments da
--      set rider_id = v_rider_id,        -- no such variable
--
-- Postgres validates a plpgsql body lazily, so `CREATE FUNCTION` succeeded and every probe passed.
-- The name resolves as a column reference, finds nothing, and the claim fails at runtime:
--
--   ERROR: 42703: column "v_rider_id" does not exist
--
-- **No rider has ever claimed an order through this function.** The seed assignment was created
-- already-claimed, so the branch was never reached. 018's own probe passed because it stopped at
-- AUTH_REQUIRED, which is raised before this statement.
--
-- Fixed to `v_rr.id`, matching the original 018 intent.
--
-- ## Defect 2: `is_online` not set alongside `status` (fatal, offline rider)
--
-- The rider promotion was:
--
--   update public.riders r
--      set status = case when r.status = 'offline' then 'assigned' else r.status end,
--          updated_at = now()
--    where r.id = v_rr.id;
--
-- and the table carries:
--
--   riders_is_online_consistent: CHECK (is_online = (status <> 'offline'))
--
-- `status` becomes 'assigned'; `is_online` is untouched. For a rider whose status was 'offline',
-- the CHECK needs `is_online = true`, so the row is rejected:
--
--   ERROR: 23514: new row for relation "riders" violates check constraint
--          "riders_is_online_consistent"
--
-- A rider who had not gone online could never claim. Invisible because no client-writable path to
-- `is_online` exists and the one seeded rider had `status='available', is_online=true`, so the
-- promotion CASE never fired.
--
-- The fix derives `is_online` from the same CASE that produces `status`, so the two columns under
-- one CHECK cannot disagree:
--
--   is_online = (case ... end <> 'offline')
--
-- ## What is preserved verbatim from 018
--
-- Every guard, the `for update` lock that makes claiming atomic, the pay resolution, the
-- `rider_pay_total` mirror that closed open question 3.26, the event payload shape (including
-- `distance_km` and `has_pay_rule`, which 038g and 038d depend on), and the returned column list.
--
-- `returns table` keeps the ORIGINAL names and types - `rider_pay_base int` rather than
-- `integer`, `eta_minutes int` - because `CREATE OR REPLACE` cannot change a return type, and
-- callers destructure these positionally.
--
-- ## What this does NOT touch
--
--   * `complete_delivery_v1` sets `status = 'available'` with the same missing column. Left alone:
--     a rider can only be 'delivering' or 'assigned' when completing, so `is_online` is already
--     true and the CHECK passes. If a future flow lets an offline rider complete, that is the
--     migration to fix it in.
--   * No status value added or renamed. `riders_status_check` untouched.
--   * No new column. `is_online` exists and is indexed (`riders_online_status_geohash`,
--     `riders_status_online`).

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

  -- FIX 1: `v_rr.id`, not `v_rider_id`. 018 declared `v_rider` and never `v_rider_id`, so the
  -- original statement referenced a name that does not exist and every claim failed 42703.
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

  -- FIX 2: `is_online` derived from the same CASE as `status`, so the
  -- `riders_is_online_consistent` CHECK cannot be violated. Promoting an offline rider to
  -- 'assigned' without also setting is_online made every claim by an offline rider fail 23514.
  update public.riders r
     set status = case when r.status = 'offline' then 'assigned' else r.status end,
         is_online = (case when r.status = 'offline' then 'assigned' else r.status end <> 'offline'),
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
           greatest(5, round(v_leg_km * 2)::int),
           coalesce(v_pay.has_rule, false);
end;
$$;

-- Repo rule: every migration touching a plpgsql function ends with a call to it, because Postgres
-- validates a function body lazily and a migration that applied cleanly can still ship a function
-- that cannot run. This probe cannot reach the assignment UPDATE - AUTH_REQUIRED is raised first -
-- which is exactly why defect 1 survived 018's own probe.
do $$
begin
  perform public.claim_order_v1(gen_random_uuid(), gen_random_uuid());
  raise exception 'PROBE FAILED: claim_order_v1 ran without a session';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for claim_order_v1: %', sqlerrm;
    end if;
end $$;
