-- 033: the second redundancy pass. Four functions state twice that they changed a row.
--
-- Split from the audit findings so that each is separately applicable and separately verified.
-- `032` dropped three indexes. This one removes a duplicated assignment. `034` will collapse the
-- two byte-identical `bump_version_*` functions, which is a bigger change and gets its own file
-- so that a mistake in it cannot roll this one back.
--
-- =============================================================================================
-- THE REDUNDANCY
-- =============================================================================================
-- All four version-bump functions contain
--
--     update public.vendors v
--        set menu_version = v.menu_version + 1, updated_at = now()
--
-- and `vendors` carries `trg_vendors_updated_at`, a BEFORE UPDATE FOR EACH ROW trigger running
-- `public.set_updated_at()`, whose entire body is
--
--     new.updated_at := now();
--     return new;
--
-- So `updated_at` is assigned twice on the same row by the same statement, to the same value:
-- `set_updated_at()` overwrites whatever the SET clause said, and both use `now()`, which is
-- transaction-constant. Measured on the live project before this file was written:
--
--     update ... set menu_version = menu_version + 1, updated_at = now()   -> updated_at = T
--     update ... set menu_version = menu_version + 1                       -> updated_at = T
--
-- Identical. Removing the explicit clause cannot change any outcome.
--
-- WHY IT IS STILL WORTH REMOVING. The cost is not the redundant write - it is that two different
-- places now hold the rule "a vendor row changed, so stamp updated_at", and they hold it
-- independently. That is the desynchronisation shape this repo has paid for twice already: `005b`
-- fixed four near-identical bump functions in one go and `005a` had to exist because one of them
-- was wrong, and `014a` fixed a vendor-visibility leak caused by a value that had two sources of
-- truth. One source is strictly easier to reason about than two.
--
-- WHAT THIS DOES NOT DO. It does not touch `trg_vendors_updated_at` or `set_updated_at()`, which
-- remain the single mechanism that moves `updated_at` on `vendors`. If the trigger were ever
-- dropped, this file's functions would stop stamping the column - which is the correct failure
-- direction, because one dropped trigger then removes the behaviour everywhere instead of leaving
-- a hidden second path that still half-works.
--
-- =============================================================================================
-- THE FOUR FUNCTIONS
-- =============================================================================================
-- Only the SET clause changes. Bodies, volatility, `search_path` and the transition-table
-- contract are all preserved exactly, because these are STATEMENT triggers and `new_rows` is the
-- whole input.

create or replace function public.bump_version_for_categories()
returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.vendors v
     set menu_version = v.menu_version + 1
   where v.id in (select distinct nr.vendor_id from new_rows nr);
  return null;
end $$;

create or replace function public.bump_version_for_items()
returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.vendors v
     set menu_version = v.menu_version + 1
   where v.id in (select distinct nr.vendor_id from new_rows nr);
  return null;
end $$;

create or replace function public.bump_version_for_items_of()
returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.vendors v
     set menu_version = v.menu_version + 1
   where v.id in (select distinct mi.vendor_id
                    from new_rows nr join public.menu_items mi on mi.id = nr.item_id);
  return null;
end $$;

create or replace function public.bump_version_for_choices()
returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.vendors v
     set menu_version = v.menu_version + 1
   where v.id in (select distinct mi.vendor_id
                    from new_rows nr
                    join public.item_options io on io.id = nr.option_id
                    join public.menu_items mi on mi.id = io.item_id);
  return null;
end $$;

-- =============================================================================================
-- Assertions
-- =============================================================================================
do $$
declare
  v_expected constant text[] := array[
    'bump_version_for_categories','bump_version_for_items',
    'bump_version_for_items_of','bump_version_for_choices'];
  v_missing text;
  v_still_names text;
  v_ts timestamptz;
  v_ts2 timestamptz;
  v_mv integer;
  v_mv2 integer;
  v_cat uuid;
  v_item uuid;
  v_ven uuid;
  v_admin uuid;
  v_trigger_count integer;
