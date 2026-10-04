-- 011t_notification_type_lookup.sql
-- The validation half of open question 3.12, resolved as option (a').
--
-- 3.12's original options were: hardcode the 19 catalogue keys into a CHECK, or validate at the RPC.
-- Validating at the RPC is better here, and the reason is maintenance cost rather than principle: a
-- CHECK freezes 19 keys into the schema, so the 20th notification type costs a migration and turns a
-- copy change into a deployment. Checking against notification_templates keeps the catalogue in the
-- database, where the templates already live, so adding a key is an INSERT - which is what 011s just
-- demonstrated by adding all 19.
--
-- This is the lookup that RPCs call. It is in private, so PostgREST cannot reach it, and it is the
-- only thing standing between a typo and a blank notification.
--
-- Deliberately NOT a foreign key. notification_templates is unique per (key, channel, lang), so there
-- is no single row to reference from notifications.type. Restructuring the templates so a push-only
-- table is unique per (key, lang) would make an FK possible; that is 3.12 option (c) and it is more
-- schema than the problem is worth while the catalogue is this stable.
--
-- is_active is honoured, so deactivating a template for one language stops that notification being
-- treated as valid rather than rendering in a language nobody wants. That is the behaviour an admin
-- would expect from the flag that already exists on the row.

create or replace function private.notification_type_exists(p_type text)
returns boolean language sql stable set search_path = '' as $$
  select exists (
    select 1 from public.notification_templates
    where key = p_type and is_active
  );
$$;

revoke execute on function private.notification_type_exists(text) from public, anon, authenticated;