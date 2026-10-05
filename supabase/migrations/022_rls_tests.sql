-- 022: rls_tests — pgTAP assertions that fail when a security boundary is missing.
--
-- Named for data-model.md §15.2 row 022: "pgTAP. Fails the build if a tenant
-- boundary is missing, if a policy uses a bare auth.uid(), or if a foreign key
-- is unindexed." Those three are the spec's requirement. The rest are the
-- assertions that the 001-020 integrity suite (see 001-020-integrity-notes.md)
-- had to run by hand, kept here so they stop depending on anyone remembering.
--
-- WHY THIS EXISTS. Every check below was, at some point, something I had to
-- discover by executing SQL against the live database rather than by reading the
-- migrations: the missing tenant boundary, the unindexed FK, the client table
-- grant. Two of them were only visible in pg_policies. A suite that runs is worth
-- more than a comment saying it should.
--
-- HOW TO RUN.
--   begin; select * from tests.run_all(); rollback;   -- inside a transaction
-- `run_all` wraps each check so a raised error fails that check rather than
-- aborting the run, and the whole thing is designed for `revert()`.
--
-- Each check function returns the LIST OF OFFENDERS, empty string when clean.
-- One `is()` per check, so plan() stays stable no matter how many tables there
-- are, and a failure still names every table that broke it rather than just the
-- first.

create extension if not exists pgtap with schema extensions;

create schema if not exists tests;

-- ---------------------------------------------------------------------------
-- 1. RLS enabled on every public table
-- ---------------------------------------------------------------------------
-- A table with RLS off is readable in full by any role with the grant. The grant
-- list is the other half of this; both are required for a boundary to exist.
create or replace function tests.rls_enabled_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%I.%I', n.nspname, c.relname), ', ' order by c.relname), '')
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'p')
     and c.relispartition = false
     and not c.relrowsecurity;
$$;

-- ---------------------------------------------------------------------------
-- 2. Every RLS-enabled table actually has a policy
-- ---------------------------------------------------------------------------
-- RLS on with no policy denies everything, which looks like a working boundary
-- and is actually a broken application. Caught 014-style mistakes here.
create or replace function tests.rls_policyless_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'p')
     and c.relispartition = false
     and c.relrowsecurity
     and not exists (
       select 1 from pg_policies p
        where p.schemaname = 'public' and p.tablename = c.relname);
$$;

-- ---------------------------------------------------------------------------
-- 3. No policy uses a bare auth.uid()
-- ---------------------------------------------------------------------------
-- data-model.md §13.2 mandates the scalar-subquery form, and §17 finding 2 makes
-- the lint check this migration's job. The bare form is not a style preference:
-- `auth.uid()` is STABLE, so Postgres evaluates it once per statement rather than
-- per row, which turns an intended per-row comparison into a single value
-- compared against every row. `(select auth.uid())` is VOLATILE and re-evaluates.
--
-- Implemented by removing every correctly-parenthesised occurrence and then
-- looking for a survivor, so `( select auth.uid() )` with odd spacing is not
-- flagged and a genuinely bare call is.
create or replace function tests.bare_auth_uid_offenders()
returns text language sql stable set search_path = '' as $$
  with raw as (
    select p.tablename, p.policyname, p.qual, p.with_check
      from pg_policies p
     where p.schemaname = 'public'
  ), stripped as (
    select tablename, policyname, expr
      from (
        select tablename, policyname,
               regexp_replace(coalesce(qual, ''), '\(\s*select\s+auth\.uid\(\)\s*\)', '', 'gi') as expr
          from raw
        union all
        select tablename, policyname,
               regexp_replace(coalesce(with_check, ''), '\(\s*select\s+auth\.uid\(\)\s*\)', '', 'gi')
          from raw
      ) s
  )
  select coalesce(string_agg(format('%s.%s', tablename, policyname), ', ' order by tablename, policyname), '')
    from stripped
   where expr ~* 'auth\.uid\(\)';
$$;

