-- 034: the third redundancy pass. Two functions that are byte-identical, under two names.
--
-- =============================================================================================
-- WHAT IS BEING COLLAPSED, AND WHY IT IS SAFE
-- =============================================================================================
-- `bump_version_for_categories()` and `bump_version_for_items()` have the SAME `md5(prosrc)` and
-- the same body length. Both are:
--
--     update public.vendors v
--        set menu_version = v.menu_version + 1
--      where v.id in (select distinct nr.vendor_id from new_rows nr);
--
-- They differ only in which table's triggers call them, and `menu_categories` and `menu_items`
-- happen to share the property that makes one body serve both: each carries its own `vendor_id`,
-- so neither needs a join to find the vendor. That is the whole reason they are identical, and
-- it is worth naming rather than leaving as a coincidence.
--
-- WHY THIS MATTERS. This repo has already paid for exactly this shape once. `005a` exists because
-- `005` shipped one `bump_menu_version()` that read `new.item_id` unconditionally, which
-- `menu_categories` does not have; PL/pgSQL resolves record fields at RUNTIME, so the trigger and
-- all five CREATE TRIGGER statements succeeded and the function only failed when a category was
-- actually inserted. `005a`'s own header states the lesson: "That makes one function safe across
-- all five catalog tables without five near-identical functions." `005b` then replaced it with
-- four functions, and two of those four came out byte-identical. A fix applied to one name is
-- silently absent from the other; that is the divergence hazard, not the extra 181 bytes.
--
-- WHAT CHANGES AND WHAT DOES NOT.
--   * The function BODY does not change at all. This is a rename plus a re-point, not a rewrite.
--   * `menu_categories` INSERT and UPDATE, and `menu_items` INSERT and UPDATE, now share one
--     function. Four triggers, one body - the shape `005a` asked for.
--   * `bump_version_for_items_of` (one hop: row -> item -> vendor) and `bump_version_for_choices`
--     (two hops: row -> option -> item -> vendor) are UNTOUCHED. They are not duplicates of
--     anything; they are the other two join depths and the family legitimately has three members.
--
-- ORDER MATTERS, and it is the risky part of this file.
--   1. create the new function, while both old ones still exist and the triggers still resolve;
--   2. assert the new body is identical to the old body, BEFORE anything points at it;
--   3. re-point the four triggers, restating `REFERENCING NEW TABLE AS new_rows` exactly;
--   4. only then drop the two old functions.
-- Dropping first would either fail (a trigger depends on them) or, with CASCADE, silently delete
-- the triggers too - which is why no CASCADE appears anywhere in this file.
--
-- `REFERENCING NEW TABLE AS new_rows` is the part that must not be dropped in step 3. These are
-- STATEMENT triggers over a transition table; recreate one without the clause and `new_rows`
-- stops existing, and the body fails at the first catalog write.

-- =============================================================================================
-- 1. the shared function
-- =============================================================================================
create or replace function public.bump_version_for_direct_vendor()
returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.vendors v
     set menu_version = v.menu_version + 1
   where v.id in (select distinct nr.vendor_id from new_rows nr);
  return null;
end $$;

-- =============================================================================================
-- 3. re-point the four triggers, transition-table clause restated verbatim
-- =============================================================================================
drop trigger if exists trg_bump_v_menu_categories_ins on public.menu_categories;
create trigger trg_bump_v_menu_categories_ins
  after insert on public.menu_categories
  referencing new table as new_rows
  for each statement execute function public.bump_version_for_direct_vendor();

drop trigger if exists trg_bump_v_menu_categories_upd on public.menu_categories;
create trigger trg_bump_v_menu_categories_upd
  after update on public.menu_categories
  referencing new table as new_rows
  for each statement execute function public.bump_version_for_direct_vendor();

-- The trigger NAMES are unchanged from `005b`; only the function they call changes. Using a
-- different name here would leave `005b`'s trigger alive alongside the new one, and menu_items
-- would then carry TWO statement triggers on the same event and bump menu_version twice per write.
drop trigger if exists trg_bump_v_menu_items_ins on public.menu_items;
create trigger trg_bump_v_menu_items_ins
  after insert on public.menu_items
  referencing new table as new_rows
  for each statement execute function public.bump_version_for_direct_vendor();

drop trigger if exists trg_bump_v_menu_items_upd on public.menu_items;
create trigger trg_bump_v_menu_items_upd
  after update on public.menu_items
  referencing new table as new_rows
  for each statement execute function public.bump_version_for_direct_vendor();

-- =============================================================================================
-- 4. now the two old functions are unreferenced and may go
-- =============================================================================================
drop function if exists public.bump_version_for_categories();
drop function if exists public.bump_version_for_items();

-- =============================================================================================
-- Assertions
-- =============================================================================================
do $$
declare
  v_old_body text;
  v_new_body text;
  v_still_duplicated text;
  v_dangling text;
  v_lost_transition text;
  v_double_fired text;
  v_cat uuid;
  v_item uuid;
  v_ven uuid;
  v_admin uuid;
  v_mv integer;
  v_mv2 integer;
