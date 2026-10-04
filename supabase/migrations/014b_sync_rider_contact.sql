-- =============================================================================================
-- 014b_sync_rider_contact.sql
-- =============================================================================================
-- Open question 3.13, resolved as option (a): keep both copies of name and phone, and make drift
-- impossible.
--
-- THE PROBLEM. users and riders each hold a name and a phone number, and each has its OWN
-- UNIQUE (phone_number) constraint:
--
--   users_phone_number_key   -> UNIQUE (phone_number)
--   riders_phone_number_key  -> UNIQUE (phone_number)
--
-- Two independent constraints, so the same rider can be +201000000001 in one table and
-- +201000000999 in the other, with nothing objecting. Verified before writing: the only trigger on
-- `riders` was updated_at, so there was no sync in either direction.
--
-- WHY THE COLUMNS CANNOT SIMPLY GO AWAY. riders.user_id is nullable by design - a rider can be
-- onboarded by an admin before they ever sign in. So riders has to be able to stand alone, which is
-- why this is option (a) rather than option (b) (drop the column, require linking first), which would
-- have removed the admin-onboarding path.
--
-- WHY THIS MATTERS MORE THAN IT LOOKS. ADR 20 exposes riders.phone_number through riders_public,
-- which is what a customer calls. If the two copies diverge, the customer calls a number the rider's
-- own account does not show, and dispatch calls another. The customer is the one who suffers, and the
-- rider cannot see why. It is not a leak - no other user can read the mismatch - it is an
-- operational fault that costs a failed delivery.
--
-- BOTH DIRECTIONS ARE NEEDED. A trigger only on `riders` closes the gap at insert time and leaves it
-- open afterwards: an admin editing the phone in the auth profile would silently re-introduce the
-- drift. So users -> riders is pushed too, and the stated goal - drift is impossible - is only
-- actually reached with both.
--
-- THE NULL GUARD IS THE WHOLE TRICK. constitution 18 says the phone number is "a profile field
-- collected after sign-in", so users.phone_number is NULL until the user completes their profile.
-- A plain `SELECT ... INTO new.phone_number` would assign NULL on a linked rider whose auth account
-- has not set a phone yet, and would WIPE a perfectly good contact number that an admin entered
-- during onboarding. Every field is therefore only overwritten when the source is non-null, so a
-- partial profile can never destroy data on the other side.
--
-- SECURITY DEFINER on both. ADR 20 gives clients no INSERT or UPDATE on `riders` at all, so without
-- SECURITY DEFINER the push trigger would fail the moment a rider changed their own phone - and the
-- rider updating their profile would get a permission error for something that should just work.
create or replace function private.sync_rider_contact_from_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_first text;
  v_last  text;
  v_phone text;
  v_cc    char(2);
begin
  if new.user_id is null then
    return new;
  end if;

  select u.first_name, u.last_name, u.phone_number, u.country_code
    into v_first, v_last, v_phone, v_cc
  from public.users u
   where u.id = new.user_id;

  if not found then
    return new;
  end if;

  -- Only non-null sources overwrite. See the null guard note above: this is the difference between
  -- syncing and destroying an onboarded rider's contact details.
  if v_phone is not null then new.phone_number := v_phone; end if;
  if v_first is not null then new.first_name  := v_first; end if;
  if v_last  is not null then new.last_name   := v_last;  end if;
  if v_cc    is not null then new.country_code := v_cc;    end if;

  return new;
end $$;

create or replace function private.push_user_contact_to_rider()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- A profile that has not set a phone yet cannot propagate one. Without this, completing a profile
  -- step that clears the phone would blank the rider record.
  if new.phone_number is null then
    return null;
  end if;

  -- The `is distinct from` guard makes this a no-op when nothing actually changed, so it does not
  -- bump riders.updated_at on every unrelated profile edit.
  update public.riders r
     set first_name    = coalesce(new.first_name,    r.first_name),
         last_name     = coalesce(new.last_name,     r.last_name),
         phone_number  = new.phone_number,
         country_code  = coalesce(new.country_code,  r.country_code)
   where r.user_id = new.id
     and (r.phone_number is distinct from new.phone_number
          or r.first_name    is distinct from coalesce(new.first_name,   r.first_name)
          or r.last_name     is distinct from coalesce(new.last_name,    r.last_name)
          or r.country_code  is distinct from coalesce(new.country_code, r.country_code));

  -- A rider changing their auth phone to a number another rider's profile already holds will raise
  -- riders_phone_number_key here, and the profile update fails. That is intended: two riders cannot
  -- share one contact number, and silently reassigning the row would be worse than refusing.
  return null;
end $$;

create trigger trg_rider_contact_from_user before insert or update on public.riders
  for each row execute function private.sync_rider_contact_from_user();

create trigger trg_user_contact_to_rider after update of first_name, last_name, phone_number, country_code
  on public.users for each row execute function private.push_user_contact_to_rider();

revoke execute on function private.sync_rider_contact_from_user() from public, anon, authenticated;
revoke execute on function private.push_user_contact_to_rider() from public, anon, authenticated;

-- The grant the client does not have but needs, for the record: authenticated holds SELECT on
-- rider_pay_rules and nothing else here. Assert the premise rather than trusting it.
do $$
begin
  if exists (select 1 from information_schema.role_table_grants
             where grantee in ('anon','authenticated')
               and table_schema = 'public' and table_name = 'riders') then
    raise exception 'FAIL CLOSED: riders is client-writable, which changes this trigger design';
  end if;

  if not exists (select 1 from pg_trigger
                 where tgrelid = 'public.riders'::regclass
                   and tgname = 'trg_rider_contact_from_user'
                   and not tgisinternal) then
    raise exception 'FAIL CLOSED: rider contact sync trigger is missing';
  end if;

  if not exists (select 1 from pg_trigger
                 where tgrelid = 'public.users'::regclass
                   and tgname = 'trg_user_contact_to_rider'
                   and not tgisinternal) then
    raise exception 'FAIL CLOSED: user contact push trigger is missing';
  end if;
end $$;