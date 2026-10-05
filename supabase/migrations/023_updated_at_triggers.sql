-- 023: close constitution II.17 on the 17 tables that had `updated_at` and no trigger.
--
-- THE DEFECT. `updated_at timestamptz not null default now()` is declared on 36 tables
-- between 002 and 012. Nineteen of them got a `set_updated_at` trigger. Seventeen did not:
--
--   addresses, areas, brands, cities, delivery_fee_tiers, delivery_zones, feature_flags,
--   item_options, menu_categories, menu_item_sizes, menu_items, option_choices, settings,
--   users, vendor_earnings_daily, vendor_schedules, vendors
--
-- Verified against the live database before writing this file: these 17 are exactly the
-- public tables that own an `updated_at` column and no `updated_at` trigger, and after
-- this file 36 tables own the column and all 36 have the trigger. `pg_class` x
-- `pg_attribute` x `pg_trigger` is the only authority for that count, and it is stated
-- here because "all of them" is exactly the claim that was wrong for ten migrations.
--
-- WHY IT WENT UNNOTICED FOR TEN MIGRATIONS. Almost every one of these tables is mutated
-- only through an RPC that assigns `updated_at = now()` in the same SET list as the data
-- it changes. That hides the missing trigger rather than compensating for it: the
-- timestamp is right, so nothing looks broken, and the column is quietly load-bearing on
-- out-of-band DDL that no function depends on and no test asserts. 016 found this while
-- reviewing `users` and correctly refused to fix one table in a migration assigned three
-- functions. All 17 land here instead.
--
-- WHAT THIS FILE IS. Seventeen triggers, one test function, one runner. It adds NO
-- function of its own:
--
--   * `public.set_updated_at()` already exists, created by 006_cart.sql:17 -
--     `language plpgsql`, `set search_path = ''`, deliberately NOT security definer
--     (a trigger function runs with the privileges of the statement that fired it, and
--     this one only assigns NEW - it needs no elevated rights and grants none).
--     Redefining it here would be a second source of truth for a function 19 triggers
--     already depend on, and 016:205 explicitly left it untouched.
--
--   * It creates no index, so migration rule 5 (CREATE INDEX CONCURRENTLY) does not
--     engage, and 023 being the first file applied against a non-empty database changes
--     nothing here: every one of the 17 is empty except `settings` (13 seeded rows), and
--     CREATE TRIGGER takes a brief ACCESS EXCLUSIVE lock without rewriting anything.
--
--   * It grants nothing to any role.
--
-- ---------------------------------------------------------------------------
-- REDUNDANT EXPLICIT ASSIGNMENTS, AND WHY THEY ARE NOT EDITED
-- ---------------------------------------------------------------------------
-- Four places already assign `updated_at = now()` by hand on tables this file adds a
-- trigger to. All four now assign the same value twice, and the two agree - `now()` is
-- the transaction timestamp, so a BEFORE UPDATE trigger and the SET list that fired it
-- see the identical value. Behaviour is unchanged.
--
--   005a:30,51 and 005b:95,105,115,126  vendors, inside bump_version_for_*()
--   016:516, 016:820                    users, inside complete_profile_v1 / update_profile_v1
--
-- None of them is corrected here. data-model.md 15.1 rule 3: a migration that has run is
-- immutable. The redundancy is harmless and the files are the historical record.
--
-- 016:192-206 states the case for keeping its own assignments - a function whose
-- correctness depends on out-of-band DDL is a comment-shaped claim - and adds that if a
-- trigger is ever added to `users` "it assigns the same value to the same column and the
-- two agree". This is that migration. The comment is now historical, not current, and
-- correcting it is CHANGELOG work rather than an edit to an applied file.
--
-- ---------------------------------------------------------------------------
-- THE TRIGGER IS UNCONDITIONAL, AND THAT IS THE POINT
-- ---------------------------------------------------------------------------
-- `set_updated_at()` assigns on EVERY update, including an update that changes nothing.
-- A no-op `UPDATE settings SET value = value` moves `updated_at`. That is the same
-- semantics the existing 19 tables already have, and consistency is worth more here than
-- a cleverer trigger: a `IS DISTINCT FROM` guard on the whole row would make
-- `updated_at` mean "a value changed" on some tables and "a statement ran" on others,
-- which is worse than either meaning alone. The 19 that already had it mean "a statement
-- ran", and these 17 now mean the same thing.
--
-- The cost is that a no-op write is a false delta for the incremental export
-- (free-tier-plan 3.4). The fix for that belongs in the write path - the admin
-- functions in 026-028 decide whether to issue the UPDATE at all - not in a trigger
-- that has to be right for 36 tables at once. 014b:84 already uses an `is distinct from`
-- guard, but for a narrower reason: to stop an unrelated profile edit from bumping
-- `riders.updated_at` through a cross-table sync, which is a different question from
-- "should this table's own update bump its own timestamp".
--
-- ---------------------------------------------------------------------------
-- TRIGGER COEXISTENCE, CHECKED RATHER THAN ASSUMED
-- ---------------------------------------------------------------------------
-- Three of the 17 already carry another trigger. All three coexist, and the reasons are
-- recorded so the next reader does not have to re-derive them:
--
--   menu_items          trg_menu_item_vendor       BEFORE INSERT OR UPDATE, per row
--   delivery_fee_tiers  trg_fee_tiers_monotonic    AFTER INSERT OR UPDATE, DEFERRABLE
--                                                    CONSTRAINT trigger
--   users               trg_user_contact_to_rider  AFTER UPDATE OF four columns
--
-- PostgreSQL fires triggers of the same timing and event in name order. On `menu_items`
-- that puts `trg_menu_item_vendor` before `trg_menu_items_updated_at` ('_' is 0x5f, 's'
-- is 0x73). Both are BEFORE ... FOR EACH ROW and they write different columns -
-- `vendor_id` and `updated_at` - so the order cannot matter. The other two differ in
-- timing or in event, so they cannot collide at all.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FILE DELIBERATELY DOES NOT FIX
-- ---------------------------------------------------------------------------
-- Five tables in the admin write surface have no `updated_at` COLUMN, so no trigger could
-- be added to them and they are untouched here:
--
--   cuisines            no created_at, no updated_at
--   vendor_areas        no created_at, no updated_at
--   vendor_cuisines     no created_at, no updated_at
--   vendor_holidays     created_at only
--   vendor_staff        created_at, deleted_at
--
-- All five are Tier 1 in admin-crud-plan.md 4 and all five are written by
-- 026_admin_geo_vendor.sql, so rule 17 is still violated on them after 023, 024 and 026
-- land. 024 gives four of them a `deleted_at` and `vendor_staff` already has one, which
-- makes the omission easy to miss: the table looks lifecycle-complete and is not. Decided
-- (asked, not assumed): 023 stays triggers-only, and the five columns are recorded as
-- open question 3.21 for a later migration rather than smuggled in here.
--
-- A second, separate class is also left alone: `favorites`, `favorite_items`,
-- `device_tokens` and `driver_shifts` are mutable, own no `updated_at`, and are Tier 2 or
-- Tier 3. `favorites` in particular is customer-owned and toggled, so the three purposes
-- rule 17 names do apply to it. Out of scope for a trigger migration; recorded, not
-- forgotten.
--
-- `user_roles` has no `created_at`, no `updated_at` and no `deleted_at`. admin-crud-plan
-- 4a rules hard delete for it, which is right for a join table, and 8 question 5 rules
-- that admin writes do not also write `audit_log`. A role grant with no timestamp
-- anywhere is the consequence of those two decisions taken together, and it is recorded
-- in the admin-write-surface ADR rather than quietly patched here.
--
-- ---------------------------------------------------------------------------
-- LANE CHECK
-- ---------------------------------------------------------------------------
-- BASELINE, captured before anything below runs. A session GUC rather than a plpgsql
-- variable because a migration file is a sequence of independent statements, not one
-- function body - there is nothing that survives from here to the DO block at the bottom
-- except a setting. Same mechanism 016:213 uses, and for the same reason.
select set_config('marketak.m023_triggers', count(*)::text, false)
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and not t.tgisinternal;

