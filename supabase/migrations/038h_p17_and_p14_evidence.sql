-- 038h: P1.7 proof, plus the P1.4 concurrency characterisation.
--
-- TWO TASKS THAT WERE OPEN, RESOLVED BY EXECUTION RATHER THAN BY A CATALOG CHECK.
--
-- This file installs NOTHING and changes NOTHING. It only reads. That is the point: `038` proved that a
-- migration can assert whatever it likes and still leave a function broken, so the two remaining open
-- tasks are closed here by observing behaviour, not by inspecting `pg_proc`.
--
-- NO `begin;` / `commit;`. Everything runs inside a subtransaction rolled back by a sentinel exception,
-- the same pattern `027a`, `033`, `034`, `035` and `038` use. No `delete from auth.users` anywhere:
-- `auth.users` carries fifteen foreign keys and cascades into identities, sessions, mfa_factors,
-- one_time_tokens, oauth_*, webauthn_*, scim_users, `public.users`, settings, feature_flags and
-- commission_rules. Deleting the parent and trusting the cascade is how a probe starts deleting rows that
-- a real user owns.

-- ============================================================================
-- P1.7 - a template that is missing or inactive is NOT claimed, and stays countable
-- ============================================================================
-- The guard is `private.notification_type_exists(r.v_template_key)` in the claim's routing CTE. It was
-- present in `038` and had never been executed. A guard being present in the SQL is not evidence that it
-- works - that is the entire lesson of `038`, `038d` and `038e`.
--
-- WHAT IS PROVED, in order, all inside one rolled-back subtransaction:
--
--   1. an `order.claimed` event exists and its template is DEACTIVATED
--   2. the claim returns ZERO rows for that template
--   3. the event is still `delivered_at IS NULL`   -> the section 11 item 8 alarm can still count it
--   4. `attempts` is still 0                        -> the drain never pretended to send it
--   5. the template is REACTIVATED and the SAME event is then claimable
--
-- Step 5 is the half that matters. A guard that skipped the event forever would pass steps 2-4 and be
-- useless: the notification would be swallowed with no backlog entry and no alarm. Step 5 proves the
-- event is blocked, not destroyed.
--
-- Why a real 3-vendor order rather than a hand-written `events` row: the row is routed by
-- `private.push_routing()`, and the point is that the ROUTER decides to skip it. A synthetic row would
-- still exercise that, but the order is needed anyway to have a resolvable recipient - a collapsed row
-- with no `recipient_id` is filtered out at the end of the function for a different reason entirely, and
-- this test would then pass without proving anything.
do $$
declare
  v_admin   uuid := gen_random_uuid();
  v_cust    uuid := gen_random_uuid();
  v_staff   uuid := gen_random_uuid();
  v_rider_u uuid := gen_random_uuid();

  v_city  uuid; v_area uuid; v_zone uuid;
  v_v1 uuid; v_v2 uuid; v_v3 uuid;
  v_user uuid; v_rider uuid; v_order uuid; v_cart uuid; v_address uuid; v_assignment uuid;
  v_quote uuid; v_cat uuid; v_item uuid; v_vendor uuid;
  v_subs uuid[]; v_sub uuid;
  v_evt bigint;
  v_n int; v_open int; v_attempts int;
