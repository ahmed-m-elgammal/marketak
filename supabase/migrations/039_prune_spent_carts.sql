-- 039_prune_spent_carts.sql
-- Purpose: bound cart storage. Delete spent carts (and, by CASCADE, their lines)
--          so abandoned baskets cannot accumulate forever on a 400 MB database.
--
-- Scope, deliberately narrow:
--   * Deletes from public.carts ONLY. public.cart_items goes with it via the
--     existing cart_items_cart_id_fkey ON DELETE CASCADE, so an orphan line is
--     not representable.
--   * Never touches orders, sub_orders, order_items, the money cycle, events or
--     any audit-bearing table.
--
-- Safety: the money cycle does not depend on a spent cart. place_order_v1 copies
--   every line into order_items *before* it sets is_active = false, and the quote
--   it re-prices from (quote_id, quote_fingerprint, quote_expires_at) is consumed
--   in the same transaction. Once a cart is inactive it has no remaining reader.
--
-- Clock: trg_carts_updated_at is a BEFORE UPDATE trigger, so for a spent cart
--   updated_at is the moment place_order_v1 deactivated it. The 7-day retention
--   therefore starts at checkout, and stays far beyond the 5-minute quote TTL and
--   any dispute window.
--
-- Matches the existing sweeper contract (prune_events, prune_notifications):
--   SECURITY DEFINER, search_path pinned, batched with pg_sleep, EXECUTE revoked
--   from every role so only the cron owner can invoke it.

create or replace function private.prune_spent_carts()
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_deleted integer := 0;
  v_batch   integer;
begin
  loop
    with d as (
      delete from public.carts c
       where c.id in (
             select x.id
               from public.carts x
              where x.is_active = false
                and x.updated_at < now() - interval '7 days'
              order by x.updated_at
              limit 1000)
      returning 1)
    select count(*) into v_batch from d;

    v_deleted := v_deleted + v_batch;
    exit when v_batch < 1000;
    perform pg_sleep(0.05);
  end loop;
  return v_deleted;
end
$function$;

revoke execute on function private.prune_spent_carts() from public;
revoke execute on function private.prune_spent_carts() from anon;
revoke execute on function private.prune_spent_carts() from authenticated;
revoke execute on function private.prune_spent_carts() from service_role;

-- 3:17 is free; the other daily sweepers sit at 3:23 and 3:41.
select cron.schedule(
  'prune-carts-daily',
  '17 3 * * *',
  $$select private.prune_spent_carts()$$
)
where not exists (
  select 1 from cron.job where jobname = 'prune-carts-daily'
);