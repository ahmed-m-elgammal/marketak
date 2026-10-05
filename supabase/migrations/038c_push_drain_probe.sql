-- 038c: the behavioural probe for the push drain. Runs on its own and installs nothing.
--
-- `038` shipped the three functions. `038a` corrected `register_device_token_v1` and re-asserted the
-- P1.8 grants. `038b` corrected `claim_events_v1`. This file is the probe that found those defects, and
-- it is separate on purpose: bundling a FIX with a PROBE in one file meant a failure in a 700-line
-- assertion block rolled the fix back with it, leaving the database with the broken function. That is
-- the `035` lesson arriving late - a migration that installs unattended DELETE jobs and its tests
-- together means a failing test takes the safety net away. `035` got this right by having no
-- `begin;`/`commit;`; the mistake here was bundling a FIX with a PROBE at all.
--
-- It stands up a REAL order with THREE vendors and drives the real RPCs - `quote_order_v1`,
-- `place_order_v1`, `transition_order_v1`, `claim_order_v1` - because a hand-built `events` row would
-- test the drain against data no emitter actually produces. That is the `027` lesson: a fixture that
-- bypasses the writers proves nothing about the writers.
--
-- Rolled back by a sentinel exception, the same pattern `027a`, `033`, `034`, `035` and `038` use. No
-- explicit `delete from auth.users` anywhere: `auth.users` carries fifteen foreign keys and cascades
-- into identities, sessions, mfa_factors, one_time_tokens, oauth_*, webauthn_*, scim_users,
-- public.users, settings, feature_flags and commission_rules.
do $$
declare
  v_admin   uuid := gen_random_uuid();
  v_cust    uuid := gen_random_uuid();
  v_staff   uuid := gen_random_uuid();
  v_rider_u uuid := gen_random_uuid();
  v_city  uuid; v_area uuid; v_zone uuid;
  v_v1 uuid; v_v2 uuid; v_v3 uuid;
  v_user uuid; v_rider uuid; v_order uuid; v_cart uuid; v_address uuid;
  v_assignment uuid;
  v_quote uuid; v_cat uuid; v_item uuid; v_vendor uuid;
  v_subs uuid[]; v_sub uuid;
  v_batch bigint[];
  v_marked bigint; v_open bigint; v_a bigint; v_b bigint;
  v_n integer;
  v_row record;
  v_got text;
