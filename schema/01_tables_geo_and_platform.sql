-- =============================================================================
-- 01_tables_geo_and_platform.sql
-- Geo hierarchy + platform-level configuration.
-- Source: live database (pg_class / pg_attribute / pg_constraint).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- cities: the delivery city. One city is flagged `is_primary`; the app is
-- single-city-first but the schema allows more than one.
-- -----------------------------------------------------------------------------
create table public.cities
(
  id uuid not null default gen_random_uuid(),
  code text not null,
  name text not null,
  name_ar text not null,
  country_code character(2) not null,
  timezone text not null,
  center_lat numeric(9,6) not null,
  center_lng numeric(9,6) not null,
  currency character(3) not null default 'EGP'::bpchar,
  is_active boolean not null default true,
  is_primary boolean not null default false,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint cities_code_key unique UNIQUE (code),
  constraint cities_pkey primary key PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- areas: named neighbourhoods inside a city. `geohash_prefix` is the spatial
-- join key used to match an address to an area without a point-in-polygon test.
-- -----------------------------------------------------------------------------
create table public.areas
(
  id uuid not null default gen_random_uuid(),
  city_id uuid not null,
  slug text not null,
  name text not null,
  name_ar text not null,
  geohash_prefix text not null,
  center_lat numeric(9,6) not null,
  center_lng numeric(9,6) not null,
  radius_km numeric(5,2) not null default 3.0,
  is_active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint areas_city_id_slug_key unique UNIQUE (city_id, slug),
  constraint areas_pkey primary key PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- delivery_zones: the money-and-policy unit. Every fee constant used in
-- pricing lives here, never as a literal in application code.
-- -----------------------------------------------------------------------------
create table public.delivery_zones
(
  id uuid not null default gen_random_uuid(),
  city_id uuid not null,
  area_id uuid not null,
  name text not null,
  name_ar text not null,
  currency character(3) not null default 'EGP'::bpchar,
  delivery_base_fee integer not null default 2500,
  free_radius_km numeric(5,2) not null default 5.00,
  per_km_fee integer not null default 200,
  max_vendors_per_order smallint not null default 3,
  min_order_value integer not null default 0,
  max_distance_km numeric(5,2) not null default 12,
  peak_hours int4range,
  is_active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint delivery_zones_delivery_base_fee_check check CHECK ((delivery_base_fee >= 0)),
  constraint delivery_zones_max_vendors_per_order_check check CHECK (((max_vendors_per_order >= 1) AND (max_vendors_per_order <= 10))),
  constraint delivery_zones_pkey primary key PRIMARY KEY (id),
  constraint max_vendors_per_order_range check CHECK (((max_vendors_per_order >= 1) AND (max_vendors_per_order <= 10))),
  constraint min_order_value_nonneg check CHECK ((min_order_value >= 0)),
  constraint per_km_fee_nonneg check CHECK ((per_km_fee >= 0))
);

-- -----------------------------------------------------------------------------
-- delivery_fee_tiers: per-zone delivery-fee multiplier by number of vendors in
-- the basket. Multipliers are basis points (10000 = 1.00x). Enforced
-- monotonically increasing as vendor_count rises (trigger).
-- -----------------------------------------------------------------------------
create table public.delivery_fee_tiers
(
  zone_id uuid not null,
  vendor_count smallint not null,
  multiplier_bps integer not null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint delivery_fee_tiers_multiplier_bps_check check CHECK (((multiplier_bps >= 0) AND (multiplier_bps <= 100000))),
  constraint delivery_fee_tiers_pkey primary key PRIMARY KEY (zone_id, vendor_count),
  constraint delivery_fee_tiers_vendor_count_check check CHECK (((vendor_count >= 1) AND (vendor_count <= 10)))
);

-- -----------------------------------------------------------------------------
-- settings: global key/value configuration. `value` is jsonb so booleans,
-- numbers and strings all round-trip; readers coerce with private.setting_*().
-- -----------------------------------------------------------------------------
create table public.settings
(
  key text not null,
  value jsonb not null,
  description text,
  updated_at timestamp with time zone not null default now(),
  updated_by uuid,
  deleted_at timestamp with time zone,

  constraint settings_pkey primary key PRIMARY KEY (key)
);

-- -----------------------------------------------------------------------------
-- feature_flags: remote config with an explicit value_type so the client knows
-- how to parse, plus optional targeting_rules evaluated server-side by
-- get_flags_v1(app_role, app_version).
-- -----------------------------------------------------------------------------
create table public.feature_flags
(
  id uuid not null default gen_random_uuid(),
  flag_key text not null,
  value_type text not null,
  value jsonb not null,
  targeting_rules jsonb not null default '{}'::jsonb,
  description text,
  is_active boolean not null default true,
  updated_at timestamp with time zone not null default now(),
  updated_by uuid,
  deleted_at timestamp with time zone,

  constraint feature_flags_flag_key_key unique UNIQUE (flag_key),
  constraint feature_flags_pkey primary key PRIMARY KEY (id),
  constraint feature_flags_value_type_check check CHECK ((value_type = ANY (ARRAY['bool'::text, 'string'::text, 'number'::text, 'json'::text])))
);