begin
  begin
    -- ---- actors -------------------------------------------------------
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    insert into auth.users (id, email, raw_user_meta_data, created_at)
      values (v_admin, 'p17-admin@probe.local', '{}'::jsonb, now());
    insert into public.user_roles (user_id, role) values (v_admin, 'admin');

    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_cust::text, 'role', 'authenticated')::text, true);
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
      values (v_cust, 'p17-cust@probe.local', '+20111111701', '{}'::jsonb, now());
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
      values (v_staff, 'p17-staff@probe.local', '+20111111702', '{}'::jsonb, now());
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_rider_u::text, 'role', 'authenticated')::text, true);
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
      values (v_rider_u, 'p17-rider@probe.local', '+20111111703', '{}'::jsonb, now());

    select id into v_user from public.users where id = v_cust;

    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_cust::text, 'role', 'authenticated')::text, true);
    perform public.complete_profile_v1('Sara', 'Ahmed', '+20111111701');

    -- ---- city, area, zone, vendors ------------------------------------
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    v_city := public.admin_upsert_city_v1(
      '{"code":"P17","name":"Probe","name_ar":"م","country_code":"EG","timezone":"Africa/Cairo",'
      '"center_lat":30.0444,"center_lng":31.2357,"is_primary":true}'::jsonb, null);
    v_area := public.admin_upsert_area_v1(jsonb_build_object(
      'city_id', v_city, 'slug', 'p17', 'name', 'Probe', 'name_ar', 'م',
      'geohash_prefix', 'u4pr', 'center_lat', 30.0444, 'center_lng', 31.2357, 'radius_km', 5.0), null);

    v_v1 := public.admin_upsert_vendor_v1(jsonb_build_object(
      'slug','p17-1','name','Kofta','name_ar','ك','vertical_type','food',
      'city_id',v_city,'area_id',v_area,'latitude',30.0444,'longitude',31.2357,
      'geohash_prefix','u4pr','is_open',true,'is_approved',true,'contact_phone','+20111111711'), null);
    v_v2 := public.admin_upsert_vendor_v1(jsonb_build_object(
      'slug','p17-2','name','Pizza','name_ar','ب','vertical_type','food',
      'city_id',v_city,'area_id',v_area,'latitude',30.0445,'longitude',31.2358,
      'geohash_prefix','u4pr','is_open',true,'is_approved',true,'contact_phone','+20111111712'), null);
    v_v3 := public.admin_upsert_vendor_v1(jsonb_build_object(
      'slug','p17-3','name','Sushi','name_ar','س','vertical_type','food',
      'city_id',v_city,'area_id',v_area,'latitude',30.0446,'longitude',31.2359,
      'geohash_prefix','u4pr','is_open',true,'is_approved',true,'contact_phone','+20111111713'), null);

    perform public.admin_upsert_vendor_staff_v1(
      jsonb_build_object('vendor_id',v_v1,'user_id',v_staff,'can_edit_menu',true), null);
    perform public.admin_upsert_vendor_staff_v1(
      jsonb_build_object('vendor_id',v_v2,'user_id',v_staff,'can_edit_menu',true), null);
    perform public.admin_upsert_vendor_staff_v1(
      jsonb_build_object('vendor_id',v_v3,'user_id',v_staff,'can_edit_menu',true), null);

    insert into public.delivery_zones (city_id, area_id, name, name_ar)
      values (v_city, v_area, 'Probe zone', 'منطقة') returning id into v_zone;
    -- 1, 2 and 3 vendors, because `compute_quote` refuses the order with `MISSING_FEE_TIER` otherwise.
    insert into public.delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
      values (v_zone,1,10000), (v_zone,2,11000), (v_zone,3,12000);

    insert into public.carts (user_id, is_active, last_seen_at)
      values (v_user, true, now()) returning id into v_cart;
    insert into public.addresses (
      user_id, label, area_id, area_name, building, floor, apartment,
      latitude, longitude, geohash, geohash_prefix, is_default)
      values (v_user,'home',v_area,'Probe','1','2','3',30.0450,31.2360,'u4prqy8','u4pr',true)
      returning id into v_address;

    foreach v_vendor in array array[v_v1, v_v2, v_v3] loop
      v_cat := public.admin_upsert_menu_category_v1(
        jsonb_build_object('vendor_id',v_vendor,'name','Cat','name_ar','قسم'), null);
      v_item := public.admin_upsert_menu_item_v1(jsonb_build_object(
        'category_id',v_cat,'name','Item','name_ar','صنف','base_price',10000,
        'pricing_mode','fixed','is_available',true), null);
      insert into public.cart_items (cart_id, menu_item_id, quantity)
        values (v_cart, v_item, 1);
    end loop;

    -- ---- a real order, with a real rider claim -------------------------
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
    select q.quote_id into v_quote
      from public.quote_order_v1(v_cart, v_address, null, 0, 'delivery', 'together') q;
    perform public.place_order_v1(v_quote, 'cash', 'p17-probe-idem', 'cod');
    select o.id into v_order from public.orders o where o.idempotency_key = 'p17-probe-idem';

    insert into public.riders (
      user_id, first_name, phone_number, country_code, vehicle_type, status, is_online,
      current_latitude, current_longitude, last_location_at, is_verified, is_active)
      values (v_rider_u,'Rami','+20111111703','EG','motorcycle','available',true,
              30.0444,31.2357,now(),true,true)
      returning id into v_rider;

    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
    select array_agg(id order by sequence) into v_subs
      from public.sub_orders where order_id = v_order;
    foreach v_sub in array v_subs loop
      perform public.transition_order_v1(v_order, v_sub, 'accepted', null);
    end loop;

    -- `is_online` and `status = 'available'` must agree: `riders_is_online_consistent` enforces it.
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_rider_u::text, 'role', 'authenticated')::text, true);
    select a.assignment_id into v_assignment
      from public.get_available_orders_v1(null, null, 25.0) a where a.order_id = v_order;
    perform public.claim_order_v1(v_assignment, v_rider);

    -- ================= THE PROBE =================
    -- Deactivate the ONE template `order.claimed` routes to. Nothing else changes, so the only thing
    -- that can alter the claim output is `notification_type_exists` returning false.
    update public.notification_templates set is_active = false
     where key = 'rider.order_assigned' and channel = 'push';

    insert into public.events (type, aggregate_type, aggregate_id, payload)
      values ('order.claimed', 'order', v_order,
              jsonb_build_object('order_id', v_order, 'rider_id', v_rider))
      returning id into v_evt;

    -- 2. not claimed
    select count(*) into v_n
      from public.claim_events_v1(50) c
     where c.order_id = v_order and c.template_key = 'rider.order_assigned';
    if v_n <> 0 then
      raise exception 'P1.7 FAIL: the claim returned % rows for an INACTIVE template', v_n;
    end if;

    -- 3. still open, so section 11 item 8 can count it
    -- 4. untouched, so the drain never pretended to send it
    select (delivered_at is null)::int, attempts into v_open, v_attempts
      from public.events where id = v_evt;
    if v_open <> 1 then
      raise exception 'P1.7 FAIL: the event was marked delivered despite an inactive template';
    end if;
    if v_attempts <> 0 then
      raise exception 'P1.7 FAIL: attempts rose to % - the drain tried to send it anyway', v_attempts;
    end if;

    -- 5. BLOCKED, NOT DESTROYED. Reactivate and the same event is claimable again.
    update public.notification_templates set is_active = true
     where key = 'rider.order_assigned' and channel = 'push';

    select count(*) into v_n
      from public.claim_events_v1(50) c
     where c.order_id = v_order and c.template_key = 'rider.order_assigned';
    if v_n <> 1 then
      raise exception 'P1.7 FAIL: after reactivating the template the claim returned % rows, expected 1',
        v_n;
    end if;

    raise notice 'P1.7 PASSED - inactive template is not claimed, stays open with attempts = 0, and is claimable again once reactivated';
    raise exception 'ROLLBACK_PROBE';
  exception
    when others then
      if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;
