-- 022c: fix a false positive in the bare-auth.uid() lint, and allowlist the five
-- unindexed foreign keys that were adjudicated as deliberate.
--
-- First run of the 022 suite: 8 pass, 2 fail. Both failures are the CHECK's fault,
-- not the schema's, and both are recorded here because a lint that cries wolf is
-- worse than no lint — it gets ignored, and then it catches nothing.
--
-- ---------------------------------------------------------------------------
-- FIX 1 — the bare auth.uid() lint was wrong, and flagged 34 correct policies
-- ---------------------------------------------------------------------------
-- It reported every *_read policy in the schema. The policies are correct. This
-- one, for instance:
--
--   ((owner_id IN ( SELECT private.account_ids_for(( SELECT auth.uid() AS uid))
--                   AS account_ids_for)) OR ( SELECT private.is_admin() ...))
--
-- `( SELECT auth.uid() AS uid)` is exactly the scalar-subquery form data-model.md
-- 13.2 mandates. My pattern was
--
--   \(\s*select\s+auth\.uid\(\)\s*\)
--
-- which requires `auth.uid()` to be followed immediately by `)`. The alias `AS uid`
-- sits in between, so the correctly-parenthesised form did not match and the call
-- survived the strip. The lint was detecting the alias, not the bug it was written
-- to detect.
--
-- Replaced with a pattern that strips any parenthesised subselect containing both
-- `select` and `auth.uid()`, which tolerates an alias and any spacing:
--
--   \([^()]*\bselect\b[^()]*auth\.uid\(\)[^()]*\)
--
-- The `[^()]*` guards matter: they stop the match running past a nested paren, so
-- `( SELECT private.account_ids_for(( SELECT auth.uid() AS uid)) ...)` strips the
-- inner `( SELECT auth.uid() AS uid)` and leaves the rest, which contains no
-- `auth.uid()` and so correctly passes.
--
-- ---------------------------------------------------------------------------
-- FIX 2 — the unindexed-FK check was RIGHT, and needs its exceptions written down
-- ---------------------------------------------------------------------------
-- Five foreign keys have no index with them in the leading position. This is a true
-- positive, already adjudicated in 001-020-integrity-notes.md batch 3, where each
-- was accepted deliberately:
--
--   carts_quote_address_id_fkey        transient checkout input, read via cart_id
--   cart_items_selected_size_id_fkey   nullable option FK, read through its line
--   order_items_selected_size_id_fkey  same
--   event_daily_stats_city_id_fkey     admin-only nightly rollup, read whole or
--   search_daily_stats_city_id_fkey    by date range; never filtered by city_id
--
-- None is used as a lookup key or referenced by any RLS policy, so the only cost is
-- a sequential scan on parent delete or key update. The alternative — leaving them
-- out of the check — is what "nobody looked" looks like, so they are allowlisted by
-- name here with the reason attached. A NEW unindexed FK still fails the suite.
--
-- Nothing about the schema changes: no index added, no constraint dropped.

create or replace function tests.bare_auth_uid_offenders()
returns text language sql stable set search_path = '' as $$
  with raw as (
    select p.tablename, p.policyname, p.qual, p.with_check
      from pg_policies p
     where p.schemaname = 'public'
  ), stripped as (
    select tablename, policyname, expr
      from (
        -- 022c: was \(\s*select\s+auth\.uid\(\)\s*\) which missed the aliased form
        -- `( SELECT auth.uid() AS uid)` and flagged 34 correct policies.
        select tablename, policyname,
               regexp_replace(coalesce(qual, ''),
                              '\([^()]*\bselect\b[^()]*auth\.uid\(\)[^()]*\)', '', 'gi') as expr
          from raw
        union all
        select tablename, policyname,
               regexp_replace(coalesce(with_check, ''),
                              '\([^()]*\bselect\b[^()]*auth\.uid\(\)[^()]*\)', '', 'gi')
          from raw
      ) s
  )
  select coalesce(string_agg(format('%s.%s', tablename, policyname), ', ' order by tablename, policyname), '')
    from stripped
   where expr ~* 'auth\.uid\(\)';
$$;

create or replace function tests.unindexed_fk_offenders()
returns text language sql stable set search_path = '' as $$
  -- 022c: the five below were reviewed and accepted in 001-020-integrity-notes.md
  -- batch 3. None is a lookup key or appears in any RLS policy, so the only cost is
  -- a scan on parent delete or key update. Listed by name so the exception is
  -- visible and a NEW unindexed foreign key still fails the suite.
  --
  --   carts_quote_address_id_fkey        transient checkout input, read via cart_id
  --   cart_items_selected_size_id_fkey   nullable option FK, read through its line
  --   order_items_selected_size_id_fkey  same
  --   event_daily_stats_city_id_fkey     admin-only nightly rollup, never filtered
  --   search_daily_stats_city_id_fkey    by city_id
  with accepted (conname) as (
    values ('carts_quote_address_id_fkey'),
           ('cart_items_selected_size_id_fkey'),
           ('order_items_selected_size_id_fkey'),
           ('event_daily_stats_city_id_fkey'),
           ('search_daily_stats_city_id_fkey')
  ),
  fk as (
    select con.conrelid as reftbl,
           con.conname,
           con.conkey::int[] as cols,
           array_length(con.conkey, 1) as ncols,
           (select string_agg(a.attname, ',' order by o.ord)
              from unnest(con.conkey) with ordinality as o(attnum, ord)
              join pg_attribute a on a.attrelid = con.conrelid and a.attnum = o.attnum) as colnames
      from pg_constraint con
     where con.contype = 'f'
       and con.connamespace = 'public'::regnamespace
  )
  select coalesce(string_agg(format('%s(%s)', fk.conname, fk.colnames), ', ' order by fk.conname), '')
    from fk
   where not exists (select 1 from accepted where accepted.conname = fk.conname)
     and not exists (
     select 1
       from pg_index i
      where i.indrelid = fk.reftbl
        and (select array_agg(x::int order by o)
               from unnest(string_to_array(i.indkey::text, ' ')) with ordinality as t(x, o)
              where o <= fk.ncols) = fk.cols
   );
$$;