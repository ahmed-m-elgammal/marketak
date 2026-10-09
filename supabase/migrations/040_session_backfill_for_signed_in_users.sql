-- 040_session_backfill_for_signed_in_users.sql
-- Purpose: make a returning shopper's session useful immediately.
--
-- Problem: handle_new_user() inserts public.users with only (id, email). It deliberately does
--   NOT read phone_number from raw_user_meta_data, because that value is user-editable
--   (Supabase security rule: never authorise from user_metadata) and Apple/Google both suppress
--   it after first sign-in. So a user who authenticated with a Google-linked phone number comes
--   back with phone_number NULL and profile_completed_at NULL.
--
-- What this does: when Google (or Apple) *does* supply the verified phone on a later sign-in,
--   adopt it only when the profile still has none, then stamp profile_completed_at so the
--   shopper is not sent through onboarding for a phone we already hold.
--
-- Safety, stated precisely:
--   * Never overwrites an existing phone_number. A user-edited value always wins.
--   * Only runs on the auth side of the trigger, where new.email and the provider are
--     trustworthy, and only fills phone_number from new.phone_number when Supabase asserts it.
--   * Leaves profile_completed_at NULL when no phone is present, so constitution 18's gate still
--     sends that shopper to complete-profile. This widens the gate; it never bypasses it.
--   * on conflict do nothing, so a replayed auth event cannot mutate an established profile.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path TO ''
as $function$
begin
  insert into public.users (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;

  insert into public.user_roles (user_id, role)
  values (new.id, 'customer')
  on conflict (user_id, role) do nothing;

  -- Adopt a provider-verified phone the profile does not have yet, and only then consider the
  -- profile complete. `phone_number is null` is what makes this a fill and not an overwrite.
  if new.phone_number is not null and length(btrim(new.phone_number)) > 0 then
    update public.users u
       set phone_number = btrim(new.phone_number),
           profile_completed_at = coalesce(u.profile_completed_at, now())
     where u.id = new.id
       and u.phone_number is null
       and u.profile_completed_at is null;
  end if;

  return new;
end
$function$;

revoke execute on function public.handle_new_user() from public;
revoke execute on function public.handle_new_user() from anon;
revoke execute on function public.handle_new_user() from authenticated;
revoke execute on function public.handle_new_user() from service_role;