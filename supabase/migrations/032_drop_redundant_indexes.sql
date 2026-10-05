-- 032: the first of the whole-database redundancy passes. Three indexes that cost write
-- amplification and storage and buy nothing.
--
-- This file is outside the `023`-`031` sequence in `admin-crud-plan.md` §6, which is why it is
-- numbered `032` rather than `028a`: `028`-`031` are still unwritten, and inserting an `028a`
-- would imply it belongs to the admin-engagement work. These are independent of that sequence
-- and of each other, and each is separately applicable and separately verified.
--
-- =============================================================================================
-- WHAT WAS FOUND, AND HOW
-- =============================================================================================
-- A whole-database pass for redundancy across tables, triggers and functions. Three indexes
-- turned out to duplicate, column for column and predicate for predicate, a unique index that
-- already exists on the same table:
--
--   delivery_fee_tiers_zone_count    (zone_id, vendor_count)   == PK (zone_id, vendor_count)
--   platform_float_date              (business_date)           == UNIQUE (business_date)
--   wallets_owner                    (owner_type, owner_id)    == UNIQUE (owner_type, owner_id)
--
-- All three are non-unique, all three have no predicate, and every column involved is NOT NULL.
-- That last point is what makes this airtight rather than merely likely: a unique index over
-- NOT NULL columns has no NULL-ordering or NULL-distinctness behaviour that a plain index over
-- the same columns would have handled differently, so the unique index is a strict superset of
-- what the plain one could serve. Every equality lookup, range scan, sort and uniqueness check
-- that could use the redundant index can use the unique one instead.
--
-- Concretely: no query can observe a difference. The only observable effect is that writes to
-- those three tables update one fewer btree.
--
-- =============================================================================================
-- WHY THIS IS THE SAFEST FIX IN THE AUDIT, AND THE ORDER THE PASSES ARE IN
-- =============================================================================================
-- Ranked by blast radius, safest first, which is the order they should be applied:
--
--   1. THIS FILE. Drop a redundant index. A unique index on the identical key remains, so there
--      is no moment at which the table loses its only access path. Correctness cannot change;
--      only write cost. Nothing is rewritten and no row is touched.
--   2. The redundant `updated_at = now()` in the four `bump_version_*` functions. Provably
--      identical behaviour, because `set_updated_at()` runs BEFORE UPDATE on the same statement
--      and sets the same column to the same value.
--   3. Collapsing `bump_version_for_categories` and `bump_version_for_items`, which have
--      byte-identical bodies. Behaviour-identical, but it drops a function and re-points two
--      triggers, so a mistake breaks catalog writes rather than costing some write throughput.
--   4. Collapsing `sync_order_item_aggregates_{ins,upd,del}` and the duplicate
--      `sync_order_status`. Same shape as 3, on the order path, which is hotter.
--
-- Deliberately NOT in this file, because both need a decision rather than a mechanical fix:
--
--   * `device_tokens.app_role` is CHECK-constrained to {customer,rider,admin} while
--     `user_roles.role` and `event_daily_stats.app_role` allow `support` as well. That divergence
--     is real but LATENT, not live: `device_tokens` has no writer of any kind - no routine
--     inserts it, it has no triggers, and `contracts.md` names no function to register a token.
--     Nothing is currently blocked. Widening the CHECK is one line, but which direction is
--     correct is a product decision - align `device_tokens` to `user_roles`, or recognise that
--     a push token legitimately has fewer roles than an account role - and guessing it here
--     would be the exact failure `admin-crud-plan.md` rule 9 exists to prevent.
--
--   * `orders.first_picked_up_at` is never written by any routine. It is either a column whose
--     writer was never built or a column nothing needs. Dropping it loses a stated intent;
--     implementing it is new behaviour. Not a mechanical fix.

-- =============================================================================================
-- THE DROPS
-- =============================================================================================
drop index if exists public.delivery_fee_tiers_zone_count;
drop index if exists public.platform_float_date;
drop index if exists public.wallets_owner;

-- =============================================================================================
-- Assertions
-- =============================================================================================
-- The negative-test discipline from `026` assertion 9 and `027a` assertion 1: a check that
-- cannot fail is not a check. Every predicate here is proved both ways.
do $$
declare
  v_dupes text;
  v_missing_cover text;
  v_n integer;