begin
  -- 1. THE BODY DID NOT CHANGE. `bump_version_for_categories` no longer exists, so this compares
  --    against a recorded fingerprint of what it was, not against a live function - the same
  --    discipline as the synthetic probes in `032` and `033`, because a check that reads the thing
  --    the migration just deleted can only ever fail.
  --    `btrim` on the normalized body, because collapsing `\s+` to a single space turns prosrc's
  --    trailing newline into a trailing space and the comparison would fail on whitespace alone.
  --    Normalising BOTH sides is what keeps this an assertion about the SQL rather than about the
  --    editor that wrote it.
  v_old_body := 'begin update public.vendors v set menu_version = v.menu_version + 1 where v.id in (select distinct nr.vendor_id from new_rows nr); return null; end';
  select btrim(regexp_replace(prosrc, '\s+', ' ', 'g')) into v_new_body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'bump_version_for_direct_vendor';

  if v_new_body is null then
    raise exception 'FAIL CLOSED: bump_version_for_direct_vendor does not exist';
  end if;
  if v_new_body <> v_old_body then
    raise exception
      'FAIL CLOSED: the collapsed body is not the body that was collapsed. Got: %', v_new_body;
  end if;

  -- 2. NO TWO FUNCTIONS IN THE BUMP FAMILY SHARE A BODY.
  --
  --    Scoped to the family on purpose. The first draft of this assertion was database-wide and
  --    failed closed on the dry run - correctly - because `sync_order_status` and
  --    `sync_order_item_aggregates_ins` are ALSO byte-identical. That pair is audit findings 2
  --    and 3, it lives on the order path rather than the catalog, and it is `035`'s work. A
  --    database-wide "zero duplicates" assertion written here would be claiming a fix this file
  --    does not make, and would block `034` from landing until an unrelated migration also did.
  --
  --    `035` is the one that asserts zero database-wide.
  select string_agg(p.proname, ', ' order by p.proname) into v_still_duplicated
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('bump_version_for_direct_vendor','bump_version_for_items_of','bump_version_for_choices')
   group by md5(p.prosrc)
  having count(*) > 1;

  if v_still_duplicated is not null then
    raise exception
      'FAIL CLOSED: these bump functions still share a body: %', v_still_duplicated;
  end if;

  -- 3. NO TRIGGER POINTS AT A FUNCTION THAT NO LONGER EXISTS. `pg_trigger.tgfoid` is an OID, so a
  --    dropped function would leave a dangling reference rather than an error at CREATE time, and
  --    the failure would surface as "trigger function does not exist" on the first catalog write.
  select string_agg(c.relname||'.'||t.tgname, ', ' order by c.relname, t.tgname) into v_dangling
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not t.tgisinternal
     and not exists (select 1 from pg_proc p where p.oid = t.tgfoid);
  if v_dangling is not null then
    raise exception
      'FAIL CLOSED: these triggers reference a function that does not exist: %', v_dangling;
  end if;

  -- 4. All four re-pointed triggers kept their transition-table clause. This is the specific way
  --    step 3 above can go wrong, so it is asserted per trigger rather than inferred from the
  --    body executing.
  select string_agg(c.relname||'.'||t.tgname, ', ' order by c.relname, t.tgname) into v_lost_transition
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_proc p on p.oid = t.tgfoid
   where n.nspname = 'public' and not t.tgisinternal
     and c.relname in ('menu_categories','menu_items')
     and p.proname = 'bump_version_for_direct_vendor'
     and t.tgtype::int & 1 = 0
     and t.tgqual is null
     and not pg_get_triggerdef(t.oid) ilike '%referencing new table as new_rows%';
  if v_lost_transition is not null then
    raise exception
      'FAIL CLOSED: these triggers lost REFERENCING NEW TABLE AS new_rows, so new_rows will not exist at run time: %',
      v_lost_transition;
  end if;

  -- 4b. NO TABLE+EVENT CALLS THE SAME TRIGGER FUNCTION TWICE. This is the specific mistake this
  --     file was one keystroke away from: the first draft dropped `trg_bump_v_items_ins`, which is
  --     not the name `005b` used, so the old trigger would have survived AND a new one would have
  --     been added - and `menu_items` would then have bumped menu_version twice on every write,
  --     with no error anywhere. Caught by reading the file back before applying, not by the
  --     database.
  --
  --     The predicate is deliberately "same table, same event, SAME FUNCTION" and NOT merely "more
  --     than one trigger". Asserting the latter failed closed on the dry run against ten
  --     legitimate pre-existing cases: `cart_items` carries a row-level assert and a
  --     statement-level touch on INSERT, `users` carries `set_updated_at` and
  --     `push_user_contact_to_rider` on UPDATE, `menu_categories` carries `set_updated_at` and a
  --     bump on UPDATE, and so on. Several triggers per event is this schema's NORMAL shape; two
  --     triggers calling the SAME function is duplication.
  --
  --     A CTE, because `ev` is built from `t.tgtype` and SQL will not let a SELECT expression
  --     reference a column that is not in the GROUP BY.
  with evs as (
    select c.relname as tbl,
             p.proname as fn,
             (case when (t.tgtype::int & 4)  = 4  then 'INSERT' else '' end)
          || (case when (t.tgtype::int & 8)  = 8  then 'DELETE' else '' end)
          || (case when (t.tgtype::int & 16) = 16 then 'UPDATE' else '' end) as ev
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_proc p on p.oid = t.tgfoid
     where n.nspname = 'public' and not t.tgisinternal
  )
  select string_agg(d.tbl || ' ' || d.ev || ' -> ' || d.fn, ', ' order by d.tbl, d.ev, d.fn)
    into v_double_fired
    from (select tbl, ev, fn, count(*) as n from evs group by tbl, ev, fn) d
   where d.n > 1;

  if v_double_fired is not null then
    raise exception
      'FAIL CLOSED: these table+event pairs call the same trigger function more than once, so the work runs twice per statement: %',
      v_double_fired;
  end if;

  -- 5. The family is now three functions, one per join depth, and no two share a body.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('bump_version_for_direct_vendor','bump_version_for_items_of','bump_version_for_choices')) <> 3 then
    raise exception 'FAIL CLOSED: the bump family is not the expected three functions';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('bump_version_for_categories','bump_version_for_items')) then
    raise exception 'FAIL CLOSED: one of the two duplicate functions still exists';
  end if;

  -- 6. EXECUTE IT, on both re-pointed tables. `027` shipped green with a function that had never
  --    run once, so the catalog is read and the catalog is then written to, per
  --    `admin-crud-plan.md` §7a. Rolled back by a sentinel, and the rollback is proved.
  v_admin := gen_random_uuid();
  begin
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_admin, '034-probe@test.local', '+20199990003', '{}'::jsonb, now());
    insert into public.user_roles (user_id, role) values (v_admin, 'admin');
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

    insert into public.cities (code, name, name_ar, country_code, timezone, center_lat, center_lng)
    values ('P' || substr(v_admin::text, 1, 5), '034 probe', '034 probe', 'EG', 'Africa/Cairo', 30.0, 31.2);
    insert into public.areas (city_id, slug, name, name_ar, geohash_prefix, center_lat, center_lng)
    select c.id, 'p-' || substr(v_admin::text, 1, 5), '034 probe', '034 probe', 'u4pr', 30.0, 31.2
      from public.cities c where c.code = 'P' || substr(v_admin::text, 1, 5);
    insert into public.vendors (slug, name, name_ar, vertical_type, city_id, area_id,
                                latitude, longitude, geohash_prefix, is_approved, is_active)
    select 'p-' || substr(v_admin::text, 1, 5), '034 probe', '034 probe', 'food',
           c.id, a.id, 30.0, 31.2, 'u4pr', true, true
      from public.cities c join public.areas a on a.city_id = c.id
     where c.code = 'P' || substr(v_admin::text, 1, 5);

    select id into v_ven from public.vendors where slug = 'p-' || substr(v_admin::text, 1, 5);
    select menu_version into v_mv from public.vendors where id = v_ven;

    -- menu_categories INSERT -> the newly shared function
    v_cat := public.admin_upsert_menu_category_v1(
      jsonb_build_object('vendor_id', v_ven, 'name', '034 probe category'));
    select menu_version into v_mv2 from public.vendors where id = v_ven;
    if v_mv2 <> v_mv + 1 then
      raise exception 'FAIL CLOSED: category insert did not bump menu_version once. % -> %', v_mv, v_mv2;
    end if;

    -- menu_items INSERT -> the same function, proving both tables really do share one body now
    v_item := public.admin_upsert_menu_item_v1(
      jsonb_build_object('category_id', v_cat, 'name', '034 probe dish', 'base_price', 250));
    if v_item is null then
      raise exception 'FAIL CLOSED: item insert failed, so the second re-pointed trigger never fired';
    end if;
    select menu_version into v_mv from public.vendors where id = v_ven;
    if v_mv <> v_mv2 + 1 then
      raise exception 'FAIL CLOSED: item insert did not bump menu_version once. % -> %', v_mv2, v_mv;
    end if;

    -- and the untouched one-hop function still works from the same probe
    perform public.admin_upsert_menu_item_size_v1(
      jsonb_build_object('item_id', v_item, 'name', '034 probe size', 'price', 250));
    select menu_version into v_mv2 from public.vendors where id = v_ven;
    if v_mv2 <> v_mv + 1 then
      raise exception 'FAIL CLOSED: size insert did not bump menu_version once. % -> %', v_mv, v_mv2;
    end if;

    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then
      raise;
    end if;
  end;

  if (select count(*) from public.cities  where code = 'P' || substr(v_admin::text, 1, 5)) <> 0
     or (select count(*) from public.vendors where slug = 'p-' || substr(v_admin::text, 1, 5)) <> 0
     or (select count(*) from public.menu_categories where name = '034 probe category') <> 0
     or (select count(*) from public.users where email = '034-probe@test.local') <> 0
  then
    raise exception 'FAIL CLOSED: the probe leaked its fixture. The sentinel rollback did not hold.';
  end if;
end $$;
