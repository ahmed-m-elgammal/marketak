-- =============================================================================================
-- 014a_fix_vendor_sub_order_leak.sql
-- =============================================================================================
-- A cross-vendor data leak found by testing 014, not by reading it. Demonstrated, not theorised.
--
-- WHAT 014 GOT WRONG. 014 stated one rule for the whole order subtree:
--
--   create policy sub_orders_read on sub_orders for select to authenticated
--     using (order_id in (select private.visible_order_ids((select auth.uid()))));
--
-- and its comment claimed this enforced data-model.md 13.1 invariant 2 - "a vendor can read only
-- its own sub-orders". It did not. private.visible_order_ids deliberately unions three vantage
-- points, one of which is "an order containing one of my vendors' sub-orders". Applying that at the
-- ORDER level is correct: a vendor does need the parent order row for the total, the delivery fee
-- and the customer's address. Applying it at SUB_ORDER level then hands the vendor every sibling
-- sub-order on that order.
--
-- MEASURED, on a two-vendor fixture where order MK-1 contains one sub-order per vendor:
--
--   vendor staff of vendor 1, SELECT count(*) FROM sub_orders   ->  3   (expected 2)
--   ... of which belonging to vendor 2                          ->  1   (expected 0)
--
-- So vendor 1 could read vendor 2's line items, prices and commission share for an order they are
-- both cooking. That is the exact leak invariant 2 exists to prevent, and 014's comment asserted it
-- was prevented. A comment that claims a guarantee the code does not provide is worse than no
-- comment, because the next reviewer trusts it.
--
-- THE FIX. Split the two questions that 014 merged. An order you own or are delivering lets you see
-- every sub-order on it - you are the customer, you paid for all of it, or you are carrying all of
-- it. An order that merely CONTAINS your sub-order does not: you see your own slice only.
--
--   sub_orders / order_items  -> own vendor_id, OR order_id in owned_or_assigned
--   everything else in the subtree -> visible_order_ids, unchanged
--
-- order_items is corrected in the same migration because it carries vendor_id and had the identical
-- policy shape; leaving it would have fixed the symptom on one table and kept the leak on the other.
-- =============================================================================================

create or replace function private.owned_or_assigned_order_ids(p_user uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select o.id from public.orders o where o.user_id = p_user
  union
  select da.order_id from public.delivery_assignments da
   where da.rider_id in (select private.rider_ids_for(p_user));
$$;

grant execute on function private.owned_or_assigned_order_ids(uuid) to authenticated;

drop policy if exists sub_orders_read on public.sub_orders;
create policy sub_orders_read on public.sub_orders for select to authenticated
  using (vendor_id in (select private.vendor_ids_for((select auth.uid())))
         or order_id in (select private.owned_or_assigned_order_ids((select auth.uid())))
         or (select private.is_admin()));

drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items for select to authenticated
  using (vendor_id in (select private.vendor_ids_for((select auth.uid())))
         or order_id in (select private.owned_or_assigned_order_ids((select auth.uid())))
         or (select private.is_admin()));

-- order_modifications and order_status_history are left on visible_order_ids deliberately. Both are
-- per-ORDER rather than per-vendor: a modification to order MK-1 is something the customer, the
-- vendor preparing it and the rider carrying it all need to see, and neither table carries a
-- vendor_id that could be filtered on without inventing one. Their contents are status transitions
-- and item-level deltas for the order as a whole, which every participant already knows.

-- Re-assert the invariants 014 asserts overall, now that they are actually true.
do $$
declare no_rls text;
begin
  select string_agg(c.relname, ', ') into no_rls
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r','p')
    and c.relname <> 'riders_public' and not c.relrowsecurity;
  if no_rls is not null then raise exception 'FAIL CLOSED: RLS disabled on %', no_rls; end if;

  if exists (select 1 from information_schema.role_table_grants
             where grantee in ('anon','authenticated')
               and table_schema = 'public' and privilege_type <> 'SELECT') then
    raise exception 'FAIL CLOSED: a non-SELECT client grant exists';
  end if;

  -- The exact policy shape that leaked, asserted so it cannot be reintroduced.
  if exists (
    select 1 from pg_policies
    where tablename = 'sub_orders' and policyname = 'sub_orders_read'
      and qual not like '%vendor_ids_for%'
  ) then
    raise exception 'FAIL CLOSED: sub_orders_read no longer filters by vendor_id';
  end if;
end $$;