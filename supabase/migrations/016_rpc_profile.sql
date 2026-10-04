-- =============================================================================================
-- 016_rpc_profile.sql
-- =============================================================================================
-- The profile gate. constitution.md II.18: "a user without profile_completed_at can browse but
-- cannot order. The gate is enforced in the RPC, in RLS, and in the app - one layer is not enough."
-- This migration is the RPC layer. It is the only writer of profile_completed_at in the schema.
--
-- It creates three functions and NOTHING ELSE - no table, no trigger, no index. That is asserted at
-- the bottom against counts captured at the top, not merely claimed here.
--
-- contracts.md 1.3 names three functions. data-model.md 15.2 lists only two of them for this
-- migration (complete_profile_v1, get_profile_status_v1); update_profile_v1 is in the contract and
-- absent from the table. Built here because the contract is authoritative for RPC signatures, and
-- because an app with no way to edit a name after onboarding has a real defect. 15.2 is the doc that
-- is behind, not this file.
--
-- ALL THREE FUNCTIONS ARE SECURITY DEFINER, INCLUDING THE PURE READ. 014 gives `authenticated`
-- SELECT on `users` and `addresses` and no write anywhere, so the two mutations have no choice. The
-- read does - a security invoker get_profile_status_v1 would be satisfied by the existing policies -
-- and it is still definer, for two reasons. 015's search_catalog_v1 is a definer read too, so this
-- keeps one pattern; and a definer read that forgets its WHERE clause leaks silently, whereas an
-- invoker one is caught by a policy. That is why the identity predicate is written out by hand in
-- every function below even where it looks redundant. SECURITY DEFINER bypasses RLS, so a predicate
-- that lives only in pg_policies is not enforced here, and 014a exists because 014's comment claimed
-- a guarantee the policies did not provide.
--
-- WHY THE ERROR MAPPING IS THE INTERESTING PART OF THIS FILE. 014b put an
-- `after update of first_name, last_name, phone_number, country_code` trigger on `users` that pushes
-- those four values into any linked `riders` row. `riders.phone_number` carries its own UNIQUE
-- constraint (`riders_phone_number_key`, a different constraint from `users_phone_number_key`).
-- So writing a profile phone can abort on a constraint that has nothing to do with the profile, from
-- code the client never called, and the client would receive a raw 23505 unique_violation naming a
-- table it has no access to. complete_profile_v1 checks for that collision BEFORE writing and raises
-- a domain code, and wraps the write in an exception handler as the race backstop. Both layers, in
-- that order: the check gives a good message, the handler gives correctness under concurrency.
--
-- MONEY. There is none in this migration and none is implied by it. No piastres, no fee, no
-- multiplier, no limit - constitution.md III.7 is not engaged. The only numeric literals in the
-- function bodies below are length bounds on a name, a path and a digit count, none of which is a
-- business constant.
-- =============================================================================================

