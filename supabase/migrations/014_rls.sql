-- =============================================================================================
-- 014_rls.sql
-- =============================================================================================
-- Row-level security. This is the migration that makes the database safe to expose to clients, and
-- until it lands the database is closed: 001-013 revoked every client grant, so nothing in public is
-- reachable. Everything here widens access, deliberately and table by table.
--
-- Architecture (open question, resolved): RLS plus table-level SELECT for `authenticated`, with every
-- mutation going through a security-definer RPC. data-model.md 13.3 says "anon gets no direct table
-- access at all - every read goes through an RPC" while the grant table two paragraphs below gives
-- authenticated "SELECT on read tables". The two contradict. RLS plus SELECT is chosen because 13.1
-- expresses visibility as ROW rules ("Own", "Own vendor's sub-orders", "Assigned only"), 13.2 is
-- entirely about policy query performance, and only this option leaves Realtime usable for order
-- status. Mutations are never granted: no INSERT, UPDATE or DELETE to any client role on any table.
--
-- THREE THINGS IN THE SPEC ARE WRONG AND ARE CORRECTED HERE. Each was verified on this database
-- before being acted on, not inferred from the documentation.
-- =============================================================================================

-- ---------------------------------------------------------------------------------------------
-- FINDING 1 - 13.2's helper-function pattern does not work as written.
-- ---------------------------------------------------------------------------------------------
-- 13.2 says:
--     revoke execute on function private.vendor_ids_for(uuid) from public, anon, authenticated;
--     create policy sub_orders_vendor_read on sub_orders for select
--       using (vendor_id in (select private.vendor_ids_for((select auth.uid()))));
-- That fails at runtime with `permission denied for function f`. An RLS policy expression is
-- evaluated as the role running the query, so the calling role must hold EXECUTE.
--
-- Tested on this database:
--     REVOKE EXECUTE FROM authenticated, policy calls the function   -> permission denied
--     GRANT  EXECUTE TO authenticated, no USAGE on the schema        -> policy works
--     direct call to authenticated                                  -> permission denied for schema
--
-- The real control is not the EXECUTE revocation, it is that `private` has no schema USAGE for any
-- client role - verified false for anon, authenticated AND service_role. A role with EXECUTE but no
-- USAGE cannot name the function, cannot call it through a wrapper, and cannot call it through
-- PostgREST. So: EXECUTE is granted to authenticated because policies require it, and the schema
-- stays shut. That is strictly stronger than 13.2 describes, and it is why 13.2's line is corrected.
--
-- ---------------------------------------------------------------------------------------------
-- FINDING 2 - RLS does NOT propagate to partitions. This is a live data-leak path.
-- ---------------------------------------------------------------------------------------------
-- `notifications` and `audit_log` are monthly-partitioned by 010 and 012. Enabling RLS and adding a
-- deny-all policy to the PARENT leaves every partition with relrowsecurity = false and zero policies.
-- Verified on this database with a throwaway partitioned table. The partitions live in `public`,
-- which `authenticated` holds USAGE on, so `select * from notifications_2026_10` bypasses the
-- parent's policy entirely. Today the blanket zero-grant posture hides this, but 13.3's own
-- `alter default privileges ... revoke all on tables` line would expose every partition the moment
-- anyone added a single grant.
--
-- So RLS is enabled on every partition, the parent policies are mirrored onto each partition, and
-- private.ensure_month_partition is replaced at the end of this migration so future partitions are
-- covered automatically rather than by remembering.
--
-- ---------------------------------------------------------------------------------------------
-- FINDING 3 - 13.1's "riders: Public fields only" is not expressible, and the product needs more.
-- ---------------------------------------------------------------------------------------------
-- RLS filters rows, never columns, so "public fields only" cannot be a policy. `riders` holds
-- phone_number, current_latitude, current_longitude, vehicle_plate, cash_held and max_cash_held.
--
-- The required behaviour, as specified: a CUSTOMER sees each rider's name, vehicle, rating and
-- PHONE NUMBER - the customer has to be able to call the rider, which is the whole point of paying
-- cash at the door. A RIDER sees the customer's name, phone number and location, but ONLY for an
-- order they have accepted.
--
-- Shape chosen: `riders` itself gets NO grant to any client role, and public.riders_public exposes
-- exactly the rider-identifying columns. `current_latitude`, `current_longitude`, `cash_held` and
-- `max_cash_held` are therefore unreachable rather than merely hidden, and `user_id` never leaves
-- the database - which matters because user_id is the key that 010a's cash-limit leak walked.
-- Rider-to-customer visibility rides on orders, so it is gated by delivery_assignments in the order
-- policies below and needs no special case here.
-- =============================================================================================

