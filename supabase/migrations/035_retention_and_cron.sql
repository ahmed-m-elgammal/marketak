-- 035: retention and the cron floor. `free-tier-plan.md` §8 lever 3, and lever 7's database half.
--
-- Nothing here is a new design. Every window is quoted from `free-tier-plan.md` §3.3 and §3.7,
-- every mechanic from §3.7's operational-rules table, and the batching shape from the same. This
-- file supplies them.
--
-- WHY FIRST. `free-tier-plan.md` §8 rates lever 3 "Low" effort and "Disk full in ~2 weeks" if
-- skipped. Measured now, against the live project: `pg_cron` is not installed, so nothing prunes
-- anything, and every `events` row any RPC has ever written is permanent. `orders`,
-- `order_eta_snapshots`, `rider_location_pings` and `notifications` are all empty, so the pruning
-- is untested in anger - which is why the assertions below execute it rather than inspect it.
--
-- =============================================================================================
-- WHAT IS REUSED, NOT REBUILT
-- =============================================================================================
--   * `private.ensure_month_partition(text, date)` already exists (`001`) and has ZERO callers. It
--     is wired up below rather than replaced. It also creates the child policy alongside the
--     partition, which is the RLS-propagation risk `decisions.md` §14.1 records.
--
--     Its allowlist is `events`, `notifications`, `rider_location_pings`, `audit_log` - but
--     `events` and `rider_location_pings` are NOT partitioned (`pg_class.relkind = 'r'`, zero
--     children; `free-tier-plan.md` §3.7 chose to keep `events` unpartitioned deliberately). Calling
--     it with either raises. So `private.ensure_partitions()` below passes only the two tables
--     that are actually partitioned.
--
--   * `events_delivered_at` and `events_undelivered` already exist (`013`) and are exactly the
--     indexes §3.7 names for this work.
--   * `notifications_created_at` and `rider_location_pings_recorded_at` already exist.
--   * `pg_stat_statements` is already installed; nothing here duplicates it.
--
-- ONE INDEX IS ADDED, and §3.7's rule is why. "Every table above has a named `pg_cron` prune job
-- with an index on the prune column." Three of the four retention tables have one.
-- `order_eta_snapshots` does not: its only indexes are `pkey`, `_order` and `_sub_order`, and its
-- prune column per §3.3's 24-hour window is `computed_at`. Pruning it today is a sequential scan.
--
-- =============================================================================================
-- `events` IS NOT PARTITIONED, AND THIS IS NOT AN OMISSION
-- =============================================================================================
-- `free-tier-plan.md` §3.7: "Monthly partitions cannot express a 7-day window: a September
-- partition still holds deliverable rows on 1 October, so it survives until ~7 October. That is 37
-- days of retention in practice." Partitioned it measures 239 MB - 60% of the 400 MB ceiling.
-- Pruned by `DELETE` on `events_delivered_at` it measures 45 MB. `013` ships it unpartitioned and
-- this file keeps it that way.
--
-- ONLY DELIVERED EVENTS ARE PRUNED, and that is a decision worth stating. The predicate requires
-- `delivered_at is not null`, so an event that has been stuck undelivered is never destroyed. If it
-- were, a broken dispatcher would silently delete its own backlog and §11 item 8 - "Undelivered
-- `events` older than 1 hour: Any" - would have nothing left to count. Backlog must accumulate
-- until someone looks at it. The assertion block proves both directions.
--
-- =============================================================================================
-- BATCHING
-- =============================================================================================
-- §3.7: "Prune in batches (`limit 1000`) with a short `pg_sleep` between batches. A single
-- `DELETE` of 2M rows locks and bloats." Every function below loops on that shape and returns the
-- number of rows it removed, so a cron run is observable rather than silent.

create extension if not exists pg_cron;

-- 1. The index §3.7 requires and that does not exist.
create index if not exists order_eta_snapshots_computed_at
  on public.order_eta_snapshots (computed_at);

-- 2. The four prunes.
create or replace function private.prune_events()
returns integer
language plpgsql security definer set search_path = '' as $$
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
end $$;

create or replace function private.prune_order_eta_snapshots()
returns integer
language plpgsql security definer set search_path = '' as $$
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
end $$;

create or replace function private.prune_notifications()
returns integer
language plpgsql security definer set search_path = '' as $$
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
end $$;

