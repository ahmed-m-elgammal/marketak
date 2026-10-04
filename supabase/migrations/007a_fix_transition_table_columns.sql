-- 007's sync_order_status joined new_rows to sub_orders on nr.sub_order_id. The transition table on
-- a trigger declared ON sub_orders IS a sub_orders relation, so its column is id, and it already
-- carries order_id directly. The join was both wrong and unnecessary.
--
-- Found by executing the trigger, which is the only way it surfaces: CREATE FUNCTION and CREATE
-- TRIGGER both succeed against a nonexistent column because PL/pgSQL resolves at runtime.
create or replace function public.sync_order_status()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_order uuid;
begin
  -- Distinct, because one statement can touch several sub_orders of the same order.
  for v_order in select distinct nr.order_id from new_rows nr
  loop
    update public.orders o
       set status = (
             select case
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
            where so.order_id = v_order
           ),
           vendor_count = (select count(*) from public.sub_orders so where so.order_id = v_order),
           -- order_items.order_id is derived and correct, so this needs no join through sub_orders.
           item_count   = (select coalesce(sum(oi.quantity), 0)
                             from public.order_items oi where oi.order_id = v_order),
           confirmed_at = case
             when (select bool_and(so.status <> 'pending') from public.sub_orders so where so.order_id = v_order)
               then coalesce(o.confirmed_at, now()) else o.confirmed_at end,
           completed_at = case
             when (select bool_and(so.status in ('delivered','cancelled','rejected'))
                     from public.sub_orders so where so.order_id = v_order)
               then coalesce(o.completed_at, now()) else o.completed_at end
     where o.id = v_order;
  end loop;
  return null;
end $$;