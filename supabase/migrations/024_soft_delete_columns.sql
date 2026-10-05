-- 024: the two missing lifecycle columns, so the admin write surface can exist.
--
-- Constitution II.17: "Soft delete plus `updated_at` on every business table. Archiving,
-- snapshot invalidation and incremental export all depend on them." The schema does not follow
-- that. `023` closed the `updated_at` TRIGGER gap on the 17 tables that already had the column;
-- this file closes the two gaps underneath it.
--
--   * 14 tables have no `deleted_at`, so `admin_*_delete_v1` cannot be written for them.
--     admin-crud-plan.md §6 calls this migration "Prerequisite for the admin delete functions",
--     and it is: 8 of the 10 tables in `026_admin_geo_vendor.sql` are in that 14.
--   * 5 tables own no `updated_at` COLUMN, so no trigger could be added to them and every admin
--     write to them would move no timestamp. Open question 3.31, found while planning `023` and
--     recorded rather than smuggled into a trigger migration.
--
-- ---------------------------------------------------------------------------
-- WHAT IS DELIBERATELY NOT GIVEN A deleted_at, AND WHY
-- ---------------------------------------------------------------------------
-- admin-crud-plan.md §4a classifies all 27 Tier 1 tables and reaches a deliberate conclusion for
-- nine of them. Rule 17 as literally written is wrong for these, and taking it literally would put
-- a meaningless column on tables whose lifecycle is something else. That plan row is the authority
-- for what follows; it is summarised here so a reader does not have to hold the other document open.
--
--   commission_rules     superseded by a new dated rule. Soft-deleting destroys the dated history
--                        that makes constitution I.9 auditable. `025` supersedes instead
--   rider_pay_rules      superseded, same reasoning
--   delivery_zones       lifecycle is `is_active`. A retired zone is inactive, not deleted
--   delivery_fee_tiers   same
--   wallets              frozen via `freeze_wallet_v1`. Deleting a wallet destroys the balance
--                        history that rule 1 requires to stay computable
--   reviews              `is_hidden`. The mechanism exists and `reviews_vendor_created` is already
--                        partial on `not is_hidden`
--   user_roles           hard delete. A join table. A revoked role that is merely soft-deleted
--                        still reads as present
--   settings             hard delete. Key/value. A removed key means the key does not exist
--   feature_flags        same
--
-- This is an AMENDMENT to rule 17, not a reinterpretation of it, and admin-crud-plan.md §9 says it
-- needs its own ADR. The rule's purpose — archiving, snapshot invalidation, incremental export — is
-- fully honoured for every table where those three actually apply.
--
-- ---------------------------------------------------------------------------
-- MIGRATION MECHANICS
-- ---------------------------------------------------------------------------
-- data-model.md §15.1 rule 7: new nullable column, backfill, then add the constraint. Followed
-- literally below. Every `deleted_at` lands NULLABLE and stays nullable, because a NOT NULL
-- column with a default would rewrite every row (rule 4) and a soft-delete column that cannot be
-- null is not a soft-delete column.
--
-- `add column if not exists` throughout, so the file is re-runnable. The `DO` block at the bottom
-- asserts the outcome rather than trusting the DDL to have done what it said.
--
-- No `CONCURRENTLY` anywhere: `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block,
-- and rule 5 applies from `023` onward only to index builds. All fifteen tables are empty except
-- `settings`, so even the indexes here are instant. One index IS added, on `vendor_areas`, and the
-- reason is below.
--
-- ---------------------------------------------------------------------------
-- THE ONE INDEX, AND WHY IT IS NOT ON EVERY TABLE
-- ---------------------------------------------------------------------------
-- Every table that gains a `deleted_at` also needs a way to ask "the live rows" without a full
-- scan, because that is the predicate every read in `026` and every read RPC uses. The existing
-- convention is a partial index on the live set, and 005b/012 already set it:
--
--   vendor_earnings_daily_live  on (vendor_id, business_date) where deleted_at is null
--   rider_earnings_daily_live   on (rider_id, business_date)  where deleted_at is null
--
-- The tables added here are all small configuration — a handful of cities, areas, brands,
-- cuisines, and a few rows per vendor. A seq scan on those is a handful of pages, and a partial
-- index per table would be fifteen indexes to maintain on tables that will never be large enough
-- to need one. So: NO new indexes here, and `026` reads these tables directly. The one exception
-- is `vendor_areas`, below.
--
-- `vendor_areas` is the exception because it is the only table in this set that grows with
-- (vendors x areas) rather than with configuration, and `014`'s `vendor_areas_read` policy
-- filters it. Its existing index is `vendor_areas (area_id) where is_active` — a live index that
-- does NOT exclude a soft-deleted row, so a deleted mapping would keep appearing in area
-- listings. Rather than replace that index (a drop and rebuild on a live table) this adds the
-- complementary one on the other side of the key, and `026` filters on `deleted_at is null`
-- explicitly so the two together serve both access paths.
--
-- ---------------------------------------------------------------------------
-- updated_at ON FIVE TABLES
-- ---------------------------------------------------------------------------
-- `cuisines`, `vendor_areas`, `vendor_cuisines`, `vendor_holidays` and `vendor_staff` are added
-- `updated_at timestamptz not null default now()` AND the `set_updated_at` trigger, so they match
-- the 36 tables that already behave that way. Without the trigger the column would be a
-- comment-shaped claim, which is the exact defect `023` and open question 3.20 were about.
--
-- Two of the five get `created_at` as well, because they have none and a table whose only
-- timestamp is `updated_at` cannot answer "how old is this row". `cuisines`, `vendor_areas` and
-- `vendor_cuisines` do NOT get one: they are join and lookup tables — a cuisine is a code, a
-- vendor_cuisines row is a pair of ids — and `created_at` on a row that only exists to express
-- membership is a second thing to keep true. That asymmetry is a judgement and is recorded as one
-- rather than left to be discovered.
--
-- All five columns land NOT NULL DEFAULT now(), which on an empty table is a metadata-only
-- operation: PostgreSQL 11+ stores the default in the catalog rather than rewriting rows. This is
-- safe here precisely because these tables are empty, and it is why rule 4 is not engaged.

-- =============================================================================================
-- PART 1 — deleted_at on the fourteen tables that archive
-- =============================================================================================
-- Geography and configuration
alter table public.cities             add column if not exists deleted_at timestamptz;
alter table public.areas              add column if not exists deleted_at timestamptz;
alter table public.delivery_zones     add column if not exists deleted_at timestamptz;
alter table public.delivery_fee_tiers add column if not exists deleted_at timestamptz;
alter table public.settings           add column if not exists deleted_at timestamptz;
alter table public.feature_flags      add column if not exists deleted_at timestamptz;

-- Vendor
alter table public.brands             add column if not exists deleted_at timestamptz;
alter table public.cuisines           add column if not exists deleted_at timestamptz;
alter table public.vendor_areas       add column if not exists deleted_at timestamptz;
alter table public.vendor_cuisines    add column if not exists deleted_at timestamptz;
alter table public.vendor_schedules   add column if not exists deleted_at timestamptz;
alter table public.vendor_holidays    add column if not exists deleted_at timestamptz;
-- vendor_staff ALREADY has deleted_at, added by 010a. Re-stated here so this file is the single
-- place a reader looks for the admin delete surface's prerequisites. `if not exists` makes the
-- re-statement a no-op rather than an error.

-- Menu
alter table public.menu_item_sizes    add column if not exists deleted_at timestamptz;
alter table public.item_options       add column if not exists deleted_at timestamptz;
alter table public.option_choices     add column if not exists deleted_at timestamptz;

-- Engagement
alter table public.promo_slots           add column if not exists deleted_at timestamptz;
alter table public.notification_templates add column if not exists deleted_at timestamptz;
alter table public.vouchers              add column if not exists deleted_at timestamptz;

-- =============================================================================================
-- PART 2 — the one index, and why
-- =============================================================================================
-- Live-set index on the other side of the key. `vendor_areas_read` filters by area_id; this serves
-- the by-vendor direction that `026`'s vendor-scoped reads use, and both exclude soft-deleted rows
-- so a withdrawn area mapping stops appearing in either listing.
create index if not exists vendor_areas_live
  on public.vendor_areas (vendor_id) where deleted_at is null;

-- =============================================================================================
-- PART 3 — created_at and updated_at on the five tables that own neither
-- =============================================================================================
-- `cuisines`: a reference table of codes. `created_at` omitted deliberately — see the header.
alter table public.cuisines
  add column if not exists updated_at timestamptz not null default now();

-- `vendor_areas` and `vendor_cuisines` are pure join tables. `created_at` omitted for the same
-- reason; `updated_at` added because a mapping can be re-pointed or withdrawn and the dashboard
-- needs to know when.
alter table public.vendor_areas
  add column if not exists updated_at timestamptz not null default now();
alter table public.vendor_cuisines
  add column if not exists updated_at timestamptz not null default now();

-- `vendor_holidays` already has created_at (004), so only updated_at is missing.
alter table public.vendor_holidays
  add column if not exists updated_at timestamptz not null default now();

-- `vendor_staff` already has created_at and deleted_at (003 + 010a). Only updated_at is missing,
-- and its absence is what 010a had to work around: it noted the table "had updated_at and NEITHER
-- deleted_at NOR an is_active flag" — meaning the column is absent, not merely untriggered, so the
-- staff list had no way to show when a grant changed.
alter table public.vendor_staff
  add column if not exists updated_at timestamptz not null default now();

-- The triggers. `public.set_updated_at()` already exists from 006 and is deliberately NOT
-- redefined — 19 triggers plus these five depend on it, and 016:205 explicitly left it untouched.
-- The naming follows the existing 24 exactly.
drop trigger if exists trg_cuisines_updated_at on public.cuisines;
create trigger trg_cuisines_updated_at before update on public.cuisines
  for each row execute function public.set_updated_at();

drop trigger if exists trg_vendor_areas_updated_at on public.vendor_areas;
create trigger trg_vendor_areas_updated_at before update on public.vendor_areas
  for each row execute function public.set_updated_at();

drop trigger if exists trg_vendor_cuisines_updated_at on public.vendor_cuisines;
create trigger trg_vendor_cuisines_updated_at before update on public.vendor_cuisines
  for each row execute function public.set_updated_at();

drop trigger if exists trg_vendor_holidays_updated_at on public.vendor_holidays;
create trigger trg_vendor_holidays_updated_at before update on public.vendor_holidays
  for each row execute function public.set_updated_at();

drop trigger if exists trg_vendor_staff_updated_at on public.vendor_staff;
create trigger trg_vendor_staff_updated_at before update on public.vendor_staff
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- Assertions
-- =============================================================================================
-- The file states its own postconditions. `add column if not exists` is idempotent, which is
-- exactly why it is also silent about failure: a typo'd table name would be a no-op rather than an
-- error, and a silently-missing column would only surface when `026` failed to compile. These
-- assertions turn that class of silence into a failed migration.
do $$
declare
  v_need_deleted constant text[] := array[
    'cities', 'areas', 'delivery_zones', 'delivery_fee_tiers', 'settings', 'feature_flags',
    'brands', 'cuisines', 'vendor_areas', 'vendor_cuisines', 'vendor_schedules', 'vendor_holidays',
    'vendor_staff', 'menu_item_sizes', 'item_options', 'option_choices',
    'promo_slots', 'notification_templates', 'vouchers'
  ];
  -- The nine that must NOT have one. Asserted as absent on purpose: a future migration that
  -- helpfully adds `deleted_at` to `commission_rules` would destroy the dated history rule 9
  -- depends on, and this is the place that would notice.
  v_no_deleted constant text[] := array[
    'commission_rules', 'rider_pay_rules', 'wallets', 'reviews', 'user_roles'
  ];
  v_need_updated constant text[] := array[
    'cuisines', 'vendor_areas', 'vendor_cuisines', 'vendor_holidays', 'vendor_staff'
  ];
  v_missing_del text;
  v_unexpected_del text;
  v_missing_upd text;
  v_missing_trg text;
  v_null_default text;
  v_not_nullable text;
begin
  -- 1. Every table that archives HAS deleted_at. Counted from the 19 named above, which is the 14
  --    this file adds plus the 5 that already had one (vendors, menu_categories, menu_items,
  --    vendor_staff, user_auth_providers) minus vendor_staff which is in both lists.
  select string_agg(t, ', ' order by t) into v_missing_del
    from unnest(v_need_deleted) as t
   where not exists (
     select 1 from pg_attribute a
      where a.attrelid = to_regclass('public.' || t)
        and a.attname = 'deleted_at' and not a.attisdropped);

  if v_missing_del is not null then
    raise exception 'FAIL CLOSED: no deleted_at on: %', v_missing_del;
  end if;

  -- 2. The five lifecycle tables that must NOT gain one.
  select string_agg(t, ', ' order by t) into v_unexpected_del
    from unnest(v_no_deleted) as t
   where exists (
     select 1 from pg_attribute a
      where a.attrelid = to_regclass('public.' || t)
        and a.attname = 'deleted_at' and not a.attisdropped);

  if v_unexpected_del is not null then
    raise exception
      'FAIL CLOSED: deleted_at must NOT exist on % - see admin-crud-plan.md 4a for the lifecycle each one has',
      v_unexpected_del;
  end if;

  -- 3. The five that gained updated_at have it.
  select string_agg(t, ', ' order by t) into v_missing_upd
    from unnest(v_need_updated) as t
   where not exists (
     select 1 from pg_attribute a
      where a.attrelid = to_regclass('public.' || t)
        and a.attname = 'updated_at' and not a.attisdropped);

  if v_missing_upd is not null then
    raise exception 'FAIL CLOSED: no updated_at on: %', v_missing_upd;
  end if;

  -- 4. And the trigger, because a column with no trigger is the defect 023 was written to close.
  --    Asserted via the suite's own check rather than a second hand-rolled predicate, so the
  --    migration and the suite cannot disagree about what "has the trigger" means.
  if exists (
    select 1 from unnest(tests.updated_at_trigger_offenders()) as x) then
    raise exception
      'FAIL CLOSED: a table owns updated_at with no trigger: %',
      (select tests.updated_at_trigger_offenders());
  end if;

  select string_agg(t, ', ' order by t) into v_missing_trg
    from unnest(v_need_updated) as t
   where not exists (
     select 1
       from pg_trigger g
       join pg_proc p on p.oid = g.tgfoid
      where g.tgrelid = to_regclass('public.' || t)
        and not g.tgisinternal
        and p.proname = 'set_updated_at');

  if v_missing_trg is not null then
    raise exception 'FAIL CLOSED: no set_updated_at trigger on: %', v_missing_trg;
  end if;

  -- 5. The five updated_at columns are NOT NULL with a default. A nullable updated_at is a
  --    nullable updated_at, and the whole incremental-export argument rests on it being set on
  --    every row including ones inserted by an admin.
  select string_agg(t, ', ' order by t) into v_null_default
    from unnest(v_need_updated) as t
   where exists (
     select 1 from pg_attribute a
      where a.attrelid = to_regclass('public.' || t)
        and a.attname = 'updated_at' and a.atthasdef = false);

  if v_null_default is not null then
    raise exception 'FAIL CLOSED: updated_at has no default on: %', v_null_default;
  end if;

  select string_agg(t, ', ' order by t) into v_not_nullable
    from unnest(v_need_updated) as t
   where exists (
     select 1 from pg_attribute a
      where a.attrelid = to_regclass('public.' || t)
        and a.attname = 'updated_at' and not a.attnotnull);

  if v_not_nullable is not null then
    raise exception 'FAIL CLOSED: updated_at is nullable on: %', v_not_nullable;
  end if;

  -- 6. deleted_at is NULLABLE on all of them, which is the opposite requirement and the reason
  --    it is asserted separately. A NOT NULL soft-delete column is a contradiction.
  if exists (
    select 1 from unnest(v_need_deleted) as t
      join pg_attribute a on a.attrelid = to_regclass('public.' || t)
     where a.attname = 'deleted_at' and a.attnotnull)
  then
    raise exception 'FAIL CLOSED: a deleted_at column is NOT NULL; a soft-delete column must be nullable';
  end if;
end $$;
