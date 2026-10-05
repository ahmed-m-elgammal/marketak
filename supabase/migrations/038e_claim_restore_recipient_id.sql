-- 038e: restore `recipient_id` in `collapsed`, and make the migration fail if the function cannot RUN.
--
-- WHAT 038d GOT WRONG. It reordered the `collapsed` select list and dropped the `recipient_id` CASE
-- expression on the floor while doing so, leaving `group by 1, 2, 3, 6` pointing at an AGGREGATE. The
-- migration applied SUCCESSFULLY and the assertion block passed, because PostgreSQL does not validate a
-- plpgsql body at `create function` time - it parses the body into a syntax tree and defers every name
-- and semantic check to first execution. So `038d` shipped a function that only fails when the drain
-- calls it, which is the worst possible time.
--
-- This is the SAME failure `038` shipped (`column e.v_recipient does not exist`) and the reason `038b`
-- exists. Two migrations in a row have now passed their own assertions while leaving a function that
-- cannot run, so the assertion approach is wrong and this file changes it.
--
-- THE FIX THAT ACTUALLY STOPS IT. A migration that touches a plpgsql function now ends with a CALL, not a
-- catalog check. `select count(*) from public.claim_events_v1(1)` compiles the whole body, resolves every
-- column reference, checks every group-by ordinal, and evaluates it. It costs one indexed scan of the
-- partial index. A function that cannot run cannot pass its own migration, and the `035` lesson applies in
-- reverse: a migration must not be able to install something broken and call it a day.
--
-- Catalog assertions are KEPT, because they check a different thing. `pg_proc` proves the grants are right;
-- the call proves the body is right. Neither substitutes for the other.

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
    -- ordering. `v_recipient` and `v_template_key` come from the ROUTING table, not from `events`.
    --
    -- `payload` and `aggregate_id` are carried through because three template variables live in the
    -- payload and one needs the sub_order id to aggregate `order_items`.
    select e.id, e.created_at, e.payload, e.aggregate_id,
           r.v_recipient, r.v_template_key,
           (e.payload ->> 'order_id')::uuid as order_id
      from public.events e
      join private.push_routing() r
        on  r.v_event_type = e.type
        and r.v_payload_to is not distinct from (e.payload ->> 'to')
     where e.delivered_at is null
       -- Not claimable while its template is missing or inactive, so the §11 item 8 alert still counts
       -- it rather than it vanishing silently.
       and private.notification_type_exists(r.v_template_key)
       -- An event with no order_id cannot be collapsed and has no recipient to resolve.
       and (e.payload ? 'order_id')
     order by e.created_at, e.id
     limit v_limit
       for update of e skip locked
  ), addressed as (
    -- The addressee is resolved BEFORE the collapse, and the vendor half is EXPANDED: one row per
    -- distinct vendor on the order.
    --
    -- This ordering is the whole reason the vendor fan-out works. Resolving the vendor AFTER the collapse
    -- would collapse a 3-vendor `order.placed` into one row with one arbitrarily-chosen vendor, and two
    -- vendors would never hear about the order. Expanding first and collapsing second gives three vendor
    -- rows and one customer row, which is a fan-out rather than a duplicate.
    select r.id, r.created_at, r.payload, r.aggregate_id,
           r.v_recipient, r.v_template_key, r.order_id,
           o.user_id as customer_id,
           vc.vendor_id
      from routing r
      join public.orders o on o.id = r.order_id
      left join lateral (
        -- `distinct`, NOT `min(so.vendor_id)`: there is no `min(uuid)` in PostgreSQL.
        select distinct so.vendor_id
          from public.sub_orders so
         where so.order_id = r.order_id
      ) vc on r.v_recipient = 'vendor'
  ), collapsed as (
    -- THE COLLAPSE. One row per (recipient, recipient_id, template, order). Three sub-orders reaching
    -- `picked_up` on one order is one push, carrying all three ids.
    --
    -- `recipient_id` is ORDINAL 4 and the `group by` says `1, 2, 3, 4`. Those two lines have to move
    -- together: 038d reordered this list, lost the CASE, and left the group by pointing at an aggregate.
    -- The CASE is deliberately ordinal rather than repeated in the `group by` so the link between "the
    -- addressee is part of the key" and "this expression computes the addressee" cannot drift apart
    -- again.
    select a.v_recipient,
           a.v_template_key,
           a.order_id,
           case a.v_recipient
             when 'customer' then a.customer_id
             when 'vendor'   then a.vendor_id
             when 'rider'    then (select da.rider_id
                                    from public.delivery_assignments da
                                   where da.order_id = a.order_id and da.rider_id is not null
                                   order by da.assigned_at nulls last
                                   limit 1)
           end                          as recipient_id,
           array_agg(a.id order by a.id) as event_ids,
           min(a.created_at)             as oldest_event,
           -- `reason`. `cancel_order_v1` writes ONE `order.cancelled` event per order, so the group has one
           -- payload value and this is a formality. `order by a.id` + `limit 1` is used rather than
           -- `min()` so that ordering is defined even if a future emitter ever emits two, and so the value
           -- is the OLDEST reason rather than alphabetically-first, which is the more defensible choice
           -- when two exist.
           (select x from unnest(array_agg(a.payload ->> 'reason' order by a.id)) x
             where x is not null limit 1) as reason,
           -- `refund_amount`. SUMMED, not taken from one event, for the same reason: if a partial refund
           -- and a full refund were both emitted the customer should be told the combined figure. The
           -- `->>` cast makes these text[]; `::int` is safe because the emitter built it from an integer.
           coalesce((select sum(x::int)
                       from unnest(array_remove(array_agg(a.payload ->> 'refund_amount' order by a.id),
                                               null)) x), 0) as refund_amount,
           -- `rider_pay_total`, same first-non-null treatment as `reason`: one `order.claimed` per order.
           (select x::int from unnest(array_agg(a.payload ->> 'rider_pay_total' order by a.id)) x
             where x is not null limit 1) as rider_pay_total,
           -- The sub_orders this notification is actually about, so `affected_items` sums over exactly
           -- them. Filtered to the rejection template because `aggregate_id` on a `sub_order` aggregate is
           -- a sub_order, but on `order.placed` it is the ORDER - summing `order_items` for an order id
           -- would silently count every item on every sub_order.
           array_agg(distinct a.aggregate_id)
             filter (where a.v_template_key = 'order.vendor_rejected') as rejected_sub_orders
      from addressed a
     -- Grouped on the resolved addressee, NOT on the routing alone. This is the difference between one
     -- notification and three: without the addressee in the key, all three vendors of one order share a
     -- group and exactly one of them is ever told.
     group by 1, 2, 3, 4
  ), resolved as (
    -- The display join, once per collapsed notification rather than once per event. `riders` is read
    -- directly rather than through `riders_public`: ADR 20 removed the table's client grants and gave
    -- clients the view, but this function runs with BYPASSRLS and needs no view. Had it been
    -- `authenticated`-callable, `rider_name` would have had to come from the view instead - the one place
    -- where the grant decision changes the SQL and not only the privilege.
    select c.*,
           o.order_number,
           o.total,
           o.vendor_count,
           o.item_count,
           o.payment_method,
           o.promised_delivery_at,
           v.name as vendor_name,
           -- `affected_items`: total QUANTITY, not a row count. `{affected_items}` reads as a count of
           -- things in a sentence, and one `order_items` row can be quantity 4. SUMMED over the
           -- sub_orders named by the collapsed rejection events, so two vendors rejecting three lines
           -- between them report six, not two.
           --
           -- `coalesce(..., 0)` rather than null: a rejection always affected something, so zero would be
           -- a lie, but the query MUST return a number because the template interpolates it directly.
           (select coalesce(sum(oi.quantity), 0)
              from public.order_items oi
             where oi.sub_order_id = any (coalesce(c.rejected_sub_orders, '{}'::uuid[]))) as affected_items,
           -- The rejection reason, read from the sub_order the transition function wrote it to.
           -- `transition_order_v1` persists it in `sub_orders.rejection_reason` and does NOT put it in the
           -- event payload, so this is the only place it exists.
           (select min(so.rejection_reason)
              from public.sub_orders so
             where so.id = any (coalesce(c.rejected_sub_orders, '{}'::uuid[]))
               and so.rejection_reason is not null) as rejection_reason,
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
         -- `jsonb_strip_nulls` so a variable the join could not supply is ABSENT rather than
         -- present-and-null. A missing key is a renderer error; a null is a silent empty string, which is
         -- how an Arabic message ends up with a hole in it.
         jsonb_strip_nulls(jsonb_build_object(
           'order_number',    r.order_number,
           'vendor_count',    r.vendor_count,
           'total',           r.total,
           'vendor_name',     r.vendor_name,
           -- `reason` falls back to the persisted rejection reason so a vendor-rejection notification
           -- still reads correctly; `rejection_reason` then drops out via `jsonb_strip_nulls`.
           'reason',          coalesce(r.reason, r.rejection_reason),
           'refund_amount',   r.refund_amount,
           'rider_pay_total', r.rider_pay_total,
           -- `affected_items` is gated on the template: on any other notification the sub_order list is
           -- empty, the sum is 0, and a literal `0` would read as a real count.
           'affected_items',  case when r.v_template_key = 'order.vendor_rejected'
                                     then r.affected_items end,
           'rider_name',      nullif(r.rider_name, ''),
           'stops',           case when r.stops > 0 then r.stops end,
           'eta',             case when r.promised_delivery_at is not null
                                      then to_char(r.promised_delivery_at at time zone 'UTC', 'HH24:MI')
                                 end,
           'payment_method',  r.payment_method,
           'item_count',      r.item_count
         )),
         -- `preferred_language` is ar/en and both rows exist for all 19 keys, so this fallback is
         -- unreachable in practice. It is here so a missing row degrades to English rather than raising
         -- inside the drain and stalling every subsequent notification.
         coalesce(
           (select t.lang from public.notification_templates t
             where t.key = r.v_template_key and t.channel = 'push' and t.is_active
               and t.lang = (select u.preferred_language from public.users u where u.id = r.recipient_id)),
           'en'
         ),
         r.oldest_event
    from resolved r
   -- A collapsed row with no resolved recipient cannot be delivered to anyone. Left unclaimed rather than
   -- marked, so the backlog keeps showing it.
   where r.recipient_id is not null;
end;
$$;

comment on function public.claim_events_v1(int) is
  'Claim a batch of undelivered push-worthy events, collapsed one row per '
  '(recipient, recipient_id, template_key, order_id). service_role only. Returns event_ids for the '
  'collapsed group so mark_events_delivered_v1 can close exactly those rows.';

revoke execute on function public.claim_events_v1(int) from public, anon, authenticated;
grant execute on function public.claim_events_v1(int) to service_role;

-- THE RUNTIME CHECK. Plpgsql bodies are not validated at `create function` time, so this CALL is the only
-- assertion in the file that can catch a wrong column, a wrong ordinal, or a wrong aggregate. Everything
-- below it is catalog state, which a broken body passes happily.
do $$
declare
  v_leaked text;
  v_unrenderable text;
  c_worker_owned   constant text[] := array['review_prompt', 'action_required', 'prep_deadline'];
  c_claim_supplies constant text[] := array[
    'order_number', 'vendor_count', 'total', 'vendor_name', 'reason', 'refund_amount',
    'rider_pay_total', 'affected_items', 'rider_name', 'stops', 'eta',
    'payment_method', 'item_count'
  ];
begin
  perform * from public.claim_events_v1(1);
  perform * from public.mark_events_delivered_v1('{}'::bigint[], null);

  -- `anon` and `authenticated` must hold no EXECUTE. `events` has one SELECT policy and no INSERT or
  -- UPDATE policy, so a client that could call the drain could mark arbitrary events delivered and hold
  -- `attempts` flat, which would blind the §11 item 8 backlog alarm.
  select string_agg(r, ', ' order by r) into v_leaked
    from unnest(array[
      'public.claim_events_v1(int)',
      'public.mark_events_delivered_v1(bigint[],jsonb)']) as x(r)
   where has_function_privilege('anon', r, 'EXECUTE')
      or has_function_privilege('authenticated', r, 'EXECUTE');
  if v_leaked is not null then
    raise exception 'FAIL CLOSED: a client role can EXECUTE %. Revoke AFTER create.', v_leaked;
  end if;

  -- Every placeholder a ROUTED template names must be supplied by the claim function or the Worker.
  -- Scoped by joining the routing table: the 12 active push templates the MVP does not route want
  -- `{amount}`, `{period}` and friends that no emitter produces yet, which is Phase 4 work.
  select string_agg(format('%s (/%s) wants {%s}', t.key, t.lang, m.name[1]), '; '
                     order by t.key, t.lang, m.name[1])
    into v_unrenderable
    from private.push_routing() rt
    join public.notification_templates t
      on t.key = rt.v_template_key and t.channel = 'push' and t.is_active
    cross join lateral regexp_matches(t.body, '\{(\w+)\}', 'g') as m(name)
   where m.name[1] <> all (c_worker_owned)
     and m.name[1] <> all (c_claim_supplies);
  if v_unrenderable is not null then
    raise exception
      'Template placeholder nobody supplies: %. Add it to claim_events_v1 variables, or to the Worker '
      'static map, or remove it from the body.', v_unrenderable;
  end if;
end $$;