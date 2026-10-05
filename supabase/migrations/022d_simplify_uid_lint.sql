-- 022d: replace the bare-auth.uid() lint with a form that actually works.
--
-- 022c fixed the intent but not the behaviour: the suite still reports the same 34
-- policies. The stripping regex
--
--   \([^()]*\bselect\b[^()]*auth\.uid\(\)[^()]*\)
--
-- never matched, for a reason that should have been checked before shipping it
-- rather than after: the policies nest the call, so the paren the engine anchors
-- on and the paren that closes the subselect are not the ones that belong together
-- — `((owner_id IN ( SELECT private.account_ids_for(( SELECT auth.uid() AS uid))`
-- has four opens before the call and the nearest matching pair is ambiguous to a
-- pattern with no nesting awareness. Two attempts at a clever pattern; the honest
-- conclusion is that this problem does not need one.
--
-- What the check actually has to decide is one thing: is `auth.uid()` preceded by
-- `select`? If yes it is the mandated scalar subquery. If no it is the bare STABLE
-- call that data-model.md 13.2 forbids, because STABLE is evaluated once per
-- statement and would compare one user's id against every row. The alias, the
-- spacing and the nesting are all irrelevant to that question, so none of them
-- should be in the pattern.
--
--   ( SELECT auth.uid() AS uid)   -> preceded by select -> passes
--   (select auth.uid())          -> preceded by select -> passes
--   user_id = auth.uid()         -> not preceded     -> FAILS, correctly
--
-- This is the third attempt and the first that is short enough to be obviously
-- correct by inspection, which is the property the previous two lacked.

create or replace function tests.bare_auth_uid_offenders()
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(format('%s.%s', tablename, policyname), ', ' order by tablename, policyname), '')
    from (
      select p.tablename, p.policyname,
             regexp_replace(coalesce(p.qual, ''), '\s+', ' ', 'g') as q,
             regexp_replace(coalesce(p.with_check, ''), '\s+', ' ', 'g') as wc
        from pg_policies p
       where p.schemaname = 'public'
    ) s
   -- present at all, but never immediately after a `select`
   where (q ~* 'auth\.uid\(\)' and q !~* 'select\s+auth\.uid\(\)')
      or (wc ~* 'auth\.uid\(\)' and wc !~* 'select\s+auth\.uid\(\)');
$$;