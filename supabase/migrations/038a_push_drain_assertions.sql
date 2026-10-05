-- 038a: the `register_device_token_v1` fix, and the P1.8 grant read-back.
--
-- The `claim_events_v1` fix is `038b`, and the behavioural probe is `038c`. Bundling a FIX with a PROBE in
-- one file meant a failure in a 700-line assertion block rolled the fix back with it, leaving the
-- database with the broken function. That is the `035` lesson arriving late: a migration that installs
-- unattended DELETE jobs and its tests together means a failing test takes the safety net away. `035` got
-- this right by having no `begin;`/`commit;`; the mistake here was bundling a FIX with a PROBE at all.

-- ---------------------------------------------------------------------------
-- 1. register_device_token_v1, corrected
-- ---------------------------------------------------------------------------
-- The first version declared `returns table (id uuid, token text, platform text, app_role text, ...)`.
-- Those OUT parameters share their names with the columns, so plpgsql resolved the unqualified `token`
-- in `on conflict (token)` to the OUT PARAMETER and the very first call raised:
--
--   ERROR  42702: column reference "token" is ambiguous
--
-- A conflict target cannot be schema-qualified - PostgreSQL rejects `on conflict
-- (public.device_tokens.token)` with a syntax error - and renaming the OUT parameters to `out_*` would
-- push odd names onto every client of an RPC whose signature is still being decided. Returning the row
-- type gives the client the table's own column names with no collision, and matches how every other
-- writer in this schema is shaped. `drop function` first, because the return type cannot change in place.

drop function if exists public.register_device_token_v1(text, text, text, text);

create function public.register_device_token_v1(
  p_token        text,
  p_platform     text,
  p_app_role     text,
  p_app_version  text default null
)
returns setof public.device_tokens
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := (select auth.uid());
  v_language text;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_token is null or btrim(p_token) = '' then
    perform private.err('TOKEN_REQUIRED', 'a push token is required');
  end if;
  if length(btrim(p_token)) > 4096 then
    perform private.err('TOKEN_TOO_LONG', 'push token is longer than 4096 characters');
  end if;

  -- Checked here rather than left to the CHECK constraints, so the client gets a named code instead of
  -- a raw `device_tokens_platform_check` violation it cannot map to anything.
  if p_platform is null or p_platform not in ('android', 'ios') then
    perform private.err('PLATFORM_INVALID', 'platform must be android or ios');
  end if;
  -- The column CHECK permits `admin` too and this function cannot narrow it - that is existing schema.
  -- Restricting the ARGUMENT constrains what a client may register, not what a row may hold, and that
  -- weaker guarantee is stated rather than claimed. Nothing routes to an `admin` token.
  if p_app_role is null or p_app_role not in ('customer', 'rider') then
    perform private.err('APP_ROLE_INVALID', 'app_role must be customer or rider');
  end if;

  -- One token per role. Routing resolves the recipient from `app_role`, so a customer token that
  -- silently started receiving rider messages would be a mis-delivery rather than a duplicate.
  if exists (
    select 1 from public.device_tokens t
     where t.user_id = v_user
       and t.app_role = p_app_role
       and t.token <> btrim(p_token)
  ) then
    perform private.err('TOKEN_ALREADY_REGISTERED',
      'another device is registered for this role; sign out on that device first');
  end if;

  -- `language` is read from the user, never accepted as an argument: it is the column the Worker renders
  -- from, and accepting it would let a client choose the language its own notifications arrive in. That
  -- cross-table read is why this is `security definer`.
  select u.preferred_language into v_language
    from public.users u where u.id = v_user;
  if v_language is null then
    perform private.err('PROFILE_INCOMPLETE', 'set a preferred language before registering for push');
  end if;

  -- `on conflict (token)` - the GLOBALLY unique key, `device_tokens_token_key`. NOT `(user_id, token)`:
  -- no such index exists, and the constraint forbids what that key would imply, since one token cannot
  -- belong to two users.
  return query
  insert into public.device_tokens
    (user_id, token, platform, app_role, app_version, language, last_seen_at)
  values
    (v_user, btrim(p_token), p_platform, p_app_role, p_app_version, v_language, now())
  on conflict (token) do update
     set user_id       = excluded.user_id,
         platform      = excluded.platform,
         app_role      = excluded.app_role,
         app_version   = excluded.app_version,
         language      = excluded.language,
         last_seen_at  = now()
  returning *;
end;
$$;

comment on function public.register_device_token_v1(text, text, text, text) is
  'Register or refresh this device''s push token. Upserts on (token), which is globally UNIQUE. '
  'language is read from users.preferred_language and never accepted from the client.';

revoke execute on function public.register_device_token_v1(text, text, text, text) from public, anon;
grant execute on function public.register_device_token_v1(text, text, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. P1.8 - the grant read-back
-- ---------------------------------------------------------------------------
-- `events` has exactly one policy, `events_admin_read`, a SELECT policy gated on `private.is_admin()`,
-- and NO INSERT or UPDATE policy at all - verified against `pg_policy`, one row with `polcmd = 'r'`. So a
-- client with EXECUTE on the drain could mark arbitrary events delivered, suppressing notifications
-- permanently, and could do it with `attempts` never rising, so `free-tier-plan.md` section 11 item 8
-- ("Undelivered `events` older than 1 hour") could never fire. An alarm that cannot ring is worse than no
-- alarm, because it reads as healthy.
--
-- These two are the FIRST functions in this repository not granted to `authenticated`. All 82 existing
-- `_v1` functions are, and each of them is correct: a client asking for its own order to be placed is what
-- they are for. The pattern a future author will copy from them is
-- `grant execute ... to authenticated, service_role`, which is why this is asserted from the catalog
-- rather than trusted from the migration text above.
do $$
declare
  v_leaked text;
begin
  select string_agg(r, ', ' order by r) into v_leaked
    from unnest(array[
      'public.register_device_token_v1(text,text,text,text)',
      'public.claim_events_v1(int)',
      'public.mark_events_delivered_v1(bigint[],jsonb)']) as x(r)
   where has_function_privilege('anon', r, 'EXECUTE');
  if v_leaked is not null then
    raise exception 'FAIL CLOSED: anon can EXECUTE %. Revoke after create, not before.', v_leaked;
  end if;

  select string_agg(r, ', ' order by r) into v_leaked
    from unnest(array[
      'public.claim_events_v1(int)',
      'public.mark_events_delivered_v1(bigint[],jsonb)']) as x(r)
   where has_function_privilege('authenticated', r, 'EXECUTE');
  if v_leaked is not null then
    raise exception
      'FAIL CLOSED: authenticated can EXECUTE %. A client could mark events delivered, suppressing '
      'notifications and holding attempts flat so section 11 item 8 can never fire.', v_leaked;
  end if;

  if not has_function_privilege('service_role', 'public.mark_events_delivered_v1(bigint[],jsonb)', 'EXECUTE') then
    raise exception 'FAIL CLOSED: service_role cannot mark; the drain has no writer';
  end if;
end $$;