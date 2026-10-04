-- 007b: orders.item_count could never become non-zero.
--
-- sync_order_status() computes item_count from order_items, but it was only ever attached to
-- sub_orders. order_items.sub_order_id is a NOT NULL foreign key to sub_orders, so an order line
-- cannot exist until after its sub_order does - which means the aggregate was always recomputed
-- before any line was counted, and nothing recomputed it afterwards. Every order in the database
-- would have carried item_count = 0 while holding real items.
--
-- Proven, not inferred. A single-vendor order with one line of quantity 3:
--
--   order_number | vendor_count | item_count | actual_lines | actual_dishes
--   PROOF-1      |            1 |          0 |            1 |             3
--
-- vendor_count was right, because it comes from sub_orders, which is what fired the trigger.
-- item_count was wrong for the structural reason above, not by accident of that fixture.
--
-- The fix has two parts:
--
--   1. The aggregate UPDATE moves into private.recompute_order_aggregates(uuid), so sub_orders and
--      order_items share one definition of "recompute this order" instead of two copies that can
--      drift. sync_order_status() keeps its name and its trigger signature, so the two triggers
--      007a installed are untouched.
--
--   2. order_items gets its own statement-level triggers. DELETE needs its own function because a
--      DELETE trigger can only declare an OLD TABLE transition table, and an UPDATE needs both,
--      because order_items.order_id is derived from sub_order_id - so moving a line to a different
--      sub_order moves it to a different order, and the order it left needs recomputing too. All
--      three delegate to the same helper; none of them reimplements the aggregate.
--
-- Statement-level for the same reason 007 used it on sub_orders: a five-line basket should recompute
-- its order once, not five times.
--
-- 007's comment says payouts arrives in migration 010. data-model.md 15.2 puts it in 009, which is
-- what 009 will follow. Noted here because this file touches that neighbourhood and 007 is
-- immutable once applied (15.1 rule 3), so the correction is recorded forward rather than edited in.

-- The helper takes an argument, which means PostgREST would expose it at
-- /rest/v1/rpc/recompute_order_aggregates if it lived in an exposed schema - the exact problem 005e
-- moved private.is_admin() out of public to solve. It belongs in private.
--
-- EXECUTE is revoked and NOT re-granted: nothing outside a trigger should reach it. place_order_v1
-- is security definer and runs as the owner, so 017 needs no grant either. Direct client writes to
-- order_items are meant to be impossible, and a missing grant makes that failure loud rather than
-- silent if it is ever attempted.
create or replace function private.recompute_order_aggregates(p_order_id uuid)
returns void language plpgsql set search_path = '' as $$
begin
  update public.orders o
     set status = (
           select case
             -- A total cancellation outranks everything.
             when bool_and(so.status in ('cancelled','rejected')) then 'cancelled'
             when bool_and(so.status = 'delivered') then 'delivered'
             when bool_and(so.status in ('cancelled','rejected','delivered'))
               then 'partially_cancelled'
             when bool_and(so.status in ('picked_up','delivering')) then 'picked_up'
             when bool_and(so.status = 'ready') then 'ready'
             when bool_and(so.status in ('preparing','ready')) then 'preparing'
             when bool_or(so.status in ('accepted','preparing','ready','picked_up','delivering','delivered'))
               then 'partially_confirmed'
             else 'pending'
           end
           from public.sub_orders so
          where so.order_id = p_order_id
         ),
         vendor_count = (select count(*) from public.sub_orders so where so.order_id = p_order_id),
         -- order_items.order_id is derived and correct, so this needs no join through sub_orders.
         item_count   = (select coalesce(sum(oi.quantity), 0)
                           from public.order_items oi where oi.order_id = p_order_id),
         confirmed_at = case
           when (select bool_and(so.status <> 'pending') from public.sub_orders so where so.order_id = p_order_id)
             then coalesce(o.confirmed_at, now()) else o.confirmed_at end,
         completed_at = case
           when (select bool_and(so.status in ('delivered','cancelled','rejected'))
                   from public.sub_orders so where so.order_id = p_order_id)
             then coalesce(o.completed_at, now()) else o.completed_at end
   where o.id = p_order_id;
end $$;

revoke execute on function private.recompute_order_aggregates(uuid) from public, anon, authenticated;

-- Same name, same trigger signature, same behaviour. Only the body moved. Distinct because one
-- statement can touch several sub_orders of the same order, and recomputing it once per row would
-- make a five-vendor confirmation five times more expensive for no gain.
create or replace function public.sync_order_status()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_order uuid;
begin
  for v_order in select distinct nr.order_id from new_rows nr
  loop
    perform private.recompute_order_aggregates(v_order);
  end loop;
  return null;
end $$;

-- INSERT. New rows only: a line being added can only belong to an order that did not previously
-- count it.
create or replace function public.sync_order_item_aggregates_ins()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_order uuid;
begin
  for v_order in select distinct nr.order_id from new_rows nr
  loop
    perform private.recompute_order_aggregates(v_order);
  end loop;
  return null;
end $$;

-- UPDATE. Both transition tables, because order_items.order_id is derived from sub_order_id - so
-- moving a line to a different sub_order moves it to a different order, and the order it left would
-- otherwise keep counting a line it no longer has.
create or replace function public.sync_order_item_aggregates_upd()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_order uuid;
begin
  for v_order in select distinct nr.order_id from new_rows nr
  loop
    perform private.recompute_order_aggregates(v_order);
  end loop;
  -- order_items.order_id is derived from sub_order_id, so changing the parent sub_order changes the
  -- order. Recomputing only the new one would leave the old order counting a line it no longer has.
  for v_order in select distinct orr.order_id from old_rows orr
  loop
    perform private.recompute_order_aggregates(v_order);
  end loop;
  return null;
end $$;

-- DELETE. A DELETE trigger can only declare an OLD TABLE, which is why this is not shared with the
-- INSERT path: PL/pgSQL resolves transition-table names at runtime, so a function naming new_rows
-- would create cleanly and fail on first use against an OLD-only trigger. Same trap as 007a.
create or replace function public.sync_order_item_aggregates_del()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_order uuid;
begin
  for v_order in select distinct orr.order_id from old_rows orr
  loop
    perform private.recompute_order_aggregates(v_order);
  end loop;
  return null;
end $$;

create trigger trg_order_items_aggregates_ins
  after insert on public.order_items
  referencing new table as new_rows
  for each statement execute function public.sync_order_item_aggregates_ins();

create trigger trg_order_items_aggregates_upd
  after update on public.order_items
  referencing old table as old_rows new table as new_rows
  for each statement execute function public.sync_order_item_aggregates_upd();

create trigger trg_order_items_aggregates_del
  after delete on public.order_items
  referencing old table as old_rows
  for each statement execute function public.sync_order_item_aggregates_del();