create or replace function private.prune_rider_location_pings()
returns integer
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- 3. The partition creator, wiring up the existing orphan. CURRENT and NEXT month, always, so
--    there is a partition waiting before the boundary arrives rather than at it.
create or replace function private.ensure_partitions()
returns integer
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- 4. Grants. These are maintenance functions, not an API. `revoke ... from public` matters more
--    than usual here: without it `create or replace function` re-grants EXECUTE to PUBLIC and any
--    signed-in client could call `prune_notifications` and delete another user's inbox.
revoke execute on function private.prune_events()                    from public, anon, authenticated;
revoke execute on function private.prune_order_eta_snapshots()       from public, anon, authenticated;
revoke execute on function private.prune_notifications()             from public, anon, authenticated;
revoke execute on function private.prune_rider_location_pings()      from public, anon, authenticated;
revoke execute on function private.ensure_partitions()               from public, anon, authenticated;

-- 5. The schedules. Granularity from §3.7's table and §3.3's windows. `cron.schedule` upserts by
--    name in pg_cron 5, so re-applying this file does not create duplicates.
select cron.schedule('prune-events-hourly',      '7 * * * *',  $$select private.prune_events()$$);
select cron.schedule('prune-eta-hourly',         '13 * * * *', $$select private.prune_order_eta_snapshots()$$);
select cron.schedule('prune-notifications-daily','23 3 * * *', $$select private.prune_notifications()$$);
select cron.schedule('prune-pings-daily',        '41 3 * * *', $$select private.prune_rider_location_pings()$$);
-- Day 1 at 00:10, so next month's partition exists before the 2nd, not on the 1st.
select cron.schedule('ensure-partitions-monthly','10 0 1 * *', $$select private.ensure_partitions()$$);
-- §3.7: "Nightly VACUUM ANALYZE on the highest-churn tables. Free-tier IOPS are limited; bloat is
-- the silent killer." VACUUM cannot run inside a function, so this one is a raw command.
select cron.schedule('vacuum-hot-nightly',       '37 4 * * *',
  $$vacuum (analyze) public.events, public.orders, public.order_items, public.cart_items$$);

-- NO `begin;` / `commit;` IN THIS FILE, deliberately. An earlier draft had `commit;` before the
-- assertions, which meant the prunes and the cron schedules would be committed and live BEFORE a
-- failing assertion could stop them - and this migration's whole purpose is to install unattended
-- DELETE jobs. Every other migration in this repository relies on one implicit transaction per file
-- (`data-model.md` §15.1), and so does this one: a failed assertion now leaves nothing installed,
-- including `pg_cron` itself.

-- =============================================================================================
-- Assertions
-- =============================================================================================
-- Per `admin-crud-plan.md` §7a these EXECUTE the prunes rather than reading their definitions.
-- The probe inserts aged rows, runs each prune, and asserts both directions: the aged row is gone
-- AND the young row survives. A prune that deletes everything would fail the second half; a prune
-- that deletes nothing would fail the first. Both halves matter, and for `events` there is a third:
-- an UNDELIVERED aged row must survive, or a broken dispatcher would delete its own backlog.
do $$
declare
  v_admin      uuid := gen_random_uuid();
  v_user       uuid := gen_random_uuid();
  v_rider      uuid := gen_random_uuid();
  v_old        uuid;
  v_undelivered uuid;
  v_fresh      uuid;
  v_order      uuid;
  v_rider_row  uuid;
  v_eta_old    uuid;
  v_eta_fresh  uuid;
  v_ping_old   bigint;
  v_ping_fresh bigint;
  v_notif_old  bigint;
  v_notif_fresh bigint;
  v_n          integer;
  v_got        text;
