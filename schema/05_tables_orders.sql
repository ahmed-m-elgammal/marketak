-- =============================================================================
-- 05_tables_orders.sql
-- The checkout. A checkout is ONE `orders` row plus N `sub_orders` rows, one
-- per vendor. There is deliberately no nullable `vendor_id` on `orders`.
--
-- `orders` holds the customer-facing money view (what the customer is charged).
-- `sub_orders` holds the settlement view (what the vendor is owed).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- orders: the checkout header. Every money column is an integer in the
-- currency's minor unit (EGP piastres). The CHECK constraints below are the
-- authoritative arithmetic — the total is derived, never trusted from input.
--
--   total = (subtotal + delivery_fee + service_fee + rider_tip) - discount_amount
--
-- `price_fingerprint` + `pricing_version` are what place_order_v1 compares
-- against a fresh re-price; on mismatch it aborts with PRICE_CHANGED.
-- `address_snapshot` freezes the delivery address as placed.
-- -----------------------------------------------------------------------------
create table public.orders
(
  id uuid not null default gen_random_uuid(),
  order_number text not null,
  user_id uuid not null,
  status text not null default 'pending'::text,
  subtotal integer not null default 0,
  delivery_base_fee integer not null default 0,
  delivery_multiplier_bps integer not null default 10000,
  distance_km numeric(6,2),
  delivery_fee integer not null default 0,
  service_fee integer not null default 0,
  discount_amount integer not null default 0,
  voucher_code text,
  voucher_discount integer not null default 0,
  rider_tip integer not null default 0,
  rider_pay_total integer not null default 0,
  platform_revenue integer not null default 0,
  total integer not null default 0,
  currency character(3) not null default 'EGP'::bpchar,
  price_fingerprint text,
  pricing_version integer not null default 1,
  payment_method text,
  payment_channel text,
  payment_status text not null default 'unpaid'::text,
  payment_collected_at timestamp with time zone,
  payment_collected_by uuid,
  payment_reference text,
  payment_proof_path text,
  delivery_type text not null default 'delivery'::text,
  delivery_grouping text not null default 'together'::text,
  vendor_limit_applied smallint,
  address_id uuid,
  address_snapshot jsonb not null,
  delivery_latitude numeric(9,6),
  delivery_longitude numeric(9,6),
  delivery_geohash_prefix text,
  area_id uuid,
  is_contactless boolean not null default false,
  access_note text,
  scheduled_delivery_time timestamp with time zone,
  promised_delivery_at timestamp with time zone,
  eta_minutes integer,
  eta_maxutes integer,
  vendor_count integer not null default 0,
  item_count integer not null default 0,
  placed_at timestamp with time zone not null default now(),
  confirmed_at timestamp with time zone,
  first_picked_up_at timestamp with time zone,
  completed_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  cancellation_reason text,
  cancellation_actor_id uuid,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  idempotency_key text,

  constraint orders_delivery_grouping_check check CHECK ((delivery_grouping = ANY (ARRAY['together'::text, 'separate'::text]))),
  constraint orders_delivery_multiplier_bps_check check CHECK ((delivery_multiplier_bps > 0)),
  constraint orders_delivery_type_check check CHECK ((delivery_type = ANY (ARRAY['delivery'::text, 'pickup'::text]))),
  constraint orders_distance_km_check check CHECK (((distance_km IS NULL) OR (distance_km >= (0)::numeric))),
  constraint orders_eta_maxutes_check check CHECK (((eta_maxutes IS NULL) OR (eta_maxutes > 0))),
  constraint orders_eta_minutes_check check CHECK (((eta_minutes IS NULL) OR (eta_minutes > 0))),
  constraint orders_eta_ordered check CHECK (((eta_minutes IS NULL) OR (eta_maxutes IS NULL) OR (eta_maxutes >= eta_minutes))),
  constraint orders_money_nonneg check CHECK (((subtotal >= 0) AND (delivery_fee >= 0) AND (service_fee >= 0) AND (discount_amount >= 0) AND (voucher_discount >= 0) AND (rider_tip >= 0) AND (rider_pay_total >= 0) AND (platform_revenue >= 0) AND (total >= 0))),
  constraint orders_order_number_key unique UNIQUE (order_number),
  constraint orders_payment_channel_check check CHECK ((payment_channel = ANY (ARRAY['cod'::text, 'vodafone_cash'::text, 'instapay'::text, 'gateway'::text]))),
  constraint orders_payment_method_check check CHECK ((payment_method = ANY (ARRAY['cash'::text, 'wallet'::text]))),
  constraint orders_payment_pair check CHECK ((((payment_method IS NULL) AND (payment_channel IS NULL)) OR ((payment_method IS NOT NULL) AND (payment_channel IS NOT NULL)))),
  constraint orders_payment_status_check check CHECK ((payment_status = ANY (ARRAY['unpaid'::text, 'collected'::text, 'failed'::text, 'refunded'::text]))),
  constraint orders_pkey primary key PRIMARY KEY (id),
  constraint orders_status_check check CHECK ((status = ANY (ARRAY['pending'::text, 'partially_confirmed'::text, 'preparing'::text, 'ready'::text, 'picked_up'::text, 'delivering'::text, 'delivered'::text, 'partially_cancelled'::text, 'cancelled'::text]))),
  constraint orders_total_consistent check CHECK ((total = ((((subtotal + delivery_fee) + service_fee) + rider_tip) - discount_amount))),
  constraint orders_voucher_within_discount check CHECK ((voucher_discount <= discount_amount))
);