-- ---------------------------------------------------------------------------------------------
-- ASSUMPTIONS. Every place the spec was silent, decided here rather than guessed at quietly
-- (AGENTS.md rule 9). Each is revisited in the migration report.
-- ---------------------------------------------------------------------------------------------
--
-- A1. `missing` is `text[]`, built with `array_append` in a fixed declaration order, never
--     `array_agg` without ORDER BY, because that order is undefined and the app renders the
--     completion screen from it. `array_append` and not `||` on an untyped literal - see the BUG note
--     below, which is why. The
--     vocabulary is closed and is exactly four tokens, each the name of the column or
--     relation that has to be filled: first_name, last_name, phone_number, address. Using column
--     names means the app binds a label to a token mechanically instead of through a lookup table
--     that can drift. It reflects what complete_profile_v1 demands, which is a superset of what the
--     `profile_phone_required` CHECK demands - the CHECK only requires a phone, but the RPC requires
--     three fields, and a completion screen that asks for less than the submit call needs is a dead
--     end (constitution.md 5 of the error contract: PROFILE_INCOMPLETE is "never a dead end").
--
-- A2. All three functions return the SAME six-column record. contracts.md says complete_profile_v1
--     and update_profile_v1 return "the new profile" / "the new profile state" without enumerating
--     them, while get_profile_status_v1 is enumerated. One shape for all three is chosen because the
--     app already reads its own row (`authenticated` holds SELECT on `users` under `users_read`), so
--     echoing names and phone back is redundant, and what the app must re-evaluate after a write is
--     `has_phone` and `can_order`. If the reviewer wants the full row back instead, this is a change
--     to two RETURNS TABLE clauses and three RETURN QUERYs, not a redesign.
--
-- A3. `can_order` is derived, never stored. It is `profile_completed_at is not null`, and no column
--     is added for it, because constitution.md II.15/16 make the database the single place a
--     permission decision is written and a stored copy of a derived gate is a second source of truth
--     that will drift. Asserted at the bottom of this migration.
--
-- A4. `can_browse` is true for every caller that gets an answer. constitution.md II.18 makes browsing
--     unconditional for a signed-in user, and this function refuses to answer at all for a
--     soft-deleted account - so reaching this line IS the browse permission, and a stored or computed
--     flag would be redundant. `users.is_active` is deliberately NOT consulted: nothing in the spec
--     defines a customer-facing meaning for it, and returning a permission the schema cannot enforce
--     anywhere else would be worse than not returning it. If the product decides deactivation should
--     withdraw browsing, that is a spec change and this becomes `is_active and deleted_at is null`.
--
-- A5. The E.164 check is `^\+[1-9][0-9]{7,14}$` applied to `btrim` of the input. That is "a plus, a
--     country code that does not start with zero, and 8 to 15 digits in total", which is the E.164
--     length bound. Input is TRIMMED but otherwise NOT normalised: a stored number must be the number
--     that was validated, because `users_phone_number_key`, `riders_phone_number_key` and 014b's
--     trigger all compare raw text. Normalising here would let two spellings of one number both pass
--     the regex and then collide, or fail to collide, depending on which the client sent.
--
-- A6. Name bounds are 1 to 80 CHARACTERS after trim, measured in characters not bytes, because an
--     Arabic name costs two bytes per character in UTF-8 and a byte bound would reject legitimate
--     names. 80 is well past any real personal name in Arabic or Latin script; past it the input is
--     a data-entry fault. Chosen here because `users.first_name` is unbounded `text` with no CHECK.
--
-- A7. IDEMPOTENCY of complete_profile_v1 is decided on the gate, because contracts.md fixes the
--     signature at three arguments and gives it no idempotency_key to key on. See the long comment at
--     the function.
--
-- A8. `avatar_path` is validated as a PATH, not merely as a string: no URI scheme, no `..`, no
--     backslash, 1 to 512 characters. Which BUCKET a path belongs to is not decidable from the path
--     and is not decided here - that is the upload signer's job (constitution.md III.22). Recorded as
--     a residual gap rather than papered over.
--
-- A9. `country_code` is accepted by update_profile_v1 and validated as exactly two uppercase ASCII
--     letters. It is `char(2)`, and an assignment cast into `char(2)` TRUNCATES silently, so
--     'EGYPT' would become 'EG' with no error anywhere unless the length is checked here. It is not
--     derived from the phone number, which would need a country-prefix table that does not exist.
--
-- A10. A new error code is invented where contracts.md 5 has none that fits. The existing table was
--     read line by line for this. `INVALID_OPTIONS` is menu options and does not generalise;
--     `PHONE_IN_USE` is kept for a collision in `users` exactly as specified, and a SECOND code is
--     used for a collision in `riders` - see the long comment at the phone pre-check for why reusing
--     PHONE_IN_USE there would be wrong. Invented, all in the house NOUN_ADJECTIVE style:
--       PHONE_INVALID           bad E.164, or an attempt to null the phone
--       NAME_INVALID            empty, blank, over-long, or nulled name
--       PHONE_IN_USE_BY_RIDER   the number is held by a riders row that is not this user's
--       PROFILE_ALREADY_COMPLETE  complete_profile_v1 called on a completed profile with new values
--       INVALID_PATCH           unknown key, forbidden key, wrong JSON type, or out-of-range value
--     contracts.md 5 must be amended to carry these five. It is not amended here because this
--     migration was scoped to one file.
--
-- A11. `raise_app_error` is specced in contracts.md 5 but DOES NOT EXIST in the database - nothing in
--     001-015 creates it. It is not created here either: creating a fourth function in `public` widens
--     the PostgREST surface past the three functions contracts.md 1.3 assigns to this migration, and
--     the grant decision for it belongs to whichever migration establishes the error contract for
--     017-020 as a whole. Every raise below therefore inlines the exact format that helper would
--     produce - `CODE: arabic message` at errcode P0001 - so adopting the helper later is a
--     mechanical substitution with no behaviour change. Per contracts.md 5 the message carries
--     Arabic and the ENGLISH text comes from the client's typed error table keyed on the code, which
--     is why `raise_app_error` takes `p_message_ar` and nothing else.
--
-- BUG FOUND BY EXERCISING THIS FILE, AND IT IS THE REASON THE DO BLOCK AT THE BOTTOM IS NOT ENOUGH.
--
-- The first applied version of this migration appended to the `missing` array like this:
--
--     v_missing := v_missing || 'address';
--
-- That does not append an element. With a `text[]` on the left and an UNTYPED literal on the right,
-- PostgreSQL resolves `||` to `anyarray || anyarray` - array concatenation - and then tries to read
-- 'address' as an array literal:
--
--     ERROR:  22P02: malformed array literal: "address"
--     DETAIL:  Array value must start with "{" or dimension information.
--     CONTEXT:  PL/pgSQL function public.get_profile_status_v1() line 68 at assignment
--
-- `array_append(anyarray, anyelement)` is unambiguous, which is why it is used instead. A `::text`
-- cast on the literal would also have worked and would have been one character per site; the
-- function form was chosen because it cannot be reintroduced by a later edit that forgets the cast.
--
-- WHAT THIS MEANS FOR EVERYTHING ELSE IN THIS FILE. The migration applied cleanly and all ten
-- assertions passed, because every one of them is structural - prosecdef, search_path, volatility,
-- grants, constraint names - and the one behavioural assertion deliberately runs with auth.uid() null
-- and so returns before reaching the array. **A migration that applies without error is not evidence
-- that its functions work.** This was caught only by calling get_profile_status_v1 with a JWT claim
-- set and a real profile behind it, which is exactly what a pgTAP suite exists to do and what
-- data-model.md 15.2 has scheduled for 022. Ten call sites were affected - four in this function and
-- six in update_profile_v1's change set - and the practical effect was that every profile RPC raised
-- on its primary path: get_profile_status_v1 for any incomplete profile, and update_profile_v1 for
-- any patch that actually changed something.
--
-- THE SECOND BUG, IN THE SAME FUNCTION, AND IT WOULD HAVE BEEN WORSE BECAUSE IT IS SILENT.
--
-- get_profile_status_v1 ended with a bare `return;` after assigning its six OUT parameters. On
-- PostgreSQL 17.11 that emits ZERO rows, not one row of the OUT values. Measured, with three
-- minimal functions differing only in their exit:
--
--     returns table(a int, b text) ... a := 1; b := 'x'; return;        -> 0 rows
--     returns table(a int, b text) ... return query select 1, 'x';      -> 1 row
--     returns table(a int, b text) ... a := 1; b := 'x'; return next;   -> 1 row
--
-- So every caller got an empty result. Nothing errored. A completion screen that receives no rows
-- cannot tell "nothing is missing" from "the database did not answer", and the app's first launch
-- call is this one.
--
-- The documentation sentence that "RETURN ... allows the value of the OUT parameters to be set"
-- describes a function returning a COMPOSITE type. `RETURNS TABLE` is sugar for `SETOF` with OUT
-- parameters, and the bare form does not carry them across. `return next;` is the fix.
--
-- MEASURED, so that the obvious "fix" is not applied: the two mutators exit with
-- `return query select * from public.get_profile_status_v1();` and one of them follows that with a
-- bare `return;` to stop. That combination is CORRECT and yields exactly one row - the queued row
-- survives, and the bare RETURN is a harmless exit. Rewriting it to `return next;` would append a
-- second, all-NULL row. So the two idioms in this file are deliberately different and both are
-- commented where they appear.
-- =============================================================================================