begin
  -- The probe runs inside a subtransaction that is rolled back by raising a sentinel, the same
  -- pattern `027a`, `033` and `034` use. An earlier draft cleaned up with explicit
  -- `delete from auth.users where id in (...)`, which was scoped to three known uuids but was still
  -- a DELETE against a core identity table - and `auth.users` is referenced by FIFTEEN foreign keys,
  -- so it cascades into identities, sessions, mfa_factors, one_time_tokens, oauth_*, webauthn_*,
  -- scim_users, public.users, settings, feature_flags and commission_rules. No migration should
  -- contain that statement at all, even scoped. Rolling the subtransaction back removes the need
  -- for every one of them.
  --
  -- Nothing outside this block is rolled back, so the cron jobs created above stay - which is what
  -- assertion "the schedules" needs to observe.
  begin
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_admin, '035-probe@test.local', '+20199990004', '{}'::jsonb, now());
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_user,  '035-u@test.local',     '+20199990005', '{}'::jsonb, now());
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_rider, '035-r@test.local',     '+20199990006', '{}'::jsonb, now());

  -- TWO ROWS THE PROBE HAS TO STAND ON, and this is a correction, not scaffolding.
  --
  -- `rider_location_pings.rider_id` and `order_eta_snapshots.order_id` are both `not null` and both
  -- foreign keys, and the first draft of this probe invented uuids for them. It could not have run:
  -- `rider_id` references `public.riders`, NOT `auth.users` - a rider is onboarded through the
  -- verification flow, and `on_auth_user_created` deliberately creates only `public.users` rows
  -- (see `handle_new_user`). A probe row is therefore NOT a rider row.
  --
  -- `orders` needs a unique `order_number`, a real `user_id`, a non-null `address_snapshot`, and it
  -- carries `orders_total_consistent`, so the money columns cannot be left to contradict each other.
  -- All zero satisfies it: total = subtotal + delivery_fee + service_fee + rider_tip - discount_amount.
  --
  -- `riders` needs `first_name`, `phone_number`, `country_code` and `vehicle_type`. 014b's
  -- `trg_rider_contact_from_user` fires BEFORE INSERT and copies name and phone off the linked user
  -- when they are non-null; `handle_new_user` writes only id and email, so the probe's own values
  -- survive and the UNIQUE on `phone_number` is satisfied by a value no other row holds.
  v_rider_row := gen_random_uuid();
  insert into public.riders (id, user_id, first_name, phone_number, country_code, vehicle_type, status)
  values (v_rider_row, v_rider, '035', '+20199990006', 'EG', 'motorcycle', 'offline');

  v_order := gen_random_uuid();
  insert into public.orders (id, order_number, user_id, address_snapshot)
  values (v_order, '035-PROBE-0001', v_user, '{}'::jsonb);

  ----------------------------------------------------------------- events
  v_old         := gen_random_uuid();
  v_undelivered := gen_random_uuid();
  v_fresh       := gen_random_uuid();
  insert into public.events (id_uuid, type, payload, delivered_at, created_at) values
    (v_old,         'probe.old',         '{}'::jsonb, now(), now() - interval '10 days'),
    (v_undelivered, 'probe.undelivered', '{}'::jsonb, null,   now() - interval '10 days'),
    (v_fresh,       'probe.fresh',       '{}'::jsonb, now(), now());
  -- created_at is set explicitly and `events` carries no INSERT trigger (`pg_trigger` on it is empty),
  -- so the aged rows are genuinely aged. `events_delivered_after_created` holds because delivered_at
  -- is now() and created_at is in the past.

  v_n := private.prune_events();
  -- `exists`, NOT `not exists`. The row is GONE when this prune works, and "gone" is exactly what
  -- `not exists` reports - so the inverted form fires when the prune SUCCEEDS. That bug shipped in
  -- the first draft of this file and the dry run caught it, which is the whole reason these probes
  -- execute the prunes instead of reading them.
  if exists (select 1 from public.events where id_uuid = v_old) then
    raise exception 'FAIL CLOSED: prune_events left a 10-day-old DELIVERED event behind (removed %) rows', v_n;
  end if;
  if not exists (select 1 from public.events where id_uuid = v_undelivered) then
    raise exception
      'FAIL CLOSED: prune_events deleted an UNDELIVERED event older than its window. A broken dispatcher would destroy its own backlog and free-tier-plan.md 11 item 8 would have nothing to count.';
  end if;
  if not exists (select 1 from public.events where id_uuid = v_fresh) then
    raise exception 'FAIL CLOSED: prune_events deleted an event inside its retention window';
  end if;

  ----------------------------------------------------- order_eta_snapshots
  v_eta_old   := gen_random_uuid();
  v_eta_fresh := gen_random_uuid();
  insert into public.order_eta_snapshots (id, order_id, promised_at, predicted_at, computed_at) values
    (v_eta_old,   v_order, now(), now(), now() - interval '30 hours'),
    (v_eta_fresh, v_order, now(), now(), now());
  v_n := private.prune_order_eta_snapshots();
  if exists (select 1 from public.order_eta_snapshots where id = v_eta_old) then
    raise exception 'FAIL CLOSED: prune_order_eta_snapshots left a 30-hour-old row behind';
  end if;
  if not exists (select 1 from public.order_eta_snapshots where id = v_eta_fresh) then
    raise exception 'FAIL CLOSED: prune_order_eta_snapshots deleted a fresh row. The 24h window from free-tier-plan.md 3.3 is not being honoured.';
  end if;

  --------------------------------------------------------- rider_location_pings
  -- `id` is a `bigint` from a sequence, not a uuid, so it is left to the default and read back.
  insert into public.rider_location_pings (order_id, rider_id, latitude, longitude, recorded_at)
  values (v_order, v_rider_row, 30.0, 31.2, now() - interval '40 days')
  returning id into v_ping_old;

  insert into public.rider_location_pings (order_id, rider_id, latitude, longitude, recorded_at)
  values (v_order, v_rider_row, 30.0, 31.2, now())
  returning id into v_ping_fresh;
  v_n := private.prune_rider_location_pings();
  if exists (select 1 from public.rider_location_pings where id = v_ping_old) then
    raise exception 'FAIL CLOSED: prune_rider_location_pings left a 40-day-old row behind';
  end if;
  if not exists (select 1 from public.rider_location_pings where id = v_ping_fresh) then
    raise exception 'FAIL CLOSED: prune_rider_location_pings deleted a fresh row';
  end if;

  --------------------------------------------------- notifications + the orphan
  -- This half proves `private.ensure_month_partition` works, which is why it is called: the probe
  -- needs a partition old enough to hold a 40-day-old notification, and creating one IS the test.
  perform private.ensure_month_partition('notifications', (now() - interval '40 days')::date);
  if to_regclass('public.notifications_' || to_char(date_trunc('month', now() - interval '40 days'), 'YYYY_MM')) is null then
    raise exception 'FAIL CLOSED: ensure_month_partition did not create the partition it was asked for';
  end if;

  -- `id` is a `bigint` off a sequence here too, so the probe reads it back rather than inventing one.
  -- `title` and `body` are `jsonb` with `jsonb_typeof = 'object'` CHECKs, so `'{}'` is the shape.
  insert into public.notifications (user_id, type, title, body, created_at)
  values (v_user, 'order.placed', '{}'::jsonb, '{}'::jsonb, now() - interval '40 days')
  returning id into v_notif_old;

  insert into public.notifications (user_id, type, title, body, created_at)
  values (v_user, 'order.placed', '{}'::jsonb, '{}'::jsonb, now())
  returning id into v_notif_fresh;
  v_n := private.prune_notifications();
  if exists (select 1 from public.notifications where id = v_notif_old) then
    raise exception 'FAIL CLOSED: prune_notifications left a 40-day-old row behind';
  end if;
  if not exists (select 1 from public.notifications where id = v_notif_fresh) then
    raise exception 'FAIL CLOSED: prune_notifications deleted a fresh row';
  end if;

  ----------------------------------------------------------------- schedules
  -- The prunes are worthless if nothing calls them, so the schedules are asserted by name rather
  -- than trusted because six `cron.schedule` calls appear above.
  select count(*) into v_n
    from cron.job
   where jobname in ('prune-events-hourly','prune-eta-hourly','prune-notifications-daily',
                     'prune-pings-daily','ensure-partitions-monthly','vacuum-hot-nightly');
  if v_n <> 6 then
    raise exception 'FAIL CLOSED: expected 6 cron jobs, found %', v_n;
  end if;

  -- And nothing client-callable may reach the prunes.
  select string_agg(routine, ', ') into v_got
    from unnest(array['private.prune_events()','private.prune_order_eta_snapshots()',
                      'private.prune_notifications()','private.prune_rider_location_pings()',
                      'private.ensure_partitions()']) as r(routine)
   where has_function_privilege('anon', r.routine, 'EXECUTE')
      or has_function_privilege('authenticated', r.routine, 'EXECUTE')
      or has_function_privilege('public', r.routine, 'EXECUTE');
  if v_got is not null then
    raise exception 'FAIL CLOSED: these maintenance functions are callable by a client: %', v_got;
  end if;

    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then
      raise;
    end if;
  end;

  -- Nothing to clean up. The sentinel rolled the whole subtransaction back, including the users,
  -- the aged rows, the rows the prunes correctly refused to delete, and the extra partition the
  -- probe made `ensure_month_partition` create. If any of that had survived, this migration would
  -- have shipped test data into the retention tables it is about to start deleting from.
end $$;
