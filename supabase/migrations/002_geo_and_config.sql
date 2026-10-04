-- 002_geo_and_config.sql
-- Geography and global configuration. Schema only, no seed data (see 002s).

-- ---------------------------------------------------------------------------
-- cities
-- One operating city at a time, but the model holds many. Nothing in the app may hardcode a
-- city, a timezone or a currency: the operating city is a row, marked is_primary.
-- ---------------------------------------------------------------------------
create table cities (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  name          text not null,
  name_ar       text not null,
  country_code  char(2) not null,
  timezone      text not null,          -- IANA. Required, with no default: a wrong timezone
                                          -- silently corrupts vendor opening hours.
  center_lat    numeric(9,6) not null,
  center_lng    numeric(9,6) not null,
  currency      char(3) not null default 'EGP',
  is_active     boolean not null default true,
  is_primary    boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Exactly one operating city. Partial unique index, so zero or two is impossible.
create unique index cities_one_primary on cities (is_primary) where is_primary;

-- ---------------------------------------------------------------------------
-- areas
-- A named neighbourhood. This table replaces the brief's vendors.area_ids JSON array, which
-- cannot be indexed and would force a sequential scan on the hottest query in the product:
-- "which vendors serve this address?" (ADR 15)
-- ---------------------------------------------------------------------------
create table areas (
  id             uuid primary key default gen_random_uuid(),
  city_id        uuid not null references cities(id),
  slug           text not null,
  name           text not null,
  name_ar        text not null,
  geohash_prefix text not null,          -- 5 chars is about 4.9km x 4.9km
  center_lat     numeric(9,6) not null,
  center_lng     numeric(9,6) not null,
  radius_km      numeric(5,2) not null default 3.0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (city_id, slug)
);
create index on areas (geohash_prefix);
create index on areas (city_id) where is_active;

-- ---------------------------------------------------------------------------
-- delivery_zones
-- The delivery base fee, free radius, per-km fee and vendor cap all live here and are
-- admin-editable at runtime. No money constant is hardcoded in any function body
-- (constitution rule 7).
-- ---------------------------------------------------------------------------
create table delivery_zones (
  id                    uuid primary key default gen_random_uuid(),
  city_id               uuid not null references cities(id),
  area_id               uuid not null references areas(id),
  name                  text not null,
  name_ar               text not null,

  currency              char(3) not null default 'EGP',
  delivery_base_fee     integer not null default 2500 check (delivery_base_fee >= 0),
  free_radius_km        numeric(5,2) not null default 5.00,
  per_km_fee            integer not null default 200,
  max_vendors_per_order smallint not null default 3 check (max_vendors_per_order between 1 and 10),
  min_order_value       integer not null default 0,
  max_distance_km       numeric(5,2) not null default 12,
  peak_hours            int4range,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index on delivery_zones (area_id) where is_active;
create index on delivery_zones (city_id);

-- ---------------------------------------------------------------------------
-- delivery_fee_tiers
-- The per-vendor multiplier:  delivery_fee = base * multiplier_bps / 10000
-- Basis points, never a float. 10000 = x1.00, 11000 = x1.10, 12000 = x1.20. (ADR 4)
-- ---------------------------------------------------------------------------
create table delivery_fee_tiers (
  zone_id        uuid not null references delivery_zones(id) on delete cascade,
  vendor_count   smallint not null check (vendor_count between 1 and 10),
  multiplier_bps integer not null check (multiplier_bps between 0 and 100000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (zone_id, vendor_count)
);

-- ---------------------------------------------------------------------------
-- settings
-- Global configuration, including every money constant. Kept as rows so a rebrand or a fee
-- change is an UPDATE, not a release.
-- ---------------------------------------------------------------------------
create table settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id)
);

-- updated_by is an audit column, rarely joined, but Postgres does not auto-index foreign
-- keys and an auth.users delete would otherwise scan this table. (data-model.md 14.2)
create index on settings (updated_by) where updated_by is not null;