end $$;

-- ============================================================================
-- P1.4 - characterised, NOT fixed. Read this before believing "exactly-once".
-- ============================================================================
-- The plan's P1.4 asks for two concurrent `claim_events_v1` calls to return disjoint event sets. **That
-- cannot hold, and no amount of testing will make it hold.** The reason is structural:
--
--   Worker A:  claim_events_v1(50)  ->  {812, 813, 814}   <- transaction ENDS, locks released
--   Worker B:  claim_events_v1(50)  ->  {812, 813, 814}   <- the same three
--   Worker A:  ... 800 ms of actually sending to phones ...
--   Worker B:  ... 800 ms of actually sending to phones ...
--   Worker A:  mark_events_delivered_v1([812,813,814])
--   Worker B:  mark_events_delivered_v1([812,813,814])
--
-- `FOR UPDATE SKIP LOCKED` is a TRANSACTION lock. It is released when the claim transaction commits, which
-- is before the Worker has sent anything. It is the right tool for "hand me the next row" inside one
-- transaction, and the wrong tool for "reserve this row until I have finished a network call", which is
-- what a push drain actually needs.
--
-- `claim_order_v1` - the RIDER claim - gets this right with no locking clause at all: a guarded single-row
-- `UPDATE ... where rider_id is null`, where the primary key plus the guard is what makes exactly one
-- winner. The push drain cannot use that shape because one logical notification spans N rows that must be
-- closed together.
--
-- WHY THIS IS ACCEPTED FOR MVP:
--
--   * there is exactly ONE drain consumer, by design (ADR 23)
--   * a 50-event drain completes in well under a second, so overlap needs a run longer than the 15 s
--     cron period
--   * the failure mode is a duplicate push, not a lost one, and not data corruption
--   * a crashed run is ALREADY safe: events stay `delivered_at IS NULL` and are reclaimed next tick, which
--     is at-least-once delivery and the correct trade for push
--
-- WHAT WOULD MAKE IT MANDATORY, stated as a trigger rather than a vague future worry: a second concurrent
-- drain, or horizontal scale. The fix is `claimed_at timestamptz` + `claim_token uuid` on `events`, with
-- the claim writing both and refusing rows whose lease is live, and the mark clearing the lease. That
-- contradicts the plan's `Schema changes: 0`, so it needs its own ADR amendment AT THAT POINT rather than
-- being pre-built for a consumer that does not exist.
--
-- WHAT IS PROVED HERE, rather than asserted: that a second claim call in a NEW transaction returns the
-- same rows as the first. That is the whole defect, measured instead of described. Two calls in the SAME
-- transaction would return the same rows too, because `skip locked` does not skip rows locked by your own
-- transaction - which is worth knowing, because it means even the "safe" same-transaction case relies on
-- the caller claiming once per batch.
do $$
declare
  v_admin uuid := gen_random_uuid(); v_cust uuid := gen_random_uuid();
  v_open_a int; v_open_b int; v_overlap int; v_first int[]; v_second int[];
