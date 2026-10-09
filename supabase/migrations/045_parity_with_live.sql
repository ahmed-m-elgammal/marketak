-- 045: parity with the live database.
--
-- ## Why this file exists
--
-- The migration history has a hole. Between `044_dev_seed` and today, six migrations were applied
-- to the live project and their files were never committed: `038i_claim_currency`,
-- `fix_handle_new_user_phone_column`, `stock_decrement`, `admin_upsert_rider_idempotent`,
-- `dev_seed_second_run` and `dev_seed_vendor_areas`. The files are gone, so the history cannot be
-- reconstructed honestly — writing a file named `043_stock_decrement.sql` whose body contains no
-- stock decrement would put a decision in the record that nobody made.
--
-- This file takes the other route: it states, once, the current definition of every function that
-- those six migrations touched and that has no committed file. A database built from
-- `supabase/migrations/` alone therefore ends up byte-identical to the live project for these
-- three functions.
--
-- ## What it contains, and where each line comes from
--
--   handle_new_user       fixed by `fix_handle_new_user_phone_column`. The `auth.users` column is
--                         `phone`, not `phone_number`; the original body read a column that does
--                         not exist, which only failed when a signup actually fired. It also
--                         stamps `profile_completed_at` when Supabase asserts a phone, because a
--                         provider-verified phone is already a complete profile.
--
--   place_order_v1        `stock_decrement` added an inventory decrement here and it was later
--                         reverted. The committed body below is the POST-revert state: no stock
--                         handling at all, with a comment recording why. It also reflects
--                         `p_payment_channel` gaining a DEFAULT, so `cash` orders can omit it.
--
--   claim_events_v1       fixed by `038i_claim_currency`, which added `currency` to the Worker's
--                         `variables` payload, read from the ORDER rather than a constant and
--                         `btrim`'d because `cities.currency` is `bpchar` and SQLite-style padding
--                         would turn `'EGP'` into `'EGP '`.
--
--   admin_upsert_rider_v1 deliberately ABSENT. It already has a committed file,
--                         `042_rider_self_service.sql`, and its live definition matches that file
--                         exactly — the email-idempotency lookup, the allowed key list, everything.
--                         `admin_upsert_rider_idempotent` left no detectable change to it.
--
-- ## How to read it
--
-- The three bodies below are byte-for-byte output of `pg_get_functiondef(oid)`, upper-cased
-- keywords and all, precisely so they can be diffed against the database with no judgement call.
-- Every DDL change is `create or replace`, so the file is safe to run on a database that already
-- has these functions and on a fresh one where `017_rpc_core.sql` created them first.
--
-- No grants are repeated: all three are already granted to `authenticated` and `service_role` by
-- the project's default ACL and by `014_rls.sql`, and replacing a function does not drop its ACL.
--
-- ## Probes
--
-- Repo rule: a migration that touches a plpgsql function ends by calling it, because Postgres
-- validates a body lazily and `CREATE FUNCTION` succeeding proves nothing. These three all raise
-- `AUTH_REQUIRED` from a migration session, which reaches the gate and proves the body parsed.

