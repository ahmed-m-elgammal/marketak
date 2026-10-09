-- 028: index the three foreign keys that have none.
--
-- Postgres indexes a primary key for free and does NOT index the referencing column of a foreign
-- key. Without one, every join through the FK is a sequential scan and every delete on the parent
-- is a full scan of the child - because `ON DELETE SET NULL` has to find every child row that
-- points at the parent before it can null it.
--
-- The three below are the last unindexed FKs in the schema. `data-model.md` §14.2 states all are
-- indexed and `AGENTS.md` repeats it; both were wrong, found by `scripts/check-policies.mjs` on
-- 2026-10-08 against the live project.
--
-- ## Which of the three actually matters
--
-- All three are `ON DELETE SET NULL` into `menu_item_sizes` or `addresses`, so all three cost a
-- child scan on a parent delete. They differ in how the child table grows:
--
--   order_items.selected_size_id   -> menu_item_sizes   NEVER PRUNED. `orders` is not deletable
--                                                       (constitution: an order is not deletable),
--                                                       so this table grows with every order ever
--                                                       placed. This is the one that matters.
--   cart_items.selected_size_id    -> menu_item_sizes   high churn - every add-to-cart writes rows.
--                                                       Scans live carts of people shopping now.
--   carts.quote_address_id         -> addresses         grows with users, one cart each. Weakest case
--                                                       of the three; indexed for completeness.
--
-- ## Read the correction that comes with this
--
-- The join side of the usual "index your FKs" argument is WEAK here. `order_items` is a frozen
-- snapshot - `item_name`, `unit_price`, the selected options and the selected size are all copied at
-- placement - so rendering a receipt joins back to `menu_item_sizes` only in the repeat-order flow
-- (#32 in `APP-SCREENS-AND-COMPONENTS.md`), and that reads one order by an indexed `order_id` in a
-- small row set. The DELETE CASCADE is the reason for these indexes, not the read path.
--
-- The delete also takes row locks on every child it nulls and holds them for the transaction. That
-- is the mechanism by which this stops being a latency problem and becomes a blocking one: it is
-- latency proportional to `count(*)` over a table that only grows, on an operation - a restaurant
-- tidying its menu - that is routine and frequent, and the locks it holds contend with live
-- transactions touching those rows.
--
-- ## Why plain CREATE INDEX and not CONCURRENTLY
--
-- `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block, and migration application wraps
-- DDL in one. Plain `CREATE INDEX` takes an ACCESS EXCLUSIVE lock for the duration of the build.
--
-- That is acceptable precisely now and would not be later: these tables hold 1-2 rows, so the lock
-- is held for milliseconds. If this migration is ever replayed against a populated database, it must
-- be CONCURRENTLY, run outside a migration wrapper, or it blocks writes on `order_items` for the
-- build duration - which is the very stall it exists to prevent. Recorded here so nobody replays a
-- migration file into production without noticing.
--
-- ## Size
--
-- Three btree indexes, ~1 index entry per row, no writes added to any hot path. Neither index is
-- UNIQUE - a size may be selected by many lines - and neither is partial, because a NULL
-- `selected_size_id` is a legitimate value (an item sold with no size chosen) and must not be
-- excluded from the index.

create index if not exists carts_quote_address_id
  on public.carts (quote_address_id);

create index if not exists cart_items_selected_size_id
  on public.cart_items (selected_size_id);

create index if not exists order_items_selected_size_id
  on public.order_items (selected_size_id);