-- ---------------------------------------------------------------------------------------------
-- LANE CHECK BASELINE, captured before anything below runs.
--
-- This migration creates three functions and nothing else. §15.2 assigns it exactly
-- `complete_profile_v1, get_profile_status_v1` - plus update_profile_v1, which contracts.md 1.3
-- requires - and a migration that quietly also repairs a table is a migration nobody can review.
--
-- An earlier draft of this file added `trg_users_updated_at` to `users`, on the grounds that 003
-- created the table before 006 introduced `public.set_updated_at()` and that both mutators below
-- write `users`. The reasoning was sound and the change was wrong, for two reasons. `users` is not
-- special: seventeen tables across 001-015 have an `updated_at` column and no trigger, so fixing one
-- of them here is one arbitrary seventeenth, in a migration assigned three functions, and it belongs
-- in a migration that handles all seventeen together. And a function whose correctness depends on
-- out-of-band DDL carries the same defect 014a was written about - a guarantee that is true only
-- while some other file stays untouched, with nothing failing if it stops being true.
--
-- So both mutators below assign `updated_at = now()` EXPLICITLY, in the same SET list as the data
-- they are changing. That makes the timestamp part of the function's own contract: readable in the
-- statement, covered by the exception block, and impossible to lose by dropping a trigger. If a
-- `set_updated_at` trigger is ever added to `users` by that future migration, it assigns the same
-- value to the same column and the two agree. `public.set_updated_at()` itself is untouched and
-- still used by every table that already has the trigger.
--
-- The two baseline counts below are what the closing assertions compare against, so that "this
-- migration created no trigger and no table" is checked rather than asserted in a comment. They are
-- session GUCs rather than plpgsql variables because a migration file is a sequence of independent
-- statements, not one function body - there is no variable that survives from here to the DO block.
-- ---------------------------------------------------------------------------------------------
select set_config('marketak.m016_triggers', count(*)::text, false)
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and not t.tgisinternal;

select set_config('marketak.m016_tables', count(*)::text, false)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind in ('r', 'p');