-- =============================================================================================
-- The 17 triggers
-- =============================================================================================
-- Naming follows the existing 19 exactly: trg_<table>_updated_at. The drop-then-create
-- pair is the 005b:81-83 pattern, so the file is re-runnable and a partially applied
-- attempt leaves nothing behind.

-- Geography and configuration
drop trigger if exists trg_cities_updated_at on public.cities;
create trigger trg_cities_updated_at before update on public.cities
  for each row execute function public.set_updated_at();

drop trigger if exists trg_areas_updated_at on public.areas;
create trigger trg_areas_updated_at before update on public.areas
  for each row execute function public.set_updated_at();

drop trigger if exists trg_delivery_zones_updated_at on public.delivery_zones;
create trigger trg_delivery_zones_updated_at before update on public.delivery_zones
  for each row execute function public.set_updated_at();

drop trigger if exists trg_delivery_fee_tiers_updated_at on public.delivery_fee_tiers;
create trigger trg_delivery_fee_tiers_updated_at before update on public.delivery_fee_tiers
  for each row execute function public.set_updated_at();

drop trigger if exists trg_settings_updated_at on public.settings;
create trigger trg_settings_updated_at before update on public.settings
  for each row execute function public.set_updated_at();

drop trigger if exists trg_feature_flags_updated_at on public.feature_flags;
create trigger trg_feature_flags_updated_at before update on public.feature_flags
  for each row execute function public.set_updated_at();