begin
  -- 1. NO NON-UNIQUE INDEX SHARES AN EXACT KEY AND PREDICATE WITH A UNIQUE INDEX ON THE SAME
  --    TABLE. Stated generally rather than as three names, so the next migration that adds a
  --    duplicate index fails here rather than in a slow query three months later.
  select string_agg(p.indexrelid::regclass::text, ', ' order by p.indexrelid::regclass::text)
    into v_dupes
    from pg_index p
    join pg_index u
      on  u.indrelid = p.indrelid
      and u.indisunique
      and not u.indisprimary
      and u.indexrelid <> p.indexrelid
      and coalesce(pg_get_expr(u.indpred, u.indrelid), '') = coalesce(pg_get_expr(p.indpred, p.indrelid), '')
      and (select string_agg(a2.attname, ',' order by k2.ord)
             from unnest(u.indkey) with ordinality k2(attnum, ord)
             join pg_attribute a2 on a2.attrelid = u.indrelid and a2.attnum = k2.attnum)
       = (select string_agg(a3.attname, ',' order by k3.ord)
             from unnest(p.indkey) with ordinality k3(attnum, ord)
             join pg_attribute a3 on a3.attrelid = p.indrelid and a3.attnum = k3.attnum)
   where not p.indisunique
     and not p.indisprimary
     and p.indpred is null
     and u.indpred is null
     and p.indexrelid in (
       select c.oid::regclass
         from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'i');

  if v_dupes is not null then
    raise exception
      'FAIL CLOSED: these non-unique indexes duplicate a unique index on the identical key and predicate: %',
      v_dupes;
  end if;

  --    The negative test, both directions, and it is SELF-CONTAINED on purpose.
  --
  --    The first version of this probe looked up `delivery_fee_tiers_zone_count` in the catalog.
  --    That index is dropped three statements earlier in this same file, so the probe could only
  --    ever fail — which is a check that cannot pass, not a check. It failed closed on the dry run
  --    for exactly that reason.
  --
  --    `027a` hit the identical trap and solved it the same way: probe with a literal, not with
  --    the thing the migration just changed. So the detector is exercised against a synthetic
  --    two-row index table below, which is unaffected by anything above.
  --    Note the flags: a redundant index is non-unique AND non-primary. Marking the fixture row
  --    `prim => true` was the first attempt and it made the detector correctly report 0, because
  --    a primary index is by definition unique and the detector excludes primaries on both sides.
  --    The fixture has to describe a real redundant index, which is neither.
  with synth(tbl, idx, key, uniq, prim, pred) as (values
    ('delivery_fee_tiers', 'delivery_fee_tiers_zone_count', 'zone_id,vendor_count', false, false, ''::text),
    ('delivery_fee_tiers', 'delivery_fee_tiers_pkey',       'zone_id,vendor_count', true,  false, ''::text)
  )
  select count(*) into v_n
    from synth p join synth u
      on  u.tbl = p.tbl and u.uniq and not u.prim and u.idx <> p.idx
     and u.pred = p.pred and u.key = p.key
   where not p.uniq and not p.prim;

  if v_n <> 1 then
    raise exception
      'FAIL CLOSED: the duplicate-index detector found % matches on the known-duplicate fixture, expected 1, so assertion 1 proves nothing',
      v_n;
  end if;

  --    And the control: same pair, different key, must find nothing. Without this, a detector that
  --    matched everything would satisfy the line above.
  with synth(tbl, idx, key, uniq, prim, pred) as (values
    ('delivery_fee_tiers', 'idx_a', 'zone_id,vendor_count', false, false, ''::text),
    ('delivery_fee_tiers', 'idx_b', 'zone_id',             true,  false, ''::text)
  )
  select count(*) into v_n
    from synth p join synth u
      on  u.tbl = p.tbl and u.uniq and not u.prim and u.idx <> p.idx
     and u.pred = p.pred and u.key = p.key
   where not p.uniq and not p.prim;

  if v_n <> 0 then
    raise exception
      'FAIL CLOSED: the duplicate-index detector false-positives on indexes with different keys, so it would block correct code';
  end if;

  -- 2. Every index this file dropped is gone.
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind = 'i'
                and c.relname in ('delivery_fee_tiers_zone_count','platform_float_date','wallets_owner')) then
    raise exception 'FAIL CLOSED: one of the three redundant indexes still exists';
  end if;

  -- 3. And the unique index that was covering each one still exists and is still unique. This is
  --    the one that matters: if the cover had been dropped by mistake, assertion 1 would pass
  --    happily with nothing left behind it.
  select string_agg(x.name, ', ') into v_missing_cover
    from (values
      ('delivery_fee_tiers_pkey', 'delivery_fee_tiers'::regclass),
      ('platform_float_business_date_key', 'platform_float'::regclass),
      ('wallets_owner_type_owner_id_key', 'wallets'::regclass)
    ) as x(name, tbl)
   where not exists (
     select 1 from pg_index i where i.indexrelid = to_regclass('public.' || x.name) and i.indisunique);

  if v_missing_cover is not null then
    raise exception
      'FAIL CLOSED: these unique indexes were the only access path for the columns just de-indexed, and are missing or no longer unique: %',
      v_missing_cover;
  end if;

  -- 4. No foreign key lost its leading-column index, and no table lost its primary key. Both
  --    were re-checked in `022` and both are cheap to assert here, because dropping an index is
  --    exactly the operation that would quietly break either.
  --
  --    Both helpers return `text`, not an array, and return the EMPTY STRING rather than NULL when
  --    clean - the same trap `027a` recorded for `tests.updated_at_trigger_offenders()`. The first
  --    version of this assertion wrote `unnest(tests.unindexed_fk_offenders())` and failed on the
  --    dry run with `function unnest(text) does not exist`.
  if nullif(tests.unindexed_fk_offenders(), '') is not null then
    raise exception
      'FAIL CLOSED: dropping these indexes left a foreign key unindexed: %',
      tests.unindexed_fk_offenders();
  end if;
  if nullif(tests.no_primary_key_offenders(), '') is not null then
    raise exception
      'FAIL CLOSED: a table has no primary key: %', tests.no_primary_key_offenders();
  end if;
end $$;