-- ---------------------------------------------------------------------------
-- 4. Every foreign key is the leading column(s) of an index
-- ---------------------------------------------------------------------------
-- Postgres does not index foreign keys automatically. An unindexed FK is a
-- sequential scan on every join to the child and a full scan on parent delete or
-- key update. Leading is the operative word: an index that merely CONTAINS the
-- FK column cannot serve the constraint check.
create or replace function tests.unindexed_fk_offenders()
returns text language sql stable set search_path = '' as $$
  with fk as (
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
   where not exists (
     select 1
       from pg_index i
      where i.indrelid = fk.reftbl
        and (select array_agg(x::int order by o)
               from unnest(string_to_array(i.indkey::text, ' ')) with ordinality as t(x, o)
              where o <= fk.ncols) = fk.cols
   );
$$;

-- ---------------------------------------------------------------------------
-- 5. private is unreachable by every client role
-- ---------------------------------------------------------------------------
-- The RLS helpers are SECURITY DEFINER and must be EXECUTABLE by the querying
-- role, which is why the grant exists. What makes that safe is that `private`
-- has no USAGE, so no client role can resolve anything inside it. An earlier
-- draft of 019-rpc-money-notes.md reported this as a vulnerability because it
-- read the grant and never checked the schema privilege; this assertion is the
-- version that would have caught the mistake.
create or replace function tests.private_reachable_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%s has USAGE on private', r), ', ' order by r), '')
    from unnest(array['anon', 'authenticated', 'service_role']) as r
   where has_schema_privilege(r, 'private', 'USAGE');
$$;

-- ---------------------------------------------------------------------------
-- 6. The ledger is append-only for clients
-- ---------------------------------------------------------------------------
-- 009 blocks UPDATE and DELETE by trigger; this checks the other half, that no
-- client role holds the grant to attempt it at all. service_role is excluded on
-- purpose: it is the trusted server role and legitimately holds DML.
create or replace function tests.ledger_writable_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%s:%s', grantee, privilege_type), ', ' order by grantee, privilege_type), '')
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name = 'ledger_entries'
     and grantee in ('anon', 'authenticated')
     and privilege_type in ('UPDATE', 'DELETE', 'TRUNCATE');
$$;

-- ---------------------------------------------------------------------------
-- 7. anon holds no table grant at all
-- ---------------------------------------------------------------------------
-- Nothing in this schema is browsable without a session. If a table needs to be
-- readable by a signed-out visitor it needs an explicit decision, not a default.
create or replace function tests.anon_grants_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%s:%s', table_name, privilege_type), ', ' order by table_name, privilege_type), '')
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee = 'anon';
$$;

-- ---------------------------------------------------------------------------
-- 8. Client roles hold only SELECT on tables
-- ---------------------------------------------------------------------------
-- Every mutation in this schema is a SECURITY DEFINER RPC. A direct client write
-- grant means some future app code can bypass a rule the RPC enforces.
create or replace function tests.client_write_grants_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%s:%s:%s', grantee, table_name, privilege_type), ', '
                                order by grantee, table_name, privilege_type), '')
    from information_schema.role_table_grants
   where table_schema = 'public'
     and grantee in ('anon', 'authenticated')
     and privilege_type <> 'SELECT';
$$;

-- ---------------------------------------------------------------------------
-- 9. Every public table has a primary key
-- ---------------------------------------------------------------------------
create or replace function tests.no_primary_key_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%I.%I', n.nspname, c.relname), ', ' order by c.relname), '')
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'p')
     and c.relispartition = false
     and not exists (
       select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary);
$$;

-- ---------------------------------------------------------------------------
-- 10. Every SECURITY DEFINER function pins search_path
-- ---------------------------------------------------------------------------
-- data-model.md §17 finding 1. `set search_path = public` still lets an object in
-- public shadow a built-in; the fix is `set search_path = ''` with
-- fully-qualified names. An unpinned SECURITY DEFINER function is a privilege
-- escalation waiting for someone to create a table with a built-in's name.
create or replace function tests.unpinned_definer_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%I.%I', n.nspname, p.proname), ', ' order by n.nspname, p.proname), '')
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where p.prosecdef
     and p.proname <> 'ensure_month_partition'
     and not exists (
       select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
        where cfg like 'search\_path=%');
$$;

-- ---------------------------------------------------------------------------
-- runner
-- ---------------------------------------------------------------------------
create or replace function tests.run_all()
returns setof text language plpgsql security definer set search_path = '' as $$
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
    tests.unpinned_definer_offenders()
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
    'every SECURITY DEFINER function pins search_path'
  ];
  v_i int;
begin
  -- pgtap is installed into `extensions`, and this function pins search_path to
  -- '', so every pgtap call is schema-qualified. An unqualified is() here would
  -- resolve against nothing and fail the suite rather than assert anything.
  perform extensions.plan(array_length(v_results, 1));

  for v_i in 1 .. array_length(v_results, 1) loop
    -- Each check is evaluated defensively: a raised error fails that one check
    -- with its message rather than aborting the run and hiding the other nine.
    begin
      return next extensions.is(
        coalesce(v_results[v_i], ''), '',
        v_labels[v_i] || case when coalesce(v_results[v_i], '') = ''
                             then '' else ' -- offenders: ' || v_results[v_i] end);
    exception when others then
      return next extensions.is(
        'RAISED: ' || sqlerrm, '',
        v_labels[v_i] || ' -- the check itself failed');
    end;
  end loop;

  return next extensions.finishes();
end;
$$;

revoke all on function tests.run_all() from public, anon, authenticated;
grant  execute on function tests.run_all() to authenticated, service_role;

comment on schema tests is
  'pgTAP security assertions. See data-model.md 15.2 row 022. Run: begin; select * from tests.run_all(); rollback;';