begin
  begin
    ----------------------------------------------------------------- actors
    -- `on_auth_user_created` fires on each insert and creates the `public.users` row, so these are
    -- real sign-ups rather than rows written around the trigger.
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    insert into auth.users (id, email, raw_user_meta_data, created_at)
    values (v_admin, '038-admin@probe.local', '{}'::jsonb, now());
    insert into public.user_roles (user_id, role) values (v_admin, 'admin');

    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_cust::text, 'role', 'authenticated')::text, true);
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_cust, '038-cust@probe.local', '+20111110010', '{}'::jsonb, now());

    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_staff, '038-staff@probe.local', '+20111110011', '{}'::jsonb, now());

    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_rider_u::text, 'role', 'authenticated')::text, true);
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_rider_u, '038-rider@probe.local', '+20111110012', '{}'::jsonb, now());

    select id into v_user from public.users where id = v_cust;

    -- Completed through the RPC, not by writing `profile_completed_at` directly: the constraint is
    -- `CHECK (profile_completed_at IS NULL OR phone_number IS NOT NULL)`, so setting the timestamp alone
    -- violates it. This cost a dry run and is recorded so the next probe does not repeat it.
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_cust::text, 'role', 'authenticated')::text, true);
    perform public.complete_profile_v1('Sara', 'Ahmed', '+20111110010');

    if exists (select 1 from public.users where id = v_user and profile_completed_at is null) then
      raise exception 'FAIL CLOSED: complete_profile_v1 did not complete a profile';
    end if;

    ----------------------------------------------------------------- geography, three vendors, a zone
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

    v_city := public.admin_upsert_city_v1(
      '{"code":"038C","name":"Probe","name_ar":"م","country_code":"EG","timezone":"Africa/Cairo",
        "center_lat":30.0444,"center_lng":31.2357,"is_primary":true}'::jsonb, null);
    v_area := public.admin_upsert_area_v1(jsonb_build_object(
      'city_id', v_city, 'slug', 'probe', 'name', 'Probe', 'name_ar', 'م',
      'geohash_prefix', 'u4pr', 'center_lat', 30.0444, 'center_lng', 31.2357,
      'radius_km', 5.0), null);

    v_v1 := public.admin_upsert_vendor_v1(jsonb_build_object(
      'slug','probe-1','name','One','name_ar','١','vertical_type','food','city_id',v_city,
      'area_id',v_area,'latitude',30.0444,'longitude',31.2357,'geohash_prefix','u4pr',
      'is_open',true,'is_approved',true,'contact_phone','+201000000011'), null);
    v_v2 := public.admin_upsert_vendor_v1(jsonb_build_object(
      'slug','probe-2','name','Two','name_ar','٢','vertical_type','food','city_id',v_city,
      'area_id',v_area,'latitude',30.0445,'longitude',31.2358,'geohash_prefix','u4pr',
      'is_open',true,'is_approved',true,'contact_phone','+201000000012'), null);
    v_v3 := public.admin_upsert_vendor_v1(jsonb_build_object(
      'slug','probe-3','name','Three','name_ar','٣','vertical_type','food','city_id',v_city,
      'area_id',v_area,'latitude',30.0446,'longitude',31.2359,'geohash_prefix','u4pr',
      'is_open',true,'is_approved',true,'contact_phone','+201000000013'), null);

    -- ONE staff user across all three vendors. `private.vendor_ids_for` is a set, so this is what lets
    -- one actor drive three acceptances, and `data-model.md` §8 allows it.
    perform public.admin_upsert_vendor_staff_v1(
      jsonb_build_object('vendor_id', v_v1, 'user_id', v_staff, 'can_edit_menu', true), null);
    perform public.admin_upsert_vendor_staff_v1(
      jsonb_build_object('vendor_id', v_v2, 'user_id', v_staff, 'can_edit_menu', true), null);
    perform public.admin_upsert_vendor_staff_v1(
      jsonb_build_object('vendor_id', v_v3, 'user_id', v_staff, 'can_edit_menu', true), null);

    -- A zone and its three fee tiers, or `compute_quote` raises NO_DELIVERY_ZONE and then
    -- MISSING_FEE_TIER. Both were found by dry run. `026` covers cities, areas and vendors but NOT
    -- zones, so there is no admin upsert for one and the row is written directly; every money column
    -- keeps its schema default, which is the point - this migration asserts nothing about fees.
    insert into public.delivery_zones (city_id, area_id, name, name_ar)
    values (v_city, v_area, 'Probe zone', 'منطقة') returning id into v_zone;

    -- Basis points, matching the spec's x1.00 / x1.10 / x1.20. Integers, so no float enters the fee.
    insert into public.delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
    values (v_zone, 1, 10000), (v_zone, 2, 11000), (v_zone, 3, 12000);

    -- `carts.id` and `addresses.id` both DEFAULT to gen_random_uuid(), so they are omitted and read
    -- back. Assigning an uninitialised plpgsql variable instead is what produced
    -- `null value in column "id"` on the first dry run.
    insert into public.carts (user_id, is_active, last_seen_at)
    values (v_user, true, now()) returning id into v_cart;

    -- `addresses.geohash` is NOT NULL alongside `geohash_prefix`, and `label` is CHECKed against
    -- {home, work, other}. Both are the kind of detail a hand-written fixture gets wrong.
    insert into public.addresses
      (user_id, label, area_id, area_name, building, floor, apartment,
       latitude, longitude, geohash, geohash_prefix, is_default)
    values (v_user, 'home', v_area, 'Probe', '1', '2', '3',
            30.0450, 31.2360, 'u4prqy8', 'u4pr', true)
    returning id into v_address;

    ----------------------------------------------------------------- ONE ITEM PER VENDOR
    -- The category carries the vendor: `menu_items.vendor_id` is NOT in
    -- `admin_upsert_menu_item_v1`'s key allowlist and is filled by `trg_menu_item_vendor` from
    -- `menu_categories.vendor_id`. Reusing one category for three items would have produced three items
    -- at ONE vendor and a one-sub-order order - and every collapse and fan-out assertion below would
    -- then have passed for the wrong reason. That is the `027` failure mode, so it is asserted.
    foreach v_vendor in array array[v_v1, v_v2, v_v3] loop
      v_cat := public.admin_upsert_menu_category_v1(
        jsonb_build_object('vendor_id', v_vendor, 'name', 'Cat ' || v_vendor::text,
                           'name_ar', 'قسم'), null);
      v_item := public.admin_upsert_menu_item_v1(jsonb_build_object(
        'category_id', v_cat, 'name', 'Item ' || v_vendor::text, 'name_ar', 'صنف',
        'base_price', 10000, 'pricing_mode', 'fixed', 'is_available', true), null);
      insert into public.cart_items (cart_id, menu_item_id, quantity)
      values (v_cart, v_item, 1);
    end loop;

    if exists (select 1 from public.cart_items where cart_id = v_cart and vendor_id is null) then
      raise exception 'FAIL CLOSED: a cart item has no vendor_id after the sync trigger';
    end if;
    if (select count(distinct vendor_id) from public.cart_items where cart_id = v_cart) <> 3 then
      raise exception 'FAIL CLOSED: the cart spans % vendors, expected 3',
        (select count(distinct vendor_id) from public.cart_items where cart_id = v_cart);
    end if;

    ----------------------------------------------------------------- the real checkout
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    -- `quote_order_v1` RETURNS A TABLE, so it is assigned through `select into` and yields `quote_id`,
    -- not a bare uuid.
    select q.quote_id into v_quote from public.quote_order_v1(
      v_cart, v_address, null, 0, 'delivery', 'together') q;
    if v_quote is null then
      raise exception 'FAIL CLOSED: quote_order_v1 returned no quote_id';
    end if;

    perform public.place_order_v1(v_quote, 'cash', '038-probe-idem', 'cod');

    select o.id into v_order from public.orders o where o.idempotency_key = '038-probe-idem';
    if v_order is null then
      raise exception 'FAIL CLOSED: the probe order was not created';
    end if;

    -- The three-vendor premise, asserted before anything relies on it.
    select count(*) into v_n from public.sub_orders where order_id = v_order;
    if v_n <> 3 then
      raise exception 'FAIL CLOSED: the probe order has % sub-orders, expected 3', v_n;
    end if;

    -- A rider row, before the claim. `get_available_orders_v1` refuses anything that is not an active,
    -- VERIFIED rider with a location, and `riders.is_verified` defaults to false, so an unverified rider
    -- would leave the order unclaimable and the `order.claimed` route untested.
    --
    -- Inserted with `user_id` linked, so `trg_rider_contact_from_user` (014b) copies the completed
    -- profile's name and phone onto the row. That trigger reads `users.phone_number`, which
    -- `complete_profile_v1` set to the same value, so the UNIQUE on `riders.phone_number` holds.
    --
    -- `is_online` is supplied, not left to its `false` default, because `riders_is_online_consistent` is
    -- `CHECK (is_online = (status <> 'offline'))` and `status = 'available'` therefore REQUIRES
    -- `is_online = true`. The two columns are redundant by design and the CHECK is what stops them
    -- disagreeing; found by dry run.
    insert into public.riders
      (user_id, first_name, phone_number, country_code, vehicle_type, status, is_online,
       current_latitude, current_longitude, last_location_at, is_verified, is_active)
    values
      (v_rider_u, 'Rami', '+20111110012', 'EG', 'motorcycle', 'available', true,
       30.0444, 31.2357, now(), true, true)
    returning id into v_rider;

    ----------------------------------------------------------------- P1.1 register_device_token_v1
    -- Driven as the customer, so `auth.uid()` is real rather than the migration role's.
    select * into v_row from public.register_device_token_v1('tok-038-a','android','customer','1.0.0');
    if v_row.token <> 'tok-038-a' then
      raise exception 'FAIL CLOSED: register returned %', v_row.token;
    end if;
    if v_row.language <> 'ar' then
      raise exception 'FAIL CLOSED: language is %, expected ar from preferred_language', v_row.language;
    end if;
    if v_row.user_id <> v_user then
      raise exception 'FAIL CLOSED: the token is not owned by the caller';
    end if;

    -- Re-registering the SAME token must UPDATE, never duplicate. This is the `(user_id, token)` bug:
    -- under a composite key it would have created a second row against a globally unique column.
    select * into v_row from public.register_device_token_v1('tok-038-a','ios','customer','1.1.0');
    if (select count(*) from public.device_tokens where token = 'tok-038-a') <> 1 then
      raise exception 'FAIL CLOSED: re-registering one token produced more than one row';
    end if;
    if v_row.platform <> 'ios' then
      raise exception 'FAIL CLOSED: the upsert did not update platform; got %', v_row.platform;
    end if;

    -- A second token for the same role is refused, because routing resolves by role.
    begin
      perform public.register_device_token_v1('tok-038-b','android','customer','1.0.0');
      raise exception 'FAIL CLOSED: two customer tokens were accepted';
    exception when others then
      if sqlerrm not like 'TOKEN_ALREADY_REGISTERED%' then
        raise exception 'FAIL CLOSED: second token raised "%", expected TOKEN_ALREADY_REGISTERED', sqlerrm;
      end if;
    end;

    -- `admin` is refused as an argument, even though the column CHECK permits it.
    begin
      perform public.register_device_token_v1('tok-038-c','android','admin','1.0.0');
      raise exception 'FAIL CLOSED: an admin token was accepted';
    exception when others then
      if sqlerrm not like 'APP_ROLE_INVALID%' then
        raise exception 'FAIL CLOSED: admin role raised "%", expected APP_ROLE_INVALID', sqlerrm;
      end if;
    end;

    -- A rider token for the same user IS allowed: one per role, not one per user.
    select * into v_row from public.register_device_token_v1('tok-038-r','android','rider','1.0.0');
    if v_row.app_role <> 'rider' then
      raise exception 'FAIL CLOSED: a rider token was refused; one-per-role is the rule';
    end if;

    -- Signed out is refused before anything else is attempted.
    perform set_config('request.jwt.claims', '{}'::text, true);
    begin
      perform public.register_device_token_v1('tok-038-d','android','customer','1.0.0');
      raise exception 'FAIL CLOSED: a signed-out caller registered a token';
    exception when others then
      if sqlerrm not like 'AUTH_REQUIRED%' then
        raise exception 'FAIL CLOSED: signed-out raised "%", expected AUTH_REQUIRED', sqlerrm;
      end if;
    end;
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    ----------------------------------------------------------------- the routing table (P1.6)
    select count(*) into v_n from private.push_routing();
    if v_n <> 7 then
      raise exception 'FAIL CLOSED: the routing table has % rows, expected 7', v_n;
    end if;

    -- `to=cancelled` and `to=delivered` must NOT be routed: both transitions are emitted a second time
    -- as `order.cancelled` and `order.delivered`, so routing either would double-notify.
    select string_agg(v_template_key, ', ') into v_got
      from private.push_routing()
     where v_event_type = 'order.status_changed'
       and v_payload_to in ('cancelled', 'delivered');
    if v_got is not null then
      raise exception 'FAIL CLOSED: the routing table double-sends on %', v_got;
    end if;

    -- `order.arriving` claims a "2 km" literal with no variable behind it, and no position source
    -- exists. Routing it would tell a customer something untrue.
    if exists (select 1 from private.push_routing() where v_template_key = 'order.arriving') then
      raise exception 'FAIL CLOSED: order.arriving is routed; its body asserts a distance it cannot know';
    end if;

    -- Every routed template must exist and be active in BOTH languages, or the event is permanently
    -- unclaimable and sits in the backlog forever with nothing to explain it.
    select string_agg(distinct r.v_template_key, ', ') into v_got
      from private.push_routing() r
     where not exists (
       select 1 from public.notification_templates t
        where t.key = r.v_template_key and t.channel = 'push' and t.is_active
          and t.lang in ('ar', 'en')
        group by t.key having count(*) = 2);
    if v_got is not null then
      raise exception 'FAIL CLOSED: routed templates are missing or not bilingual: %', v_got;
    end if;

    ----------------------------------------------------------------- P1.5 the collapse rule
    -- Three vendors move one order. `transition_order_v1` emits one event per SUB_ORDER, so there are
    -- three of each transition. The MVP routes none of accepted / preparing / ready, so the collapse is
    -- proven on `picked_up`.
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);

    select array_agg(id order by sequence) into v_subs
      from public.sub_orders where order_id = v_order;

    -- The vendor half. `transition_order_v1` assigns the role from the transition, not from a flag:
    -- `picked_up`, `delivering` and `delivered` are rider-only, `accepted` / `rejected` / `preparing`
    -- / `ready` are vendor-only, and only an admin may do either. A vendor staff row therefore CANNOT
    -- reach `picked_up`, and trying it raises
    -- `NOT_AUTHORIZED: this role cannot make that transition` - found by dry run, and it is a real
    -- authorisation boundary rather than a fixture problem.
    foreach v_sub in array v_subs loop
      perform public.transition_order_v1(v_order, v_sub, 'accepted',  null);
      perform public.transition_order_v1(v_order, v_sub, 'preparing', null);
      perform public.transition_order_v1(v_order, v_sub, 'ready',     null);
    end loop;

