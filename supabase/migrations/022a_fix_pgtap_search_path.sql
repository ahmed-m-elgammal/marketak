-- 022a: fix tests.run_all so the pgTAP suite can actually execute.
--
-- 022 shipped a run_all that could not run. Two reasons, both found by executing
-- it rather than reading it:
--
--   1. pgtap's own functions call `_set(...)` UNQUALIFIED. Installed into the
--      `extensions` schema with `set search_path = ''` on run_all, `extensions.plan()`
--      resolved but its internal `_set()` did not, and the suite died with
--      "function _set(unknown, integer) does not exist". pgtap assumes it is on
--      the search path.
--   2. run_all was SECURITY DEFINER, which it never needed. Every check reads
--      only catalogs - pg_class, pg_policies, pg_index, pg_constraint and
--      information_schema.role_table_grants - all of which are world-readable, so
--      SECURITY INVOKER sees the same rows. Dropping definer removes an
--      unnecessary privilege escalation from a function whose whole job is to
--      assert that no such escalation exists.
--
-- The resolution is therefore a fixed `set search_path = extensions` on a SECURITY
-- INVOKER function, which is safe in a way a definer function with a widened
-- search_path would not be: there is no privilege to escalate FROM. The check
-- functions keep `set search_path = ''` and stay schema-qualified, because none
-- of them call pgtap.
--
-- Grant also tightened. 022 granted execute to authenticated, which put a
-- security-audit surface in front of every signed-in user for no benefit: the
-- build harness runs as the service role, and these functions disclose nothing an
-- authenticated user cannot already read from the catalogs.

alter schema tests owner to postgres;
revoke all on schema tests from public;
grant usage on schema tests to service_role;

revoke all on function tests.run_all() from public, anon, authenticated;

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

  return next finishes();
end;
$$;

grant execute on function tests.run_all() to service_role;

comment on function tests.run_all() is
  'Runs the 022 security suite. SECURITY INVOKER on purpose: it reads only catalogs. search_path is extensions because pgtap calls _set() unqualified.';