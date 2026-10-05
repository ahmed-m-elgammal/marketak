-- 038d: supply the four template variables `claim_events_v1` did not return.
--
-- WHY. Three of the seven MVP templates could not be rendered. Read from the live
-- `notification_templates`, `lang='en'`:
--
--   order.cancelled        Your order was cancelled: {reason}. Refunded {refund_amount}.
--   order.vendor_rejected  {vendor_name} declined part of your order: {affected_items}. You need to {action_required}.
--   rider.order_assigned   Order {order_number} is yours. {stops} stop(s). Earnings {rider_pay_total}.
--
-- `038b`'s `variables` object carried only order_number, vendor_count, total, vendor_name, rider_name,
-- stops, eta, payment_method and item_count. Three of those seven notifications therefore reached the
-- Worker with a hole where the sentence needed a word, and `jsonb_strip_nulls` would have made the hole
-- ABSENT rather than visibly null - which is the worse failure, because a renderer that does not check
-- for a missing key prints the literal `{reason}` to the customer.
--
-- WHERE THE VALUES COME FROM. Read out of the live emitters, not assumed:
--
--   reason          cancel_order_v1  already writes payload.reason
--   refund_amount   cancel_order_v1  already writes payload.refund_amount
--   rider_pay_total claim_order_v1   already writes payload.rider_pay_total
--
-- So three of the four are one-line changes to read what the emitter already produced. That is the whole
-- argument for this migration being a two-column fix rather than a new derivation: the emitters were
-- right all along and the claim function was the only thing that dropped the values on the floor.
--
--   affected_items  NOT in any payload. `transition_order_v1` emits
--                   `order.status_changed` with only {order_id, sub_order_id, actor_user_id, actor_role,
--                   from, to} - no item count and no reason. The rejection reason lives in
--                   `sub_orders.rejection_reason` and the item count has to be summed from `order_items`.
--                   So this one IS derived here, and it is the only genuinely new computation in the file.
--
-- The three remaining unrendered placeholders - `action_required`, `review_prompt`, `prep_deadline` - are
-- deliberately NOT supplied here. They are static strings with no per-order content, and duplicating them
-- into the database would give an admin one more place to edit a notification by mistake. They stay
-- Worker-owned, which is recorded in the plan rather than left implicit.
--
-- MONEY IS PASSED RAW, NOT FORMATTED. `rider_pay_total` is piastres, exactly like the `total` that `038b`
-- already returned. Formatting it here would put currency formatting in two places that must then agree,
-- and the constitution makes every money constant configuration rather than a literal - a formatted string
-- baked into SQL cannot be configuration. The Worker formats `total` and `rider_pay_total` through the one
-- money helper in `packages/shared`. Two integers in, one formatter out.

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
    -- `payload` and `aggregate_id` are now carried through because three template variables live in the
    -- payload and one needs the sub_order id to aggregate `order_items`. `038b` selected neither, which is
    -- exactly why it could not render them.
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
    select a.v_recipient,
           a.v_template_key,
           a.order_id,
           array_agg(a.id order by a.id) as event_ids,
           min(a.created_at)             as oldest_event,
           -- `reason`. `cancel_order_v1` writes ONE `order.cancelled` event per order, so the group has
           -- one payload value and this is a formality. `order by a.id` + `limit 1` is used rather than
           -- `min()` so that ordering is defined even if a future emitter ever emits two, and so the
           -- value is the OLDEST reason rather than alphabetically-first, which is the more defensible
           -- choice when two exist.
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
           -- The sub_orders this notification is actually about, so `affected_items` can be summed over
           -- exactly them. Filtered to the rejection template because `aggregate_id` on a `sub_order`
           -- aggregate is a sub_order, but on `order.placed` it is the ORDER - summing `order_items` for
           -- an order id would silently count every item on every sub_order.
           array_agg(distinct a.aggregate_id)
             filter (where a.v_template_key = 'order.vendor_rejected') as rejected_sub_orders
      from addressed a
     -- Grouped on the resolved addressee, NOT on the routing alone. This is the difference between one
     -- notification and three: without the addressee in the key, all three vendors of one order share a
     -- group and exactly one of them is ever told. Ordinal 6 is the `recipient_id` expression.
     group by 1, 2, 3, 6
  ), resolved as (
    -- The display join, once per collapsed notification rather than once per event. `riders` is read
    -- directly rather than through `riders_public`: ADR 20 removed the table's client grants and gave
    -- clients the view, but this function runs with BYPASSRLS and needs no view. Had it been
    -- `authenticated`-callable, `rider_name` would have had to come from the view instead - the one
    -- place where the grant decision changes the SQL and not only the privilege.
    select c.*,
           o.order_number,
           o.total,
           o.vendor_count,
           o.item_count,
           o.payment_method,
           o.promised_delivery_at,
           v.name as vendor_name,
           -- `affected_items`: total QUANTITY, not a row count. `{affected_items}` reads as a count of
           -- things in a sentence ("declined 3 items"), and one `order_items` row can be quantity 4.
           -- SUMMED over the sub_orders named by the collapsed rejection events, so two vendors
           -- rejecting three lines between them report six, not two.
           --
           -- `coalesce(..., 0)` rather than null: a rejection always affected something, so zero would
           -- be a lie, but the query MUST return a number because the template will interpolate it
           -- directly. `left join` rather than an inner one so an order whose items were pruned by a
           -- retention job still renders instead of dropping the notification entirely.
           (select coalesce(sum(oi.quantity), 0)
              from public.order_items oi
             where oi.sub_order_id = any (coalesce(c.rejected_sub_orders, '{}'::uuid[]))) as affected_items,
           -- The rejection reason, read from the sub_order the transition function wrote it to.
           -- `transition_order_v1` persists it in `sub_orders.rejection_reason` and does NOT put it in
           -- the event payload, so this is the only place it exists.
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
           'order_number',   r.order_number,
           'vendor_count',   r.vendor_count,
           'total',          r.total,
           'vendor_name',    r.vendor_name,
           -- `reason` falls back to the persisted rejection reason so a vendor-rejection notification
           -- still reads correctly, and `rejection_reason` then drops out via `jsonb_strip_nulls`.
           'reason',         coalesce(r.reason, r.rejection_reason),
           'refund_amount',  r.refund_amount,
           'rider_pay_total',r.rider_pay_total,
           'affected_items', case when r.v_template_key = 'order.vendor_rejected'
                                   then r.affected_items end,
           'rider_name',     nullif(r.rider_name, ''),
           'stops',          case when r.stops > 0 then r.stops end,
           'eta',            case when r.promised_delivery_at is not null
                                     then to_char(r.promised_delivery_at at time zone 'UTC', 'HH24:MI')
                                end,
           'payment_method', r.payment_method,
           'item_count',     r.item_count
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

-- Every placeholder an ACTIVE push template names must be supplied by one of exactly two places: the claim
-- function's `variables`, or the Worker's static map. Checked from the CATALOG rather than from the
-- template bodies being frozen, so a later edit that adds a placeholder without teaching either side about
-- it fails HERE rather than reaching a customer as a literal `{placeholder}`.
--
-- The Worker-owned set is written out explicitly rather than implied by an exclusion. An exclusion list
-- would let a typo in a template key silently widen the hole it was meant to close.
do $$
declare
  v_unrenderable text;
  v_leaked text;
  c_worker_owned   constant text[] := array['review_prompt', 'action_required', 'prep_deadline'];
  c_claim_supplies constant text[] := array[
    'order_number', 'vendor_count', 'total', 'vendor_name', 'reason', 'refund_amount',
    'rider_pay_total', 'affected_items', 'rider_name', 'stops', 'eta',
    'payment_method', 'item_count'
  ];
begin
  select string_agg(format('%s (/%s) wants {%s}', t.key, t.lang, m.name), '; ' order by t.key, t.lang, m.name)
    into v_unrenderable
    from public.notification_templates t
    cross join lateral regexp_matches(t.body, '\{(\w+)\}', 'g') as m(name)
   where t.channel = 'push'
     and t.is_active
     and m.name <> all (c_worker_owned)
     and m.name <> all (c_claim_supplies);
  if v_unrenderable is not null then
    raise exception
      'Template placeholder nobody supplies: %. Add it to claim_events_v1 variables, or to the Worker '
      'static map, or remove it from the body.', v_unrenderable;
  end if;

  select string_agg(r, ', ' order by r) into v_leaked
    from unnest(array['public.claim_events_v1(int)']) as x(r)
   where has_function_privilege('anon', r, 'EXECUTE')
      or has_function_privilege('authenticated', r, 'EXECUTE');
  if v_leaked is not null then
    raise exception 'FAIL CLOSED: a client role can EXECUTE %. Revoke after create.', v_leaked;
  end if;
end $$;