-- =============================================================================================
-- get_profile_status_v1 - called at app launch
-- =============================================================================================
-- The one function that reads nothing the caller could not read anyway, and the one whose return
-- shape the other two reuse. SECURITY DEFINER + a hand-written identity predicate: see the header.
create or replace function public.get_profile_status_v1()
returns table (
  profile_completed_at timestamptz,
  has_phone            boolean,
  has_address          boolean,
  can_browse           boolean,
  can_order            boolean,
  missing              text[]
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid        uuid := (select auth.uid());
  v_completed  timestamptz;
  v_first      text;
  v_last       text;
  v_phone      text;
  v_deleted    timestamptz;
  v_address    boolean;
  v_missing    text[] := '{}'::text[];
begin
  -- Wrapped in a scalar subquery per data-model.md 13.2, and assigned once rather than re-read.
  -- Migration 022 fails the build on a bare auth.uid(); the same rule is applied here so the two
  -- never drift.
  if v_uid is null then
    raise exception 'NOT_AUTHORIZED: %',
      'يجب تسجيل الدخول'
      using errcode = 'P0001';
  end if;

  -- The identity predicate, restated. Under 014's `users_read` policy this is implied by RLS; under
  -- SECURITY DEFINER it is not, and nothing downstream would catch its absence.
  select u.profile_completed_at, u.first_name, u.last_name, u.phone_number, u.deleted_at
    into v_completed, v_first, v_last, v_phone, v_deleted
    from public.users u
   where u.id = v_uid;

  -- Not found is reachable: 003's trigger creates the row on auth insert, but an admin can delete it
  -- and `users.id` cascades from auth.users. Answering with a fabricated incomplete profile would
  -- send the app to a completion screen that could never succeed.
  if not found then
    raise exception 'NOT_AUTHORIZED: %',
      'لا يوجد ملف مستخدم لهذا الحساب'
      using errcode = 'P0001';
  end if;

  if v_deleted is not null then
    raise exception 'NOT_AUTHORIZED: %',
      'هذا الحساب غير نشط'
      using errcode = 'P0001';
  end if;

  -- Also a restated predicate: `addresses_read` is own-row, and SECURITY DEFINER does not inherit it.
  -- Any non-deleted address counts. contracts.md 1.3 says `has_address` and nothing more, and does
  -- not require a DEFAULT address - an order can be placed against any address the user picks.
  select exists (
           select 1 from public.addresses a
            where a.user_id = v_uid
              and a.deleted_at is null
         )
    into v_address;

  -- Fixed order by explicit array_append, not array_agg: array_agg without ORDER BY has undefined
  -- order and this array drives the order fields appear on the completion screen. See A1, and the
  -- BUG note at the top of this file for why this is array_append rather than `||`.
  --
  -- A name that is present but blank counts as missing, which btrim alone would miss - a whitespace
  -- name is not a name, and complete_profile_v1 would reject it, so the screen must ask again.
  if v_phone is null or btrim(v_phone) = '' then
    v_missing := array_append(v_missing, 'phone_number');
  end if;
  if v_first is null or btrim(v_first) = '' then
    v_missing := array_append(v_missing, 'first_name');
  end if;
  if v_last is null or btrim(v_last) = '' then
    v_missing := array_append(v_missing, 'last_name');
  end if;
  if not v_address then
    v_missing := array_append(v_missing, 'address');
  end if;

  profile_completed_at := v_completed;
  has_phone            := v_phone is not null and btrim(v_phone) <> '';
  has_address          := v_address;
  -- See A4. Reaching this line means the caller is a live signed-in user; browsing is unconditional
  -- under constitution.md II.18. Deliberately not `is_active` - nothing defines that meaning, and a
  -- permission nothing enforces is worse than no permission.
  can_browse           := true;
  -- Derived, never stored (A3).
  can_order            := v_completed is not null;
  missing              := v_missing;
  -- RETURN NEXT, not a bare RETURN. Measured on PostgreSQL 17.11: a bare `return;` in a
  -- `returns table` function emits ZERO rows rather than the OUT parameter values, so this function
  -- silently answered every caller with an empty result. `return next;` emits them. The documentation
  -- sentence that "RETURN ... allows the value of the OUT parameters to be set" is about functions
  -- returning a composite type; `RETURNS TABLE` is `SETOF` with OUT parameters, and the bare form
  -- does not carry them over. See the BUG note at the top of this file.
  return next;
end $$;

grant  execute on function public.get_profile_status_v1() to authenticated;
revoke execute on function public.get_profile_status_v1() from public, anon;

-- =============================================================================================
-- complete_profile_v1 - the ONLY writer of profile_completed_at
-- =============================================================================================
-- IDEMPOTENCY, decided rather than defaulted (A7). The signature is fixed at three arguments by
-- contracts.md 1.3, so there is no idempotency_key to key on the way constitution.md I.5 does for
-- money. The gate itself is the only key available, so:
--
--   already completed, values identical  -> no UPDATE, no event, return current state
--   already completed, values differ     -> PROFILE_ALREADY_COMPLETE
--   not completed                        -> UPDATE + exactly one event
--
-- The first case is the retry. A mobile client on a flaky connection re-sends after a timeout, and a
-- function that raised there would show an error for a request that in fact succeeded - the classic
-- double-submit failure. It is also what keeps `user.profile_completed` written at most once per
-- user, which is asserted at the bottom.
--
-- The second case is deliberately NOT also a silent no-op. complete_profile_v1 is the completion
-- path, not the save path; if a client calls it as "save my profile" then a no-op leaves the user
-- believing a changed name was stored when it was not, and there is no symptom to debug from. It
-- fails loudly and points at update_profile_v1 instead. Silently discarding a genuine edit is the
-- worse of the two failures.
--
-- Consequence worth stating plainly: after completion, a name or phone change goes through
-- update_profile_v1. That is the contract's own division of labour - complete_profile_v1 is "the only
-- way to set profile_completed_at", update_profile_v1 is for everything else - and it is preserved
-- because update_profile_v1 rejects profile_completed_at outright.
create or replace function public.complete_profile_v1(
  p_first_name text,
  p_last_name  text,
  p_phone      text
)
returns table (
  profile_completed_at timestamptz,
  has_phone            boolean,
  has_address          boolean,
  can_browse           boolean,
  can_order            boolean,
  missing              text[]
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid           uuid := (select auth.uid());
  v_first         text;
  v_last          text;
  v_phone         text;
  v_stored_first  text;
  v_stored_last   text;
  v_stored_phone  text;
  v_completed     timestamptz;
  v_deleted       timestamptz;
  v_constraint    text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHORIZED: %', 'يجب تسجيل الدخول' using errcode = 'P0001';
  end if;

  -- Identity predicate restated; SECURITY DEFINER bypasses `users_read`. See the header.
  select u.first_name, u.last_name, u.phone_number, u.profile_completed_at, u.deleted_at
    into v_stored_first, v_stored_last, v_stored_phone, v_completed, v_deleted
    from public.users u
   where u.id = v_uid;

  if not found then
    raise exception 'NOT_AUTHORIZED: %',
      'لا يوجد ملف مستخدم لهذا الحساب'
      using errcode = 'P0001';
  end if;

  if v_deleted is not null then
    raise exception 'NOT_AUTHORIZED: %',
      'هذا الحساب غير نشط'
      using errcode = 'P0001';
  end if;

  -- ---- validation, before anything is written --------------------------------------------------
  -- Trim only (A5). No digit massaging: the stored value has to be the value that was validated,
  -- because the unique constraints and 014b's trigger all compare raw text.
  v_first := btrim(p_first_name);
  v_last  := btrim(p_last_name);
  v_phone := btrim(p_phone);

  if v_first is null or v_first = '' or char_length(v_first) > 80 then
    raise exception 'NAME_INVALID: %',
      'الاسم الأول مطلوب ويجب ان يكون بين 1 و 80 حرفا'
      using errcode = 'P0001';
  end if;

  if v_last is null or v_last = '' or char_length(v_last) > 80 then
    raise exception 'NAME_INVALID: %',
      'اسم العائلة مطلوب ويجب ان يكون بين 1 و 80 حرفا'
      using errcode = 'P0001';
  end if;

  if v_phone is null or v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'PHONE_INVALID: %',
      'رقم الهاتف غير صالح. مثال: +201xxxxxxxxx'
      using errcode = 'P0001';
  end if;

  -- Idempotency (A7). Compared AFTER trimming and validation, so a retry that differs only in
  -- surrounding whitespace is recognised as the retry it is.
  if v_completed is not null then
    if v_first is not distinct from v_stored_first
       and v_last  is not distinct from v_stored_last
       and v_phone is not distinct from v_stored_phone then
      return query select * from public.get_profile_status_v1();
      return;
    end if;

    raise exception 'PROFILE_ALREADY_COMPLETE: %',
      'الملف الشخصي مكتمل بالفعل. استخدم تعديل الملف الشخصي لتغيير البيانات'
      using errcode = 'P0001';
  end if;

  -- ---- phone uniqueness, in TWO tables --------------------------------------------------------
  -- `users` first: this is the collision contracts.md 5 documents as PHONE_IN_USE. The caller's own
  -- row is excluded, so re-sending an unchanged number is not a self-collision.
  if exists (
       select 1 from public.users u
        where u.phone_number = v_phone
          and u.id <> v_uid
      ) then
    raise exception 'PHONE_IN_USE: %',
      'هذا الرقم مستخدم في حساب آخر'
      using errcode = 'P0001';
  end if;

  -- `riders` second, and this is the 014b hazard the whole header is about.
  --
  -- `riders.phone_number` is `text not null unique` in its own right. `riders.user_id` is NULLABLE BY
  -- DESIGN - a rider can be onboarded by an admin before ever signing in (open question 3.13, option
  -- (a)) - so this collision has two shapes: another user's rider, and a rider who has no auth
  -- account at all. Both block the write, and `u.id <> v_uid` cannot express the second one because
  -- there is no u.
  --
  -- A rider row belonging to the CALLER is not a collision and must be excluded, not merely tolerated:
  -- 014b's trigger issues no UPDATE for that row when the number is already equal (its
  -- `is distinct from` guard), so a rider re-running their own completion must not be refused by a
  -- precondition that describes their own record.
  --
  -- WHY A SECOND ERROR CODE AND NOT PHONE_IN_USE. The two collisions mean different things and need
  -- different handling. PHONE_IN_USE is a customer account holding the number: the user picks another
  -- one and the inline field error is exactly right. This one is a number registered to a rider of the
  -- platform - possibly a rider who never signed in, possibly a colleague, possibly the user themself
  -- with a stale second number on file - and the user cannot influence it by trying a different
  -- number, because retrying is exactly what sends them in a loop. contracts.md 5's stated behaviour
  -- for PHONE_IN_USE is "inline message on the phone field", which would be a dead end here. A
  -- distinct code lets the app route this to support instead of to the field.
  if exists (
       select 1 from public.riders r
        where r.phone_number = v_phone
          and (r.user_id is null or r.user_id <> v_uid)
      ) then
    raise exception 'PHONE_IN_USE_BY_RIDER: %',
      'هذا الرقم مسجل لسائق في المنصة. يرجى اختيار رقم آخر أو التواصل مع الدعم'
      using errcode = 'P0001';
  end if;

  -- ---- the write, and the event, in one transaction -------------------------------------------
  -- Both statements sit inside the exception block on purpose. A plpgsql block with an EXCEPTION
  -- handler runs as a subtransaction, so catching an error here UNDOES the UPDATE as well as the
  -- trigger's failure - the users row cannot survive a failed write. Re-raising then aborts the
  -- whole function, so the event can never be committed next to a write that did not happen
  -- (constitution.md II.16).
  --
  -- The handler is the race backstop for the two checks above. Those are check-then-act: a
  -- concurrent transaction can commit a colliding rider between the check and the UPDATE. The
  -- constraint name is what tells the two collisions apart, since both arrive as SQLSTATE 23505.
  begin
    -- `updated_at` assigned HERE, explicitly, not left to a trigger. See the lane-check note above:
    -- there is no trigger on `users`, and a correctness property that depends on out-of-band DDL is
    -- not a property this function has.
    update public.users u
       set first_name          = v_first,
           last_name           = v_last,
           phone_number        = v_phone,
           profile_completed_at = now(),
           updated_at           = now()
     where u.id = v_uid
       and u.deleted_at is null;

    -- Payload is ids only. contracts.md 3: "Ids and minimum data. Never secrets, never PII beyond
    -- ids" - so no name and no phone number, which is the obvious thing to add here and the one
    -- thing that must not be. No consumer is registered for this type in contracts.md 3.1, which is
    -- the same position `voucher.created` and `vendor.earnings_rolled` are in ("None in v1"); the
    -- auth_daily_stats aggregate is the obvious future reader and it reads from `events` like every
    -- other consumer.
    insert into public.events (type, aggregate_type, aggregate_id, payload)
    values ('user.profile_completed', 'user', v_uid,
            jsonb_build_object('user_id', v_uid));
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'riders_phone_number_key' then
        raise exception 'PHONE_IN_USE_BY_RIDER: %',
          'هذا الرقم مسجل لسائق في المنصة. يرجى اختيار رقم آخر أو التواصل مع الدعم'
          using errcode = 'P0001';
      end if;
      raise exception 'PHONE_IN_USE: %',
        'هذا الرقم مستخدم في حساب آخر'
        using errcode = 'P0001';
  end;

  -- One shape for all three RPCs (A2). Reusing the function rather than repeating the derivation is
  -- the point: `missing` in particular is built in one place and cannot disagree with itself.
  return query select * from public.get_profile_status_v1();
end $$;

grant  execute on function public.complete_profile_v1(text, text, text) to authenticated;
revoke execute on function public.complete_profile_v1(text, text, text) from public, anon;

-- =============================================================================================
-- update_profile_v1 - edit a profile, never the gate
-- =============================================================================================
-- Accepted keys, a CLOSED set of six:
--
--   first_name         text    1-80 chars after trim
--   last_name          text    1-80 chars after trim
--   phone_number       text    E.164, never null
--   avatar_path        text    1-512 chars, path-shaped (A8)
--   preferred_language text    'ar' or 'en'
--   country_code       text    exactly two uppercase ASCII letters (A9)
--
-- Rejected keys, each with its own reason, and each named back to the client in the message:
--
--   profile_completed_at  the gate. constitution.md II.18 and contracts.md 1.3 make
--                         complete_profile_v1 the only writer of it, and this function is the reason
--                         that is true rather than merely stated.
--   id                    the primary key, and it IS auth.uid(). A patch that could set it would be a
--                         patch that could address another account.
--   is_active, deleted_at operator lifecycle fields. Soft delete and deactivation are admin actions
--                         (constitution.md II.17); a self-service RPC that could set them is a user
--                         un-deleting themself.
--   created_at, updated_at  not the caller's to set. `updated_at` is assigned by the UPDATE below on
--                         every write, so accepting it in the patch would let a caller backdate the
--                         only record of when the profile last changed.
--   last_seen_at          written by the app and the Worker, not by a profile edit.
--   email                 carried from the OAuth provider and "not a credential" (003's own comment).
--                         Letting a client rewrite it creates an account-recovery path nobody designed.
--
-- Unknown keys are rejected too, and are a DIFFERENT error from a forbidden key: "you may not set
-- this" and "this does not exist" are different client bugs and a single silent union of the two
-- would hide a typo behind a permissions message.
create or replace function public.update_profile_v1(p_patch jsonb)
returns table (
  profile_completed_at timestamptz,
  has_phone            boolean,
  has_address          boolean,
  can_browse           boolean,
  can_order            boolean,
  missing              text[]
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_deleted   timestamptz;
  v_key       text;
  v_first     text;
  v_last      text;
  v_phone     text;
  v_avatar    text;
  v_language  text;
  v_country   text;
  v_changed   text[] := '{}'::text[];
  v_constraint text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHORIZED: %', 'يجب تسجيل الدخول' using errcode = 'P0001';
  end if;

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'INVALID_PATCH: %',
      'التعديل يجب ان يكون كائن JSON'
      using errcode = 'P0001';
  end if;

  -- Forbidden keys first, each named. Rejected, never ignored: a silently dropped
  -- `profile_completed_at` would let a client believe it had opened the gate to ordering.
  --
  -- Written as a scalar subquery rather than `select ... into` so that each statement returns
  -- exactly one row and v_key is deterministically NULL when nothing matches. The outcome was the
  -- same either way, but this form does not rest on PL/pgSQL's zero-row assignment rule, and
  -- `order by` makes WHICH key is named in the message deterministic rather than arbitrary.
  select (
           select k.k
             from jsonb_object_keys(p_patch) as k(k)
            where k.k = any (array[
                    'profile_completed_at', 'id', 'is_active', 'deleted_at',
                    'created_at', 'updated_at', 'last_seen_at', 'email'
                  ])
            order by k.k
            limit 1
         ) into v_key;

  if v_key is not null then
    raise exception 'INVALID_PATCH: %',
      'الحقل ' || v_key || ' لا يمكن تعديله من هنا'
      using errcode = 'P0001';
  end if;

  select (
           select k.k
             from jsonb_object_keys(p_patch) as k(k)
            where k.k <> all (array[
                    'first_name', 'last_name', 'phone_number',
                    'avatar_path', 'preferred_language', 'country_code'
                  ])
            order by k.k
            limit 1
         ) into v_key;

  if v_key is not null then
    raise exception 'INVALID_PATCH: %',
      'حقل غير معروف: ' || v_key
      using errcode = 'P0001';
  end if;

  -- Identity predicate restated; SECURITY DEFINER bypasses `users_read`. Existence and liveness are
  -- the two reasons this function can raise NOT_AUTHORIZED for a caller that is otherwise entitled.
  select u.deleted_at into v_deleted
    from public.users u
   where u.id = v_uid;

  if not found then
    raise exception 'NOT_AUTHORIZED: %',
      'لا يوجد ملف مستخدم لهذا الحساب'
      using errcode = 'P0001';
  end if;

  if v_deleted is not null then
    raise exception 'NOT_AUTHORIZED: %',
      'هذا الحساب غير نشط'
      using errcode = 'P0001';
  end if;

  -- ---- per-key validation, and the change set at the same time ---------------------------------
  -- Each branch both validates the incoming value and records whether it DIFFERS from what is
  -- stored. The stored value is read per key rather than in one SELECT because a patch touches a
  -- subset of the columns, and this way only the keys actually present are read.
  --
  -- Building v_changed rather than trusting the UPDATE's row count is deliberate: PostgreSQL counts
  -- a row as affected when it MATCHED, not when it changed, so `get diagnostics ... row_count = 0`
  -- never fires for a no-op rewrite and cannot be used to suppress a duplicate event on a retry.
  -- Built with array_append for the reason in the BUG note at the top of this file.
  if p_patch ? 'first_name' then
    v_first := btrim(p_patch ->> 'first_name');
    if v_first is null or v_first = '' or char_length(v_first) > 80 then
      raise exception 'NAME_INVALID: %',
        'الاسم الأول مطلوب ويجب ان يكون بين 1 و 80 حرفا'
        using errcode = 'P0001';
    end if;
    if v_first is distinct from (select u.first_name from public.users u where u.id = v_uid) then
      v_changed := array_append(v_changed, 'first_name');
    end if;
  end if;

  if p_patch ? 'last_name' then
    v_last := btrim(p_patch ->> 'last_name');
    if v_last is null or v_last = '' or char_length(v_last) > 80 then
      raise exception 'NAME_INVALID: %',
        'اسم العائلة مطلوب ويجب ان يكون بين 1 و 80 حرفا'
        using errcode = 'P0001';
    end if;
    if v_last is distinct from (select u.last_name from public.users u where u.id = v_uid) then
      v_changed := array_append(v_changed, 'last_name');
    end if;
  end if;

  if p_patch ? 'phone_number' then
    -- Null is refused, not treated as "clear it". `profile_phone_required` makes a completed
    -- profile without a phone impossible anyway, and letting the request through would surface as a
    -- raw CHECK violation instead of a code the app knows.
    v_phone := btrim(p_patch ->> 'phone_number');
    if v_phone is null or v_phone !~ '^\+[1-9][0-9]{7,14}$' then
      raise exception 'PHONE_INVALID: %',
        'رقم الهاتف غير صالح. مثال: +201xxxxxxxxx'
        using errcode = 'P0001';
    end if;

    -- Same two checks, same two codes, same order as complete_profile_v1. Not a copy for
    -- convenience: this branch writes the identical column and therefore fires the identical 014b
    -- trigger, so skipping either check here would reintroduce exactly the raw unique_violation the
    -- other function exists to prevent.
    if exists (
         select 1 from public.users u
          where u.phone_number = v_phone
            and u.id <> v_uid
        ) then
      raise exception 'PHONE_IN_USE: %',
        'هذا الرقم مستخدم في حساب آخر'
        using errcode = 'P0001';
    end if;

    if exists (
         select 1 from public.riders r
          where r.phone_number = v_phone
            and (r.user_id is null or r.user_id <> v_uid)
        ) then
      raise exception 'PHONE_IN_USE_BY_RIDER: %',
        'هذا الرقم مسجل لسائق في المنصة. يرجى اختيار رقم آخر أو التواصل مع الدعم'
        using errcode = 'P0001';
    end if;

    if v_phone is distinct from (select u.phone_number from public.users u where u.id = v_uid) then
      v_changed := array_append(v_changed, 'phone_number');
    end if;
  end if;

  if p_patch ? 'avatar_path' then
    v_avatar := btrim(p_patch ->> 'avatar_path');
    -- Path-shaped, not string-shaped (A8). `^[A-Za-z][A-Za-z0-9+.-]*://` catches every URI scheme,
    -- so a client cannot hand the app an http URL where an R2 key belongs (constitution.md III.22).
    -- chr(92) rather than a backslash literal, because a hand-typed escape is exactly the class of
    -- thing 015's header warns about.
    if v_avatar is null or v_avatar = ''
       or char_length(v_avatar) > 512
       or v_avatar ~ '^[A-Za-z][A-Za-z0-9+.-]*://'
       or position('..' in v_avatar) > 0
       or position(chr(92) in v_avatar) > 0 then
      raise exception 'INVALID_PATCH: %',
        'مسار الصورة غير صالح. يجب ان يكون مسارا في التخزين وليس رابطا'
        using errcode = 'P0001';
    end if;
    if v_avatar is distinct from (select u.avatar_path from public.users u where u.id = v_uid) then
      v_changed := array_append(v_changed, 'avatar_path');
    end if;
  end if;

  if p_patch ? 'preferred_language' then
    v_language := btrim(p_patch ->> 'preferred_language');
    -- Checked here rather than left to the column's CHECK, because a CHECK violation raises a raw
    -- Postgres message and contracts.md 5 says never surface one.
    if v_language is null or v_language <> all (array['ar', 'en']) then
      raise exception 'INVALID_PATCH: %',
        'اللغة يجب ان تكون ar او en'
        using errcode = 'P0001';
    end if;
    if v_language is distinct from (select u.preferred_language from public.users u where u.id = v_uid) then
      v_changed := array_append(v_changed, 'preferred_language');
    end if;
  end if;

  if p_patch ? 'country_code' then
    -- Length checked explicitly because `char(2)` truncates on assignment without raising (A9).
    v_country := upper(btrim(p_patch ->> 'country_code'));
    if v_country is null or v_country !~ '^[A-Z]{2}$' then
      raise exception 'INVALID_PATCH: %',
        'رمز الدولة يجب ان يكون حرفين'
        using errcode = 'P0001';
    end if;
    if v_country is distinct from rtrim((select u.country_code from public.users u where u.id = v_uid)) then
      v_changed := array_append(v_changed, 'country_code');
    end if;
  end if;

  -- ---- the write, and the event ---------------------------------------------------------------
  -- An empty patch, or one whose values all match what is stored, writes nothing and emits nothing.
  -- Same reasoning as complete_profile_v1's idempotent branch: a retry after a timeout must not
  -- produce a second outbox row.
  if cardinality(v_changed) > 0 then
    begin
      -- Explicit column list, no dynamic SQL. The accepted key set is closed and six wide, so a
      -- format()-built SET clause would be more machinery than the problem has.
      --
      -- The WHERE re-states `id = (select auth.uid())`. Under SECURITY DEFINER it is the only thing
      -- standing between this statement and every row in `users`, and it is the predicate 014's
      -- `users_read` would otherwise have applied.
      update public.users u
         set first_name          = case when p_patch ? 'first_name'         then v_first    else u.first_name end,
             last_name           = case when p_patch ? 'last_name'          then v_last     else u.last_name end,
             phone_number        = case when p_patch ? 'phone_number'       then v_phone    else u.phone_number end,
             avatar_path         = case when p_patch ? 'avatar_path'        then v_avatar   else u.avatar_path end,
             preferred_language = case when p_patch ? 'preferred_language' then v_language else u.preferred_language end,
             country_code        = case when p_patch ? 'country_code'       then v_country  else u.country_code end,
             -- Not conditional on the patch and not left to a trigger. `users` has no
             -- set_updated_at trigger, so this line IS what makes updated_at true; see the lane-check
             -- note at the top of this file.
             updated_at           = now()
       where u.id = v_uid
         and u.deleted_at is null;

      -- The list of changed FIELDS, never their values: the values include the phone number, and
      -- contracts.md 3 forbids PII beyond ids in a payload.
      insert into public.events (type, aggregate_type, aggregate_id, payload)
      values ('user.profile_updated', 'user', v_uid,
              jsonb_build_object('user_id', v_uid, 'fields', to_jsonb(v_changed)));

    -- Same backstop as complete_profile_v1, and it is needed here for a reason that is easy to
    -- miss: 014b's trigger is `after update of first_name, last_name, phone_number, country_code`,
    -- so it fires for THIS statement even when the patch carried no phone key at all. A name-only
    -- edit on a linked rider whose riders.phone_number has drifted from users.phone_number will make
    -- the trigger push that number across, and can hit riders_phone_number_key - so a name edit can
    -- fail on a phone collision. That is 014b's designed behaviour and not something this function
    -- introduces; what this handler changes is that the client is told so in a code it can act on
    -- instead of receiving a 23505 that names a table it cannot read.
    exception
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint = 'riders_phone_number_key' then
          raise exception 'PHONE_IN_USE_BY_RIDER: %',
            'هذا الرقم مسجل لسائق في المنصة. يرجى اختيار رقم آخر أو التواصل مع الدعم'
            using errcode = 'P0001';
        end if;
        raise exception 'PHONE_IN_USE: %',
          'هذا الرقم مستخدم في حساب آخر'
          using errcode = 'P0001';
    end;
  end if;

  return query select * from public.get_profile_status_v1();
end $$;

grant  execute on function public.update_profile_v1(jsonb) to authenticated;
revoke execute on function public.update_profile_v1(jsonb) from public, anon;

-- =============================================================================================
-- fail closed
-- =============================================================================================
-- The migration asserts its own invariants rather than trusting them, for the reason 014's closing
-- comment gives: a policy or grant set that silently omits something is the exact failure mode the
-- controls exist to prevent.
--
-- What is NOT asserted here, deliberately: the E.164 regex and the length bounds. 015 refused exactly
-- this on purpose - "a guard that duplicates the thing it guards is a second source of truth, not a
-- check". Re-typing the pattern into this block would create a second copy that can drift from the
-- one in the function body, which is the failure 015's own assertion caught itself making. Behaviour
-- belongs in 022's pgTAP, which can call these functions with real input. These assertions are
-- structural: they are the properties that must hold for the error mapping and the privilege model to
-- work at all.
do $$
declare
  v_bad      text;
  v_err      text;
begin
  -- 1. All three exist, are SECURITY DEFINER, and pin search_path to ''. A definer function with a
  --    live search_path can be redirected by a shadowing object in public, which is the whole reason
  --    003 pins it on handle_new_user.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
   where p.oid in (
       'public.get_profile_status_v1()'::regprocedure,
       'public.complete_profile_v1(text,text,text)'::regprocedure,
       'public.update_profile_v1(jsonb)'::regprocedure
     )
     and (not p.prosecdef
          or not (coalesce(p.proconfig, '{}'::text[]) @> array['search_path=""']));

  if v_bad is not null then
    raise exception 'FAIL CLOSED: not security definer or search_path not pinned: %', v_bad;
  end if;

  -- 2. Volatility. A mutator mislabelled STABLE can be folded into a query and skipped; a reader
  --    mislabelled VOLATILE is merely slower. Both are silent, so both are asserted. pg_proc encodes
  --    these as 'v' volatile / 's' stable / 'i' immutable, so each is compared to its OWN value -
  --    an earlier draft compared all three against 'v' and would have failed on the correct, stable
  --    reader.
  if (select provolatile from pg_proc
       where oid = 'public.get_profile_status_v1()'::regprocedure) <> 's' then
    raise exception 'FAIL CLOSED: get_profile_status_v1 is not STABLE';
  end if;

  if (select provolatile from pg_proc
       where oid = 'public.complete_profile_v1(text,text,text)'::regprocedure) <> 'v' then
    raise exception 'FAIL CLOSED: complete_profile_v1 is not VOLATILE';
  end if;

  if (select provolatile from pg_proc
       where oid = 'public.update_profile_v1(jsonb)'::regprocedure) <> 'v' then
    raise exception 'FAIL CLOSED: update_profile_v1 is not VOLATILE';
  end if;

  -- 3. Grants. authenticated executes all three; anon and PUBLIC execute none.
  select string_agg(r.proname, ', ') into v_bad
    from pg_proc r
   where r.oid in (
       'public.get_profile_status_v1()'::regprocedure,
       'public.complete_profile_v1(text,text,text)'::regprocedure,
       'public.update_profile_v1(jsonb)'::regprocedure
     )
     and not has_function_privilege('authenticated', r.oid, 'execute');

  if v_bad is not null then
    raise exception 'FAIL CLOSED: authenticated cannot execute: %', v_bad;
  end if;

  -- The anon check, and it subsumes PUBLIC on its own: privilege lookup includes grants made to
  -- PUBLIC, so if PUBLIC held EXECUTE then anon would hold it too and this would already have
  -- failed. Checked separately anyway, because 'public' is not a role in pg_roles and passing it to
  -- has_function_privilege would error rather than answer.
  select string_agg(r.proname, ', ') into v_bad
    from pg_proc r
   where r.oid in (
       'public.get_profile_status_v1()'::regprocedure,
       'public.complete_profile_v1(text,text,text)'::regprocedure,
       'public.update_profile_v1(jsonb)'::regprocedure
     )
     and has_function_privilege('anon', r.oid, 'execute');

  if v_bad is not null then
    raise exception 'FAIL CLOSED: anon can execute: %', v_bad;
  end if;

  -- PUBLIC named precisely, because that is the role the `revoke ... from public` line targets and
  -- the one 005d's default privileges govern. grantee = 0 is the PUBLIC pseudo-role; a NULL proacl
  -- yields no rows, which is the correct reading of "never granted".
  if exists (
       select 1
         from pg_proc r,
              lateral aclexplode(r.proacl) ax
        where r.oid in (
                'public.get_profile_status_v1()'::regprocedure,
                'public.complete_profile_v1(text,text,text)'::regprocedure,
                'public.update_profile_v1(jsonb)'::regprocedure
              )
          and ax.grantee = 0
          and ax.privilege_type = 'EXECUTE'
      ) then
    raise exception 'FAIL CLOSED: PUBLIC holds EXECUTE on a profile RPC';
  end if;

  -- 4. The two unique constraints the error mapping names. This is the assertion that matters most.
  --    Both collisions arrive as SQLSTATE 23505 and are told apart ONLY by constraint name; if either
  --    is dropped or renamed, `get stacked diagnostics` silently stops populating the name and every
  --    collision quietly degrades to the default branch - PHONE_IN_USE instead of
  --    PHONE_IN_USE_BY_RIDER - which is a wrong answer rather than a failure.
  --
  --    Driven from a VALUES list of expected names with a `not exists` per row rather than by
  --    aggregating what is present and comparing to a literal string: string_agg has no defined
  --    order, so a comparison against a fixed string would fail on correct code roughly half the
  --    time depending on scan order.
  if exists (
       select 1
         from (values ('users_phone_number_key'), ('riders_phone_number_key')) as want(conname)
        where not exists (
                select 1
                  from pg_constraint c
                 where c.conname = want.conname
                   and c.conrelid in ('public.users'::regclass, 'public.riders'::regclass)
                   and c.contype = 'u'
              )
      ) then
    raise exception
      'FAIL CLOSED: users_phone_number_key or riders_phone_number_key missing or renamed, the error mapping would silently degrade';
  end if;

  -- 5. The 014b trigger the whole collision story depends on. Without it, the pre-checks become
  --    stricter than necessary and the exception handler is dead code - both harmless, but both
  --    symptoms of 014b having been reverted, which is worth knowing rather than discovering.
  if not exists (
       select 1 from pg_trigger
        where tgrelid = 'public.users'::regclass
          and tgname = 'trg_user_contact_to_rider'
          and not tgisinternal
      ) then
    raise exception 'FAIL CLOSED: trg_user_contact_to_rider is missing, 014b has been reverted';
  end if;

  -- 6. No stored copy of the gate (A3). A `can_order` column would be a second source of truth for a
  --    permission, and constitution.md II.15/16 exist because those are what actually break.
  if exists (
       select 1 from pg_attribute
        where attrelid = 'public.users'::regclass
          and attname in ('can_order', 'can_browse', 'is_profile_complete')
          and not attisdropped
      ) then
    raise exception 'FAIL CLOSED: users has a stored permission column, the gate must stay derived';
  end if;

  -- 7. RLS and the client grant posture are unchanged by this migration. Re-asserted because 014a
  --    established the precedent, and because a migration that adds three SECURITY DEFINER functions
  --    is exactly where a stray table grant would slip in unnoticed.
  select string_agg(c.relname, ', ') into v_bad
    from pg_class c
   where c.oid in ('public.users'::regclass, 'public.addresses'::regclass, 'public.events'::regclass)
     and not c.relrowsecurity;

  if v_bad is not null then
    raise exception 'FAIL CLOSED: RLS disabled on %', v_bad;
  end if;

  if exists (
       select 1 from information_schema.role_table_grants
        where grantee in ('anon', 'authenticated')
          and table_schema = 'public'
          and privilege_type <> 'SELECT'
      ) then
    raise exception 'FAIL CLOSED: a non-SELECT client grant exists';
  end if;

  -- 8. Behavioural, and the only assertion here that runs the code rather than describing it.
  --    A migration session carries no JWT, so auth.uid() is null and the auth gate must fire. This
  --    duplicates no logic - it calls the function and inspects the error - so it cannot drift from
  --    the body the way a re-typed regex would.
  --
  --    Premise: the migration runner connects directly with no request.jwt.* GUC set. If it ever
  --    connected with a claim set, this assertion would fail on correct code, which is why the
  --    premise is written down rather than assumed.
  begin
    perform * from public.get_profile_status_v1();
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err is null then
    raise exception 'FAIL CLOSED: get_profile_status_v1 answered an anonymous caller';
  end if;

  if position('NOT_AUTHORIZED' in v_err) = 0 then
    raise exception 'FAIL CLOSED: anonymous caller got the wrong error: %', v_err;
  end if;

  -- 9. Lane check: this migration created no trigger. Compared against the count captured at the top
  --    of this file rather than against a hard-coded number, because 014b legitimately added one and
  --    a future migration may add more - the guarantee is that THIS file added none, not that the
  --    total is any particular value.
  if (select count(*)
        from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and not t.tgisinternal)
     <> current_setting('marketak.m016_triggers')::integer then
    raise exception
      'FAIL CLOSED: 016 created a trigger; it is assigned three functions and nothing else';
  end if;

  -- 10. Lane check: no table either. Same reasoning - a profile RPC migration that also creates a
  --     table cannot be reviewed against its stated contents.
  if (select count(*)
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind in ('r', 'p'))
     <> current_setting('marketak.m016_tables')::integer then
    raise exception
      'FAIL CLOSED: 016 created a table; it is assigned three functions and nothing else';
  end if;
end $$;