-- 038b: the `claim_events_v1` column-name fix.
--
-- `038` shipped a claim function that could not run. Two defects, both found by EXECUTING it rather than
-- by reading it, which is why `038e` makes a runtime call part of every migration that touches a plpgsql
-- function:
--
--   ERROR  42703: column e.v_recipient does not exist
--   `v_recipient` and `v_template_key` live in the ROUTING table, not on `events`. The CTE aliased the
--   joined function as `r`, so the select list had to read `r.v_recipient`, not `e.v_recipient`.
--
--   ERROR  42883: function min(uuid) does not exist
--   The vendor fan-out wanted one row per distinct vendor per order. `min(so.vendor_id)` is not a thing -
--   PostgreSQL has no `min(uuid)`. `select distinct so.vendor_id` is the correct expansion, and it is what
--   makes the fan-out a fan-out: one row per vendor, then collapsed per (recipient, template, order).
--
-- Both were shipped-broken because a plpgsql body is not validated at `create function` time. This file
-- keeps the fix SEPARATE from the probe, which is the mistake worth remembering: the first attempt put
-- this fix and a 700-line behavioural probe in one file, the probe failed for an unrelated reason, and the
-- transaction rolled the fix back with it - leaving the database with the broken function and a migration
-- history that claimed otherwise.

create or replace function public.claim_events_v1(
  p_limit int default 50
)
returns table (
  event_ids      bigint[],
  template_key   text,
  recipient      text,
  recipient_id   uuid,
  order_id       uuid,
  order_number   text,
  variables      jsonb,
  language       text,
  oldest_event   timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit int;
begin
  v_limit := greatest(1, least(coalesce(p_limit, 50), 200));

  return query
  with routing as (
    -- THE CLAIM. `events_undelivered (created_at) WHERE delivered_at IS NULL` is the claim filter and its
    -- ordering. `r.v_recipient` and `r.v_template_key` come from the ROUTING table - the `r.` prefix is
    -- the whole point of 038b.
    select e.id, e.created_at,
           r.v_recipient, r.v_template_key,
           (e.payload ->> 'order_id')::uuid as order_id
      from public.events e
      join private.push_routing() r
        on  r.v_event_type = e.type
        and r.v_payload_to is not distinct from (e.payload ->> 'to')
     where e.delivered_at is null
       and private.notification_type_exists(r.v_template_key)
       and (e.payload ? 'order_id')
     order by e.created_at, e.id
     limit v_limit
       for update of e skip locked
  ), addressed as (
    -- The addressee is resolved BEFORE the collapse, and the vendor half is EXPANDED: one row per
    -- distinct vendor on the order. Resolving the vendor AFTER the collapse would collapse a 3-vendor
    -- `order.placed` into one row with one arbitrarily-chosen vendor, and two vendors would never hear
    -- about the order.
    select r.id, r.created_at, r.v_recipient, r.v_template_key, r.order_id,
           o.user_id as customer_id,
           vc.vendor_id
      from routing r
      join public.orders o on o.id = r.order_id
      left join lateral (
        -- `distinct`, NOT `min(so.vendor_id)`: there is no `min(uuid)` in PostgreSQL. This is the second
        -- 038b defect.
        select distinct so.vendor_id
          from public.sub_orders so
         where so.order_id = r.order_id
      ) vc on r.v_recipient = 'vendor'
  ), collapsed as (
    -- THE COLLAPSE. One row per (recipient, recipient_id, template, order).
    select a.v_recipient,
           a.v_template_key,
           a.order_id,
           array_agg(a.id order by a.id) as event_ids,
           min(a.created_at)             as oldest_event,
           case a.v_recipient
             when 'customer' then a.customer_id
             when 'vendor'   then a.vendor_id
             when 'rider'    then (select da.rider_id
                                    from public.delivery_assignments da
                                   where da.order_id = a.order_id and da.rider_id is not null
                                   order by da.assigned_at nulls last
                                   limit 1)
           end                          as recipient_id
      from addressed a
     -- Grouped on the resolved addressee, NOT on the routing alone. Without the addressee in the key,
     -- all three vendors of one order share a group and exactly one of them is ever told.
     group by 1, 2, 3, 6
  ), resolved as (
    -- The display join, once per collapsed notification rather than once per event. `riders` is read
    -- directly rather than through `riders_public`: ADR 20 removed the table's client grants and gave
    -- clients the view, but this function runs with BYPASSRLS and needs no view.
    select c.*,
           o.order_number,
           o.total,
           o.vendor_count,
           o.item_count,
           o.payment_method,
           o.promised_delivery_at,
           v.name as vendor_name,
           (select trim(both ' ' from coalesce(r2.first_name,'') || ' ' || coalesce(r2.last_name,''))
              from public.riders r2
              join public.delivery_assignments da on da.rider_id = r2.id
             where da.order_id = c.order_id
             order by da.assigned_at nulls last
             limit 1) as rider_name,
           (select jsonb_array_length(coalesce(da.stop_sequence, '[]'::jsonb))
              from public.delivery_assignments da
             where da.order_id = c.order_id and da.rider_id is not null
             order by da.assigned_at nulls last
             limit 1) as stops
      from collapsed c
      join public.orders o on o.id = c.order_id
      left join public.vendors v on v.id = c.recipient_id and c.v_recipient = 'vendor'
  )
  select r.event_ids,
         r.v_template_key,
         r.v_recipient,
         r.recipient_id,
         r.order_id,
         r.order_number,
         jsonb_strip_nulls(jsonb_build_object(
           'order_number',   r.order_number,
           'vendor_count',   r.vendor_count,
           'total',          r.total,
           'vendor_name',    r.vendor_name,
           'rider_name',     nullif(r.rider_name, ''),
           'stops',          case when r.stops > 0 then r.stops end,
           'eta',            case when r.promised_delivery_at is not null
                                     then to_char(r.promised_delivery_at at time zone 'UTC', 'HH24:MI')
                                end,
           'payment_method', r.payment_method,
           'item_count',     r.item_count
         )),
         coalesce(
           (select t.lang from public.notification_templates t
             where t.key = r.v_template_key and t.channel = 'push' and t.is_active
               and t.lang = (select u.preferred_language from public.users u where u.id = r.recipient_id)),
           'en'
         ),
         r.oldest_event
    from resolved r
   where r.recipient_id is not null;
end;
$$;

comment on function public.claim_events_v1(int) is
  'Claim a batch of undelivered push-worthy events, collapsed one row per '
  '(recipient, recipient_id, template_key, order_id). service_role only.';

revoke execute on function public.claim_events_v1(int) from public, anon, authenticated;
grant execute on function public.claim_events_v1(int) to service_role;

-- The runtime call. Without it this file would have shipped the broken body a second time and been
-- recorded as applied, which is exactly what happened with `038`.
do $$
declare
  v_leaked text;
begin
  perform * from public.claim_events_v1(1);
  select string_agg(r, ', ' order by r) into v_leaked
    from unnest(array['public.claim_events_v1(int)']) as x(r)
   where has_function_privilege('anon', r, 'EXECUTE')
      or has_function_privilege('authenticated', r, 'EXECUTE');
  if v_leaked is not null then
    raise exception 'FAIL CLOSED: a client role can EXECUTE %.', v_leaked;
  end if;
end $$;