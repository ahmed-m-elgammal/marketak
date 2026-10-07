-- =============================================================================
-- 04_tables_cart.sql
-- Carts, cart lines and favourites. The cart is the input to quoting; it is
-- display-only with respect to money (cached_price is never charged).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- carts: one live cart per user. The `quote_*` columns hold the pointer to the
-- server-side quote produced by quote_order_v1; place_order_v1 consumes that
-- quote and re-prices inside the transaction.
-- -----------------------------------------------------------------------------
create table public.carts
(
  id uuid not null default gen_random_uuid(),
  user_id uuid not null,
  is_active boolean not null default true,
  last_seen_at timestamp with time zone not null default now(),
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  quote_id uuid,
  quote_fingerprint text,
  quote_expires_at timestamp with time zone,
  quote_address_id uuid,
  quote_voucher_code text,
  quote_rider_tip integer,
  quote_delivery_type text,
  quote_grouping text,
  quote_snapshot jsonb,

  constraint carts_pkey primary key PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- cart_items: a chosen menu item plus its selections. `vendor_id` and
-- `cached_price` are maintained by trigger purely so the cart can be grouped
-- by vendor and rendered without a re-price on every render.
-- -----------------------------------------------------------------------------
create table public.cart_items
(
  id uuid not null default gen_random_uuid(),
  cart_id uuid not null,
  vendor_id uuid not null,
  menu_item_id uuid not null,
  quantity integer not null,
  selected_options jsonb not null default '[]'::jsonb,
  special_instructions text,
  display_snapshot jsonb,
  cached_price integer,
  cached_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  selected_size_id uuid,
  selected_size_name text,
  selected_size_price integer,

  constraint cart_items_cached_price_check check CHECK (((cached_price IS NULL) OR (cached_price >= 0))),
  constraint cart_items_pkey primary key PRIMARY KEY (id),
  constraint cart_items_quantity_check check CHECK (((quantity > 0) AND (quantity <= 99))),
  constraint cart_items_selected_options_check check CHECK ((jsonb_typeof(selected_options) = 'array'::text))
);

-- -----------------------------------------------------------------------------
-- favorites / favorite_items: two separate lists — saved merchants and saved
-- individual items. Pure user preference; no effect on ordering.
-- -----------------------------------------------------------------------------
create table public.favorites
(
  user_id uuid not null,
  vendor_id uuid not null,
  created_at timestamp with time zone not null default now(),

  constraint favorites_pkey primary key PRIMARY KEY (user_id, vendor_id)
);

create table public.favorite_items
(
  user_id uuid not null,
  menu_item_id uuid not null,
  created_at timestamp with time zone not null default now(),

  constraint favorite_items_pkey primary key PRIMARY KEY (user_id, menu_item_id)
);