-- Vendor
drop trigger if exists trg_vendors_updated_at on public.vendors;
create trigger trg_vendors_updated_at before update on public.vendors
  for each row execute function public.set_updated_at();

drop trigger if exists trg_brands_updated_at on public.brands;
create trigger trg_brands_updated_at before update on public.brands
  for each row execute function public.set_updated_at();

drop trigger if exists trg_vendor_schedules_updated_at on public.vendor_schedules;
create trigger trg_vendor_schedules_updated_at before update on public.vendor_schedules
  for each row execute function public.set_updated_at();

-- Catalog. These four are the tables whose writes bump vendors.menu_version, so they are
-- the ones the incremental export and the R2 snapshot URL depend on - which is the whole
-- reason this migration is a prerequisite rather than a cleanup.
drop trigger if exists trg_menu_categories_updated_at on public.menu_categories;
create trigger trg_menu_categories_updated_at before update on public.menu_categories
  for each row execute function public.set_updated_at();

drop trigger if exists trg_menu_items_updated_at on public.menu_items;
create trigger trg_menu_items_updated_at before update on public.menu_items
  for each row execute function public.set_updated_at();

drop trigger if exists trg_menu_item_sizes_updated_at on public.menu_item_sizes;
create trigger trg_menu_item_sizes_updated_at before update on public.menu_item_sizes
  for each row execute function public.set_updated_at();

drop trigger if exists trg_item_options_updated_at on public.item_options;
create trigger trg_item_options_updated_at before update on public.item_options
  for each row execute function public.set_updated_at();

drop trigger if exists trg_option_choices_updated_at on public.option_choices;
create trigger trg_option_choices_updated_at before update on public.option_choices
  for each row execute function public.set_updated_at();

-- Customer and analytics
drop trigger if exists trg_users_updated_at on public.users;
create trigger trg_users_updated_at before update on public.users
  for each row execute function public.set_updated_at();

drop trigger if exists trg_addresses_updated_at on public.addresses;
create trigger trg_addresses_updated_at before update on public.addresses
  for each row execute function public.set_updated_at();

