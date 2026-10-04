-- Migrations 001-005c built the schema; RLS lands in 014. In the meantime every table in public was
-- reachable through PostgREST with the PUBLISHABLE anon key, which is designed to be embedded in a
-- shipped app and therefore public. That exposed users, user_roles, addresses, device_tokens and
-- vendor_earnings_daily to anyone who unpacks the binary.
--
-- There is no application yet, so nothing legitimate is reading these tables. Deny by default now
-- and let 014 grant back exactly what each role needs. Failing closed is the only safe default
-- between "schema exists" and "policies exist".
--
-- Confirmed by the Supabase security advisor going from 25 RLS errors to zero.

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- Functions are EXECUTE-granted to PUBLIC by default, which is why is_admin() was reachable by
-- anon through /rest/v1/rpc/is_admin.
revoke execute on all functions in schema public from anon;
revoke execute on function public.is_admin() from public, anon;

-- Any table or function created later inherits these defaults instead of PUBLIC execute, so a new
-- migration cannot silently re-open the door.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;