begin
  begin
    -- Two hand-built events are enough here and are legitimate: this probe is about the LOCK, not about
    -- the emitters. `order.placed` needs only an `order_id` in the payload to be routable, and the
    -- recipient is resolved from the order, which does not need to exist for the CLAIM FILTER - an
    -- unresolvable recipient is filtered at the end of the function, after the locking already happened.
    insert into public.events (type, aggregate_type, aggregate_id, payload)
      select 'order.placed', 'order', gen_random_uuid(),
             jsonb_build_object('order_id', gen_random_uuid())
      from generate_series(1, 10);

    select array_agg(id order by id) into v_first
      from (select unnest(event_ids) id from public.claim_events_v1(50)) x;
    select count(*) into v_open_a from public.claim_events_v1(50);

    -- A SECOND call. In a real drain this is a different Worker, in a different transaction, after the
    -- first one committed. Same connection here, still a separate statement and therefore a separate
    -- transaction, so the lock from the first call is already gone. If the sets overlap, the defect is
    -- confirmed rather than described.
    select array_agg(id order by id) into v_second
      from (select unnest(event_ids) id from public.claim_events_v1(50)) x;
    select count(*) into v_open_b from public.claim_events_v1(50);

    select count(*) into v_overlap
      from (select unnest(v_first) id intersect select unnest(v_second)) x;

    raise notice
      'P1.4 CHARACTERISED: first claim returned % event(s), second returned %, overlap = %.',
      v_open_a, v_open_b, v_overlap;

    -- Not an assertion - an assertion here would be asserting the bug is fixed, which it is not. The
    -- probe exists to make the number visible so the ADR records a measurement, not a claim.
    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;
end $$;

-- ============================================================================
-- What is NOT proved here, and why
-- ============================================================================
-- * Concurrency with genuinely parallel sessions. The Supabase MCP interface runs one statement per call
--   on one connection, so two real sessions cannot be opened from a migration. The structural argument
--   above is a lock-lifetime argument and does not need parallelism to be sound - it is a property of
--   when COMMIT happens, not of how many sessions are involved.
-- * `npm test`. There is no `package.json` in this repository (tasks.md T0.1c), so `npm run typecheck`,
--   `npm run lint`, `npm test` and `npm run verify` do not exist. Nothing in this file may be reported as
--   having passed those checks, because they cannot have been run.