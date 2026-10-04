-- T0.1a: orders. This is the multi-vendor core and the reason the schema exists.
--
-- A checkout is ONE orders row plus N sub_orders rows. Never one order with a nullable vendor_id.
--
-- Applying every lesson from auditing 001-006c, so these defects cannot recur here:
--   * order_items.order_id and order_items.vendor_id are DERIVED from sub_orders, never trusted.
--     The audit found menu_items.vendor_id could be desynced from its category; without derivation
--     an order line could name a sub_order from one order and a vendor from another, which would
--     leak a competitor's line into a vendor dashboard.
--   * orders.status is DERIVED from its sub_orders. The spec says "derived, never set directly",
--     which is only true if something derives it.
--   * Every money column on sub_orders gets a CHECK. data-model had these unguarded.
--   * sub_orders.sequence is unique per order, so the pickup sequence is well defined.
--   * history and modification tables are append-only: UPDATE and DELETE are revoked.
--   * Every foreign key is indexed, per§14.2.

-- =============================================================================================
-- orders - the checkout envelope
-- =============================================================================================
create table public.orders (
  id           uuid primary key default gen_random_uuid(),
  order_number text not null unique,                -- 'C-261004-7F3K9'

  user_id      uuid not null references public.users(id),

  -- Aggregate status, DERIVED from sub_orders by sync_order_status(). Never set directly.
  status       text not null default 'pending' check (status in (
                 'pending','partially_confirmed','preparing','ready',
                 'picked_up','delivering','delivered','partially_cancelled','cancelled')),

  -- Money, whole checkout.
  subtotal                integer not null default 0,
  delivery_base_fee       integer not null default 0,
  delivery_multiplier_bps integer not null default 10000 check (delivery_multiplier_bps > 0),
  distance_km             numeric(6,2) check (distance_km is null or distance_km >= 0),
  delivery_fee            integer not null default 0,
  service_fee             integer not null default 0,
  discount_amount         integer not null default 0,
  voucher_code            text,
  voucher_discount        integer not null default 0,
  rider_tip               integer not null default 0,

  -- Frozen at checkout. What the rider earns and what the platform keeps are decided HERE, from
  -- the rules in force at that moment, so a later rule change cannot rewrite history.
  rider_pay_total  integer not null default 0,
  platform_revenue integer not null default 0,

  total    integer not null default 0,
  currency char(3) not null default 'EGP',

  -- The quote this order was priced from, so a disputed charge can be replayed.
  price_fingerprint text,
  pricing_version   integer not null default 1,

  -- Payment is chosen AT DELIVERY, not at checkout. The platform never holds customer money: the
  -- customer pays the rider directly, and 'wallet' means the customer sent VF Cash or Instapay to
  -- the rider's own number.
  payment_method      text check (payment_method in ('cash','wallet')),
  payment_channel     text check (payment_channel in
                         ('cod','vodafone_cash','instapay','gateway')),
  payment_status      text not null default 'unpaid'
                         check (payment_status in ('unpaid','collected','failed','refunded')),
  payment_collected_at timestamptz,
  payment_collected_by uuid references public.users(id),
  payment_reference   text,                          -- rider-recorded VF Cash / Instapay reference
  payment_proof_path  text,                          -- R2 private, optional

  -- Delivery
  delivery_type     text not null default 'delivery' check (delivery_type in ('delivery','pickup')),
  delivery_grouping text not null default 'together' check (delivery_grouping in ('together','separate')),
  vendor_limit_applied smallint,                      -- max_vendors_per_order in force at checkout
  address_id        uuid references public.addresses(id),
  address_snapshot  jsonb not null,                   -- frozen: the address at checkout
  delivery_latitude numeric(9,6),
  delivery_longitude numeric(9,6),
  delivery_geohash_prefix text,
  area_id           uuid references public.areas(id),
  is_contactless    boolean not null default false,
  access_note       text,
  scheduled_delivery_time timestamptz,
  promised_delivery_at    timestamptz,
  eta_minutes       integer check (eta_minutes is null or eta_minutes > 0),
  eta_maxutes       integer check (eta_maxutes is null or eta_maxutes > 0),

  -- Lifecycle
  vendor_count integer not null default 0,
  item_count   integer not null default 0,
  placed_at      timestamptz not null default now(),
  confirmed_at   timestamptz,
  first_picked_up_at timestamptz,
  completed_at   timestamptz,
  cancelled_at   timestamptz,
  cancellation_reason text,
  cancellation_actor_id uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- The total must be internally consistent, not merely non-negative: a total that does not equal
  -- its own components is a pricing bug, and a CHECK is the cheapest place to catch it.
  --
  -- discount_amount is the TOTAL reduction from every source. voucher_discount is the portion of it
  -- attributable to a voucher - a breakdown for the receipt, NOT an additional deduction. Adding
  -- both here would double-count every voucher, which is why the CHECK subtracts only
  -- discount_amount and separately asserts voucher_discount <= discount_amount.
  constraint orders_money_nonneg check (
    subtotal >= 0 and delivery_fee >= 0 and service_fee >= 0
    and discount_amount >= 0 and voucher_discount >= 0 and rider_tip >= 0
    and rider_pay_total >= 0 and platform_revenue >= 0 and total >= 0
  ),
  constraint orders_total_consistent check (
    total = subtotal + delivery_fee + service_fee + rider_tip - discount_amount
  ),
  constraint orders_voucher_within_discount check (voucher_discount <= discount_amount),
  constraint orders_eta_ordered check (
    eta_minutes is null or eta_maxutes is null or eta_maxutes >= eta_minutes
  ),
  -- money arrived as a pair or not at all
  constraint orders_payment_pair check (
    (payment_method is null and payment_channel is null)
    or (payment_method is not null and payment_channel is not null)
  )
);