-- -----------------------------------------------------------------------------
-- sub_orders: one row per vendor inside an order. This is the unit the vendor
-- accepts, prepares and is paid for. UNIQUE (order_id, vendor_id) means a
-- vendor appears at most once per checkout even if the customer added items
-- from it in several batches.
--
-- Settlement fields: commission_amount / platform_fee_amount /
-- vendor_net_payout are what the payout runs consume. `settlement_status`
-- gates the money: a sub_order can only carry a payout_id once it is
-- 'settled' or 'in_payout'.
-- -----------------------------------------------------------------------------
create table public.sub_orders
(
  id uuid not null default gen_random_uuid(),
  order_id uuid not null,
  vendor_id uuid not null,
  sequence smallint not null,
  status text not null default 'pending'::text,
  subtotal integer not null default 0,
  delivery_fee_share integer not null default 0,
  service_fee_share integer not null default 0,
  discount_share integer not null default 0,
  commission_amount integer not null default 0,
  platform_fee_amount integer not null default 0,
  vendor_net_payout integer not null default 0,
  menu_version_snapshot integer,
  prep_estimate_minutes integer not null default 20,
  prep_actual_minutes integer,
  ready_at timestamp with time zone,
  accepted_at timestamp with time zone,
  preparing_at timestamp with time zone,
  picked_up_at timestamp with time zone,
  delivered_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  cancellation_reason text,
  cancellation_actor text,
  rejection_reason text,
  settlement_status text not null default 'payable'::text,
  payout_id uuid,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),

  constraint sub_orders_cancellation_actor_check check CHECK ((cancellation_actor = ANY (ARRAY['customer'::text, 'vendor'::text, 'admin'::text, 'system'::text]))),
  constraint sub_orders_money_nonneg check CHECK (((subtotal >= 0) AND (delivery_fee_share >= 0) AND (service_fee_share >= 0) AND (discount_share >= 0) AND (commission_amount >= 0) AND (platform_fee_amount >= 0) AND (vendor_net_payout >= 0))),
  constraint sub_orders_order_id_vendor_id_key unique UNIQUE (order_id, vendor_id),
  constraint sub_orders_payout_only_when_settled check CHECK (((payout_id IS NULL) OR (settlement_status = ANY (ARRAY['settled'::text, 'in_payout'::text])))),
  constraint sub_orders_pkey primary key PRIMARY KEY (id),
  constraint sub_orders_prep_actual_minutes_check check CHECK (((prep_actual_minutes IS NULL) OR (prep_actual_minutes >= 0))),
  constraint sub_orders_prep_estimate_minutes_check check CHECK ((prep_estimate_minutes > 0)),
  constraint sub_orders_sequence_check check CHECK ((sequence > 0)),
  constraint sub_orders_settlement_status_check check CHECK ((settlement_status = ANY (ARRAY['payable'::text, 'in_payout'::text, 'settled'::text, 'void'::text]))),
  constraint sub_orders_status_check check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'preparing'::text, 'ready'::text, 'picked_up'::text, 'delivering'::text, 'delivered'::text, 'rejected'::text, 'cancelled'::text])))
);