-- THE RIDER HALF, done properly rather than as admin. `get_available_orders_v1` creates the
    -- `delivery_assignments` row and `claim_order_v1` takes it. This is what produces `order.claimed`,
    -- which is row 1 of the MVP routing, so running it rather than faking the event is the point.
    --
    -- `get_available_orders_v1` RETURNS A TABLE whose first column is `assignment_id` - read from
    -- `pg_get_function_result` rather than guessed, and the returned name is what `claim_order_v1` wants.
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_rider_u::text, 'role', 'authenticated')::text, true);

    select a.assignment_id into v_assignment
      from public.get_available_orders_v1(null, null, 25.0) a
     where a.order_id = v_order;
    if v_assignment is null then
      raise exception 'FAIL CLOSED: get_available_orders_v1 did not offer the probe order';
    end if;

    perform public.claim_order_v1(v_assignment, v_rider);

    -- `order.claimed` is emitted, and it is the one MVP route whose recipient is the rider.
    if not exists (select 1 from public.events
                    where type = 'order.claimed' and payload ->> 'order_id' = v_order::text) then
      raise exception 'FAIL CLOSED: claim_order_v1 emitted no order.claimed event';
    end if;

    foreach v_sub in array v_subs loop
      perform public.transition_order_v1(v_order, v_sub, 'picked_up', null);
    end loop;

    -- The premise: three events, each on its own sub_order.
    select count(*) into v_n
      from public.events
     where type = 'order.status_changed' and aggregate_type = 'sub_order'
       and aggregate_id = any (v_subs)
       and payload ->> 'to' = 'picked_up';
    if v_n <> 3 then
      raise exception 'FAIL CLOSED: expected 3 picked_up sub-order events, found %', v_n;
    end if;

    -- And they share ONE order_id, which is what makes the collapse possible at all. If they spanned
    -- three, grouping on `payload->>'order_id'` could not help and the count below would be 3.
    select count(distinct payload ->> 'order_id') into v_n
      from public.events
     where type = 'order.status_changed' and payload ->> 'to' = 'picked_up';
    if v_n <> 1 then
      raise exception 'FAIL CLOSED: the 3 picked_up events span % order_ids; collapse cannot work', v_n;
    end if;

    -- THE ASSERTION: three events, ONE notification.
    select count(*) into v_n
      from public.claim_events_v1(50) c
     where c.template_key = 'order.picked_up' and c.order_id = v_order;
    if v_n <> 1 then
      raise exception
        'FAIL CLOSED: 3 sub-order picked_up events produced % notifications. The collapse rule is broken '
        'and a 3-vendor order would send 3 pushes.', v_n;
    end if;

    -- The array must carry all three ids, because the Worker marks precisely what it sent.
    select event_ids into v_batch
      from public.claim_events_v1(50) c
     where c.template_key = 'order.picked_up' and c.order_id = v_order;
    if coalesce(cardinality(v_batch), 0) <> 3 then
      raise exception 'FAIL CLOSED: the collapsed notification carries % ids, expected 3',
        coalesce(cardinality(v_batch), 0);
    end if;

    -- The inverted form: a collapse returning the WRONG order-level row would pass the count above and
    -- fail here.
    if not exists (select 1 from unnest(v_batch) id
                    where id in (select id from public.events
                                  where type = 'order.status_changed'
                                    and payload ->> 'to' = 'picked_up')) then
      raise exception 'FAIL CLOSED: the collapsed ids are not the picked_up events';
    end if;

    select * into v_row from public.claim_events_v1(50) c
     where c.template_key = 'order.picked_up' and c.order_id = v_order;
    if v_row.recipient <> 'customer' or v_row.recipient_id <> v_user then
      raise exception 'FAIL CLOSED: picked_up routed to % / %, expected the customer',
        v_row.recipient, v_row.recipient_id;
    end if;
    if v_row.language <> 'ar' then
      raise exception 'FAIL CLOSED: claim returned language %, expected ar', v_row.language;
    end if;
    -- `order_number` is in no payload and present here. That is the display join working.
    if v_row.order_number is null then
      raise exception 'FAIL CLOSED: order_number is not resolved; the display join is broken';
    end if;

    ----------------------------------------------------------------- P1.3 mark, including partial failure
    select marked, still_open into v_marked, v_open
      from public.mark_events_delivered_v1(v_batch, null);
    if v_marked <> 3 then
      raise exception 'FAIL CLOSED: marked % of 3 collapsed events', v_marked;
    end if;
    if exists (select 1 from public.events where id = any (v_batch) and delivered_at is null) then
      raise exception 'FAIL CLOSED: a marked event is still undelivered';
    end if;

    -- A PARTIAL failure: 2 attempted, 1 ok, 1 failed. The failed one must stay claimable and its
    -- `attempts` must rise, so §11 item 8 has something to count. A design taking one boolean for the
    -- whole batch could not express this, and marking both on one failure would drop the notification.
    --
    -- Two dedicated rows rather than a real order's events, so the assertion is about the function and
    -- not about whatever the probe happened to produce.
    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('order.placed', 'order', v_order, jsonb_build_object('order_id', v_order, 'user_id', v_user))
    returning id into v_a;
    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('order.placed', 'order', v_order, jsonb_build_object('order_id', v_order, 'user_id', v_user))
    returning id into v_b;

    select marked, still_open into v_marked, v_open
      from public.mark_events_delivered_v1(array[v_a, v_b],
        jsonb_build_array(
          jsonb_build_object('event_id', v_a, 'ok', true),
          jsonb_build_object('event_id', v_b, 'ok', false, 'error', 'FCM 503 UNAVAILABLE')));

    if v_marked <> 1 then
      raise exception 'FAIL CLOSED: a 1-of-2 partial mark reported % marked', v_marked;
    end if;
    if v_open <> 1 then
      raise exception 'FAIL CLOSED: a 1-of-2 partial mark reported % left open', v_open;
    end if;
    if exists (select 1 from public.events where id = v_a and delivered_at is null) then
      raise exception 'FAIL CLOSED: the successful event was not marked';
    end if;
    if not exists (select 1 from public.events where id = v_b and delivered_at is null) then
      raise exception
        'FAIL CLOSED: the failed event was marked delivered. It would never be retried and the '
        'notification would be lost silently.';
    end if;
    if not exists (select 1 from public.events
                    where id = v_b and attempts = 1 and last_error like 'FCM 503%') then
      raise exception 'FAIL CLOSED: the failure was not recorded in attempts / last_error';
    end if;

    -- And it must be claimable again on the next drain.
    if not exists (select 1 from public.claim_events_v1(50) c where c.event_ids @> array[v_b]) then
      raise exception 'FAIL CLOSED: the failed event is not claimable again';
    end if;

    -- An empty batch is refused rather than silently marking nothing.
    begin
      perform public.mark_events_delivered_v1(array[]::bigint[], null);
      raise exception 'FAIL CLOSED: an empty batch was accepted';
    exception when others then
      if sqlerrm not like 'IDS_REQUIRED%' then
        raise exception 'FAIL CLOSED: empty batch raised "%", expected IDS_REQUIRED', sqlerrm;
      end if;
    end;

    ----------------------------------------------------------------- P1.7 an unroutable event stays open
    -- `vendor.staff_updated` is emitted and routed by nothing; `order.arriving` exists as a template and
    -- is deliberately unrouted. Neither may ever be claimed, so the §11 item 8 alert can still count it.
    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('vendor.staff_updated', 'vendor_staff', v_staff,
            jsonb_build_object('order_id', v_order, 'actor', v_admin));
    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('order.arriving', 'order', v_order, jsonb_build_object('order_id', v_order));

    select count(*) into v_n
      from public.claim_events_v1(50) c
     where c.template_key in ('vendor.staff_updated', 'order.arriving');
    if v_n <> 0 then
      raise exception 'FAIL CLOSED: % unroutable events were claimed', v_n;
    end if;

    ----------------------------------------------------------------- the vendor fan-out
    -- ONE `order.placed` event, THREE vendor notifications, each with its own recipient_id. The customer
    -- gets one from the same event; that is a fan-out, not a duplicate.
    -- The premise, counted EXCLUDING the two dedicated rows the partial-mark test inserted, because
    -- they are `order.placed` too. Filtering on the two ids rather than asserting a raw total of 1 is
    -- what makes this check still mean "place_order_v1 wrote exactly one" after the fixture above.
    select count(*) into v_n
      from public.events
     where type = 'order.placed'
       and payload ->> 'order_id' = v_order::text
       and id <> all (array[v_a, v_b]);
    if v_n <> 1 then
      raise exception 'FAIL CLOSED: place_order_v1 produced % order.placed events, expected 1', v_n;
    end if;

    select count(*) into v_n
      from public.claim_events_v1(50) c
     where c.template_key = 'vendor.new_order' and c.order_id = v_order;
    if v_n <> 3 then
      raise exception 'FAIL CLOSED: one order.placed reached % vendors, expected 3', v_n;
    end if;

    select count(distinct recipient_id) into v_n
      from public.claim_events_v1(50) c
     where c.template_key = 'vendor.new_order' and c.order_id = v_order;
    if v_n <> 3 then
      raise exception 'FAIL CLOSED: three vendor notifications share % recipient ids', v_n;
    end if;

    -- Each vendor's own name reaches them, which proves the expansion is per-vendor and not three copies
    -- of the same recipient.
    if (select count(distinct c.variables ->> 'vendor_name')
          from public.claim_events_v1(50) c
         where c.template_key = 'vendor.new_order' and c.order_id = v_order) <> 3 then
      raise exception 'FAIL CLOSED: the three vendor notifications do not carry three distinct names';
    end if;

    -- The customer half of the same event, still exactly one.
    select count(*) into v_n
      from public.claim_events_v1(50) c
     where c.template_key = 'order.placed' and c.order_id = v_order;
    if v_n <> 1 then
      raise exception 'FAIL CLOSED: the customer received % order.placed notifications', v_n;
    end if;

    ----------------------------------------------------------------- the backlog census
    -- EXACTLY what should still be open, counted AND named. A census alone could be satisfied by the wrong
    -- rows, and an exclusion list would pass even if the mark had eaten a `to=accepted` event - which is
    -- precisely the event expected to survive.
    --
    --    9  order.status_changed to accepted / preparing / ready  (routed to nothing at MVP)
    --    2  order.placed - the real one, plus the deliberately-failed v_b (v_a was marked)
    --    1  order.claimed - claimable, but the probe never marked it; only `v_batch` was marked
    --    2  vendor.staff_updated and order.arriving - unroutable by design (P1.7)
    --   ---
    --   14
    select count(*) into v_n
      from public.events
     where payload ->> 'order_id' = v_order::text and delivered_at is null;
    if v_n <> 14 then
      raise exception
        'FAIL CLOSED: % events are still open, expected 14 (9 unrouted transitions + 2 order.placed + '
        'order.claimed + 2 unroutable). A mark that is too greedy or too broad both land here.', v_n;
    end if;

    -- `order.claimed` must still be open: the probe claimed it but marked only the collapsed
    -- `picked_up` group, which is the whole point of marking precisely what was sent.
    if not exists (select 1 from public.events
                    where type = 'order.claimed' and delivered_at is null) then
      raise exception 'FAIL CLOSED: order.claimed was marked even though the probe never sent it';
    end if;

    select count(*) into v_n
      from public.events
     where payload ->> 'order_id' = v_order::text and delivered_at is null
       and type = 'order.status_changed'
       and payload ->> 'to' in ('accepted', 'preparing', 'ready');
    if v_n <> 9 then
      raise exception
        'FAIL CLOSED: % unrouted transitions are open, expected 9. A deferred template must leave its '
        'events in the backlog untouched.', v_n;
    end if;

    -- And no `picked_up` survived the mark, which is the other direction.
    if exists (select 1 from public.events
                where payload ->> 'order_id' = v_order::text and delivered_at is null
                  and payload ->> 'to' = 'picked_up') then
      raise exception 'FAIL CLOSED: a collapsed picked_up event survived the mark';
    end if;

    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then
      raise;
    end if;
  end;

  -- Prove the rollback rather than trusting it. A leaked fixture would be worse than anything this
  -- migration ships: a live `device_tokens` row is something the real dispatcher would send to.
  --
  -- `v_order` and `v_user` are declared in this block, so they are still in scope and hold the ids the
  -- probe used. Every check is by VALUE, not by pattern.
  if exists (select 1 from auth.users where email like '038-%@probe.local') then
    raise exception 'FAIL CLOSED: the probe leaked its auth.users rows';
  end if;
  if exists (select 1 from public.users where id = v_user) then
    raise exception 'FAIL CLOSED: the probe leaked its users row';
  end if;
  if exists (select 1 from public.vendors where id in (v_v1, v_v2, v_v3)) then
    raise exception 'FAIL CLOSED: the probe leaked its vendors';
  end if;
  if exists (select 1 from public.orders where id = v_order) then
    raise exception 'FAIL CLOSED: the probe leaked its order';
  end if;
  if exists (select 1 from public.events where payload ->> 'order_id' = v_order::text) then
    raise exception 'FAIL CLOSED: the probe leaked its events';
  end if;
  if exists (select 1 from public.device_tokens where token like 'tok-038-%') then
    raise exception 'FAIL CLOSED: the probe leaked a device token. A real dispatcher would send to it.';
  end if;
end $$;