begin
  -- 1. All four exist and none of them assigns updated_at any more. This is the whole point of
  --    the file, asserted over the catalog so a future edit that reintroduces the clause fails
  --    here rather than going unnoticed.
  select string_agg(p.proname, ', ' order by p.proname) into v_still_names
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = any (v_expected)
     and p.prosrc ~ 'updated_at';

  if v_still_names is not null then
    raise exception
      'FAIL CLOSED: these bump functions still assign updated_at, which is set_updated_at()''s job alone: %',
      v_still_names;
  end if;

  --    The negative test for that guard, in the shape `027a` established: probe with a literal,
  --    never with the text the migration just removed.
  if 'set menu_version = v.menu_version + 1, updated_at = now()'
       !~ 'updated_at' then
    raise exception
      'FAIL CLOSED: the updated_at guard cannot detect the assignment this file removed, so assertion 1 proves nothing';
  end if;
  if 'set menu_version = v.menu_version + 1' ~ 'updated_at' then
    raise exception
      'FAIL CLOSED: the updated_at guard false-positives on a clean body, so it would block correct code';
  end if;

  -- 2. All four still exist, are still SECURITY INVOKER, still pin search_path, and still return
  --    trigger. Removing a clause must not have disturbed any of that.
  select string_agg(e, ', ') into v_missing
    from unnest(v_expected) e
   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = e
                        and p.prorettype = 'trigger'::regtype
                        and not p.prosecdef
                        and exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
                                     where cfg like 'search\_path=%'));
  if v_missing is not null then
    raise exception
      'FAIL CLOSED: these bump functions lost their trigger return type, SECURITY INVOKER, or pinned search_path: %',
      v_missing;
  end if;

  -- 3. THE TRIGGER IS STILL THERE. This is the assertion that makes the change safe, and it is
  --    the reason the redundant clause was removable in the first place. If it fails, the
  --    migration must not have been written this way.
  if nullif(tests.updated_at_trigger_offenders(), '') is not null then
    raise exception
      'FAIL CLOSED: a table owns updated_at without a trigger, so removing these assignments would stop the column moving: %',
      tests.updated_at_trigger_offenders();
  end if;

  select count(*) into v_trigger_count
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_proc p on p.oid = t.tgfoid
   where n.nspname = 'public' and c.relname = 'vendors'
     and p.proname = 'set_updated_at' and not t.tgisinternal;
  if v_trigger_count <> 1 then
    raise exception
      'FAIL CLOSED: expected exactly one set_updated_at trigger on vendors, found %', v_trigger_count;
  end if;

  -- 4. EXECUTE IT. Assertions 1 to 3 read the catalog; only this one proves the functions still
  --    work, and it is here because `027` shipped green with a function that had never run.
  --    Per `admin-crud-plan.md` §7a the probe runs inside a subtransaction and is rolled back by
  --    a sentinel, then the rollback is proved rather than assumed.
  v_admin := gen_random_uuid();
  begin
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_admin, '033-probe@test.local', '+20199990002', '{}'::jsonb, now());
    insert into public.user_roles (user_id, role) values (v_admin, 'admin');
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

    insert into public.cities (code, name, name_ar, country_code, timezone, center_lat, center_lng)
    values ('P' || substr(v_admin::text, 1, 5), '033 probe', '033 probe', 'EG', 'Africa/Cairo', 30.0, 31.2);
    insert into public.areas (city_id, slug, name, name_ar, geohash_prefix, center_lat, center_lng)
    select c.id, 'p-' || substr(v_admin::text, 1, 5), '033 probe', '033 probe', 'u4pr', 30.0, 31.2
      from public.cities c where c.code = 'P' || substr(v_admin::text, 1, 5);
    insert into public.vendors (slug, name, name_ar, vertical_type, city_id, area_id,
                                latitude, longitude, geohash_prefix, is_approved, is_active)
    select 'p-' || substr(v_admin::text, 1, 5), '033 probe', '033 probe', 'food',
           c.id, a.id, 30.0, 31.2, 'u4pr', true, true
      from public.cities c join public.areas a on a.city_id = c.id
     where c.code = 'P' || substr(v_admin::text, 1, 5);

    select id into v_ven from public.vendors where slug = 'p-' || substr(v_admin::text, 1, 5);
    select menu_version into v_mv from public.vendors where id = v_ven;

    -- Plant a sentinel with the trigger disabled, so that the bump's own UPDATE is the only thing
    -- in the database capable of moving updated_at, then re-arm the trigger.
    --
    -- The first version of this check compared updated_at before and after the bump inside one
    -- transaction, and failed on correct code with `updated_at did not move: T -> T`. That is
    -- because `now()` is TRANSACTION-CONSTANT: the vendor's own INSERT, the bump, and the
    -- comparison all read the same transaction timestamp, so the value provably cannot differ.
    -- The check was unfalsifiable - it would have failed no matter what the functions did, which
    -- is the same defect as a regex that cannot fail, one level up. `027a` hit this exact trap
    -- and the sentinel is its answer.
    alter table public.vendors disable trigger trg_vendors_updated_at;
    update public.vendors set updated_at = '2000-01-01T00:00:00Z' where id = v_ven;
    alter table public.vendors enable trigger trg_vendors_updated_at;
    select updated_at into v_ts from public.vendors where id = v_ven;
    if v_ts <> '2000-01-01T00:00:00Z'::timestamptz then
      raise exception
        'FAIL CLOSED: could not plant the updated_at sentinel, got % - the rest of this probe would be meaningless', v_ts;
    end if;

    -- a category insert fires trg_bump_v_menu_categories_ins -> bump_version_for_categories
    v_cat := public.admin_upsert_menu_category_v1(
      jsonb_build_object('vendor_id', v_ven, 'name', '033 probe category'));

    select menu_version, updated_at into v_mv2, v_ts2 from public.vendors where id = v_ven;
    if v_mv2 <> v_mv + 1 then
      raise exception
        'FAIL CLOSED: inserting a category did not bump menu_version exactly once. % -> %', v_mv, v_mv2;
    end if;
    -- The load-bearing assertion. menu_version moved AND updated_at moved off the sentinel, even
    -- though no function in this path assigns updated_at any more. If this fails, the trigger is
    -- not firing on the bump's UPDATE and removing the clause was wrong.
    if v_ts2 <= v_ts then
      raise exception
        'FAIL CLOSED: menu_version moved but updated_at stayed at the sentinel %, so nothing stamps it any more',
        v_ts;
    end if;

    -- and the second hop, menu_items -> bump_version_for_items
    v_item := public.admin_upsert_menu_item_v1(
      jsonb_build_object('category_id', v_cat, 'name', '033 probe dish', 'base_price', 250));
    if v_item is null then
      raise exception 'FAIL CLOSED: the probe could not create an item, so bump_version_for_items never ran';
    end if;
    select menu_version into v_mv from public.vendors where id = v_ven;
    if v_mv <> v_mv2 + 1 then
      raise exception
        'FAIL CLOSED: inserting an item did not bump menu_version exactly once. % -> %', v_mv2, v_mv;
    end if;

    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then
      raise;
    end if;
  end;

  --    Prove the sentinel held. A probe that leaked its fixture would be a worse defect than the
  --    redundancy this file removes.
  if (select count(*) from public.cities  where code = 'P' || substr(v_admin::text, 1, 5)) <> 0
     or (select count(*) from public.vendors where slug = 'p-' || substr(v_admin::text, 1, 5)) <> 0
     or (select count(*) from public.menu_categories where name = '033 probe category') <> 0
     or (select count(*) from public.users where email = '033-probe@test.local') <> 0
  then
    raise exception 'FAIL CLOSED: the probe leaked its fixture. The sentinel rollback did not hold.';
  end if;
end $$;