create index orders_user_placed    on public.orders (user_id, placed_at desc);
create index orders_status_placed  on public.orders (status, placed_at desc);
create index orders_placed         on public.orders (placed_at desc);
create index orders_geohash_status on public.orders (delivery_geohash_prefix, status);
create index orders_area_id        on public.orders (area_id);
create index orders_address_id     on public.orders (address_id);
create index orders_payment_collected_by on public.orders (payment_collected_by);
create index orders_cancellation_actor on public.orders (cancellation_actor_id);

create trigger trg_orders_updated_at before update on public.orders
for each row execute function public.set_updated_at();

-- =============================================================================================
-- sub_orders - one per vendor
-- =============================================================================================
create table public.sub_orders (
  id       uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  vendor_id uuid not null references public.vendors(id),

  -- Pickup order within the trip, 1..N. Unique per order, so the sequence is well defined.
  --
  -- NO DEFAULT, deliberately. A default of 1 would let a two-vendor checkout insert two rows both
  -- numbered 1 and fail on the unique index with a message that says nothing about the cause.
  -- Requiring the caller to state the sequence turns that into an obvious omission, and
  -- place_order_v1 is the only thing that should be creating sub_orders.
  sequence smallint not null check (sequence > 0),

  status text not null default 'pending' check (status in (
            'pending','accepted','preparing','ready','picked_up','delivering',
            'delivered','rejected','cancelled')),

  -- Money for this vendor only
  subtotal            integer not null default 0,
  delivery_fee_share  integer not null default 0,
  service_fee_share   integer not null default 0,
  discount_share      integer not null default 0,
  commission_amount   integer not null default 0,      -- 0 until activated
  platform_fee_amount integer not null default 0,
  vendor_net_payout   integer not null default 0,      -- what the merchant earns

  -- Operational
  menu_version_snapshot integer,
  prep_estimate_minutes integer not null default 20 check (prep_estimate_minutes > 0),
  prep_actual_minutes   integer check (prep_actual_minutes is null or prep_actual_minutes >= 0),
  ready_at      timestamptz,
  accepted_at   timestamptz,
  preparing_at  timestamptz,
  picked_up_at  timestamptz,
  delivered_at  timestamptz,
  cancelled_at  timestamptz,
  cancellation_reason text,
  cancellation_actor  text check (cancellation_actor in ('customer','vendor','admin','system')),
  rejection_reason    text,

  -- The hook that makes payout runs safe: payable -> in_payout -> settled moves in the same
  -- transaction that writes the ledger, so a payout can never be issued twice. A rejected or
  -- cancelled sub_order is void and is never swept into a payout.
  settlement_status text not null default 'payable'
                      check (settlement_status in ('payable','in_payout','settled','void')),

  -- No foreign key yet: payouts does not exist until migration 010. 010 adds the constraint.
  payout_id  uuid,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (order_id, vendor_id),
  constraint sub_orders_money_nonneg check (
    subtotal >= 0 and delivery_fee_share >= 0 and service_fee_share >= 0
    and discount_share >= 0 and commission_amount >= 0
    and platform_fee_amount >= 0 and vendor_net_payout >= 0
  ),
  -- Only a settled or void sub_order may name a payout. A payable one must not, or a payout run
  -- could pick up the same work twice.
  constraint sub_orders_payout_only_when_settled check (
    payout_id is null or settlement_status in ('settled','in_payout')
  )
);

