-- 004_vendors.sql
-- Vendors. One physical location each; a chain is N vendors sharing a brand_id (ADR 7).

create table brands (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  name_ar    text,
  logo_path  text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- vendors
-- The brief's vendors.area_ids and vendors.cuisine_types JSON arrays are GONE, replaced by
-- vendor_areas and vendor_cuisines, because a JSON array cannot be indexed and would force
-- a sequential scan on every vendor-availability check (ADR 15, constitution rule 13).
--
-- vendors.estimated_delivery_time_min / _max are also gone: a stored static number is wrong
-- at the lunch peak, which is the only time the number matters. ETA is derived (spec 2.6).
-- ---------------------------------------------------------------------------
create table vendors (
  id                  uuid primary key default gen_random_uuid(),
  slug                text not null unique,
  name                text not null,
  name_ar             text not null,
  legal_name          text,
  brand_id            uuid references brands(id),
  vertical_type       text not null check (vertical_type in
                        ('food','grocery','pharmacy','flowers','bakery','others')),
  city_id             uuid not null references cities(id),
  area_id             uuid not null references areas(id),   -- primary area, denormalised for indexing
  latitude            numeric(9,6) not null,
  longitude           numeric(9,6) not null,
  geohash_prefix      text not null,
  delivery_radius_km  numeric(4,2) not null default 8,

  -- operations
  is_open             boolean not null default false,     -- manual override
  is_busy             boolean not null default false,     -- manual pause
  auto_open           boolean not null default true,      -- respect vendor_schedules?
  is_approved         boolean not null default false,
  is_active           boolean not null default true,
  capacity_per_slot   integer,                            -- lunch order cap
  reject_rate         numeric(5,4) not null default 0,

  -- money. All nullable-means-inherit: a vendor row never overrides a zone rule unless it
  -- has to (constitution rule 7).
  delivery_fee_override integer,
  minimum_order_value   integer not null default 0,
  prep_time_minutes     integer not null default 15,
  prep_time_max_minutes integer not null default 30,

  -- trust
  rating_avg   numeric(3,2) not null default 0 check (rating_avg between 0 and 5),
  rating_count integer not null default 0,

  -- content
  menu_version  integer not null default 1,   -- bumped by any catalog change; invalidates snapshots
  logo_path     text,
  description   text,
  description_ar text,

  contact_phone    text,
  contact_landline text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index on vendors (city_id, is_open, deleted_at);
create index on vendors (geohash_prefix) where is_active;
create index on vendors (area_id, vertical_type) where is_active and is_approved;
create index on vendors (rating_avg desc) where is_active and is_approved;
create index on vendors (brand_id) where brand_id is not null;
create index on vendors (city_id) where is_active;

-- ---------------------------------------------------------------------------
-- vendor_areas
-- Replaces vendors.area_ids. Carries the per-vendor fee override and ETA range for that
-- area, so a zone fee is the default and a vendor can deviate explicitly.
-- ---------------------------------------------------------------------------
create table vendor_areas (
  vendor_id              uuid not null references vendors(id) on delete cascade,
  area_id                uuid not null references areas(id) on delete cascade,
  delivery_fee_override  integer,
  eta_minutes            integer not null default 20,
  eta_maxutes            integer not null default 40,
  is_active              boolean not null default true,
  primary key (vendor_id, area_id)
);
create index on vendor_areas (area_id) where is_active;

-- ---------------------------------------------------------------------------
-- vendor_schedules
-- SPLIT SHIFTS: multiple rows per day_of_week, distinguished by slot. A lunch-only vendor
-- is one row at 11:00-15:00. A vendor that also does dinner is two rows per day. This is
-- why (vendor_id, day_of_week, slot) is the unique key and not (vendor_id, day_of_week).
-- ---------------------------------------------------------------------------
create table vendor_schedules (
  id          uuid primary key default gen_random_uuid(),
  vendor_id   uuid not null references vendors(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 0 and 6),
  slot        smallint not null default 0,     -- 0 is the first shift of that day
  opens_at    time not null,
  closes_at   time not null,
  is_closed   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (closes_at > opens_at),
  unique (vendor_id, day_of_week, slot)
);
create index on vendor_schedules (vendor_id, day_of_week);

-- ---------------------------------------------------------------------------
-- vendor_holidays
-- ---------------------------------------------------------------------------
create table vendor_holidays (
  id           uuid primary key default gen_random_uuid(),
  vendor_id    uuid not null references vendors(id) on delete cascade,
  holiday_date date not null,
  reason       text,
  created_at   timestamptz not null default now(),
  unique (vendor_id, holiday_date)
);
create index on vendor_holidays (holiday_date);

-- ---------------------------------------------------------------------------
-- cuisines  (replaces vendors.cuisine_types)
-- ---------------------------------------------------------------------------
create table cuisines (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  name_ar    text not null,
  sort_order integer not null default 0
);

create table vendor_cuisines (
  vendor_id  uuid not null references vendors(id) on delete cascade,
  cuisine_id uuid not null references cuisines(id) on delete cascade,
  primary key (vendor_id, cuisine_id)
);
create index on vendor_cuisines (cuisine_id);

-- ---------------------------------------------------------------------------
-- vendor_staff
-- Many-to-many, so one person can work at two vendors without two accounts.
-- ---------------------------------------------------------------------------
create table vendor_staff (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references users(id) on delete cascade,
  vendor_id      uuid not null references vendors(id) on delete cascade,
  staff_role     text not null default 'staff'
                   check (staff_role in ('owner','manager','staff','cashier')),
  can_edit_menu   boolean not null default false,
  can_manage_orders boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (user_id, vendor_id)
);
create index on vendor_staff (vendor_id);

-- ---------------------------------------------------------------------------
-- vendor_earnings_daily
-- The "merchant earned today" view, materialised so the vendor dashboard is a single
-- indexed read rather than a live aggregation over orders.
-- ---------------------------------------------------------------------------
create table vendor_earnings_daily (
  vendor_id        uuid not null references vendors(id) on delete cascade,
  business_date    date not null,
  orders_count     integer not null default 0,
  cancelled_count  integer not null default 0,
  gross_sales      integer not null default 0,
  discounts        integer not null default 0,
  delivery_fees    integer not null default 0,
  commission       integer not null default 0,
  adjustments      integer not null default 0,
  net_payout       integer not null default 0,
  cash_collected   integer not null default 0,
  wallet_collected integer not null default 0,
  updated_at       timestamptz not null default now(),
  primary key (vendor_id, business_date)
);
