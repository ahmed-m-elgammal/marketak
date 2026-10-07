-- =============================================================================
-- 06_tables_delivery.sql
-- Riders, shifts, location pings, dispatch assignments and rider pay rules.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- riders: the courier. `user_id` is optional — a rider can exist and be paid
-- out before (or without) an app account. `cash_held` is the money the rider is
-- currently carrying for cash-on-delivery orders; it is the float the platform
-- tracks, never a customer wallet.
--
-- `is_online` is kept exactly consistent with `status` by CHECK.
-- -----------------------------------------------------------------------------
create table public.riders
(
  id uuid not null default gen_random_uuid(),
  user_id uuid,
  first_name text not null,
  last_name text,
  phone_number text not null,
  country_code character(2) not null,
  vehicle_type text not null,
  vehicle_plate text,
  status text not null default 'offline'::text,
  is_active boolean not null default true,
  is_verified boolean not null default false,
  is_online boolean not null default false,
  current_latitude numeric(9,6),
  current_longitude numeric(9,6),
  current_geohash text,
  last_location_at timestamp with time zone,
  home_area_id uuid,
  rating_avg numeric(3,2) not null default 0,
  rating_count integer not null default 0,
  max_cash_held integer,
  cash_held integer not null default 0,
  completed_deliveries integer not null default 0,
  cancelled_deliveries integer not null default 0,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),

  constraint riders_cash_held_nonneg check CHECK ((cash_held >= 0)),
  constraint riders_counts_nonneg check CHECK (((rating_count >= 0) AND (completed_deliveries >= 0) AND (cancelled_deliveries >= 0))),
  constraint riders_is_online_consistent check CHECK ((is_online = (status <> 'offline'::text))),
  constraint riders_latitude_range check CHECK (((current_latitude IS NULL) OR ((current_latitude >= ('-90'::integer)::numeric) AND (current_latitude <= (90)::numeric)))),
  constraint riders_location_has_time check CHECK ((((current_latitude IS NULL) AND (current_longitude IS NULL) AND (last_location_at IS NULL)) OR ((current_latitude IS NOT NULL) AND (current_longitude IS NOT NULL) AND (last_location_at IS NOT NULL)))),
  constraint riders_longitude_range check CHECK (((current_longitude IS NULL) OR ((current_longitude >= ('-180'::integer)::numeric) AND (current_longitude <= (180)::numeric)))),
  constraint riders_max_cash_held_nonneg check CHECK (((max_cash_held IS NULL) OR (max_cash_held >= 0))),
  constraint riders_phone_number_key unique UNIQUE (phone_number),
  constraint riders_pkey primary key PRIMARY KEY (id),
  constraint riders_rating_range check CHECK (((rating_avg >= (0)::numeric) AND (rating_avg <= (5)::numeric))),
  constraint riders_status_check check CHECK ((status = ANY (ARRAY['offline'::text, 'available'::text, 'assigned'::text, 'on_break'::text]))),
  constraint riders_vehicle_type_check check CHECK ((vehicle_type = ANY (ARRAY['car'::text, 'bicycle'::text, 'motorcycle'::text, 'scooter'::text])))
);

-- -----------------------------------------------------------------------------
-- driver_shifts: when a rider is on duty and in which areas. Dispatch reads
-- this to build the candidate set; the RPCs only offer work inside a shift.
-- -----------------------------------------------------------------------------
create table public.driver_shifts
(
  id uuid not null default gen_random_uuid(),
  rider_id uuid not null,
  starts_at timestamp with time zone not null,
  ends_at timestamp with time zone not null,
  area_ids uuid[] not null default '{}'::uuid[],
  is_active boolean not null default true,
  created_at timestamp with time zone not null default now(),

  constraint driver_shifts_pkey primary key PRIMARY KEY (id),
  constraint driver_shifts_window_valid check CHECK ((ends_at > starts_at))
);

-- -----------------------------------------------------------------------------
-- rider_location_pings: high-volume position history for an active delivery.
-- `recorded_at` may be up to 5 minutes in the future to tolerate device clock
-- skew; it is pruned by private.prune_rider_location_pings().
-- -----------------------------------------------------------------------------
create table public.rider_location_pings
(
  id bigint not null default nextval('rider_location_pings_id_seq'::regclass),
  order_id uuid not null,
  rider_id uuid not null,
  latitude numeric(9,6) not null,
  longitude numeric(9,6) not null,
  heading numeric(5,2),
  speed_kmh numeric(6,2),
  accuracy_m numeric(6,2),
  recorded_at timestamp with time zone not null default now(),

  constraint rider_location_pings_accuracy_nonneg check CHECK (((accuracy_m IS NULL) OR (accuracy_m >= (0)::numeric))),
  constraint rider_location_pings_heading_range check CHECK (((heading IS NULL) OR ((heading >= (0)::numeric) AND (heading <= (360)::numeric)))),
  constraint rider_location_pings_latitude_range check CHECK (((latitude >= ('-90'::integer)::numeric) AND (latitude <= (90)::integer)::numeric))),
  constraint rider_location_pings_longitude_range check CHECK (((longitude >= ('-180'::integer)::numeric) AND (longitude <= (180)::integer)::numeric))),
  constraint rider_location_pings_not_future check CHECK ((recorded_at <= (now() + '00:05:00'::interval))),
  constraint rider_location_pings_pkey primary key PRIMARY KEY (id),
  constraint rider_location_pings_speed_nonneg check CHECK (((speed_kmh IS NULL) OR (speed_kmh >= (0)::numeric)))
);