-- =============================================================================================
-- private helpers
-- =============================================================================================
-- All security definer, stable, search_path pinned to ''. Security definer is not a privilege
-- choice here, it is a correctness requirement: private.visible_order_ids reads `orders`, and a
-- security invoker version would re-enter the orders policy from inside the orders policy.
--
-- EXECUTE goes to authenticated because the policies need it (Finding 1). No USAGE on the schema,
-- so none of this is reachable by a client.

-- The vendor ids a user staffs. deleted_at is filtered here rather than in each policy so that a
-- de-staffed member loses access everywhere at once - the alternative is a policy that forgets.
create or replace function private.vendor_ids_for(p_user uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select vs.vendor_id from public.vendor_staff vs
  where vs.user_id = p_user and vs.deleted_at is null;
$$;

-- The rider ids a user holds. riders has no deleted_at; is_active governs.
create or replace function private.rider_ids_for(p_user uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select r.id from public.riders r where r.user_id = p_user;
$$;

-- Wallet and ledger account ids owned by this user, on either side. wallets.owner_type carries the
-- discriminator ('vendor'|'rider'), so a vendor id and a rider id can never collide by accident.
create or replace function private.account_ids_for(p_user uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select w.owner_id from public.wallets w
  where (w.owner_type = 'vendor' and w.owner_id in (select private.vendor_ids_for(p_user)))
     or (w.owner_type = 'rider'  and w.owner_id in (select private.rider_ids_for(p_user)));
$$;

-- Orders assigned to this user's rider account. Separate from visible_order_ids because the rider's
-- view of the CUSTOMER is derived from it, and that is the one place assignment alone grants access
-- to a person rather than to an order.
create or replace function private.rider_order_ids(p_user uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select da.order_id from public.delivery_assignments da
  where da.rider_id in (select private.rider_ids_for(p_user));
$$;

-- Every order this user may see, as the union of the three legitimate vantage points: their own
-- order, an order containing one of their vendors' sub-orders, or an order they are delivering.
--
-- UNION rather than OR on purpose. Three OR'd branches on a policy column invite the planner to
-- seq-scan `orders`; three indexed lookups unioned stay index-driven. It also deduplicates, which
-- matters for a rider who is both customer and vendor staff on the same order.
--
-- This single function is what makes invariant 1 ("a rider reads an order only while assigned") and
-- invariant 2 ("a vendor reads only its own sub-orders") true for the whole order subtree at once,
-- instead of re-deriving the rule in six separate policies.
create or replace function private.visible_order_ids(p_user uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select o.id from public.orders o where o.user_id = p_user
  union
  select so.order_id from public.sub_orders so
   where so.vendor_id in (select private.vendor_ids_for(p_user))
  union
  select da.order_id from public.delivery_assignments da
   where da.rider_id in (select private.rider_ids_for(p_user));
$$;

grant execute on function
  private.vendor_ids_for(uuid),
  private.rider_ids_for(uuid),
  private.account_ids_for(uuid),
  private.rider_order_ids(uuid),
  private.visible_order_ids(uuid)
to authenticated;

-- private.is_admin() already exists from 005e: security definer, ignores revoked grants. Not
-- redefined. Every policy below ORs in (select private.is_admin()) through the per-table admin
-- policy created in the loop, rather than repeating it inline.

-- =============================================================================================
-- enable RLS everywhere, and give admin the whole database
-- =============================================================================================
-- Done in a loop over pg_class rather than 62 hand-written statements, for two reasons: it cannot
-- forget a table, and it cannot leave one behind. Anything added by 001-013 without a policy below
-- is admin-only by construction, which is the correct default for an operational table.
--
-- The admin policy is created per table instead of being OR'd into every role policy because
-- permissive policies on the same command are OR'd together by PostgreSQL. One extra policy per
-- table gives the same result and keeps the role policies readable.
--
-- Partitions are included in the sweep (Finding 2), and their names are stable.
do $$
declare
  t text;
begin
  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and c.relname <> 'riders_public'
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using ((select private.is_admin()))',
      t || '_admin_read', t);
  end loop;
end $$;

-- `riders` is in that sweep, which is intended: RLS on, admin can read, no client grant. The public
-- projection is the view at the end of this migration.

-- =============================================================================================
-- policies: the customer and the shared catalog
-- =============================================================================================

create policy cities_read on public.cities for select to authenticated
  using (is_active or (select private.is_admin()));

create policy areas_read on public.areas for select to authenticated
  using (is_active or (select private.is_admin()));

create policy delivery_zones_read on public.delivery_zones for select to authenticated
  using (is_active or (select private.is_admin()));

-- Fee tiers and rider pay rules are split deliberately. Fee tiers are public knowledge - the customer
-- is quoted from them. rider_pay_rules is NOT: 13.1 lumps both under "Read", which would publish
-- every rider's per-trip and per-km pay rate to every signed-in user and hand a competitor the wage
-- bill. Restricted to the rider themself and admin, and recorded in open question 3.18.
create policy delivery_fee_tiers_read on public.delivery_fee_tiers for select to authenticated
  using (true);

create policy rider_pay_rules_read on public.rider_pay_rules for select to authenticated
  using (rider_id is null
         or rider_id in (select private.rider_ids_for((select auth.uid())))
         or (select private.is_admin()));

create policy settings_read on public.settings for select to authenticated
  using (true);

create policy feature_flags_read on public.feature_flags for select to authenticated
  using (is_active or (select private.is_admin()));

create policy commission_rules_read on public.commission_rules for select to authenticated
  using (is_active
         and effective_from <= now()
         and (effective_until is null or effective_until > now()));

create policy cuisines_read on public.cuisines for select to authenticated using (true);
create policy brands_read on public.brands for select to authenticated using (is_active);

-- "All active" per 13.1. is_approved matters as much as is_active: a pending vendor must not be
-- browsable, or the customer sees a restaurant that cannot be ordered from.
create policy vendors_read on public.vendors for select to authenticated
  using ((is_active and is_approved and deleted_at is null) or (select private.is_admin()));

-- Vendor-owned rows a vendor must also be able to READ when inactive - to fix their own menu - are
-- handled by the vendor-side policies further down, not here.

create policy vendor_cuisines_read on public.vendor_cuisines for select to authenticated using (true);
create policy vendor_areas_read on public.vendor_areas for select to authenticated using (true);
create policy vendor_schedules_read on public.vendor_schedules for select to authenticated using (true);
create policy vendor_holidays_read on public.vendor_holidays for select to authenticated using (true);

create policy promo_slots_read on public.promo_slots for select to authenticated
  using (is_active or (select private.is_admin()));

-- Vouchers are readable while redeemable, so a customer can see an offer exists. Not while expired.
create policy vouchers_read on public.vouchers for select to authenticated
  using (is_active
         and valid_from <= now()
         and (valid_until is null or valid_until > now())
         or (select private.is_admin()));

-- Catalog. Each vendor-scoped table re-checks that the vendor is orderable. That is a correlated
-- probe on vendors.id (the primary key) per row rather than a join, which 13.2 warns about - but an
-- inactive vendor's menu must stop being served, and the customer-facing feed is an R2 snapshot
-- where deactivation is also enforced. Correctness wins; the cost is one index probe per row.
create policy menu_categories_read on public.menu_categories for select to authenticated
  using ((is_available and deleted_at is null
          and exists (select 1 from public.vendors v
                      where v.id = vendor_id and v.is_active and v.is_approved and v.deleted_at is null))
         or vendor_id in (select private.vendor_ids_for((select auth.uid())))
         or (select private.is_admin()));

create policy menu_items_read on public.menu_items for select to authenticated
  using ((is_available and deleted_at is null
          and exists (select 1 from public.vendors v
                      where v.id = vendor_id and v.is_active and v.is_approved and v.deleted_at is null))
         or vendor_id in (select private.vendor_ids_for((select auth.uid())))
         or (select private.is_admin()));

create policy menu_item_sizes_read on public.menu_item_sizes for select to authenticated
  using (is_available
         or exists (select 1 from public.menu_items mi where mi.id = item_id
                    and mi.vendor_id in (select private.vendor_ids_for((select auth.uid()))))
         or (select private.is_admin()));

create policy item_options_read on public.item_options for select to authenticated using (true);

create policy option_choices_read on public.option_choices for select to authenticated
  using (is_available
         or exists (select 1 from public.item_options io
                    join public.menu_items mi on mi.id = io.item_id
                    where io.id = option_id
                      and mi.vendor_id in (select private.vendor_ids_for((select auth.uid()))))
         or (select private.is_admin()));

-- =============================================================================================
-- policies: own rows
-- =============================================================================================

create policy users_read on public.users for select to authenticated
  using (id = (select auth.uid())
         or id in (select o.user_id from public.orders o
                   where o.user_id is not null
                     and o.id in (select private.rider_order_ids((select auth.uid()))))
         or (select private.is_admin()));

create policy addresses_read on public.addresses for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

-- Deliberately own-row only. A vendor and a rider reach the delivery address through the ORDER's
-- address_snapshot, never through this table - 13.1 invariant 2 requires that address visibility
-- must not leak the customer's other orders, and the only way to guarantee that is to make this
-- table unreachable to anyone but the owner.
create policy carts_read on public.carts for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy cart_items_read on public.cart_items for select to authenticated
  using (cart_id in (select c.id from public.carts c where c.user_id = (select auth.uid()))
         or (select private.is_admin()));

create policy favorites_read on public.favorites for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy favorite_items_read on public.favorite_items for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy device_tokens_read on public.device_tokens for select to authenticated
  using (user_id = (select auth.uid()));

-- No admin clause on purpose. device_tokens.token is a push credential: readable by the user it
-- belongs to and by nobody else, so a support engineer cannot export a customer's push tokens.
create policy user_auth_providers_read on public.user_auth_providers for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy user_roles_read on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy vendor_staff_read on public.vendor_staff for select to authenticated
  using (vendor_id in (select private.vendor_ids_for((select auth.uid())))
         or (select private.is_admin()));

-- =============================================================================================
-- policies: the order subtree
-- =============================================================================================
-- One rule, applied to every table that hangs off an order. private.visible_order_ids unions the
-- three vantage points, so 13.1's two hard invariants are enforced once rather than restated eight
-- times, and a rider's access ends the moment the assignment does.

create policy orders_read on public.orders for select to authenticated
  using (id in (select private.visible_order_ids((select auth.uid())))
         or (select private.is_admin()));

create policy sub_orders_read on public.sub_orders for select to authenticated
  using (order_id in (select private.visible_order_ids((select auth.uid())))
         or (select private.is_admin()));

create policy order_items_read on public.order_items for select to authenticated
  using (order_id in (select private.visible_order_ids((select auth.uid())))
         or (select private.is_admin()));

create policy order_status_history_read on public.order_status_history for select to authenticated
  using (order_id in (select private.visible_order_ids((select auth.uid())))
         or (select private.is_admin()));

create policy order_modifications_read on public.order_modifications for select to authenticated
  using (order_id in (select private.visible_order_ids((select auth.uid())))
         or (select private.is_admin()));

create policy order_eta_snapshots_read on public.order_eta_snapshots for select to authenticated
  using (order_id in (select private.visible_order_ids((select auth.uid())))
         or (select private.is_admin()));

-- The customer's own voucher use, plus admin. A vendor sees redemptions through their earnings.
create policy voucher_redemptions_read on public.voucher_redemptions for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

-- Reviews: non-hidden to everyone signed in, per 13.1. A review is a user's own words about a
-- vendor and a rider, already public by construction once not hidden.
create policy reviews_read on public.reviews for select to authenticated
  using (not is_hidden or (select private.is_admin()));

create policy delivery_assignments_read on public.delivery_assignments for select to authenticated
  using (order_id in (select private.visible_order_ids((select auth.uid())))
         or (select private.is_admin()));

create policy rider_location_pings_read on public.rider_location_pings for select to authenticated
  using (order_id in (select private.visible_order_ids((select auth.uid())))
         or (select private.is_admin()));

-- =============================================================================================
-- policies: money
-- =============================================================================================
-- 13.1: a customer has NO access to the ledger. Not "own account" - there is no customer account,
-- because the platform holds no customer money (constitution II.2). The policy below therefore
-- matches no row for a customer, which is the correct outcome expressed as enforcement.

create policy wallets_read on public.wallets for select to authenticated
  using (owner_id in (select private.account_ids_for((select auth.uid())))
         or (select private.is_admin()));

create policy payouts_read on public.payouts for select to authenticated
  using (account_id in (select private.account_ids_for((select auth.uid())))
         or (select private.is_admin()));

create policy ledger_entries_read on public.ledger_entries for select to authenticated
  using ((account_type in ('vendor', 'rider')
          and account_id in (select private.account_ids_for((select auth.uid()))))
         or (select private.is_admin()));

create policy payout_lines_read on public.payout_lines for select to authenticated
  using (payout_id in (select p.id from public.payouts p
                       where p.account_id in (select private.account_ids_for((select auth.uid()))))
         or (select private.is_admin()));

create policy vendor_earnings_daily_read on public.vendor_earnings_daily for select to authenticated
  using (vendor_id in (select private.vendor_ids_for((select auth.uid())))
         or (select private.is_admin()));

create policy rider_earnings_daily_read on public.rider_earnings_daily for select to authenticated
  using (rider_id in (select private.rider_ids_for((select auth.uid())))
         or (select private.is_admin()));

create policy platform_float_read on public.platform_float for select to authenticated
  using ((select private.is_admin()));

-- =============================================================================================
-- policies: rider and vendor operations
-- =============================================================================================

create policy driver_shifts_read on public.driver_shifts for select to authenticated
  using (rider_id in (select private.rider_ids_for((select auth.uid())))
         or (select private.is_admin()));

-- =============================================================================================
-- partitions (Finding 2)
-- =============================================================================================
-- The parent policies are NOT inherited. `notifications` needs its user policy on every partition
-- by name; `audit_log` is admin-only and its admin policy was already created by the sweep above,
-- so it only needs RLS enabled, which the sweep did.
--
-- notifications is the only partitioned table a client reads, and it is the reason this finding
-- mattered: without these, `select * from notifications_2026_10` would have returned every
-- notification in the system to any signed-in user.
do $$
declare
  p text;
begin
  for p in
    select c.relname from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'notifications\_%'
  loop
    execute format(
      'create policy %I on public.%I for select to authenticated using (user_id = (select auth.uid()))',
      p || '_user_read', p);
  end loop;
end $$;

create policy notifications_user_read on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));

-- =============================================================================================
-- riders_public - the projection that satisfies "public fields only"
-- =============================================================================================
-- A view, not a column GRANT. Column privileges would break `select=*` in PostgREST and would
-- silently change meaning every time a column is added. A view states the projection once, and
-- because `riders` has no client grant at all, the excluded columns are unreachable rather than
-- filtered - RLS could not have done this.
--
-- phone_number IS exposed: the customer pays the rider at the door and has to be able to call
-- them. That is a deliberate product decision and the reason this view exists rather than a
-- blanket deny.
create view public.riders_public as
select id, first_name, last_name, phone_number, vehicle_type, vehicle_plate,
       rating_avg, rating_count
from public.riders
where is_active;

comment on view public.riders_public is
  'Rider identity for customers: name, vehicle, rating, phone. Deliberately excludes user_id, '
  'current_latitude, current_longitude, cash_held and max_cash_held. Phone is exposed because the '
  'customer pays at the door and must be able to call.';

-- No admin policy on the view: every signed-in user sees every active rider''s public row, which is
-- the intent, so there is no row filter to add. RLS is deliberately NOT enabled on the view - a
-- policy would need to allow all rows anyway, and the view already runs with the owner''s rights so
-- it can read `riders` where clients cannot.

grant select on public.riders_public to authenticated;

-- =============================================================================================
-- ensure_month_partition - cover future partitions
-- =============================================================================================
-- Replaced so that a partition created in 021's pg_cron job is born with RLS and the right policy.
-- Without this, every month the cron creates would be a new hole, and the hole would be invisible
-- until someone read a notification belonging to somebody else.
create or replace function private.ensure_month_partition(p_table text, p_month date)
returns void language plpgsql set search_path = '' as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_child text := p_table || '_' || to_char(v_start, 'YYYY_MM');
begin
  if p_table not in ('events', 'notifications', 'rider_location_pings', 'audit_log') then
    raise exception 'NOT_A_PARTITIONED_TABLE: %', p_table using errcode = 'P0001';
  end if;

  if to_regclass('public.' || v_child) is null then
    execute format(
      'create table public.%I partition of public.%I for values from (%L) to (%L)',
      v_child, p_table, v_start, v_end
    );

    -- Finding 2. RLS is per-relation and is not inherited from the partitioned parent.
    execute format('alter table public.%I enable row level security', v_child);

    if p_table = 'notifications' then
      execute format(
        'create policy %I on public.%I for select to authenticated using (user_id = (select auth.uid()))',
        v_child || '_user_read', v_child);
    else
      -- audit_log is admin-only, matching the sweep in 014.
      execute format(
        'create policy %I on public.%I for select to authenticated using ((select private.is_admin()))',
        v_child || '_admin_read', v_child);
    end if;
  end if;
end $$;

revoke execute on function private.ensure_month_partition(text, date) from public, anon, authenticated;

-- =============================================================================================
-- grants
-- =============================================================================================
-- SELECT only, and only on read tables. No INSERT, UPDATE or DELETE to any client role on any
-- table: every mutation is a security-definer RPC in 016-020, which is what makes the RPC the single
-- place a permission decision is written (constitution III.21).
--
-- `riders` is absent by design. `platform_float`, `events`, `audit_log`, the three daily-stats
-- tables and `notification_templates` are absent because 014's resolved reading of 13.1 makes them
-- admin-only, reachable through admin RPCs rather than by direct table read.

grant usage on schema public to authenticated;

grant select on
  -- own rows
  public.users, public.addresses, public.carts, public.cart_items,
  public.favorites, public.favorite_items, public.device_tokens,
  public.user_auth_providers, public.user_roles, public.vendor_staff,
  public.notifications,
  -- catalog
  public.cities, public.areas, public.delivery_zones, public.delivery_fee_tiers,
  public.rider_pay_rules, public.settings, public.feature_flags, public.commission_rules,
  public.cuisines, public.brands, public.vendors, public.vendor_cuisines, public.vendor_areas,
  public.vendor_schedules, public.vendor_holidays, public.promo_slots, public.vouchers,
  public.menu_categories, public.menu_items, public.menu_item_sizes,
  public.item_options, public.option_choices,
  -- order subtree
  public.orders, public.sub_orders, public.order_items,
  public.order_status_history, public.order_modifications, public.order_eta_snapshots,
  public.voucher_redemptions, public.reviews,
  public.delivery_assignments, public.rider_location_pings,
  -- money
  public.wallets, public.payouts, public.payout_lines, public.ledger_entries,
  public.vendor_earnings_daily, public.rider_earnings_daily,
  public.driver_shifts,
  -- the rider projection
  public.riders_public
to authenticated;

-- anon: nothing. Not USAGE-adjacent, not a single table. Signed-in users only.

-- =============================================================================================
-- fail closed
-- =============================================================================================
-- The migration's own assertions. A policy set that silently omits a table is the exact failure
-- mode RLS exists to prevent, so it is checked rather than trusted.

do $$
declare
  no_rls text;
  writable text;
  anon_leak text;
begin
  -- 1. Every table and partition in public has RLS on.
  select string_agg(c.relname, ', ') into no_rls
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r','p')
    and c.relname <> 'riders_public'
    and not c.relrowsecurity;

  if no_rls is not null then
    raise exception 'FAIL CLOSED: RLS disabled on %', no_rls;
  end if;

  -- 2. No client role holds anything beyond SELECT on any table.
  select string_agg(format('%s -> %s on %I', grantee, privilege_type, table_name), '; ')
    into writable
  from information_schema.role_table_grants
  where grantee in ('anon','authenticated') and table_schema = 'public'
    and privilege_type <> 'SELECT';

  if writable is not null then
    raise exception 'FAIL CLOSED: non-SELECT grant: %', writable;
  end if;

  -- 3. anon holds nothing at all.
  select string_agg(format('%s on %I', table_name, privilege_type), ', ')
    into anon_leak
  from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public';

  if anon_leak is not null then
    raise exception 'FAIL CLOSED: anon has grants: %', anon_leak;
  end if;

  -- 4. `riders` itself is unreachable to clients. This is the Finding 3 guarantee, asserted.
  if exists (
    select 1 from information_schema.role_table_grants
    where grantee in ('anon','authenticated') and table_schema = 'public' and table_name = 'riders'
  ) then
    raise exception 'FAIL CLOSED: riders is directly readable; use riders_public';
  end if;

  -- 5. private stays unreachable by name, which is the real control behind every helper (Finding 1).
  if has_schema_privilege('authenticated', 'private', 'USAGE') then
    raise exception 'FAIL CLOSED: authenticated holds USAGE on private';
  end if;
end $$;