-- T0.1a: cart. The brief had no cart table, but a multi-vendor basket cannot survive app death,
-- device change or an offline period without one, and a cart that vanishes mid-checkout is the
-- fastest way to lose an order.
--
-- Carries forward the lessons from auditing 001-005c:
--   * cart_items.vendor_id is DERIVED from menu_items, not trusted. The audit found that
--     menu_items.vendor_id could be desynced from its category; deriving here means a cart line can
--     never attribute an item to a vendor that does not sell it.
--   * Every money column gets a CHECK. cached_price is a display estimate, but a negative one would
--     render as a negative price on the basket screen.
--   * selected_options is constrained to a JSON array. An object or a scalar here would break every
--     reader downstream.
--   * Every foreign key is indexed, per data-model §14.2.

-- Shared updated_at trigger. 001-005c each declared their own inline copy; this is the single
-- helper used by every table from here on.
create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- =============================================================================================
-- carts
-- =============================================================================================
create table public.carts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users(id) on delete cascade,

  -- One active cart per person. A second device reads and writes the same row, so switching phones
  -- mid-checkout keeps the basket.
  is_active    boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Partial, not a plain unique on user_id: a user may have many abandoned carts, and only one live
-- one. An index that included the inactive rows would wrongly cap a user at a single historical cart.
create unique index carts_one_active on public.carts (user_id) where is_active;

create index carts_user_created on public.carts (user_id, created_at desc);

create trigger trg_carts_updated_at before update on public.carts
for each row execute function public.set_updated_at();

-- =============================================================================================
-- cart_items
-- =============================================================================================
create table public.cart_items (
  id          uuid primary key default gen_random_uuid(),
  cart_id     uuid not null references public.carts(id) on delete cascade,

  -- Denormalised for vendor-scoped cart queries, but always derived. See sync_cart_item_vendor below.
  vendor_id   uuid not null references public.vendors(id) on delete cascade,
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,

  quantity    integer not null check (quantity > 0 and quantity <= 99),

  -- Array of chosen add-ons: [{option_id, choice_ids:[...]}]. Constrained to an array so a reader
  -- can rely on the shape.
  selected_options jsonb not null default '[]'::jsonb
                      check (jsonb_typeof(selected_options) = 'array'),

  special_instructions text,

  -- Display only. Never read by a quote or an order; place_order_v1 re-prices inside the
  -- transaction and aborts with PRICE_CHANGED if anything moved.
  display_snapshot jsonb,
  cached_price     integer check (cached_price is null or cached_price >= 0),
  cached_at        timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Two lines are the same line when they are the same item with the same options, so an
-- "add 2 then add 1 more" cannot silently produce two single-quantity rows. jsonb has no default
-- btree opclass, so the identity is a hash of the canonical text form; md5 is IMMUTABLE and so is
-- legal in an index. The collision risk is irrelevant here: it would have to be two different
-- option sets with the same hash, and a duplicate line is recoverable while a lost one is not.
create unique index cart_items_line_identity
  on public.cart_items (cart_id, menu_item_id, md5(selected_options::text));

create index cart_items_cart_id on public.cart_items (cart_id);
create index cart_items_vendor_id on public.cart_items (vendor_id);
create index cart_items_menu_item_id on public.cart_items (menu_item_id);

create trigger trg_cart_items_updated_at before update on public.cart_items
for each row execute function public.set_updated_at();

-- vendor_id is derived, never trusted. Without this a client could write a cart line claiming
-- vendor B while the menu_item belongs to vendor A, and a vendor dashboard reading rows by
-- vendor_id would then show a competitor's item. Deriving from menu_items closes it at the source:
-- menu_items.vendor_id is itself trigger-maintained, and 005b removed the column list from that
-- trigger so it can no longer drift.
--
-- BEFORE INSERT OR UPDATE with no column list, for the reason recorded in 005b: restricting the
-- trigger to a column list means a bare UPDATE of vendor_id skips the derivation entirely.
create or replace function public.sync_cart_item_vendor()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.vendor_id := (select mi.vendor_id from public.menu_items mi where mi.id = new.menu_item_id);
  if new.vendor_id is null then
    raise exception 'CART_ITEM_UNKNOWN_MENU_ITEM: %', new.menu_item_id using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger trg_cart_items_sync_vendor before insert or update on public.cart_items
for each row execute function public.sync_cart_item_vendor();

-- A cart line pointing at an unavailable or deleted item must not survive checkout silently.
-- Soft-deleted items are excluded rather than blocking the delete, because a vendor retiring a dish
-- must not fail on open carts.
create or replace function public.assert_cart_item_orderable()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_available boolean;
  v_deleted   boolean;
begin
  select mi.is_available, (mi.deleted_at is not null)
    into v_available, v_deleted
  from public.menu_items mi where mi.id = new.menu_item_id;

  if v_deleted then
    raise exception 'CART_ITEM_RETIRED: menu item % is no longer sold', new.menu_item_id
      using errcode = 'P0001';
  end if;
  if not v_available then
    raise exception 'CART_ITEM_UNAVAILABLE: menu item % is marked unavailable', new.menu_item_id
      using errcode = 'P0001';
  end if;
  return null;
end $$;

create constraint trigger trg_cart_item_orderable
  after insert or update on public.cart_items
  deferrable initially deferred
  for each row execute function public.assert_cart_item_orderable();

-- Touch the cart whenever its lines change, so a background sweep can find abandoned carts by
-- last_seen_at without joining cart_items.
--
-- Statement-level: a five-line basket edit should mark the cart seen once, not five times. A
-- transition table needs a single event, so INSERT and UPDATE get their own trigger.
create or replace function public.touch_cart_from_new_rows()
returns trigger language plpgsql set search_path = '' as $$
begin
  update public.carts c
     set last_seen_at = now()
   where c.id in (select distinct nr.cart_id from new_rows nr);
  return null;
end $$;

create trigger trg_cart_items_touch_ins after insert on public.cart_items
  referencing new table as new_rows
  for each statement execute function public.touch_cart_from_new_rows();

create trigger trg_cart_items_touch_upd after update on public.cart_items
  referencing new table as new_rows
  for each statement execute function public.touch_cart_from_new_rows();