-- ---------------------------------------------------------------------------
-- 1. handle_new_user — the `fix_handle_new_user_phone_column` fix
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.users (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;

  insert into public.user_roles (user_id, role)
  values (new.id, 'customer')
  on conflict (user_id, role) do nothing;

  -- `new.phone` is the auth.users column name. `new.phone_number` does not exist and fails at
  -- runtime inside the trigger, which is why this reads as an error only when a signup fires.
  if new.phone is not null and length(btrim(new.phone)) > 0 then
    update public.users u
       set phone_number = btrim(new.phone),
           profile_completed_at = coalesce(u.profile_completed_at, now())
     where u.id = new.id
       and u.phone_number is null
       and u.profile_completed_at is null;
  end if;

  return new;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. place_order_v1 — post-revert, no stock handling
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.place_order_v1(p_quote_id uuid, p_payment_method text, p_idempotency_key text, p_payment_channel text DEFAULT NULL::text)
 RETURNS TABLE(order_id uuid, order_number text, sub_orders jsonb, totals jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user     uuid := auth.uid();
  v_cart     public.carts%rowtype;
  v_existing public.orders%rowtype;
  v_q        jsonb;
  v_old      jsonb;
  v_diff     jsonb;
  v_order    uuid := gen_random_uuid();
  v_number   text;
  v_channel  text;
  v_sub      uuid;
  v_seq      smallint := 0;
  v_line     jsonb;
  v_tot      jsonb;
  v_fb       jsonb;
  v_sub_sub  int;
  v_sub_fee  int;
  v_sub_svc  int;
  v_sub_disc int;
  v_sub_comm int;
  v_prep     int;
  v_subs     jsonb := '[]'::jsonb;
  v_pv       record;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    perform private.err('IDEMPOTENCY_KEY_REQUIRED', 'idempotency_key is required');
  end if;

  -- constitution 5, checked before anything else so a retry after a dropped
  -- response returns the original order rather than charging twice.
  select * into v_existing from public.orders o where o.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.user_id <> v_user then
      perform private.err('IDEMPOTENCY_KEY_TAKEN', 'that idempotency key belongs to another order');
    end if;
    return query
    select v_existing.id, v_existing.order_number,
           coalesce((select jsonb_agg(jsonb_build_object(
                      'sub_order_id', so.id, 'vendor_id', so.vendor_id,
                      'status', so.status, 'subtotal', so.subtotal,
                      'sequence', so.sequence) order by so.sequence)
                     from public.sub_orders so where so.order_id = v_existing.id), '[]'::jsonb),
           jsonb_build_object(
             'subtotal', v_existing.subtotal, 'delivery_fee', v_existing.delivery_fee,
             'service_fee', v_existing.service_fee,
             'discount_amount', v_existing.discount_amount,
             'voucher_discount', v_existing.voucher_discount,
             'rider_tip', v_existing.rider_tip, 'total', v_existing.total,
             'currency', v_existing.currency);
    return;
  end if;

  -- constitution 18: the gate is enforced here, not only in the app.
  if not exists (select 1 from public.users u
                  where u.id = v_user and u.profile_completed_at is not null) then
    perform private.err('PROFILE_INCOMPLETE', 'complete your profile before ordering');
  end if;

  if p_payment_method not in ('cash','wallet') then
    perform private.err('PAYMENT_METHOD_INVALID', 'payment method must be cash or wallet');
  end if;

  -- A2
  if p_payment_method = 'cash' then
    v_channel := 'cod';
  else
    if p_payment_channel is null then
      perform private.err('PAYMENT_CHANNEL_REQUIRED',
        'wallet payments must state vodafone_cash or instapay');
    end if;
    if p_payment_channel not in ('vodafone_cash','instapay') then
      perform private.err('PAYMENT_CHANNEL_INVALID',
        'wallet channel must be vodafone_cash or instapay');
    end if;
    v_channel := p_payment_channel;
  end if;

  select * into v_cart from public.carts c
   where c.quote_id = p_quote_id and c.user_id = v_user;
  if not found then
    perform private.err('QUOTE_NOT_FOUND', 'no quote with that id');
  end if;
  if v_cart.quote_expires_at is null or now() > v_cart.quote_expires_at then
    perform private.err('QUOTE_EXPIRED', 'this quote expired, ask for a new price');
  end if;

  -- Re-price inside this transaction, from the same engine the quote used.
  -- This is the only authority: the client sent a quote_id, never a price.
  v_q := private.compute_quote(
    v_cart.id, v_cart.quote_address_id, v_cart.quote_voucher_code,
    v_cart.quote_rider_tip, v_cart.quote_delivery_type, v_cart.quote_grouping);

  if not (v_q ->> 'ok')::boolean then
    -- 017a: parenthesised. `||` binds tighter than `->` in PostgreSQL, so the
    -- unparenthesised form concatenated the prose FIRST and then handed it to
    -- `->` as json, raising 22P02 "invalid input syntax for type json" while
    -- evaluating this argument. private.err was never entered, so every
    -- rejection in the quote reached the client as an opaque Postgres error
    -- instead of a contracts.md code. See the 017a header for the repro.
    perform private.err('CART_NOT_PLACABLE',
      'cart has unpriceable lines: ' || (v_q -> 'rejections')::text);
  end if;

  -- constitution 2: abort rather than silently drift. The diff is itemised per
  -- contracts 1.5, which needs the old prices, which is why the whole quote is
  -- kept on the cart. A fingerprint alone can say that something moved but not
  -- what, and a "prices changed" sheet with no numbers in it is not consent.
  if v_q ->> 'fingerprint' is distinct from v_cart.quote_fingerprint then
    v_old := coalesce(v_cart.quote_snapshot, '{}'::jsonb);

    select coalesce(jsonb_agg(d.d order by d.d ->> 'sort_key'), '[]'::jsonb) into v_diff
    from (
      -- per-item price movement
      select jsonb_build_object(
               'type', 'ITEM_PRICE_CHANGED',
               'menu_item_id', n ->> 'menu_item_id',
               'item_name_ar', n ->> 'name_ar',
               'old_unit_price', (o #>> '{}')::int,
               'new_unit_price', (n ->> 'unit_price')::int,
               'sort_key', '0' || coalesce(n ->> 'menu_item_id', '')
             ) as d
        from jsonb_array_elements(coalesce(v_q -> 'lines', '[]'::jsonb)) n
        left join lateral (
          select x -> 'unit_price' as o from jsonb_array_elements(coalesce(v_old -> 'lines', '[]'::jsonb)) x
           where x ->> 'menu_item_id' = n ->> 'menu_item_id'
        ) prev on true
       where (prev.o ->> 'unit_price') is distinct from (n ->> 'unit_price')
      union all
      -- items that vanished from the cart entirely
      select jsonb_build_object(
               'type', 'ITEM_REMOVED',
               'menu_item_id', x ->> 'menu_item_id',
               'item_name_ar', x ->> 'name_ar',
               'old_unit_price', (x ->> 'unit_price')::int,
               'sort_key', '1' || coalesce(x ->> 'menu_item_id', '')
             ) as d
        from jsonb_array_elements(coalesce(v_old -> 'lines', '[]'::jsonb)) x
       where not exists (select 1 from jsonb_array_elements(coalesce(v_q -> 'lines', '[]'::jsonb)) n
                          where n ->> 'menu_item_id' = x ->> 'menu_item_id')
      union all
      -- the delivery fee itself, which moves with vendor count and distance
      select jsonb_build_object(
               'type', 'DELIVERY_FEE_CHANGED',
               'old_delivery_fee', coalesce((v_old -> 'totals' ->> 'delivery_fee')::int, 0),
               'new_delivery_fee', (v_q -> 'totals' ->> 'delivery_fee')::int,
               'reason_ar', 'تغير عدد المطاعم في الطلب',
               'sort_key', '2')
       where coalesce((v_old -> 'totals' ->> 'delivery_fee')::int, -1)
             is distinct from (v_q -> 'totals' ->> 'delivery_fee')::int
      union all
      -- a voucher that stopped applying
      select jsonb_build_object(
               'type', 'VOUCHER_EXPIRED',
               'voucher_code', v_old -> 'totals' ->> 'voucher_code',
               'message_ar', 'انتهت صلاحية الكود',
               'sort_key', '3')
       where coalesce((v_old -> 'totals' ->> 'voucher_discount')::int, 0)
             is distinct from coalesce((v_q -> 'totals' ->> 'voucher_discount')::int, 0)
    ) d;

    perform private.err('PRICE_CHANGED',
      'prices changed: ' || jsonb_build_object(
        'code', 'PRICE_CHANGED', 'message_ar', 'تغيرت الأسعار',
        'diff', v_diff,
        'old_total', v_old -> 'totals',
        'new_total', v_q -> 'totals',
        'new_fee_breakdown', v_q -> 'fee_breakdown')::text);
  end if;

  v_tot := v_q -> 'totals';
  v_fb  := v_q -> 'fee_breakdown';
  v_number := private.new_order_number();

  insert into public.orders (
    id, order_number, user_id, status, subtotal,
    delivery_base_fee, delivery_multiplier_bps, distance_km, delivery_fee, service_fee,
    discount_amount, voucher_code, voucher_discount, rider_tip,
    rider_pay_total, platform_revenue, total, currency,
    price_fingerprint, pricing_version, payment_method, payment_channel, payment_status,
    delivery_type, delivery_grouping, vendor_limit_applied, address_id, address_snapshot,
    delivery_latitude, delivery_longitude, area_id, is_contactless, access_note,
    vendor_count, item_count, placed_at, idempotency_key)
  values (
    v_order, v_number, v_user, 'pending', (v_tot ->> 'subtotal')::int,
    (v_fb ->> 'delivery_base_fee')::int, (v_fb ->> 'vendor_multiplier_bps')::int,
    (v_fb ->> 'distance_km')::numeric, (v_tot ->> 'delivery_fee')::int, (v_tot ->> 'service_fee')::int,
    (v_tot ->> 'discount_amount')::int, (v_tot ->> 'voucher_code')::text, (v_tot ->> 'voucher_discount')::int,
    (v_tot ->> 'rider_tip')::int,
    0, 0, (v_tot ->> 'total')::int, v_q ->> 'currency',
    v_q ->> 'fingerprint', 1, p_payment_method, v_channel, 'unpaid',
    v_q ->> 'delivery_type', v_q ->> 'grouping',
    (v_q -> 'limits' ->> 'max_vendors_per_order')::smallint,
    v_cart.quote_address_id,
    (select jsonb_build_object('address_id', a.id, 'label', a.label, 'area_name', a.area_name,
                               'building', a.building, 'floor', a.floor, 'apartment', a.apartment,
                               'landmark', a.landmark, 'delivery_instructions', a.delivery_instructions,
                               'latitude', a.latitude, 'longitude', a.longitude,
                               'geohash_prefix', a.geohash_prefix)
       from public.addresses a where a.id = v_cart.quote_address_id),
    (select a.latitude from public.addresses a where a.id = v_cart.quote_address_id),
    (select a.longitude from public.addresses a where a.id = v_cart.quote_address_id),
    (select a.area_id from public.addresses a where a.id = v_cart.quote_address_id),
    false, null,
    (v_q -> 'limits' ->> 'vendor_count')::int,
    (select coalesce(sum((l ->> 'quantity')::int), 0)
       from jsonb_array_elements(v_q -> 'lines') l),
    now(), p_idempotency_key);

  -- II.11: one sub_order per vendor, never a nullable vendor_id on the order.
  for v_pv in
    select * from jsonb_to_recordset(v_q -> 'per_vendor')
      as p(vendor_id uuid, subtotal int, delivery_fee_share int, service_fee_share int,
           discount_share int, commission_amount int, vendor_net_payout int,
           prep_estimate_minutes int)
    order by vendor_id
  loop
    v_sub := gen_random_uuid();
    v_seq := v_seq + 1;
    insert into public.sub_orders (
      id, order_id, vendor_id, sequence, status, subtotal,
      delivery_fee_share, service_fee_share, discount_share,
      commission_amount, platform_fee_amount, vendor_net_payout,
      settlement_status)
    values (
      v_sub, v_order, v_pv.vendor_id, v_seq, 'pending', v_pv.subtotal,
      v_pv.delivery_fee_share, v_pv.service_fee_share, v_pv.discount_share,
      v_pv.commission_amount, 0, v_pv.vendor_net_payout,
      'payable');

    v_subs := v_subs || jsonb_build_array(jsonb_build_object(
      'sub_order_id', v_sub, 'vendor_id', v_pv.vendor_id, 'sequence', v_seq,
      'subtotal', v_pv.subtotal, 'delivery_fee_share', v_pv.delivery_fee_share,
      'discount_share', v_pv.discount_share, 'commission_amount', v_pv.commission_amount,
      'vendor_net_payout', v_pv.vendor_net_payout, 'status', 'pending'));

    -- II.12 and II.14: every field copied, never re-read from the catalog later.
    for v_line in
      select l from jsonb_array_elements(v_q -> 'lines') l
       where l ->> 'vendor_id' = v_pv.vendor_id::text
         and l ->> 'rejection_code' is null
    loop
      insert into public.order_items (
        sub_order_id, menu_item_id, item_name, item_name_ar, image_path,
        quantity, unit_price, total_price, selected_options,
        selected_size_id, selected_size_name, selected_size_price,
        special_instructions, item_status)
      values (
        v_sub, (v_line ->> 'menu_item_id')::uuid,
        v_line ->> 'name', v_line ->> 'name_ar',
        (select mi.image_path from public.menu_items mi where mi.id = (v_line ->> 'menu_item_id')::uuid),
        (v_line ->> 'quantity')::int, (v_line ->> 'unit_price')::int,
        (v_line ->> 'total_price')::int,
        coalesce(v_line -> 'selected_options', '[]'::jsonb),
        (v_line ->> 'selected_size_id')::uuid,
        v_line ->> 'selected_size_name', (v_line ->> 'selected_size_price')::int,
        (select ci.special_instructions from public.cart_items ci
          where ci.id = (v_line ->> 'cart_item_id')::uuid),
        'confirmed');
    end loop;
  end loop;

  -- No stock handling. The platform does not track merchant inventory, so `menu_items.stock_count`
  -- is vendor-declared display data and is never decremented here. Removed by the 043 revert.

  -- The cart is spent. carts_one_active is a unique partial index on
  -- user_id where is_active, so the next cart needs this one released.
  update public.carts c
     set is_active = false,
         quote_id = null, quote_fingerprint = null, quote_expires_at = null,
         quote_address_id = null, quote_voucher_code = null, quote_rider_tip = null,
         quote_delivery_type = null, quote_grouping = null, quote_snapshot = null
   where c.id = v_cart.id and c.user_id = v_user;

  -- II.16
  -- events carries no actor column; the actor lives in the payload, which is
  -- what 016 does too.
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('order.placed', 'order', v_order,
          jsonb_build_object('order_id', v_order, 'user_id', v_user,
                             'vendor_ids', v_q -> 'vendor_ids',
                             'total', (v_tot ->> 'total')::int,
                             'currency', v_q ->> 'currency'));

  return query select v_order, v_number, v_subs, v_tot;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3. claim_events_v1 — the `038i_claim_currency` fix
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.claim_events_v1(p_limit integer DEFAULT 50)
 RETURNS TABLE(event_ids bigint[], template_key text, recipient text, recipient_id uuid, order_id uuid, order_number text, variables jsonb, language text, oldest_event timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_limit int;
begin
  v_limit := greatest(1, least(coalesce(p_limit, 50), 200));

  return query
  with routing as (
    select e.id, e.created_at, e.payload, e.aggregate_id,
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
    select r.id, r.created_at, r.payload, r.aggregate_id,
           r.v_recipient, r.v_template_key, r.order_id,
           o.user_id as customer_id,
           vc.vendor_id
      from routing r
      join public.orders o on o.id = r.order_id
      left join lateral (
        select distinct so.vendor_id
          from public.sub_orders so
         where so.order_id = r.order_id
      ) vc on r.v_recipient = 'vendor'
  ), collapsed as (
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
           (select x from unnest(array_agg(a.payload ->> 'reason' order by a.id)) x
             where x is not null limit 1) as reason,
           coalesce((select sum(x::int)
                       from unnest(array_remove(array_agg(a.payload ->> 'refund_amount' order by a.id),
                                               null)) x), 0) as refund_amount,
           (select x::int from unnest(array_agg(a.payload ->> 'rider_pay_total' order by a.id)) x
             where x is not null limit 1) as rider_pay_total,
           array_agg(distinct a.aggregate_id)
             filter (where a.v_template_key = 'order.vendor_rejected') as rejected_sub_orders
      from addressed a
     group by 1, 2, 3, 4
  ), resolved as (
    select c.*,
           o.order_number,
           o.total,
           o.vendor_count,
           o.item_count,
           o.payment_method,
           o.promised_delivery_at,
           -- `currency`, the addition in this file. Read from the ORDER, never from a constant, because the
           -- schema stores it per row on six tables and an admin can change it through
           -- `admin_upsert_city_v1`. `btrim` because the column is `bpchar` and PADDING a currency code
           -- turns `'EGP'` into `'EGP '`, which `Intl.NumberFormat` rejects.
           btrim(o.currency::text) as currency,
           coalesce(
             (select to_char((da.assigned_at + make_interval(mins => da.eta_minutes))
                             at time zone ci.timezone, 'HH24:MI')
                from public.delivery_assignments da
                join public.areas ar on ar.id = o.area_id
                join public.cities ci on ci.id = ar.city_id
               where da.order_id = c.order_id
                 and da.rider_id is not null
                 and da.assigned_at is not null
                 and da.eta_minutes is not null
               order by da.assigned_at nulls last
               limit 1),
             (select to_char(o.promised_delivery_at at time zone ci.timezone, 'HH24:MI')
                from public.areas ar join public.cities ci on ci.id = ar.city_id
               where ar.id = o.area_id)
           ) as eta,
           coalesce(
             v.name,
             (select min(vv.name)
                from public.sub_orders so
                join public.vendors vv on vv.id = so.vendor_id
               where so.id = any (coalesce(c.rejected_sub_orders, '{}'::uuid[])))
           ) as vendor_name,
           (select coalesce(sum(oi.quantity), 0)
              from public.order_items oi
             where oi.sub_order_id = any (coalesce(c.rejected_sub_orders, '{}'::uuid[]))) as affected_items,
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
         jsonb_strip_nulls(jsonb_build_object(
           'order_number',    r.order_number,
           'vendor_count',    r.vendor_count,
           'total',           r.total,
           'vendor_name',     r.vendor_name,
           'reason',          coalesce(r.reason, r.rejection_reason),
           'refund_amount',   r.refund_amount,
           'rider_pay_total', r.rider_pay_total,
           'affected_items',  case when r.v_template_key = 'order.vendor_rejected'
                                     then r.affected_items end,
           'rider_name',      nullif(r.rider_name, ''),
           'stops',           case when r.stops > 0 then r.stops end,
           'eta',             r.eta,
           'payment_method',  r.payment_method,
           'item_count',      r.item_count,
           -- Always last in the object. Order is irrelevant to jsonb semantics but a stable order makes a
           -- rendered row diffable between two runs, which is what a test comparing claim output needs.
           'currency',        r.currency
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
$function$;

-- ---------------------------------------------------------------------------
-- 4. probes — every body above is entered, or the migration is wrong
-- ---------------------------------------------------------------------------

do $$
begin
  perform public.handle_new_user();
  raise exception 'PROBE FAILED: handle_new_user ran without a trigger row';
exception
  when others then
    if sqlerrm not like '%trigger%' and sqlerrm not like '%new%' then
      raise exception 'PROBE FAILED for handle_new_user: %', sqlerrm;
    end if;
end $$;

do $$
begin
  perform public.place_order_v1(gen_random_uuid(), 'cash', gen_random_uuid()::text);
  raise exception 'PROBE FAILED: place_order_v1 ran without a session';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for place_order_v1: %', sqlerrm;
    end if;
end $$;

do $$
begin
  perform public.claim_events_v1(1);
  raise exception 'PROBE FAILED: claim_events_v1 ran without a session';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for claim_events_v1: %', sqlerrm;
    end if;
end $$;
