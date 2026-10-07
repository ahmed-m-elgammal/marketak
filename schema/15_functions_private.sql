-- =============================================================================
-- 15_functions_private.sql
-- The `private` schema. Not exposed to PostgREST.
--
-- Two kinds of function live here:
--   1. Identity resolvers used by RLS policies. SECURITY DEFINER + STABLE +
--      `search_path TO ''`. They must be definer, because a policy on `users`
--      cannot query `user_roles` as the calling role without recursing.
--   2. Business logic shared by several public RPCs — the quote, pay
--      resolution, order aggregation — so the pricing rule exists once.
-- =============================================================================

-- =============================================================================
-- 1. Identity resolvers. Every one pins search_path and qualifies every table.
-- =============================================================================

CREATE OR REPLACE FUNCTION private.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.user_roles r
    where r.user_id = (select auth.uid()) and r.role = 'admin' and r.revoked_at is null
  );
$function$;

CREATE OR REPLACE FUNCTION private.vendor_ids_for(p_user uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select vs.vendor_id from public.vendor_staff vs
  where vs.user_id = p_user and vs.deleted_at is null;
$function$;

CREATE OR REPLACE FUNCTION private.rider_ids_for(p_user uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select r.id from public.riders r where r.user_id = p_user;
$function$;

CREATE OR REPLACE FUNCTION private.account_ids_for(p_user uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select w.owner_id from public.wallets w
  where (w.owner_type = 'vendor' and w.owner_id in (select private.vendor_ids_for(p_user)))
     or (w.owner_type = 'rider'  and w.owner_id in (select private.rider_ids_for(p_user)));
$function$;

-- What this user may see of the ORDERS table. Three-way union: customer,
-- vendor (via any of its sub_orders), rider (via an assignment).
CREATE OR REPLACE FUNCTION private.visible_order_ids(p_user uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select o.id from public.orders o where o.user_id = p_user
  union
  select so.order_id from public.sub_orders so
   where so.vendor_id in (select private.vendor_ids_for(p_user))
  union
  select da.order_id from public.delivery_assignments da
   where da.rider_id in (select private.rider_ids_for(p_user));
$function$;

-- Stricter variant used by sub_orders / order_items, where the vendor must also
-- match on the row itself rather than merely have a sub_order on the order.
CREATE OR REPLACE FUNCTION private.owned_or_assigned_order_ids(p_user uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select o.id from public.orders o where o.user_id = p_user
  union
  select da.order_id from public.delivery_assignments da
   where da.rider_id in (select private.rider_ids_for(p_user));
$function$;

CREATE OR REPLACE FUNCTION private.rider_order_ids(p_user uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select da.order_id from public.delivery_assignments da
  where da.rider_id in (select private.rider_ids_for(p_user));
$function$;

-- =============================================================================
-- 2. Settings accessors. Every money and behaviour constant is read through one
--    of these, so a value lives in the settings table and nowhere else.
-- =============================================================================

CREATE OR REPLACE FUNCTION private.setting_bool(p_key text, p_default boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v boolean;
begin
  select (value #>> '{}')::boolean into v from public.settings where key = p_key;
  return coalesce(v, p_default);
end; $function$;

CREATE OR REPLACE FUNCTION private.setting_int(p_key text, p_default integer)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v int;
begin
  select (value #>> '{}')::int into v from public.settings where key = p_key;
  return coalesce(v, p_default);
end; $function$;

CREATE OR REPLACE FUNCTION private.setting_str(p_key text, p_default text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v text;
begin
  select value #>> '{}' into v from public.settings where key = p_key;
  return coalesce(v, p_default);
end; $function$;

-- =============================================================================
-- 3. Referential-integrity assertions for the polymorphic columns.
--    These have no FK constraint by design; these triggers are the guarantee.
-- =============================================================================

CREATE OR REPLACE FUNCTION private.assert_wallet_owner()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.owner_id is not null and new.owner_type = 'vendor'
     and not exists (select 1 from public.vendors where id = new.owner_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: wallet owner' using errcode = '23503';
  end if;
  if new.owner_id is not null and new.owner_type = 'rider'
     and not exists (select 1 from public.riders where id = new.owner_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: wallet owner' using errcode = '23503';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION private.assert_ledger_account()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.account_type = 'vendor'
     and not exists (select 1 from public.vendors where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: ledger account' using errcode = '23503';
  end if;
  if new.account_type = 'rider'
     and not exists (select 1 from public.riders where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: ledger account' using errcode = '23503';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION private.assert_payout_account()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.payout_type = 'vendor'
     and not exists (select 1 from public.vendors where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: payout account' using errcode = '23503';
  end if;
  if new.payout_type = 'rider'
     and not exists (select 1 from public.riders where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: payout account' using errcode = '23503';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION private.assert_commission_target()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.scope = 'vendor' and new.target_id is not null
     and not exists (select 1 from public.vendors where id = new.target_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: commission target' using errcode = '23503';
  end if;
  if new.scope = 'rider' and new.target_id is not null
     and not exists (select 1 from public.riders where id = new.target_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: commission target' using errcode = '23503';
  end if;
  return new;
end $function$;

-- =============================================================================
-- 4. Contact synchronisation. The customer pays the rider at the door, so the
--    two phone numbers must not drift apart.
-- =============================================================================

-- user profile changed -> push to the rider row. Returns NULL (AFTER-trigger
-- semantics via BEFORE: the profile row itself is untouched).
CREATE OR REPLACE FUNCTION private.push_user_contact_to_rider()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.phone_number is null then
    return null;
  end if;

  -- is-distinct-from guard: no-op when nothing changed, so riders.updated_at is not bumped on
  -- every unrelated profile edit.
  update public.riders r
     set first_name   = coalesce(new.first_name,   r.first_name),
         last_name    = coalesce(new.last_name,    r.last_name),
         phone_number = new.phone_number,
         country_code = coalesce(new.country_code, r.country_code)
   where r.user_id = new.id
     and (r.phone_number is distinct from new.phone_number
          or r.first_name    is distinct from coalesce(new.first_name,   r.first_name)
          or r.last_name     is distinct from coalesce(new.last_name,    r.last_name)
          or r.country_code  is distinct from coalesce(new.country_code, r.country_code));

  -- A rider changing their auth phone to a number another rider's profile already holds raises
  -- riders_phone_number_key and the profile update fails. Intended: two riders cannot share one
  -- contact number, and silently reassigning the row would be worse than refusing.
  return null;
end $function$;

-- rider row changed -> pull from the profile.
CREATE OR REPLACE FUNCTION private.sync_rider_contact_from_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_first text; v_last text; v_phone text; v_cc char(2);
begin
  if new.user_id is null then
    return new;
  end if;

  select u.first_name, u.last_name, u.phone_number, u.country_code
    into v_first, v_last, v_phone, v_cc
  from public.users u
   where u.id = new.user_id;

  if not found then
    return new;
  end if;

  if v_phone is not null then new.phone_number := v_phone; end if;
  if v_first is not null then new.first_name  := v_first; end if;
  if v_last  is not null then new.last_name   := v_last;  end if;
  if v_cc    is not null then new.country_code := v_cc;    end if;

  return new;
end $function$;

-- =============================================================================
-- 5. Order aggregation. This is the single writer of orders.status.
--
--    The order state machine is a fold over its sub_orders, most-terminal wins:
--      all cancelled/rejected  -> cancelled
--      all delivered           -> delivered
--      all terminal            -> partially_cancelled
--      all picked_up/delivering-> picked_up
--      all ready               -> ready
--      all preparing/ready     -> preparing
--      any past pending        -> partially_confirmed
--      else                    -> pending
-- =============================================================================
CREATE OR REPLACE FUNCTION private.recompute_order_aggregates(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  update public.orders o
     set status = (
           select case
             -- A total cancellation outranks everything.
             when bool_and(so.status in ('cancelled','rejected')) then 'cancelled'
             when bool_and(so.status = 'delivered') then 'delivered'
             when bool_and(so.status in ('cancelled','rejected','delivered'))
               then 'partially_cancelled'
             when bool_and(so.status in ('picked_up','delivering')) then 'picked_up'
             when bool_and(so.status = 'ready') then 'ready'
             when bool_and(so.status in ('preparing','ready')) then 'preparing'
             when bool_or(so.status in ('accepted','preparing','ready','picked_up','delivering','delivered'))
               then 'partially_confirmed'
             else 'pending'
           end
           from public.sub_orders so
          where so.order_id = p_order_id
         ),
         vendor_count = (select count(*) from public.sub_orders so where so.order_id = p_order_id),
         -- order_items.order_id is derived and correct, so this needs no join through sub_orders.
         item_count   = (select coalesce(sum(oi.quantity), 0)
                           from public.order_items oi where oi.order_id = p_order_id),
         confirmed_at = case
           when (select bool_and(so.status <> 'pending') from public.sub_orders so where so.order_id = p_order_id)
             then coalesce(o.confirmed_at, now()) else o.confirmed_at end,
         completed_at = case
           when (select bool_and(so.status in ('delivered','cancelled','rejected'))
                   from public.sub_orders so where so.order_id = p_order_id)
             then coalesce(o.completed_at, now()) else o.completed_at end
   where o.id = p_order_id;
end; $function$;

-- =============================================================================
-- 6. Pay resolution. Rider-specific rule wins; city default second; with no
--    rule at all, rider pay is zero and the WHOLE delivery fee is platform
--    revenue. That default is the launch posture, not an oversight.
-- =============================================================================
CREATE OR REPLACE FUNCTION private.pay_rule_for(p_rider_id uuid, p_city_id uuid)
 RETURNS rider_pay_rules
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_rule public.rider_pay_rules;
begin
  select * into v_rule from public.rider_pay_rules r
   where r.rider_id = p_rider_id and r.is_active
     and r.effective_from <= now()
     and (r.effective_until is null or r.effective_until > now())
   order by r.effective_from desc limit 1;
  if not found then
    select * into v_rule from public.rider_pay_rules r
     where r.city_id = p_city_id and r.rider_id is null and r.is_active
       and r.effective_from <= now()
       and (r.effective_until is null or r.effective_until > now())
     order by r.effective_from desc limit 1;
  end if;
  return v_rule;
end; $function$;

CREATE OR REPLACE FUNCTION private.resolve_pay(p_rider_id uuid, p_city_id uuid, p_delivery_fee integer, p_leg_km numeric, p_legs integer)
 RETURNS TABLE(rider_pay_base integer, rider_pay_distance integer, rider_pay_bonus integer, rider_pay_total integer, platform_revenue integer, has_rule boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_rule public.rider_pay_rules;
  v_hit  boolean := false;
begin
  v_rule := private.pay_rule_for(p_rider_id, p_city_id);
  v_hit := (v_rule.id is not null);

  if not v_hit then
    return query
      select 0, 0, 0, 0,
             coalesce((select round(p_delivery_fee::numeric * cr.value / 10000)::int
                        from public.commission_rules cr
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
$function$;

-- =============================================================================
-- 7. Geo, cash limit, reporting window
-- =============================================================================

-- Multi-stop route length: rider -> each vendor stop in order -> customer.
CREATE OR REPLACE FUNCTION private.trip_distance_km(p_rider_lat numeric, p_rider_lng numeric, p_vendor jsonb, p_cust_lat numeric, p_cust_lng numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare v_total numeric := 0; v_prev_lat numeric := p_rider_lat;
        v_prev_lng numeric := p_rider_lng; v_stop jsonb;
        v_lat numeric; v_lng numeric;
begin
  for v_stop in select * from jsonb_array_elements(coalesce(p_vendor,'[]'::jsonb))
  loop
    v_lat := (v_stop ->> 'latitude')::numeric;
    v_lng := (v_stop ->> 'longitude')::numeric;
    v_total := v_total + public.haversine_km(v_prev_lat, v_prev_lng, v_lat, v_lng);
    v_prev_lat := v_lat; v_prev_lng := v_lng;
  end loop;
  return round((v_total + public.haversine_km(v_prev_lat, v_prev_lng, p_cust_lat, p_cust_lng))::numeric, 3);
end; $function$;

-- Rider's own limit, else the platform default, else zero.
CREATE OR REPLACE FUNCTION private.effective_cash_limit(p_rider_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(
    (select max_cash_held from public.riders where id = p_rider_id),
    (select (value #>> '{}')::int from public.settings where key = 'rider_max_cash_held_default'),
    0
  );
$function$;

-- Default 30 days, clamped to 365, never rejected. A reversed range collapses
-- rather than raising: the caller passed the dates backwards and deserves a
-- legible empty report, not an error.
CREATE OR REPLACE FUNCTION private.earnings_window(p_from date, p_to date)
 RETURNS TABLE(win_from date, win_to date, win_clamped boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_tz text;
begin
  -- A11. The operating city's timezone, never the server's. `current_date` would be wrong for every
  -- evening hour in Cairo.
  select c.timezone into v_tz from public.cities c where c.is_primary;
  v_tz := coalesce(v_tz, 'UTC');

  win_to   := coalesce(p_to, (now() at time zone v_tz)::date);
  win_from := coalesce(p_from, win_to - 29);
  -- A reversed range yields an empty report rather than raising: a caller who passed the dates
  -- backwards deserves a legible answer, not an error.
  if win_from > win_to then
    win_from := win_to;
  end if;
  -- A18. Clamped, not rejected, and REPORTED as `range_clamped` in the response, so a caller that
  -- asked for two years is told its window was cut rather than silently handed a year of numbers.
  -- contracts.md 5 has no code for an over-long range and inventing one is not this file's job.
  win_clamped := win_from < win_to - 365;
  if win_clamped then
    win_from := win_to - 365;
  end if;
  return next;
end $function$;

CREATE OR REPLACE FUNCTION private.new_order_number()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_prefix text := private.setting_str('order_number_prefix', 'MK');
begin
  return v_prefix || '-' || to_char(now(), 'YYYYMMDD') || '-'
         || lpad(nextval('private.order_number_seq')::text, 8, '0');
end; $function$;

-- =============================================================================
-- 8. Utility
-- =============================================================================

-- Every business error is raised as one P0001 with a CODE: message prefix, so
-- the client parses the code off the front and never has to match on prose.
CREATE OR REPLACE FUNCTION private.err(p_code text, p_message text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception '%: %', p_code, p_message using errcode = 'P0001';
end; $function$;

-- Defensive uuid cast for jsonb values. Returns NULL instead of raising 22P02,
-- which is what lets an unresolvable option choice become an OPTION_UNAVAILABLE
-- rejection rather than a failed quote.
CREATE OR REPLACE FUNCTION private.try_uuid(p_text text)
 RETURNS uuid
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
begin
  if p_text is null then return null; end if;
  if p_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return null;
  end if;
  return p_text::uuid;
end; $function$;

-- The event -> recipient -> template routing table. Read by the outbox worker,
-- so adding a notification type is a row here, not a code change.
CREATE OR REPLACE FUNCTION private.push_routing()
 RETURNS TABLE(v_event_type text, v_payload_to text, v_recipient text, v_template_key text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select * from (values
    -- rider
    ('order.claimed',       null::text,    'rider',    'rider.order_assigned'),
    -- customer
    ('order.placed',        null,          'customer', 'order.placed'),
    ('order.status_changed','rejected',    'customer', 'order.vendor_rejected'),
    ('order.status_changed','picked_up',   'customer', 'order.picked_up'),
    ('order.delivered',     null,          'customer', 'order.delivered'),
    ('order.cancelled',     null,          'customer', 'order.cancelled'),
    -- vendor
    ('order.placed',        null,          'vendor',   'vendor.new_order')
  ) as t(v_event_type, v_payload_to, v_recipient, v_template_key);
$function$;

CREATE OR REPLACE FUNCTION private.notification_type_exists(p_type text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.notification_templates
    where key = p_type and is_active
  );
$function$;

-- =============================================================================
-- 9. Partition management. A new month's partition is created, RLS-enabled and
--    given a policy in the same call, so a partition can never be born open.
-- =============================================================================
CREATE OR REPLACE FUNCTION private.ensure_month_partition(p_table text, p_month date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_child text := p_table || '_' || to_char(v_start, 'YYYY_MM');
begin
  if p_table not in ('events','notifications','rider_location_pings','audit_log') then
    raise exception 'NOT_A_PARTITIONED_TABLE: %', p_table using errcode = 'P0001';
  end if;
  if to_regclass('public.' || v_child) is null then
    execute format('create table public.%I partition of public.%I for values from (%L) to (%L)',
                   v_child, p_table, v_start, v_end);
    execute format('alter table public.%I enable row level security', v_child);
    if p_table = 'notifications' then
      execute format('create policy %I on public.%I for select to authenticated using (user_id = (select auth.uid()))',
                     v_child || '_user_read', v_child);
    else
      execute format('create policy %I on public.%I for select to authenticated using ((select private.is_admin()))',
                     v_child || '_admin_read', v_child);
    end if;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION private.ensure_partitions()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_made integer := 0;
  t      text;
  m      date;
begin
  foreach t in array array['notifications', 'audit_log'] loop
    for i in 0..1 loop
      m := (date_trunc('month', now()) + (i || ' month')::interval)::date;
      perform private.ensure_month_partition(t, m);
    end loop;
  end loop;
  return v_made;
end $function$;

-- =============================================================================
-- 10. Retention. Each sweeper deletes in 1000-row batches and pauses 50ms
--     between them, so a sweep on a large table cannot monopolise the database.
--     Retention windows: events 7d delivered, notifications 30d, location 30d,
--     eta snapshots 24h.
-- =============================================================================
CREATE OR REPLACE FUNCTION private.prune_events()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_deleted integer := 0;
  v_batch   integer;
begin
  loop
    with d as (
      delete from public.events e
       where e.id in (
             select x.id from public.events x
              where x.delivered_at is not null
                and x.created_at  < now() - interval '7 days'
              order by x.created_at
              limit 1000)
      returning 1)
    select count(*) into v_batch from d;

    v_deleted := v_deleted + v_batch;
    exit when v_batch < 1000;
    perform pg_sleep(0.05);
  end loop;
  return v_deleted;
end $function$;

CREATE OR REPLACE FUNCTION private.prune_notifications()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_deleted integer := 0;
  v_batch   integer;
begin
  loop
    with d as (
      delete from public.notifications n
       where n.id in (
             select x.id from public.notifications x
              where x.created_at < now() - interval '30 days'
              order by x.created_at
              limit 1000)
      returning 1)
    select count(*) into v_batch from d;

    v_deleted := v_deleted + v_batch;
    exit when v_batch < 1000;
    perform pg_sleep(0.05);
  end loop;
  return v_deleted;
end $function$;

CREATE OR REPLACE FUNCTION private.prune_rider_location_pings()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_deleted integer := 0;
  v_batch   integer;
begin
  loop
    with d as (
      delete from public.rider_location_pings p
       where p.id in (
             select x.id from public.rider_location_pings x
              where x.recorded_at < now() - interval '30 days'
              order by x.recorded_at
              limit 1000)
      returning 1)
    select count(*) into v_batch from d;

    v_deleted := v_deleted + v_batch;
    exit when v_batch < 1000;
    perform pg_sleep(0.05);
  end loop;
  return v_deleted;
end $function$;

CREATE OR REPLACE FUNCTION private.prune_order_eta_snapshots()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_deleted integer := 0;
  v_batch   integer;
begin
  loop
    with d as (
      delete from public.order_eta_snapshots s
       where s.id in (
             select x.id from public.order_eta_snapshots x
              where x.computed_at < now() - interval '24 hours'
              order by x.computed_at
              limit 1000)
      returning 1)
    select count(*) into v_batch from d;

    v_deleted := v_deleted + v_batch;
    exit when v_batch < 1000;
    perform pg_sleep(0.05);
  end loop;
  return v_deleted;
end $function$;

-- =============================================================================
-- 11. THE PRICING ENGINE.
--     private.compute_quote() is 19 KB and is the single most important
--     function in this schema. It is reproduced verbatim in
--     16_functions_checkout.sql. It is listed here only as a reminder that it
--     lives in the private schema and is not callable by a client directly.
--     public.quote_order_v1() is the thin, authenticated wrapper around it.
-- =============================================================================