drop trigger if exists trg_vendor_earnings_daily_updated_at on public.vendor_earnings_daily;
create trigger trg_vendor_earnings_daily_updated_at before update on public.vendor_earnings_daily
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- The check that stops this from happening again
-- =============================================================================================
-- admin-crud-plan.md 7 defers all suite work to 031, and this is the one exception: the
-- guard for an invariant belongs with the migration that establishes it. Without it the
-- next table that declares `updated_at` and forgets the trigger reproduces this defect
-- silently, and the RPCs that assign the column explicitly will hide it exactly as they
-- hid these 17.
--
-- Shape matches the other ten: stable, `search_path = ''`, not security definer, returns
-- the LIST of offenders as a string so one `is()` names every table that broke it rather
-- than only the first.
--
-- The predicate is deliberately narrow. It asks: does a table that owns `updated_at` have
-- a BEFORE UPDATE row trigger running `public.set_updated_at`? It does NOT ask whether the
-- table SHOULD own the column - that is a per-table judgement (see the five above, and
-- `audit_log` / `events` / `ledger_entries`, which are append-only by design and must
-- never grow one), and a check that second-guessed it would cry wolf on the next
-- append-only table and get ignored.
create or replace function tests.updated_at_trigger_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%I.%I', n.nspname, c.relname), ', ' order by c.relname), '')
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'p')
     and c.relispartition = false
     and exists (
       select 1 from pg_attribute a
        where a.attrelid = c.oid and a.attname = 'updated_at' and not a.attisdropped)
     and not exists (
       select 1
         from pg_trigger t
         join pg_proc p on p.oid = t.tgfoid
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and p.proname = 'set_updated_at'
          -- pg_trigger.tgtype bits, from the catalog: ROW=1, BEFORE=2, INSERT=4, DELETE=8,
          -- UPDATE=16, TRUNCATE=32, INSTEAD=64. A `before update ... for each row` trigger
          -- reads 19 = 16+2+1, which is what all 19 pre-existing ones report.
          --
          -- The event bit (16) is deliberately NOT required. `before insert or update ... for
          -- each row` also satisfies "an update bumps updated_at", and requiring 16 would
          -- report such a table as an offender when it is not one. ROW set, BEFORE set and
          -- INSTEAD clear is the actual condition.
          and (t.tgtype & 1) = 1
          and (t.tgtype & 2) = 2
          and (t.tgtype & 64) = 0);
$$;

comment on function tests.updated_at_trigger_offenders() is
  'Tables owning updated_at with no BEFORE UPDATE FOR EACH ROW trigger on set_updated_at(). Added by 023; constitution II.17.';

-- The runner gains an eleventh check. Recreating it here is the same thing 022b, 022c and
-- 022d each did - the runner is one function whose body lists the checks, so adding a
-- check means replacing it. SECURITY INVOKER and `search_path = extensions` are kept
-- exactly as 022b left them: it reads only catalogs, and pgtap calls _set() unqualified.
-- No finishes(), for the reason 022b gave.
create or replace function tests.run_all()
returns setof text language plpgsql
security invoker
set search_path = extensions
as $$
declare
  v_results text[] := array[
    tests.rls_enabled_offenders(),
    tests.rls_policyless_offenders(),
    tests.bare_auth_uid_offenders(),
    tests.unindexed_fk_offenders(),
    tests.private_reachable_offenders(),
    tests.ledger_writable_offenders(),
    tests.anon_grants_offenders(),
    tests.client_write_grants_offenders(),
    tests.no_primary_key_offenders(),
    tests.unpinned_definer_offenders(),
    tests.updated_at_trigger_offenders()
  ];
  v_labels text[] := array[
    'every public table has RLS enabled',
    'every RLS-enabled table has at least one policy',
    'no policy uses a bare auth.uid()',
    'every foreign key is the leading column(s) of an index',
    'private schema is unreachable by anon, authenticated and service_role',
    'ledger_entries is not writable by anon or authenticated',
    'anon holds no table grant',
    'client roles hold only SELECT on tables',
    'every public table has a primary key',
    'every SECURITY DEFINER function pins search_path',
    'every table owning updated_at has a BEFORE UPDATE set_updated_at trigger'
  ];
  v_i int;
