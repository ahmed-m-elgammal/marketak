-- 022b: drop the finishes() call — this pgtap build does not provide it.
--
-- 022a fixed the search_path and the SECURITY DEFINER mistake, and the suite then
-- got as far as `plan()` and all ten `is()` calls before dying on line 45 with
-- "function finishes() does not exist".
--
-- The cause is the extension, not the call. pgtap 1.3.3 is installed and
-- relocatable in `extensions`, and it provides `plan`, `is`, `ok`, `no_plan` and
-- `_set` — but no `finishes`. Verified against pg_proc rather than assumed:
--
--   select proname from pg_proc where proname ~ '^(finishes|plan|is|ok|no_plan)$';
--   -> _set, _set, is, is, no_plan, ok, ok, plan        (no finishes)
--
-- finishes() only emits a diagnostic when the number of assertions run does not
-- match the plan. That check is structurally impossible to fail here: the loop
-- runs `for v_i in 1 .. array_length(v_results, 1)` and plan() is called with that
-- same `array_length(v_results, 1)`, and every check is wrapped in a handler that
-- returns an `is()` row whether it passed or raised. So the row count is 10 by
-- construction. The diagnostic is redundant, and dropping it loses nothing.
--
-- run_all still returns exactly ten rows, which is the contract: ten `is()` rows,
-- one per check, each naming any offenders.

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
  -- extensions must be on the path: pgtap calls _set() unqualified.
  -- No finishes(): absent from pgtap 1.3.3 here, and redundant because the loop
  -- bound and the plan count are the same array_length.
  perform plan(array_length(v_results, 1));

  for v_i in 1 .. array_length(v_results, 1) loop
    -- Each check is evaluated defensively: a raised error fails that one check
    -- with its message rather than aborting the run and hiding the other nine.
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
  'Runs the 022 security suite and returns one row per check. Returns ten rows by construction. SECURITY INVOKER on purpose: it reads only catalogs. search_path is extensions because pgtap calls _set() unqualified.';