-- -----------------------------------------------------------------------------
-- delivery_assignments: the dispatch leg. One row per trip. `stop_sequence`
-- holds the ordered pickup/drop-off plan as jsonb (a multi-vendor order has
-- several vendor stops before one customer stop).
--
-- It also carries the money the rider moved:
--   collected_amount / collection_method / collection_channel  — cash collected
--   rider_pay_base + rider_pay_distance + rider_pay_bonus = rider_pay_total
--
-- All three payer columns must be present or all absent together.
-- -----------------------------------------------------------------------------
create table public.delivery_assignments
(
  id uuid not null default gen_random_uuid(),
  order_id uuid not null,
  sub_order_id uuid,
  rider_id uuid,
  status text not null default 'unassigned'::text,
  stop_sequence jsonb,
  assigned_by text not null default 'system'::text,
  assigned_at timestamp with time zone,
  claimed_at timestamp with time zone,
  arrived_vendor_at timestamp with time zone,
  picked_up_at timestamp with time zone,
  arrived_at timestamp with time zone,
  delivered_at timestamp with time zone,
  distance_km numeric(6,2),
  eta_minutes integer,
  rider_pay_base integer,
  rider_pay_distance integer,
  rider_pay_bonus integer,
  rider_pay_total integer,
  platform_revenue integer,
  collected_amount integer,
  collection_method text,
  collection_channel text,
  collection_reference text,
  proof_path text,
  signature_path text,
  failure_reason text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),

  constraint delivery_assignments_assigned_by_check check CHECK ((assigned_by = ANY (ARRAY['system'::text, 'rider_claim'::text, 'admin'::text]))),
  constraint delivery_assignments_claimed_has_time check CHECK (((assigned_by IS DISTINCT FROM 'rider_claim'::text) OR ((rider_id IS NOT NULL) AND (claimed_at IS NOT NULL)))),
  constraint delivery_assignments_collection_channel_check check CHECK ((collection_channel = ANY (ARRAY['cod'::text, 'vodafone_cash'::text, 'instapay'::text]))),
  constraint delivery_assignments_collection_method_check check CHECK ((collection_method = ANY (ARRAY['cash'::text, 'wallet'::text, 'none'::text]))),
  constraint delivery_assignments_collection_none_is_zero check CHECK (((collection_method IS DISTINCT FROM 'none'::text) OR (COALESCE(collected_amount, 0) = 0))),
  constraint delivery_assignments_collection_pair check CHECK ((((collection_method IS NULL) AND (collection_channel IS NULL) AND (collected_amount IS NULL)) OR ((collection_method IS NOT NULL) AND (collection_channel IS NOT NULL)))),
  constraint delivery_assignments_distance_valid check CHECK (((distance_km IS NULL) OR (distance_km >= (0)::numeric))),
  constraint delivery_assignments_eta_positive check CHECK (((eta_minutes IS NULL) OR (eta_minutes > 0))),
  constraint delivery_assignments_pkey primary key PRIMARY KEY (id),
  constraint delivery_assignments_rider_pay_nonneg check CHECK ((((rider_pay_base IS NULL) OR (rider_pay_base >= 0)) AND ((rider_pay_distance IS NULL) OR (rider_pay_distance >= 0)) AND ((rider_pay_bonus IS NULL) OR (rider_pay_bonus >= 0)) AND ((rider_pay_total IS NULL) OR (rider_pay_total >= 0)) AND ((platform_revenue IS NULL) OR (platform_revenue >= 0)) AND ((collected_amount IS NULL) OR (collected_amount >= 0)))),
  constraint delivery_assignments_rider_pay_sums check CHECK (((rider_pay_total IS NULL) OR (rider_pay_base IS NULL) OR (rider_pay_total = ((rider_pay_base + COALESCE(rider_pay_distance, 0)) + COALESCE(rider_pay_bonus, 0))))),
  constraint delivery_assignments_status_check check CHECK ((status = ANY (ARRAY['unassigned'::text, 'assigned'::text, 'at_first_vendor'::text, 'picking_up'::text, 'picked_up'::text, 'delivering'::text, 'arrived'::text, 'delivered'::text, 'failed'::text, 'cancelled'::text])))
);

-- -----------------------------------------------------------------------------
-- rider_pay_rules: time-bounded pay configuration. `rider_id IS NULL` means
-- the city-wide default; a rider-specific row overrides it. Resolution is
-- private.pay_rule_for(). All amounts are configuration, never literals.
-- -----------------------------------------------------------------------------
create table public.rider_pay_rules
(
  id uuid not null default gen_random_uuid(),
  city_id uuid not null,
  rider_id uuid,
  per_trip_amount integer not null default 0,
  per_km_amount integer not null default 0,
  pct_of_delivery_fee_bps integer not null default 10000,
  bonus_per_leg integer not null default 0,
  effective_from timestamp with time zone not null default now(),
  effective_until timestamp with time zone,
  is_active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),

  constraint rider_pay_rules_amounts_nonneg check CHECK (((per_trip_amount >= 0) AND (per_km_amount >= 0) AND (bonus_per_leg >= 0))),
  constraint rider_pay_rules_pct_in_range check CHECK (((pct_of_delivery_fee_bps >= 0) AND (pct_of_delivery_fee_bps <= 10000))),
  constraint rider_pay_rules_pkey primary key PRIMARY KEY (id),
  constraint rider_pay_rules_window_valid check CHECK (((effective_until IS NULL) OR (effective_until > effective_from)))
);