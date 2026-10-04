-- 010a: close a demonstrated cross-tenant read, and give vendor_staff a lifecycle flag.
--
-- LEAK. public.effective_cash_limit_v1 is SECURITY DEFINER and takes a rider_id, but never checked
-- that the caller is that rider. 008 revoked EXECUTE from public and anon, which was not enough:
-- authenticated is a member of PUBLIC and therefore still holds EXECUTE, so the function stayed
-- reachable at POST /rest/v1/rpc/effective_cash_limit_v1.
--
-- Proven by execution rather than inferred. With request.jwt.claims set to a customer identity and
-- the session switched to the authenticated role:
--
--   current_user after switch                      authenticated / session postgres
--   control: select from public.riders             CONTROL OK: privileges genuinely reduced
--   public.effective_cash_limit_v1(<other rider>)  LEAKED 777777
--
-- The control matters: it proves the role switch actually reduced privileges, so the leak is the
-- function bypassing the table lockdown and not an artefact of testing as the owner. A locked-down
-- table is worthless if a definer function hands its rows to anyone who asks. That is the shape of
-- 005b and 007b again - the write path was guarded and a read path around it was not.
--
-- FIX, following the pattern 005e set for private.is_admin():
--
--   private.effective_cash_limit(uuid)   unguarded, and not in an exposed schema, so PostgREST cannot
--                                         reach it. Settlement and reconciliation use this.
--   public.effective_cash_limit_v1(uuid) guarded: the caller must be the rider named, or an admin.
--
-- On a rejected read it RAISES rather than returning null. A null would be read by the caller as
-- "limit 0", and per data-model.md 8 a limit of 0 DISABLES cash collection for that rider - so a
-- silent null would turn an information leak into an operational outage. Raising with FORBIDDEN is
-- also identical for "no such rider" and "not yours", so it confirms nothing about which ids exist.

create or replace function private.effective_cash_limit(p_rider_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select max_cash_held from public.riders where id = p_rider_id),
    (select (value #>> '{}')::int from public.settings where key = 'rider_max_cash_held_default'),
    0
  );
$$;

revoke execute on function private.effective_cash_limit(uuid) from public, anon, authenticated;

create or replace function public.effective_cash_limit_v1(p_rider_id uuid)
returns integer language plpgsql stable security definer set search_path = '' as $$
begin
  if private.is_admin() then
    return private.effective_cash_limit(p_rider_id);
  end if;

  -- riders.user_id is nullable because a rider can be onboarded by an admin before ever signing in.
  -- Until that link exists there is no way to prove the caller owns the row, so nobody but an admin
  -- gets an answer. Trusting the row id alone is the leak.
  if exists (
    select 1 from public.riders r
    where r.id = p_rider_id
      and r.user_id is not null
      and r.user_id = (select auth.uid())
  ) then
    return private.effective_cash_limit(p_rider_id);
  end if;

  raise exception 'FORBIDDEN: not your rider' using errcode = '42501';
end;
$$;

-- authenticated keeps EXECUTE on purpose: the rider app calls this for their own limit. The guard is
-- now inside the function, so the grant is no longer the control - it is stated explicitly because
-- relying on implicit PUBLIC membership is exactly how this leaked the first time.
revoke execute on function public.effective_cash_limit_v1(uuid) from anon;

-- constitution.md III.17: soft delete plus updated_at on every business table. vendor_staff had
-- updated_at and NEITHER deleted_at nor an is_active flag, so it was the one business table in the
-- schema with no lifecycle mechanism at all: a staff member who leaves could only be deleted, losing
-- the record that they ever had access. Every other table lacking deleted_at has a competing
-- mechanism - is_active, effective_until, a status enum, or append-only semantics - and was left
-- alone in 009 for that reason. vendor_staff had none, so the rule applies cleanly.
--
-- Nullable, so this is an instant metadata-only change with no backfill. The table is empty.
alter table public.vendor_staff
  add column deleted_at timestamptz;

-- A soft-deleted staff member must stop appearing on a vendor dashboard, and can_manage_orders is a
-- permission. Excluding deleted rows in the index is what makes that the default rather than a WHERE
-- clause every future query has to remember.
create index vendor_staff_not_deleted on public.vendor_staff (vendor_id)
  where deleted_at is null;