-- -----------------------------------------------------------------------------
-- order_items: the priced lines. `item_name`, `unit_price`, `total_price` and
-- `selected_options` are frozen at placement — a later menu edit must never
-- rewrite history. `menu_item_id` is SET NULL on delete so the line survives.
--
-- item_status carries vendor-side exceptions that are NOT cancellations:
-- out_of_stock, price_updated, limited_stock, replacement.
-- -----------------------------------------------------------------------------
create table public.order_items
(
  id uuid not null default gen_random_uuid(),
  sub_order_id uuid not null,
  order_id uuid not null,
  vendor_id uuid not null,
  menu_item_id uuid,
  item_name text not null,
  item_name_ar text,
  image_path text,
  quantity integer not null,
  unit_price integer not null,
  total_price integer not null,
  selected_options jsonb not null default '[]'::jsonb,
  special_instructions text,
  item_status text not null default 'confirmed'::text,
  created_at timestamp with time zone not null default now(),
  selected_size_id uuid,
  selected_size_name text,
  selected_size_price integer,

  constraint order_items_item_status_check check CHECK ((item_status = ANY (ARRAY['confirmed'::text, 'out_of_stock'::text, 'price_updated'::text, 'limited_stock'::text, 'replacement'::text]))),
  constraint order_items_pkey primary key PRIMARY KEY (id),
  constraint order_items_quantity_check check CHECK (((quantity > 0) AND (quantity <= 99))),
  constraint order_items_selected_options_check check CHECK ((jsonb_typeof(selected_options) = 'array'::text)),
  constraint order_items_total_consistent check CHECK ((total_price = (quantity * unit_price))),
  constraint order_items_total_price_check check CHECK ((total_price >= 0)),
  constraint order_items_unit_price_check check CHECK ((unit_price >= 0))
);

-- -----------------------------------------------------------------------------
-- order_status_history: append-only transition log. `actor_role` records WHO
-- moved the state, which is what the dispute and analytics queries read. A
-- transition that does not change state is rejected by CHECK.
-- -----------------------------------------------------------------------------
create table public.order_status_history
(
  id uuid not null default gen_random_uuid(),
  order_id uuid not null,
  sub_order_id uuid,
  from_status text,
  to_status text not null,
  actor_user_id uuid,
  actor_role text not null,
  reason text,
  metadata jsonb,
  created_at timestamp with time zone not null default now(),

  constraint order_history_transition_real check CHECK (((from_status IS NULL) OR (from_status <> to_status))),
  constraint order_status_history_actor_role_check check CHECK ((actor_role = ANY (ARRAY['customer'::text, 'rider'::text, 'vendor'::text, 'admin'::text, 'system'::text]))),
  constraint order_status_history_pkey primary key PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- order_modifications: post-placement edits (item removed/added, price change,
-- stock limit) with the before/after totals and whether the customer approved.
-- `difference_amount` is derived and CHECK-enforced.
-- -----------------------------------------------------------------------------
create table public.order_modifications
(
  id uuid not null default gen_random_uuid(),
  order_id uuid not null,
  sub_order_id uuid,
  order_item_id uuid,
  modification_type text not null,
  original_total integer not null,
  new_total integer not null,
  difference_amount integer not null,
  reason text,
  customer_approved boolean,
  actor_user_id uuid,
  created_at timestamp with time zone not null default now(),

  constraint order_mod_difference_consistent check CHECK ((difference_amount = (new_total - original_total))),
  constraint order_modifications_modification_type_check check CHECK ((modification_type = ANY (ARRAY['item_removed'::text, 'item_added'::text, 'price_updated'::text, 'stock_limited'::text]))),
  constraint order_modifications_new_total_check check CHECK ((new_total >= 0)),
  constraint order_modifications_original_total_check check CHECK ((original_total >= 0)),
  constraint order_modifications_pkey primary key PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- order_eta_snapshots: promised-vs-predicted ETA over time, so late delivery can
-- be measured after the fact instead of guessed at.
-- -----------------------------------------------------------------------------
create table public.order_eta_snapshots
(
  id uuid not null default gen_random_uuid(),
  order_id uuid not null,
  sub_order_id uuid,
  promised_at timestamp with time zone not null,
  predicted_at timestamp with time zone not null,
  computed_at timestamp with time zone not null default now(),

  constraint order_eta_snapshots_pkey primary key PRIMARY KEY (id)
);