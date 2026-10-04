-- is_admin() is a policy helper. It is read from inside RLS policies, never called by a client.
-- While it lived in public it was reachable at /rest/v1/rpc/is_admin, because PostgREST exposes
-- every function in an exposed schema. Revoking EXECUTE from anon is not enough: the function
-- still has to be callable by authenticated for use in policies, and that grant makes it an RPC.
--
-- The real fix is to put it where PostgREST cannot see it. PostgREST exposes only public (and
-- graphql_public), so a private schema removes it from the API surface entirely while leaving it
-- fully usable from policies.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles r
    where r.user_id = (select auth.uid()) and r.role = 'admin' and r.revoked_at is null
  );
$$;

revoke execute on function private.is_admin() from public, anon, authenticated;
grant execute on function private.is_admin() to authenticated;

drop function if exists public.is_admin();