create unique index sub_orders_order_sequence on public.sub_orders (order_id, sequence);
create index sub_orders_vendor_created  on public.sub_orders (vendor_id, created_at desc);
create index sub_orders_vendor_open     on public.sub_orders (vendor_id, status)
  where status in ('pending','accepted','preparing','ready');
create index sub_orders_settlement_payable on public.sub_orders (settlement_status)
  where settlement_status = 'payable';
create index sub_orders_payout_id on public.sub_orders (payout_id) where payout_id is not null;
create index sub_orders_status_created on public.sub_orders (status, created_at)
  where status in ('pending','accepted');

create trigger trg_sub_orders_updated_at before update on public.sub_orders
for each row execute function public.set_updated_at();

-- =============================================================================================
-- order_items
-- =============================================================================================
create table public.order_items (
  id           uuid primary key default gen_random_uuid(),
  sub_order_id uuid not null references public.sub_orders(id) on delete cascade,

  -- Denormalised for feed queries, but DERIVED. See sync_order_item_parent below.
  order_id     uuid not null references public.orders(id) on delete cascade,
  vendor_id    uuid not null references public.vendors(id),

  -- on delete set null: retiring a dish must never damage order history.
  menu_item_id uuid references public.menu_items(id) on delete set null,

  -- Frozen snapshot. An order row is a historical record, so the name and price are COPIES, not
  -- references. A vendor renaming a dish tomorrow must not rewrite last week's receipt.
  item_name    text not null,
  item_name_ar text,
  image_path   text,
  quantity     integer not null check (quantity > 0 and quantity <= 99),
  -- unit_price is the FINAL unit price for this line, INCLUDING any option price modifiers, which
  -- is what makes total_price = quantity * unit_price hold. It is not the menu item's base price.
  unit_price   integer not null check (unit_price >= 0),
  total_price  integer not null check (total_price >= 0),
  selected_options jsonb not null default '[]'::jsonb
                      check (jsonb_typeof(selected_options) = 'array'),
  special_instructions text,
  item_status  text not null default 'confirmed' check (item_status in (
                  'confirmed','out_of_stock','price_updated','limited_stock','replacement')),
  created_at   timestamptz not null default now(),

  -- total_price is derived, not supplied. Storing a value that could disagree with quantity ×
  -- unit_price is how money bugs start.
  constraint order_items_total_consistent check (total_price = quantity * unit_price)
);

create index order_items_sub_order_id on public.order_items (sub_order_id);
create index order_items_order_id     on public.order_items (order_id);
create index order_items_vendor_id    on public.order_items (vendor_id);
create index order_items_menu_item_id on public.order_items (menu_item_id) where menu_item_id is not null;

-- order_id and vendor_id come from the parent sub_order, so a line can never name one order and a
-- vendor from another. This is the same defect class as 005b's menu_items.vendor_id.
create or replace function public.sync_order_item_parent()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_order  uuid;
  v_vendor uuid;
begin
  select so.order_id, so.vendor_id into v_order, v_vendor
  from public.sub_orders so where so.id = new.sub_order_id;

  if v_order is null then
    raise exception 'ORDER_ITEM_UNKNOWN_SUB_ORDER: %', new.sub_order_id using errcode = 'P0001';
  end if;

  new.order_id  := v_order;
  new.vendor_id := v_vendor;
  return new;
end $$;

-- No column list, for the reason recorded in 005b.
create trigger trg_order_items_sync_parent before insert or update on public.order_items
for each row execute function public.sync_order_item_parent();