begin
  perform plan(array_length(v_results, 1));

  for v_i in 1 .. array_length(v_results, 1) loop
    begin
      return next is(
        coalesce(v_results[v_i], ''), '',
        v_labels[v_i] || case when coalesce(v_results[v_i], '') = ''
                             then '' else ' -- offenders: ' || v_results[v_i] end);
    exception when others then
      return next is('RAISED: ' || sqlerrm, '', v_labels[v_i] || ' -- the check itself failed');
    end;
  end loop;
end;
$$;

grant execute on function tests.run_all() to service_role;

comment on function tests.run_all() is
  'Runs the pgTAP suite and returns one row per check. Eleven rows by construction. SECURITY INVOKER: reads only catalogs. search_path is extensions because pgtap calls _set() unqualified.';

-- =============================================================================================
-- Assertions
-- =============================================================================================
-- Hand-run, in a rolled-back transaction: there is no npm test in this repo and the 022
-- suite is the only automated gate, so the migration states its own postconditions and
-- fails loudly rather than leaving them to a reader.
do $$
declare
  v_expected constant text[] := array[
    'addresses', 'areas', 'brands', 'cities', 'delivery_fee_tiers', 'delivery_zones',
    'feature_flags', 'item_options', 'menu_categories', 'menu_item_sizes', 'menu_items',
    'option_choices', 'settings', 'users', 'vendor_earnings_daily', 'vendor_schedules',
    'vendors'
  ];
  v_missing text;
  v_offenders text;
  v_delta integer;
begin
  -- 1. Lane check. Compared against the baseline captured at the top of this file rather
  --    than against the number 17, because 014b legitimately added a trigger and later
  --    migrations will add more. The guarantee is that THIS file added seventeen and
  --    nothing else - not that the schema total is any particular value.
  v_delta := (select count(*)
                from pg_trigger t
                join pg_class c on c.oid = t.tgrelid
                join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public' and not t.tgisinternal)
             - current_setting('marketak.m023_triggers')::integer;

  if v_delta <> 17 then
    raise exception
      'FAIL CLOSED: 023 created % public triggers, expected exactly 17', v_delta;
  end if;

  -- 2. Every one of the 17 has its trigger. Checked by name against the list above rather
  --    than by counting, so a trigger created on the wrong table fails here instead of
  --    balancing the count in assertion 1.
  select string_agg(t.tbl, ', ' order by t.tbl) into v_missing
    from unnest(v_expected) as t(tbl)
   where not exists (
     select 1
       from pg_trigger g
       join pg_class c on c.oid = g.tgrelid
       join pg_namespace n on n.oid = c.relnamespace
       join pg_proc p on p.oid = g.tgfoid
      where n.nspname = 'public'
        and c.relname = t.tbl
        and not g.tgisinternal
        and p.proname = 'set_updated_at'
        and (g.tgtype & 1) = 1
        and (g.tgtype & 2) = 2
        and (g.tgtype & 64) = 0);

  if v_missing is not null then
    raise exception
      'FAIL CLOSED: no set_updated_at BEFORE UPDATE row trigger on: %', v_missing;
  end if;

  -- 3. The suite's own check agrees, so the thing future migrations will be judged by is
  --    not quietly narrower than the thing this migration did.
  v_offenders := tests.updated_at_trigger_offenders();

  if v_offenders <> '' then
    raise exception
      'FAIL CLOSED: updated_at without a trigger, per the suite: %', v_offenders;
  end if;

  -- 4. The function this file depends on is the one 006 created: still there, still
  --    pinned, still not a definer. A future edit that made it SECURITY DEFINER would
  --    widen what a trigger can do on a table any definer function touches, and this is
  --    the last place that would be noticed.
  if not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'set_updated_at'
       and p.pronargs = 0
       and p.prosecdef = false
       and exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
                    where cfg like 'search\_path=%'))
  then
    raise exception
      'FAIL CLOSED: public.set_updated_at() is missing, is SECURITY DEFINER, or does not pin search_path';
  end if;
end $$;