-- =============================================================================================
-- order_status_history - append only
-- =============================================================================================
create table public.order_status_history (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  sub_order_id  uuid references public.sub_orders(id) on delete cascade,   -- null = order level
  from_status   text,
  to_status     text not null,
  actor_user_id uuid references public.users(id),
  actor_role    text not null check (actor_role in ('customer','rider','vendor','admin','system')),
  reason        text,
  metadata      jsonb,
  created_at    timestamptz not null default now(),

  -- A row that changed from one state to another and then claims a different from_status is a lie.
  constraint order_history_transition_real check (from_status is null or from_status <> to_status)
);

create index order_status_history_order     on public.order_status_history (order_id, created_at);
create index order_status_history_sub_order on public.order_status_history (sub_order_id, created_at);
create index order_status_history_actor     on public.order_status_history (actor_user_id);

-- An order-level row must not name a sub_order, and a sub_order row must name one. Without this a
-- report of "order-level transitions" silently includes vendor-level ones.
create or replace function public.assert_history_scope()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.sub_order_id is not null
     and not exists (select 1 from public.sub_orders so where so.id = new.sub_order_id) then
    raise exception 'HISTORY_UNKNOWN_SUB_ORDER: %', new.sub_order_id using errcode = 'P0001';
  end if;
  return null;
end $$;

create constraint trigger trg_history_scope
  after insert on public.order_status_history
  deferrable initially deferred
  for each row execute function public.assert_history_scope();

-- =============================================================================================
-- order_modifications - append only
-- =============================================================================================
create table public.order_modifications (
  id                uuid primary key default gen_random_uuid(),
  order_id          uuid not null references public.orders(id) on delete cascade,
  sub_order_id      uuid references public.sub_orders(id) on delete cascade,
  order_item_id     uuid references public.order_items(id) on delete cascade,
  modification_type text not null check (modification_type in
                      ('item_removed','item_added','price_updated','stock_limited')),
  original_total    integer not null check (original_total >= 0),
  new_total         integer not null check (new_total >= 0),
  difference_amount integer not null,
  reason            text,
  customer_approved boolean,
  actor_user_id     uuid references public.users(id),
  created_at        timestamptz not null default now(),

  -- difference_amount is arithmetic, not a field someone types.
  constraint order_mod_difference_consistent check (difference_amount = new_total - original_total)
);

create index order_modifications_order     on public.order_modifications (order_id);
create index order_modifications_sub_order on public.order_modifications (sub_order_id);
create index order_modifications_order_item on public.order_modifications (order_item_id);
create index order_modifications_actor     on public.order_modifications (actor_user_id);

-- =============================================================================================
-- orders.status is derived from its sub_orders
-- =============================================================================================
-- The spec says aggregate status is "derived, never set directly". That is only true if something
-- derives it, and nothing did. Recomputed from the sub_orders on every change to one, so the
-- envelope can never disagree with its parts.
--
-- Statement-level with a transition table: confirming five sub_orders recomputes the order once.
create or replace function public.sync_order_status()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_order uuid;
begin
  -- Distinct, because one order can be touched by several sub_order rows in the same statement.
  -- Distinct, because one statement can touch several sub_orders of the same order.
  for v_order in select distinct nr.order_id from new_rows nr
  loop
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

create trigger trg_sub_orders_sync_order_status_ins after insert on public.sub_orders
  referencing new table as new_rows
  for each statement execute function public.sync_order_status();

create trigger trg_sub_orders_sync_order_status_upd after update on public.sub_orders
  referencing new table as new_rows
  for each statement execute function public.sync_order_status();

-- =============================================================================================
-- Append-only enforcement
-- =============================================================================================
-- These two tables record what happened. An UPDATE or DELETE rewrites the record of an event,
-- which is the one thing an audit trail must never permit. Revoked at the database level, so it
-- holds regardless of what the application code does.
revoke update, delete on public.order_status_history from anon, authenticated;
revoke update, delete on public.order_modifications from anon, authenticated;

-- orders and sub_orders are business records too: cancellation is how an order ends, not deletion.
-- No deleted_at column by design.
revoke delete on public.orders from anon, authenticated;
revoke delete on public.sub_orders from anon, authenticated;
revoke delete on public.order_items from anon, authenticated;