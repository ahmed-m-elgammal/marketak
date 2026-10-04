# Data Model — Spec 001

Postgres. Supabase conventions: `auth.users` for identity, `public` for business data, RLS on
every table in `public`.

## Conventions

| Rule | Value | Reason |
|---|---|---|
| Primary key | `uuid` with `gen_random_uuid()` default | Public, non-enumerable ids |
| Natural key | `order_number`, `voucher.code`, `users.phone_number` | Indexed, human-reachable |
| Money | `integer` piastres + `currency char(3)` | No float drift. 1 EGP = 100 piastres |
| Quantity | `integer` with `check (quantity > 0)` | No fractional items in v1 |
| Timestamps | `timestamptz`, UTC. Display conversion uses `cities.timezone` | No hardcoded region. One rule everywhere |
| Translatable text | `jsonb`, `{"ar": "...", "en": "..."}` | A third language needs no migration |
| Soft delete | `deleted_at timestamptz` on every business table | Archive, snapshot invalidation, incremental export |
| Change tracking | `updated_at timestamptz` maintained by trigger | Sync cursor, snapshot versioning |
| Money-adjacent sums | Never in a view the app can be trusted to compute | Always an RPC |
| JSONB | Only for shapes read whole | Anything filtered or joined is a column |

**Money helper.** Add once, use everywhere:

```sql
create or replace function public.format_money(piastres int, cur text = 'EGP')
returns text language sql immutable as $$
  select format('%s %s', trim(trailing '.' from trim(trailing '0' from (piastres::numeric / 100)::text)), cur);
$$;
```

---

## 1. Geography and cities

### `cities`

The operating city is data, never a constant in code. Seeded by an admin during onboarding; nothing
in the schema or the app assumes a particular city.

```sql
create table cities (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,                 -- 'CAI', 'ALX', …
  name          text not null,
  name_ar       text not null,
  country_code  char(2) not null,
  timezone      text not null,                        -- required, IANA. No default: a wrong
                                                     -- timezone silently corrupts opening hours
  center_lat    numeric(9,6) not null,
  center_lng    numeric(9,6) not null,
  currency      char(3) not null default 'EGP',
  is_active     boolean not null default true,
  is_primary    boolean not null default false,       -- exactly one: the operating city
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index cities_one_primary on cities (is_primary) where is_primary;
```

### `areas`

A named neighbourhood. Replaces the `vendors.area_ids` JSON array, which cannot be indexed and
would force a full table scan on every vendor-availability check.

```sql
create table areas (
  id             uuid primary key default gen_random_uuid(),
  city_id        uuid not null references cities(id),
  slug           text not null,
  name           text not null,
  name_ar        text not null,
  geohash_prefix text not null,          -- 'u4pruydqqvj' — 5 chars ≈ 4.9 km × 4.9 km
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
```

### `delivery_zones`

The **delivery base fee** and the **per-vendor multiplier** live here, both editable by an admin.
Nothing about the fee formula is hardcoded.

```sql
create table delivery_zones (
  id                    uuid primary key default gen_random_uuid(),
  city_id               uuid not null references cities(id),
  area_id               uuid not null references areas(id),
  name                  text not null,
  name_ar               text not null,

  -- money, all configurable per zone
  currency              char(3) not null default 'EGP',
  delivery_base_fee     integer not null default 2500 check (delivery_base_fee >= 0),  -- 25.00 EGP
  free_radius_km        numeric(5,2) not null default 5.00,   -- distance included in the base
  per_km_fee            integer not null default 200,        -- charged beyond free_radius_km
  max_vendors_per_order smallint not null default 3 check (max_vendors_per_order between 1 and 10),
  min_order_value       integer not null default 0,
  max_distance_km       numeric(5,2) not null default 12,
  peak_hours            int4range,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index on delivery_zones (area_id) where is_active;
```

### `delivery_fee_tiers`

The per-vendor multiplier. One row per vendor count.

| vendor_count | multiplier_bps | Delivery fee on a 25.00 base |
|---|---|---|
| 1 | 10000 | 25.00 |
| 2 | 11000 | 27.50 |
| 3 | 12000 | 30.00 |

```sql
create table delivery_fee_tiers (
  zone_id        uuid not null references delivery_zones(id) on delete cascade,
  vendor_count   smallint not null check (vendor_count between 1 and 10),
  multiplier_bps integer not null check (multiplier_bps between 0 and 100000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (zone_id, vendor_count)
);
```

Basis points, not a float. `10000` = ×1.00, `11000` = ×1.10, `12000` = ×1.20.

Seed rows, and they are only a starting point that an admin can change per zone:

```sql
insert into delivery_fee_tiers (zone_id, vendor_count, multiplier_bps)
select id, v.vendor_count, v.multiplier_bps
from delivery_zones z
cross join (values (1, 10000), (2, 11000), (3, 12000)) as v(vendor_count, multiplier_bps)
where z.is_active;
```

### `rider_pay_rules`

What the rider keeps per trip. Configurable per city and overridable per rider, with effective dates
so a pay change never rewrites history.

```sql
create table rider_pay_rules (
  id              uuid primary key default gen_random_uuid(),
  city_id         uuid not null references cities(id),
  rider_id        uuid references riders(id),        -- null = the city-wide default
  per_trip_amount integer not null default 0,
  per_km_amount   integer not null default 0,
  pct_of_delivery_fee_bps integer not null default 10000,  -- 10000 = rider keeps all of it
  bonus_per_leg   integer not null default 0,        -- extra per vendor pickup, multi-vendor trips
  effective_from  timestamptz not null default now(),
  effective_until timestamptz,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (effective_until is null or effective_until > effective_from)
);
create unique index rider_pay_rules_default on rider_pay_rules (city_id)
  where rider_id is null and is_active;
create index on rider_pay_rules (rider_id, is_active);
```

Resolution order at collection time: an active rule for this rider → else the active rule for the
city → else zero, which surfaces as an admin error rather than a silent free delivery.

### `settings`

Key-value configuration for values that are not fees. Replaces Firebase Remote Config as the
authoritative flag store.

```sql
create table settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id)
);
```

Seeded keys. Nothing here is hardcoded in an app; every one is admin-editable at runtime.

| Key | Seed value | Meaning |
|---|---|---|
| `platform_name` | `"Marketak"` | English brand. Shown in the app, in order emails and on the receipt |
| `platform_name_ar` | `"ماركتك"` | Arabic brand |
| `order_number_prefix` | `"MK"` | Order numbers read `MK-261004-7F3K9` |
| `default_country_code` | `"EG"` | |
| `currency` | `"EGP"` | 1 EGP = 100 piastres everywhere |
| `service_fee_enabled` | `false` | Activates the customer service fee |
| `service_fee_default` | `0` | Amount or basis points, per `service_fee_type` |
| `service_fee_type` | `"fixed"` | `fixed` or `percentage` |
| `vendor_commission_enabled` | `false` | Flipped in month 3–4. See the revenue table in `spec.md` §3.1 |
| `rider_commission_enabled` | `true` | The launch revenue line |
| `max_vendors_per_order` | `3` | Global ceiling; a zone may be lower, never higher |
| `rider_max_cash_held_default` | `250000` | 2,500 EGP. A rider row overrides it |
| `rider_cash_limit_warning_pct` | `80` | Warn the rider at 80% of the limit |

`platform_name` and `platform_name_ar` are rows rather than constants so a rebrand is an update, not
a release. Every app surface reads them at launch through `get_flags_v1` / `get_setting_v1`, and the
Arabic value is the default everywhere because it is the primary market language.

---

## 2. Identity

### `users`

Authentication is **Google and Apple only** — no email, no password. The phone number is collected
after first sign-in as part of profile completion, not as a credential.

```sql
create table users (
  id            uuid primary key references auth.users(id) on delete cascade,
  phone_number  text unique,                    -- E.164: +201xxxxxxxxx, NULL until completed
  email         text,                           -- carried from the OAuth provider, not a credential
  first_name    text,
  last_name     text,
  avatar_path   text,                           -- R2 path only
  preferred_language text not null default 'ar' check (preferred_language in ('ar','en')),
  country_code  char(2) not null default 'EG',
  profile_completed_at timestamptz,              -- the gate. See below
  is_active     boolean not null default true,
  last_seen_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,

  -- A completed profile always has a phone number. An incomplete one is allowed to lack it,
  -- because the row has to exist for the OAuth identity to attach to.
  constraint profile_phone_required
    check (profile_completed_at is null or phone_number is not null)
);
create index on users (last_seen_at desc) where is_active and profile_completed_at is not null;
```

**`users.id` has no default, deliberately.** `default auth.users(id)` is illegal — Postgres rejects
a column reference in a `DEFAULT` expression (`ERROR 0A000`). Found by applying migration 003 to a
live project rather than by reading it. The id arrives from a trigger instead:

```sql
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.users (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  insert into public.user_roles (user_id, role) values (new.id, 'customer')
  on conflict (user_id, role) do nothing;
  return new;
end $$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
```

The `customer` role is granted to every authenticated user because customer is the **base** role —
anyone can browse and order. Every other role is granted explicitly and never inherited.
`security definer` because the trigger writes on behalf of `supabase_auth_admin`; `search_path`
pinned to `''` per §13.2.

**The profile gate.** `phone_number` is logically required — the requirement is that a completed
user always has one — but it cannot be `NOT NULL` at the column level, because a user row is created
the moment someone signs in with Google or Apple, before they have given a phone number. The check
constraint encodes the real rule instead of a weaker one:

| State | `profile_completed_at` | `phone_number` | Can browse | Can order |
|---|---|---|---|---|
| Signed in, not completed | `null` | `null` | Yes | **No** |
| Completed | set | set | Yes | Yes |

Enforcement is in three places, because one is not enough:

1. `complete_profile_v1(p_first_name, p_last_name, p_phone)` is the only way to set
   `profile_completed_at`. It validates the phone against a unique index and sets the timestamp.
2. `place_order_v1` raises `PROFILE_INCOMPLETE` when the caller's `profile_completed_at is null`.
3. RLS denies `insert` on `orders` to anyone whose profile is incomplete, so even a direct
   PostgREST call cannot bypass the RPC.

The app's behaviour is a profile-completion screen on first launch, reachable again from settings.
It asks for name, phone and a first address. Address is not a database constraint — a completed
profile only strictly requires the phone — but the app treats the first address as part of
completion, because an order cannot be placed without one and a customer who reaches checkout and
is then asked for an address has already partly failed.

### `user_roles`

Many-to-many. A rider who orders food is one user with two roles.

```sql
create table user_roles (
  user_id    uuid not null references users(id) on delete cascade,
  role       text not null check (role in ('customer','rider','admin','support')),
  granted_at timestamptz not null default now(),
  granted_by uuid references users(id),
  primary key (user_id, role)
);
create index on user_roles (role);
```

### `user_auth_providers`

Google and Apple only.

```sql
create table user_auth_providers (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references users(id) on delete cascade,
  provider_type text not null check (provider_type in ('google','apple')),
  provider_id   text not null,                   -- the provider's stable subject id
  linked_at     timestamptz not null default now(),
  unique (provider_type, provider_id)
);
create index on user_auth_providers (user_id);
```

One person may link both a Google and an Apple identity to the same `users` row, which is the normal
case on iOS. `unique (provider_type, provider_id)` is what stops a second account being created for
the same identity — the account-linking step looks up by this pair first and only inserts a new
`users` row when it finds nothing.

**No email provider and no phone provider.** A phone number is a profile field, not a way in.

### `addresses`

```sql
create table addresses (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references users(id) on delete cascade,
  label                 text not null default 'home' check (label in ('home','work','other')),
  area_id               uuid references areas(id),
  geohash               text not null,                   -- 9 chars ≈ 150 m — for grouping, not display
  geohash_prefix        text not null,                   -- 5 chars — for zone lookup
  latitude              numeric(9,6) not null,
  longitude             numeric(9,6) not null,
  area_name             text,
  building              text,
  floor                 text,
  apartment             text,
  landmark              text,                            -- often the only navigable part of an address here
  delivery_instructions text,
  is_default            boolean not null default false,
  last_used_at          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);
create index on addresses (user_id, last_used_at desc) where deleted_at is null;
create index on addresses (geohash_prefix);
create index on addresses (area_id);
create unique index addresses_one_default on addresses (user_id)
  where is_default and deleted_at is null;
```

`landmark` is not in the original brief and is essential in Egypt: "4th floor, blue door, next to
the mosque" is how couriers actually navigate.

### `device_tokens`

```sql
create table device_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  token       text not null unique,
  platform    text not null check (platform in ('android','ios')),
  app_role    text not null check (app_role in ('customer','rider','admin')),  -- hint, not a permission
  app_version text,
  language    text not null default 'ar',
  last_seen_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
create index on device_tokens (user_id, app_role);
```

### `feature_flags`

Server-side, replacing Firebase Remote Config as the source of truth.

```sql
create table feature_flags (
  id             uuid primary key default gen_random_uuid(),
  flag_key       text not null unique,
  value_type     text not null check (value_type in ('bool','string','number','json')),
  value          jsonb not null,
  targeting_rules jsonb not null default '{}'::jsonb,
  description    text,
  is_active      boolean not null default true,
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id)
);
```

`targeting_rules` shape (public, non-authoritative — never a price, fee, or permission):

```json
{
  "roles": ["customer"],
  "city_codes": ["CAI"],
  "min_app_version": {"android": "1.4.0", "ios": "1.4.0"},
  "percentage": 25,
  "vendor_ids": ["..."]
}
```

Evaluation happens in SQL so one query returns the caller's resolved flags:

```sql
create or replace function public.get_flags_v1(p_app_role text, p_app_version text)
returns table (flag_key text, value jsonb)
language sql security definer set search_path = '' as $$
  select f.flag_key, f.value
  from public.feature_flags f
  where f.is_active
    and (f.targeting_rules->'roles' is null
         or p_app_role = any(array(select jsonb_array_elements_text(f.targeting_rules->'roles'))))
    and (f.targeting_rules->'min_app_version' is null
         or coalesce((f.targeting_rules->'min_app_version'->>p_app_version), '') = ''
         or p_app_version is null);
$$;
```

Seed keys: `live_tracking_enabled`, `wallet_enabled`, `cash_enabled`, `search_enabled`,
`reviews_enabled`, `maintenance_mode`, `maintenance_message_ar`, `maintenance_message_en`,
`min_app_version_android`, `min_app_version_ios`, `force_update`, `cdn_base_url`,
`driver_ping_interval_sec` (`15`), `driver_ping_min_distance_m` (`25`), `menu_cache_ttl_min`,
`combine_multi_vendor` (`true`), `max_vendors_per_order` (`5`).

---

## 3. Vendors

### `brands`

```sql
create table brands (
  id        uuid primary key default gen_random_uuid(),
  name      text not null,
  name_ar   text,
  logo_path text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

### `vendors`

```sql
create table vendors (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,
  name              text not null,
  name_ar           text not null,
  legal_name        text,
  brand_id          uuid references brands(id),
  vertical_type     text not null check (vertical_type in
                      ('food','grocery','pharmacy','flowers','bakery','others')),
  city_id           uuid not null references cities(id),
  area_id           uuid not null references areas(id),   -- primary area, for indexing
  latitude          numeric(9,6) not null,
  longitude         numeric(9,6) not null,
  geohash_prefix    text not null,
  delivery_radius_km numeric(4,2) not null default 8,

  -- operations
  is_open           boolean not null default false,      -- manual override
  is_busy           boolean not null default false,      -- manual pause
  is_approved       boolean not null default false,
  is_active         boolean not null default true,
  auto_open         boolean not null default true,       -- respect vendor_schedules?
  capacity_per_slot integer,                             -- lunch order cap
  reject_rate       numeric(5,4) not null default 0,

  -- money
  delivery_fee_override integer,                          -- null = use zone fee
  minimum_order_value   integer not null default 0,
  prep_time_minutes     integer not null default 15,
  prep_time_max_minutes integer not null default 30,

  -- trust
  rating_avg       numeric(3,2) not null default 0 check (rating_avg between 0 and 5),
  rating_count     integer not null default 0,

  -- content
  menu_version     integer not null default 1,            -- bumped on any catalog change
  logo_path        text,
  description      text,
  description_ar   text,

  contact_phone     text,
  contact_landline  text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);
create index on vendors (city_id, is_open, deleted_at);
create index on vendors (geohash_prefix) where is_active;
create index on vendors (area_id, vertical_type) where is_active and is_approved;
create index on vendors (rating_avg desc) where is_active and is_approved;
create index on vendors (brand_id) where brand_id is not null;
```

`delivery_radius_km`, `estimated_delivery_time_min`/`_max`, `is_busy`, `area_ids`,
`cuisine_types` and `brand_id` from the original brief are mapped as follows:

| Original | Replacement | Reason |
|---|---|---|
| `area_ids` (JSON array) | `vendor_areas` join + `vendors.area_id` primary | Must be indexable |
| `cuisine_types` (JSON array) | `vendor_cuisines` join | Must be filterable |
| `estimated_delivery_time_min` / `_max` | Derived: `prep_time_minutes` + `vendor_areas.eta_minutes`/`eta_max_minutes` + travel | A stored static number goes stale at lunch |
| `is_busy` | Kept, plus `auto_open` | Manual pause must override the schedule |
| `delivery_fee_base` | `vendors.delivery_fee_override` (null → zone) | Zone-first pricing with per-vendor override |
| `country_code` | On `cities`, not on `vendors` | One city at a time; denormalising it invites drift |

### `vendor_areas`

```sql
create table vendor_areas (
  vendor_id        uuid not null references vendors(id) on delete cascade,
  area_id          uuid not null references areas(id) on delete cascade,
  delivery_fee_override integer,
  eta_minutes      integer not null default 20,
  eta_maxutes      integer not null default 40,
  is_active        boolean not null default true,
  primary key (vendor_id, area_id)
);
create index on vendor_areas (area_id) where is_active;
```

### `vendor_schedules`

Split shifts supported: multiple rows per `day_of_week` with a `slot` ordinal.

```sql
create table vendor_schedules (
  id          uuid primary key default gen_random_uuid(),
  vendor_id   uuid not null references vendors(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 0 and 6),
  slot        smallint not null default 0,               -- 0 = first shift of the day
  opens_at    time not null,
  closes_at   time not null,
  is_closed   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (closes_at > opens_at),
  unique (vendor_id, day_of_week, slot)
);
create index on vendor_schedules (vendor_id, day_of_week);
```

A lunch-only vendor is `day_of_week = 1..5, opens_at = '11:00', closes_at = '15:00'`, or two rows
per day (`10:00–14:00` and `18:00–23:00`) for a vendor that also does dinner.

### `vendor_holidays`

```sql
create table vendor_holidays (
  id           uuid primary key default gen_random_uuid(),
  vendor_id    uuid not null references vendors(id) on delete cascade,
  holiday_date date not null,
  reason       text,
  created_at   timestamptz not null default now(),
  unique (vendor_id, holiday_date)
);
create index on vendor_holidays (holiday_date);
```

### `vendor_cuisines` and `cuisines`

```sql
create table cuisines (
  id       uuid primary key default gen_random_uuid(),
  code     text not null unique,     -- 'egyptian'
  name     text not null,
  name_ar  text not null,
  sort_order integer not null default 0
);

create table vendor_cuisines (
  vendor_id uuid not null references vendors(id) on delete cascade,
  cuisine_id uuid not null references cuisines(id) on delete cascade,
  primary key (vendor_id, cuisine_id)
);
create index on vendor_cuisines (cuisine_id);
```

### `vendor_staff`

```sql
create table vendor_staff (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users(id) on delete cascade,
  vendor_id  uuid not null references vendors(id) on delete cascade,
  staff_role text not null default 'staff' check (staff_role in ('owner','manager','staff','cashier')),
  can_edit_menu boolean not null default false,
  can_manage_orders boolean not null default true,
  created_at timestamptz not null default now(),
  unique (user_id, vendor_id)
);
create index on vendor_staff (vendor_id);
```

### `vendor_earnings_daily`

The "merchant earned today" view, materialised so the vendor dashboard is a single indexed read.

```sql
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
```

---

## 4. Catalog

### `menu_categories`

```sql
create table menu_categories (
  id            uuid primary key default gen_random_uuid(),
  vendor_id     uuid not null references vendors(id) on delete cascade,
  name          text not null,
  name_ar       text,
  display_order integer not null default 0,
  is_available  boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);
create index on menu_categories (vendor_id, display_order) where deleted_at is null;
```

### `menu_items`

`pricing_mode` makes the price/size relationship explicit and enforceable in a row-level `CHECK`:
`'fixed'` requires `base_price`; `'sized'` takes its prices from `menu_item_sizes` and may leave
`base_price` null, because the displayed price is the smallest available size and is derived.

```sql
create table menu_items (
  id                      uuid primary key default gen_random_uuid(),
  category_id             uuid not null references menu_categories(id) on delete cascade,
  vendor_id               uuid not null references vendors(id) on delete cascade,  -- denormalised
  name                    text not null,
  name_ar                 text,
  description             text,
  description_ar          text,

  pricing_mode            text not null default 'fixed'
                            check (pricing_mode in ('fixed','sized')),
  base_price              integer check (base_price is null or base_price >= 0),
  is_available            boolean not null default true,
  stock_count             integer check (stock_count is null or stock_count >= 0), -- null = unlimited

  preparation_time_minutes integer,
  image_path              text,
  display_order           integer not null default 0,

  -- metadata. Structured columns for anything filtered or sorted on; jsonb only for shapes
  -- that are always read whole (constitution rule 13).
  nutritional_info        jsonb,      -- {calories, protein_g, carbs_g, fat_g, sodium_mg}
  allergens               jsonb,      -- ["gluten","dairy",...]
  ingredients             jsonb,
  tags                    text[] not null default '{}',
  calories                integer,
  is_spicy                boolean not null default false,
  is_vegetarian           boolean not null default false,
  is_featured             boolean not null default false,
  is_new                  boolean not null default false,

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  deleted_at              timestamptz,

  -- row-level, so a CHECK can enforce it. The reverse direction is cross-table and needs a trigger.
  constraint fixed_item_has_price
    check (pricing_mode <> 'fixed' or base_price is not null)
);
create index on menu_items (vendor_id, is_available, display_order) where deleted_at is null;
create index on menu_items (category_id, display_order) where deleted_at is null;
create index on menu_items using gin (tags) where deleted_at is null;
```

`vendor_id` is duplicated from the category for two reasons: RLS policies need to filter items by
vendor without a join, and the cart and quote RPCs need `vendor_id` on the item row to group a
basket. A trigger keeps it consistent:

```sql
create or replace function public.sync_menu_item_vendor()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.vendor_id := (select c.vendor_id from public.menu_categories c where c.id = new.category_id);
  return new;
end $$;

create trigger trg_menu_item_vendor before insert or update of category_id on menu_items
for each row execute function public.sync_menu_item_vendor();
```

Name search is **not** indexed here. Migration 015 adds normalised generated columns plus trigram
indexes, because Arabic search needs diacritic and alef normalisation first, and an index on raw
`lower(name)` would never be used by that query.

### `menu_item_sizes`

**Sizes are not options.** A size is intrinsic to the item and carries a real price, so it is a row
here rather than an `item_options` entry with a `price_modifier`. The distinction matters in three
places: the kitchen ticket must print the size, price filtering needs a real price rather than
base + modifier, and reporting must separate "they chose a large" from "they added extra cheese".

```sql
create table menu_item_sizes (
  id            uuid primary key default gen_random_uuid(),
  item_id       uuid not null references menu_items(id) on delete cascade,
  name          text not null,
  name_ar       text,
  price         integer not null check (price >= 0),
  is_default    boolean not null default false,
  is_available  boolean not null default true,
  calories      integer,
  display_order integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on menu_item_sizes (item_id, display_order);

-- One default size per item.
create unique index menu_item_sizes_one_default on menu_item_sizes (item_id) where is_default;
```

### Sizing integrity — two rules a `CHECK` cannot express

Both cross tables, so neither is a row-level constraint.

| Rule | Mechanism | Behaviour |
|---|---|---|
| An item with `pricing_mode = 'sized'` must have at least one size | `deferrable initially deferred` constraint trigger on `menu_items` | **Rejects** at COMMIT, so an item and its sizes can be inserted in one transaction in any order |
| Deleting the last size of a `'sized'` item would leave it unsellable | `deferrable initially deferred` constraint trigger on `menu_item_sizes` | **Rejects** — `LAST_SIZE_REMOVED` |

Both reject, and deliberately so. The first version of the second rule *repaired* the item by
flipping it to `'fixed'` with `base_price = coalesce(base_price, 0)`, which is always `0`: a `sized`
item has `base_price` NULL by definition, so the "repair" produced a free, orderable item. There is
no correct price to invent. The vendor must either add a size or switch the item to `'fixed'` and
state a real price. **Refusing is the only honest option.**

```sql
create or replace function public.assert_item_has_sizes()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.pricing_mode = 'sized'
     and not exists (select 1 from public.menu_item_sizes where item_id = new.id) then
    raise exception 'ITEM_SIZED_BUT_NO_SIZES: %', new.id using errcode = 'P0001';
  end if;
  return null;
end $$;

create constraint trigger trg_item_has_sizes
  after insert or update on menu_items
  deferrable initially deferred
  for each row execute function public.assert_item_has_sizes();
```

### Snapshot invalidation

Any catalog write bumps `vendors.menu_version`, which changes the R2 snapshot URL and tells every
device its cached menu is stale.

**These triggers are statement-level, not row-level.** As `FOR EACH ROW` triggers, a 50-row catalog
import executed 50 separate `UPDATE vendors` statements against the same row. Statement-level
triggers with transition tables do the whole statement in one `UPDATE`; verified, a 50-row insert
now moves `menu_version` by exactly 1.

A transition table is only permitted on a trigger with a **single** event, so `INSERT` and `UPDATE`
each need their own trigger — five tables therefore need ten triggers, generated in a loop rather
than written out by hand.

```sql
create or replace function public.bump_version_for_categories()
returns trigger language plpgsql set search_path = '' as $$
begin
  update public.vendors v
     set menu_version = v.menu_version + 1, updated_at = now()
   where v.id in (select distinct nr.vendor_id from new_rows nr);
  return null;
end $$;

create or replace function public.bump_version_for_items()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- menu_items already carries the denormalised vendor_id, so this needs no join.
  update public.vendors v
     set menu_version = v.menu_version + 1, updated_at = now()
   where v.id in (select distinct nr.vendor_id from new_rows nr);
  return null;
end $$;

create or replace function public.bump_version_for_items_of()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- Shared by menu_item_sizes and item_options, which both reference menu_items by item_id.
  update public.vendors v
     set menu_version = v.menu_version + 1, updated_at = now()
   where v.id in (select distinct mi.vendor_id
                    from new_rows nr join public.menu_items mi on mi.id = nr.item_id);
  return null;
end $$;

create or replace function public.bump_version_for_choices()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- option_choices references item_options, which references menu_items: two hops.
  update public.vendors v
     set menu_version = v.menu_version + 1, updated_at = now()
   where v.id in (select distinct mi.vendor_id
                    from new_rows nr
                    join public.item_options io on io.id = nr.option_id
                    join public.menu_items mi on mi.id = io.item_id);
  return null;
end $$;

do $$
declare r record;
begin
  for r in select * from (values
      ('menu_categories',  'bump_version_for_categories'),
      ('menu_items',      'bump_version_for_items'),
      ('menu_item_sizes', 'bump_version_for_items_of'),
      ('item_options',    'bump_version_for_items_of'),
      ('option_choices',  'bump_version_for_choices')
    ) as t(tbl, fn)
  loop
    execute format('create trigger %I after insert on public.%I referencing new table as new_rows'
                   ' for each statement execute function public.%I()',
                   'trg_bump_v_' || r.tbl || '_ins', r.tbl, r.fn);
    execute format('create trigger %I after update on public.%I referencing new table as new_rows'
                   ' for each statement execute function public.%I()',
                   'trg_bump_v_' || r.tbl || '_upd', r.tbl, r.fn);
  end loop;
end $$;
```

### `item_options` — add-ons, **not** sizes

An option is a choice layered on top of the item: extra cheese, spice level, add a side. It carries
a `price_modifier`, not a price. `min`/`max` selections allow "choose exactly 1" and "choose up
to 3". Size selection is `menu_item_sizes`, never an option.

```sql
create table item_options (
  id             uuid primary key default gen_random_uuid(),
  item_id        uuid not null references menu_items(id) on delete cascade,
  name           text not null,
  name_ar        text,
  is_required    boolean not null default false,
  min_selections integer not null default 0,
  max_selections integer not null default 1,
  display_order  integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (max_selections >= min_selections),
  check (max_selections > 0 or min_selections = 0)
);
create index on item_options (item_id, display_order);
```

### `option_choices`

```sql
create table option_choices (
  id            uuid primary key default gen_random_uuid(),
  option_id     uuid not null references item_options(id) on delete cascade,
  name          text not null,
  name_ar       text,
  price_modifier integer not null default 0,
  is_default    boolean not null default false,
  is_available  boolean not null default true,
  stock_count   integer,
  calories      integer,
  display_order integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on option_choices (option_id, display_order);
```

Sizes and options both feed `menu_version`, so both are covered by the statement-level triggers in
**Snapshot invalidation** above.

---

## 5. Cart

The original brief had no cart table. Without one, a multi-vendor cart cannot survive app death,
device change, or an offline period — and a cart that vanishes mid-checkout is the fastest way to
lose an order.

### `carts`

```sql
create table carts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  is_active   boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index carts_one_active on carts (user_id) where is_active;
```

One active cart per user. A second device shares it.

### `cart_items`

```sql
create table cart_items (
  id                  uuid primary key default gen_random_uuid(),
  cart_id             uuid not null references carts(id) on delete cascade,
  vendor_id           uuid not null references vendors(id) on delete cascade,
  menu_item_id        uuid not null references menu_items(id) on delete cascade,
  quantity            integer not null check (quantity > 0),
  selected_options    jsonb not null default '[]'::jsonb,
  special_instructions text,
  display_snapshot    jsonb,               -- {name, name_ar, base_price} frozen for display
  cached_price        integer,             -- display estimate only, never authoritative
  cached_at           timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index on cart_items (cart_id);
create index on cart_items (vendor_id);
create index on cart_items (menu_item_id);
```

`cached_price` exists so the cart can render offline. It is never read by a quote or an order.
`display_snapshot` keeps the cart readable even after a vendor deletes a menu item, which is
exactly when a customer needs to understand what happened to their basket.

---

## 6. Orders — the multi-vendor core

### `orders` — the checkout envelope

```sql
create table orders (
  id                uuid primary key default gen_random_uuid(),
  order_number      text not null unique,               -- 'C-261004-7F3K9'
  user_id           uuid not null references users(id),

  -- aggregate status, derived. Never set directly.
  status            text not null default 'pending' check (status in (
                    'pending','partially_confirmed','preparing','ready',
                    'picked_up','delivering','delivered','partially_cancelled','cancelled')),

  -- money, whole checkout
  subtotal          integer not null default 0,
  delivery_base_fee integer not null default 0,   -- the zone base before the vendor multiplier
  delivery_multiplier_bps integer not null default 10000,  -- ×1.00, ×1.10, ×1.20 … frozen
  distance_km       numeric(6,2),
  delivery_fee      integer not null default 0,   -- base × multiplier + distance component
  service_fee       integer not null default 0,
  discount_amount   integer not null default 0,
  voucher_code      text,
  voucher_discount  integer not null default 0,
  rider_tip         integer not null default 0,
  rider_pay_total   integer not null default 0,   -- the rider's share of the delivery fee
  platform_revenue  integer not null default 0,   -- the rider cut + commission − any discounts
  total             integer not null default 0,
  currency          char(3) not null default 'EGP',
  price_fingerprint text,                        -- the quote this order was priced from
  pricing_version   integer not null default 1,

  -- payment: chosen at delivery, not checkout. The platform never holds customer money.
  payment_method        text check (payment_method in ('cash','wallet')),
  payment_channel       text check (payment_channel in
                          ('cod','vodafone_cash','instapay','gateway')),
  payment_status        text not null default 'unpaid'
                          check (payment_status in ('unpaid','collected','failed','refunded')),
  payment_collected_at  timestamptz,
  payment_collected_by  uuid references users(id),
  payment_reference     text,                    -- rider-recorded VF Cash / Instapay reference
  payment_proof_path    text,                    -- R2 private, optional

  -- delivery
  delivery_type     text not null default 'delivery' check (delivery_type in ('delivery','pickup')),
  delivery_grouping text not null default 'together' check (delivery_grouping in ('together','separate')),
  vendor_limit_applied smallint,                    -- the max_vendors_per_order in force at checkout
  address_id        uuid references addresses(id),
  address_snapshot  jsonb not null,                     -- frozen: the address at checkout
  delivery_latitude numeric(9,6),
  delivery_longitude numeric(9,6),
  delivery_geohash_prefix text,
  area_id           uuid references areas(id),
  is_contactless    boolean not null default false,
  access_note       text,
  scheduled_delivery_time timestamptz,
  promised_delivery_at    timestamptz,
  eta_minutes       integer,
  eta_maxutes       integer,

  -- lifecycle
  vendor_count      integer not null default 0,
  item_count        integer not null default 0,
  placed_at         timestamptz not null default now(),
  confirmed_at      timestamptz,
  first_picked_up_at timestamptz,
  completed_at      timestamptz,
  cancelled_at      timestamptz,
  cancellation_reason text,
  cancellation_actor_id uuid references users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (subtotal >= 0 and delivery_fee >= 0 and service_fee >= 0 and total >= 0)
);
create index on orders (user_id, placed_at desc);
create index on orders (status, placed_at desc);
create index on orders (placed_at desc);                -- analytics / retention sweeps
create index on orders (delivery_geohash_prefix, status);
create index on orders (area_id);
create index on orders (address_id);
```

`orders` has **no `vendor_id` and no `restaurant_id`.** That is the point of the whole redesign.

### `sub_orders` — one per vendor

```sql
create table sub_orders (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references orders(id) on delete cascade,
  vendor_id       uuid not null references vendors(id),
  sequence        smallint not null default 1,

  status          text not null default 'pending' check (status in (
                    'pending','accepted','preparing','ready','picked_up','delivering',
                    'delivered','rejected','cancelled')),

  -- money for this vendor only
  subtotal        integer not null default 0,
  delivery_fee_share  integer not null default 0,
  service_fee_share   integer not null default 0,
  discount_share      integer not null default 0,
  commission_amount   integer not null default 0,     -- 0 until activated
  platform_fee_amount integer not null default 0,
  vendor_net_payout   integer not null default 0,     -- what the merchant earns

  -- operational
  menu_version_snapshot integer,
  prep_estimate_minutes integer not null default 20,
  prep_actual_minutes   integer,
  ready_at        timestamptz,
  accepted_at     timestamptz,
  preparing_at    timestamptz,
  picked_up_at    timestamptz,
  delivered_at    timestamptz,
  cancelled_at    timestamptz,
  cancellation_reason text,
  cancellation_actor  text check (cancellation_actor in ('customer','vendor','admin','system')),
  rejection_reason    text,
  settlement_status   text not null default 'payable'
                       check (settlement_status in ('payable','in_payout','settled','void')),
  payout_id       uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (order_id, vendor_id)
);
create index on sub_orders (order_id);
create index on sub_orders (vendor_id, created_at desc);
create index on sub_orders (vendor_id, status) where status in ('pending','accepted','preparing','ready');
create index on sub_orders (settlement_status) where settlement_status = 'payable';
create index on sub_orders (payout_id) where payout_id is not null;
create index on sub_orders (status, created_at) where status in ('pending','accepted');
```

`settlement_status` is the hook that makes payout runs safe: a sub-order moves `payable →
in_payout → settled` in the same transaction that writes the ledger, so a payout can never be
issued twice, and a rejected sub-order is `void` and is never swept into a payout.

### `order_items`

```sql
create table order_items (
  id                  uuid primary key default gen_random_uuid(),
  sub_order_id        uuid not null references sub_orders(id) on delete cascade,
  order_id            uuid not null references orders(id) on delete cascade,  -- denormalised for feed queries
  vendor_id           uuid not null references vendors(id),
  menu_item_id        uuid references menu_items(id) on delete set null,     -- null if deleted later
  -- frozen snapshot
  item_name           text not null,
  item_name_ar        text,
  image_path          text,
  quantity            integer not null check (quantity > 0),
  unit_price          integer not null check (unit_price >= 0),
  total_price         integer not null,
  selected_options    jsonb not null default '[]'::jsonb,
  special_instructions text,
  item_status         text not null default 'confirmed' check (item_status in (
                        'confirmed','out_of_stock','price_updated','limited_stock','replacement')),
  created_at          timestamptz not null default now()
);
create index on order_items (sub_order_id);
create index on order_items (order_id);
create index on order_items (vendor_id);
create index on order_items (menu_item_id) where menu_item_id is not null;
```

`menu_item_id` is `on delete set null`: deleting a menu item must never damage order history.

### `order_status_history`

```sql
create table order_status_history (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references orders(id) on delete cascade,
  sub_order_id   uuid references sub_orders(id) on delete cascade,  -- null = order-level
  from_status    text,
  to_status      text not null,
  actor_user_id  uuid references users(id),
  actor_role     text not null check (actor_role in ('customer','rider','vendor','admin','system')),
  reason         text,
  metadata       jsonb,
  created_at     timestamptz not null default now()
);
create index on order_status_history (order_id, created_at);
create index on order_status_history (sub_order_id, created_at);
```

One row per transition. This table is a leading database-size consumer and is archived at 60 days
along with `order_items` — see `free-tier-plan.md` §4.

### `order_modifications`

```sql
create table order_modifications (
  id                  uuid primary key default gen_random_uuid(),
  order_id            uuid not null references orders(id) on delete cascade,
  sub_order_id        uuid references sub_orders(id) on delete cascade,
  order_item_id       uuid references order_items(id) on delete cascade,
  modification_type   text not null check (modification_type in
                        ('item_removed','item_added','price_updated','stock_limited')),
  original_total      integer not null,
  new_total           integer not null,
  difference_amount   integer not null,
  reason              text,
  customer_approved   boolean,
  actor_user_id       uuid references users(id),
  created_at          timestamptz not null default now()
);
create index on order_modifications (order_id);
create index on order_modifications (sub_order_id);
create index on order_modifications (order_item_id);
```

### Delivery-time projection

```sql
create table order_eta_snapshots (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references orders(id) on delete cascade,
  sub_order_id uuid references sub_orders(id) on delete cascade,
  promised_at  timestamptz not null,
  predicted_at timestamptz not null,
  computed_at  timestamptz not null default now()
);
create index on order_eta_snapshots (order_id, computed_at desc);
create index on order_eta_snapshots (sub_order_id) where sub_order_id is not null;
```

Used to measure whether quoted ETAs were honest. Without it, "were we late?" becomes an argument
instead of a query.

---

## 7. Money

### `commission_rules`

Vendor commission is **off at launch and switched on around month 3–4**. Rider commission is the
launch revenue line. Both live here, so activating either is a row update, never a migration.

```sql
create table commission_rules (
  id             uuid primary key default gen_random_uuid(),
  scope          text not null check (scope in ('vendor','rider','platform')),
  target_id      uuid,                       -- null = platform-wide default
  vertical_type  text,                       -- null = all verticals
  commission_type text not null check (commission_type in
                   ('percentage','fixed_amount','free_delivery','negative')),
  value          numeric(12,4) not null default 0,   -- percentage or piastres per commission_type
  min_amount     integer,
  max_amount     integer,
  applies_to     text not null default 'subtotal' check (applies_to in
                   ('subtotal','delivery_fee','service_fee','payout_total')),
  effective_from timestamptz not null default now(),
  effective_until timestamptz,
  is_active      boolean not null default false,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on commission_rules (scope, target_id, is_active);
```

**Seed rows reflect the launch strategy, not a neutral placeholder.**

```sql
-- Launch: the platform takes its revenue from the delivery fee, charged to the rider.
-- The rider keeps pct_of_delivery_fee_bps from rider_pay_rules; the remainder is platform revenue.
insert into commission_rules (scope, commission_type, value, applies_to, is_active)
values ('rider', 'percentage', 20, 'delivery_fee', true);

-- Month 3-4: commission on the items, charged to the vendor. Inactive until then.
insert into commission_rules (scope, commission_type, value, applies_to, is_active)
values ('vendor', 'percentage', 0, 'subtotal', false);
```

The two are independent. Turning the vendor rule on does not disturb the rider rule, and a vendor
who signs up mid-way is not retroactively charged, because `effective_from` defaults to the moment
the row is activated and `commission` is written per sub-order at that time.

`commission_type = 'negative'` exists for one case worth having early: a launch discount funded by
the platform rather than by the vendor, recorded as a negative vendor commission so the vendor's
payout is untouched and the cost lands where it belongs.

### `wallets`

A wallet belongs to a **vendor or a rider** — the two parties the platform owes money to. There is
**no customer wallet**: the customer pays the driver directly, in cash or by their own Vodafone
Cash / Instapay transfer, and the platform records that it happened. This removes the entire
top-up fraud surface and leaves no customer float to reconcile.

```sql
create table wallets (
  id           uuid primary key default gen_random_uuid(),
  owner_type   text not null check (owner_type in ('vendor','rider')),
  owner_id     uuid not null,
  balance      integer not null default 0,     -- cached; authoritative = sum(ledger_entries)
  currency     char(3) not null default 'EGP',
  status       text not null default 'active' check (status in ('active','frozen','review')),
  status_reason text,
  version      integer not null default 0,     -- optimistic concurrency
  updated_at   timestamptz not null default now(),
  unique (owner_type, owner_id)
);
create index on wallets (owner_type, owner_id);
```

`version` exists because a rider's wallet is credited by a payout while a vendor's is debited by an
adjustment, and both can be touched by two admins at once. An update goes `where version = $old`.

Funding a vendor or rider wallet is an **admin adjustment** through `adjust_wallet_v1`, which writes
a signed `ledger_entries` row carrying the admin's id, a mandatory reason and a reference. There is
no self-service path and no customer-facing top-up screen. For money integrity that is the whole
point: the only way to change a balance is an append-only entry with a named human behind it, and
`reconcile_day_v1` compares every balance against `platform_float` and the bank statement.

### `ledger_entries`

Append-only. Never updated, never deleted. Corrections are reversing entries.

```sql
create table ledger_entries (
  id              uuid primary key default gen_random_uuid(),
  account_type    text not null check (account_type in
                    ('vendor','rider','platform','platform_earnings')),
  account_id      uuid not null,               -- vendor_id, rider_id, or NULL for platform accounts
  entry_type      text not null check (entry_type in (
                    'rider_cut','cash_collected','cash_remitted','delivery_fee',
                    'service_fee','commission','refund','reversal',
                    'vendor_payout','rider_payout','adjustment','float_sweep')),
  signed_amount   integer not null,           -- positive = credit to the account
  currency        char(3) not null default 'EGP',
  order_id        uuid references orders(id),
  sub_order_id    uuid references sub_orders(id),
  payout_id       uuid references payouts(id),
  idempotency_key text not null unique,
  note            text,
  metadata        jsonb,
  created_at      timestamptz not null default now()
);
create index on ledger_entries (account_type, account_id, created_at desc);
create index on ledger_entries (order_id);
create index on ledger_entries (sub_order_id);
create index on ledger_entries (payout_id);
create index on ledger_entries (created_at);   -- retention / partition sweep
```

`account_type` has no `customer` value, because there is no customer account to hold a balance.
A customer's payment is recorded on the **order**, as `payment_method` plus `payment_channel`
(`vodafone_cash` or `instapay`) and the rider's confirmation — not as a movement of money the
platform holds.

`rider_cut` is the launch revenue line: the platform's share of `delivery_fee`, taken at collection
time and recognised immediately, because no third party is involved and nothing is owed onward.

Enforce append-only with a rule, so even a privileged mistake cannot rewrite history:

```sql
create rule ledger_no_update as on update to ledger_entries do instead nothing;
create rule ledger_no_delete as on delete to ledger_entries do instead nothing;
```

### `payouts` and `payout_lines`

```sql
create table payouts (
  id           uuid primary key default gen_random_uuid(),
  payout_type  text not null check (payout_type in ('vendor','rider')),
  account_id   uuid not null,
  period_start date not null,
  period_end   date not null,
  gross_amount integer not null default 0,
  fee_amount   integer not null default 0,
  net_amount   integer not null default 0,
  currency     char(3) not null default 'EGP',
  method       text,                          -- 'vodafone_cash','instapay','cash'
  status       text not null default 'draft' check (status in
                 ('draft','approved','processing','paid','failed','cancelled')),
  reference    text,
  approved_by  uuid references users(id),
  approved_at  timestamptz,
  paid_at      timestamptz,
  failure_reason text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on payouts (payout_type, status, period_end desc);
create index on payouts (account_id, created_at desc);
create index on payouts (account_id, created_at desc);

create table payout_lines (
  id            uuid primary key default gen_random_uuid(),
  payout_id     uuid not null references payouts(id) on delete cascade,
  sub_order_id  uuid references sub_orders(id),
  payout_line_type text not null check (payout_line_type in ('vendor_earning','rider_trip','tip','bonus','adjustment')),
  source        text not null check (source in ('cash_collected','wallet_payment','adjustment')),
  gross_amount  integer not null,
  fee_amount    integer not null default 0,
  net_amount    integer not null,
  created_at    timestamptz not null default now()
);
create index on payout_lines (payout_id);
create unique index payout_lines_sub_order_unique on payout_lines (sub_order_id)
  where sub_order_id is not null;             -- a sub-order can be paid exactly once
```

### Platform float

The one thing that must reconcile every single day. With no customer wallet, this table has exactly
one real exposure: **cash that riders have collected and not yet banked.**

```sql
create table platform_float (
  id            uuid primary key default gen_random_uuid(),
  business_date date not null unique,

  -- the exposure
  cash_expected integer not null default 0,   -- collected by riders, not yet remitted
  cash_remitted integer not null default 0,   -- banked, counted against platform_float
  variance      integer not null default 0,   -- cash_expected − cash_remitted; must be explained

  -- what the platform earns, recognised at collection time
  delivery_fees   integer not null default 0,
  rider_cuts      integer not null default 0,  -- platform share of the delivery fee (launch line)
  commissions    integer not null default 0,  -- 0 until month 3-4
  service_fees   integer not null default 0,  -- 0 until switched on
  adjustments     integer not null default 0,

  -- what the platform owes
  vendor_payable integer not null default 0,
  rider_payable  integer not null default 0,

  -- external settlement, recorded not held. The money went customer → rider directly.
  external_cash_orders   integer not null default 0,  -- count of cash-paid orders
  external_wallet_orders integer not null default 0,  -- count of Vodafone Cash / Instapay orders

  updated_at     timestamptz not null default now()
);
```

`variance` trending to zero is the daily health check. Cash in transit that does not reconcile
against the bank or Vodafone Cash statement every day means the platform does not know what it owns.
`reconcile_day_v1` is the tool that produces it.

---

## 8. Delivery and riders

### `riders`

```sql
create table riders (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid references users(id) on delete set null,  -- null = onboarded by an admin
  first_name     text not null,
  last_name      text,
  phone_number   text not null unique,
  country_code   char(2) not null,
  vehicle_type   text not null check (vehicle_type in ('car','bicycle','motorcycle','scooter')),
  vehicle_plate  text,
  status         text not null default 'offline' check (status in
                   ('offline','available','assigned','on_break')),
  is_active      boolean not null default true,
  is_verified    boolean not null default false,
  is_online      boolean not null default false,
  current_latitude  numeric(9,6),
  current_longitude numeric(9,6),
  current_geohash   text,
  last_location_at  timestamptz,
  home_area_id   uuid references areas(id),
  rating_avg     numeric(3,2) not null default 0,
  rating_count   integer not null default 0,
  max_cash_held  integer,                       -- null = fall back to settings
  cash_held      integer not null default 0,
  completed_deliveries integer not null default 0,
  cancelled_deliveries integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on riders (is_online, status, current_geohash) where is_active;
create index on riders (status) where is_online;
```

**`max_cash_held` is configuration, not a constant.** `null` on the rider means "use
`settings.rider_max_cash_held_default`", which an admin sets per city or per rider cohort. The
effective limit is resolved by one function so the rider app, the collection RPC and the settlement
report all agree:

```sql
create or replace function public.effective_cash_limit_v1(p_rider_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select max_cash_held from public.riders where id = p_rider_id),
    (select (value #>> '{}')::int from public.settings where key = 'rider_max_cash_held_default'),
    0
  );
$$;
```

Setting it to `0` disables cash collection for that rider entirely, which is the correct state for
a rider who has been paid out and has had a cash-handling problem. This limit is a real operational
control, not a nicety: a rider who cannot be paid because they are holding too much cash stops
accepting orders, and that shows up as a drop in rider supply at exactly the lunch peak.

### `driver_shifts`

```sql
create table driver_shifts (
  id         uuid primary key default gen_random_uuid(),
  rider_id   uuid not null references riders(id) on delete cascade,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  area_ids   uuid[] not null default '{}',
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index on driver_shifts (rider_id, starts_at desc);
create index on driver_shifts (starts_at, ends_at) where is_active;
```

### `delivery_assignments`

One row per **order** in the default `together` grouping. `sub_order_id` is populated only in
`separate` mode.

```sql
create table delivery_assignments (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references orders(id) on delete cascade,
  sub_order_id   uuid references sub_orders(id) on delete cascade,
  rider_id       uuid references riders(id) on delete set null,
  status         text not null default 'unassigned' check (status in (
                   'unassigned','assigned','at_first_vendor','picking_up',
                   'picked_up','delivering','arrived','delivered','failed','cancelled')),
  stop_sequence  jsonb,                    -- [{sub_order_id, vendor_id, lat, lng, sequence}]
  assigned_by    text not null default 'system' check (assigned_by in ('system','rider_claim','admin')),
  assigned_at    timestamptz,
  claimed_at     timestamptz,
  arrived_vendor_at timestamptz,
  picked_up_at   timestamptz,
  arrived_at     timestamptz,
  delivered_at   timestamptz,
  distance_km    numeric(6,2),
  eta_minutes    integer,
  -- rider pay, resolved at assignment time from rider_pay_rules and frozen here
  rider_pay_base   integer,
  rider_pay_distance integer,
  rider_pay_bonus  integer,
  rider_pay_total  integer,
  platform_revenue integer,                 -- platform cut = delivery fee − rider pay
  collected_amount integer,
  collection_method  text check (collection_method in ('cash','wallet','none')),
  collection_channel text check (collection_channel in ('cod','vodafone_cash','instapay')),
  collection_reference text,
  proof_path     text,
  signature_path text,
  failure_reason text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index delivery_assignments_one_active on delivery_assignments (order_id)
  where status not in ('delivered','failed','cancelled');
create index delivery_assignments_open on delivery_assignments (rider_id, status)
  where status in ('assigned','at_first_vendor','picking_up','picked_up','delivering','arrived');
create index delivery_assignments_rider_history on delivery_assignments (rider_id, assigned_at desc);
create index on delivery_assignments (sub_order_id) where sub_order_id is not null;
```

The unique partial index is what makes an atomic claim possible:

```sql
create or replace function public.claim_order_v1(p_assignment_id uuid, p_rider_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_order uuid;
begin
  update public.delivery_assignments
     set rider_id = p_rider_id, status = 'assigned', assigned_at = now(), assigned_by = 'rider_claim'
   where id = p_assignment_id and rider_id is null and status = 'unassigned'
  returning order_id into v_order;
  if v_order is null then raise exception 'ORDER_ALREADY_CLAIMED' using errcode = 'P0001'; end if;
  return v_order;
end $$;
```

`stop_sequence` is computed once at assignment time and stored. Recomputing it on every poll would
be both slower and non-deterministic if the rider's location drifts.

### `rider_location_pings`

```sql
create table rider_location_pings (
  id          bigserial primary key,          -- bigserial: this table is pruned, not archived
  order_id    uuid not null references orders(id) on delete cascade,
  rider_id    uuid not null references riders(id) on delete cascade,
  latitude    numeric(9,6) not null,
  longitude   numeric(9,6) not null,
  heading     numeric(5,2),
  speed_kmh   numeric(6,2),
  accuracy_m  numeric(6,2),
  recorded_at timestamptz not null default now()
);
create index on rider_location_pings (recorded_at);
create index on rider_location_pings (order_id, recorded_at desc);
create index on rider_location_pings (rider_id, recorded_at desc);
```

`bigserial` + `recorded_at` index is deliberate: this is the highest-volume table in the database
and it is pruned at 30 days. It is partitioned by month when volume justifies it, and it is the
first candidate for removal if the database ever gets tight.

### `rider_earnings_daily`

```sql
create table rider_earnings_daily (
  rider_id      uuid not null references riders(id) on delete cascade,
  business_date date not null,
  deliveries    integer not null default 0,
  legs          integer not null default 0,    -- vendor pickups, higher on multi-vendor trips
  online_minutes integer not null default 0,
  base_fees     integer not null default 0,    -- from rider_pay_rules at the time of the trip
  distance_fees integer not null default 0,
  tips          integer not null default 0,
  bonuses       integer not null default 0,    -- per-leg bonus on multi-vendor trips
  deductions    integer not null default 0,
  net_payout    integer not null default 0,
  cash_held     integer not null default 0,
  cash_remitted integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (rider_id, business_date)
);
```

Every figure comes from the `rider_pay_rules` row that was active when the trip happened. A later pay
change does not rewrite past earnings, because the resolved amounts are written onto the
`delivery_assignments` row at collection time.

---

## 9. Growth

### `vouchers`

```sql
create table vouchers (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,
  name               text,
  discount_type      text not null check (discount_type in ('percentage','fixed_amount','free_delivery')),
  discount_value     numeric(12,2) not null check (discount_value > 0),
  min_order_value    integer not null default 0,
  max_discount_cap   integer,
  usage_limit_total  integer,
  usage_limit_per_user integer,              -- null = unlimited
  usage_count        integer not null default 0,
  applies_to_vendor_ids uuid[] not null default '{}',   -- empty = all vendors
  vertical_type      text,                   -- null = all verticals
  first_order_only   boolean not null default false,
  valid_from         timestamptz not null default now(),
  valid_until        timestamptz,
  is_active          boolean not null default true,
  created_by         uuid references users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (valid_until is null or valid_until > valid_from)
);
create index on vouchers (is_active, valid_from, valid_until);
```

### `voucher_redemptions`

```sql
create table voucher_redemptions (
  id               uuid primary key default gen_random_uuid(),
  voucher_id       uuid not null references vouchers(id) on delete cascade,
  user_id          uuid not null references users(id) on delete cascade,
  order_id         uuid references orders(id) on delete set null,
  sub_order_id     uuid references sub_orders(id) on delete set null,
  discount_amount  integer not null,
  created_at       timestamptz not null default now()
);
create unique index voucher_redemption_order on voucher_redemptions (voucher_id, order_id)
  where order_id is not null;
create index on voucher_redemptions (voucher_id, user_id);
create index on voucher_redemptions (sub_order_id) where sub_order_id is not null;
```

The unique index is what stops a double-submit from consuming two redemptions.

### `promo_slots`

```sql
create table promo_slots (
  id           uuid primary key default gen_random_uuid(),
  city_id      uuid not null references cities(id),
  slot_key     text not null,                 -- 'home_banner_1'
  title        jsonb not null,                -- {"ar":"...","en":"..."}
  subtitle     jsonb,
  image_path   text,
  target_type  text check (target_type in ('vendor','vertical','area','url')),
  target_id    text,
  starts_at    timestamptz,
  ends_at      timestamptz,
  sort_order   integer not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (city_id, slot_key)
);
```

---

## 10. Engagement

### `reviews`

```sql
create table reviews (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders(id) on delete cascade,
  sub_order_id uuid references sub_orders(id) on delete cascade,
  user_id     uuid not null references users(id),
  vendor_id   uuid not null references vendors(id),
  rider_id    uuid references riders(id),
  vendor_rating smallint check (vendor_rating between 1 and 5),
  rider_rating  smallint check (rider_rating between 1 and 5),
  comment     text,
  is_hidden   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (order_id, vendor_id)
);
create index on reviews (vendor_id, created_at desc) where not is_hidden;
create index on reviews (user_id, created_at desc);
create index on reviews (rider_id) where rider_id is not null;
create index on reviews (sub_order_id) where sub_order_id is not null;
```

Vendor and rider ratings are two independent numbers about one delivery. Conflating them makes both
useless: a customer who loves the food and hates the driver has no way to say so.

### `favorites` / `favorite_items`

```sql
create table favorites (
  user_id    uuid not null references users(id) on delete cascade,
  vendor_id  uuid not null references vendors(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, vendor_id)
);

create table favorite_items (
  user_id     uuid not null references users(id) on delete cascade,
  menu_item_id uuid not null references menu_items(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, menu_item_id)
);
```

### `notifications` and `notification_templates`

```sql
create table notifications (
  id         bigserial primary key,            -- pruned at 30 days
  user_id    uuid not null references users(id) on delete cascade,
  order_id   uuid references orders(id) on delete cascade,
  sub_order_id uuid references sub_orders(id) on delete cascade,
  type       text not null,
  title      jsonb not null,
  body       jsonb not null,
  data       jsonb,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index on notifications (user_id, created_at desc);
create index on notifications (created_at);    -- retention sweep
create index on notifications (order_id) where order_id is not null;
create index on notifications (sub_order_id) where sub_order_id is not null;

create table notification_templates (
  id        uuid primary key default gen_random_uuid(),
  key       text not null,
  channel   text not null default 'push' check (channel in ('push','inapp','sms')),
  lang      text not null check (lang in ('ar','en')),
  title     text not null,
  body      text not null,
  variables jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  unique (key, channel, lang)
);
```

---

## 11. Platform operations

### `events` — the outbox

```sql
create table events (
  id            bigserial primary key,
  id_uuid       uuid not null default gen_random_uuid() unique,  -- downstream idempotency key
  type          text not null,
  aggregate_type text,
  aggregate_id  uuid,
  payload       jsonb not null,
  attempts      smallint not null default 0,
  last_error    text,
  created_at    timestamptz not null default now(),
  delivered_at  timestamptz
);
create index on events (created_at) where delivered_at is null;   -- the dispatcher's work queue
create index on events (delivered_at, created_at);               -- the pruner
create index on events (aggregate_id, created_at);
```

Pruned at 7 days after delivery. An un-pruned `events` table grows at roughly 7 rows per order and
will consume the entire free-tier database within weeks. This is the single most common way this
architecture fails.

### Aggregates that replace raw event storage

Row-level analytics does not fit the free tier. These daily rollups keep the required retention
periods at a few hundred rows per day instead of hundreds of thousands.

```sql
create table event_daily_stats (
  business_date date not null,
  city_id       uuid references cities(id),
  app_role      text,
  event_name    text not null,
  count         integer not null default 0,
  unique_users  integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (business_date, city_id, app_role, event_name)
);

create table search_daily_stats (
  business_date date not null,
  city_id       uuid references cities(id),
  query_hash    text not null,          -- md5 of the normalised query; the raw text is not stored
  results_count integer not null,
  zero_result   boolean not null default false,
  clicks        integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (business_date, city_id, query_hash)
);

create table auth_daily_stats (
  business_date date not null,
  event_name    text not null check (event_name in
                  ('signup','login','login_failed','otp_requested','logout','password_reset')),
  count         integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (business_date, event_name)
);
```

### `audit_log`

```sql
create table audit_log (
  id          bigserial primary key,
  actor_user_id uuid references users(id),
  action      text not null,
  entity_type text not null,
  entity_id   uuid,
  before      jsonb,
  after       jsonb,
  created_at  timestamptz not null default now()
);
create index on audit_log (entity_type, entity_id, created_at desc);
create index on audit_log (created_at);
```

Retained 1 year, then archived to R2. Admin-only; the vendor and customer apps never read it.

---

## 12. Entity relationships

```
cities ─┬─ areas ─┬─ delivery_zones ─┬─ delivery_fee_tiers
        │        │                    └─ (per-vendor multipliers)
        │        ├─ addresses
        │        └─ vendor_areas ──── vendors ─┬─ vendor_schedules
        │                                     ├─ vendor_holidays
        │                                     ├─ vendor_cuisines ──── cuisines
        │                                     ├─ vendor_staff ─────── users ─┬─ user_roles
        │                                     ├─ brands                    ├─ user_auth_providers
        │                                     ├─ menu_categories           ├─ addresses
        │                                     │    └─ menu_items            ├─ wallets (vendor/rider)
        │                                     │        └─ item_options      ├─ device_tokens
        │                                     │            └─ option_choices└─ carts ── cart_items
        │                                     └─ vendor_earnings_daily
        │
        ├─ promo_slots
        ├─ rider_pay_rules
        └─ riders ─┬─ driver_shifts
                   ├─ delivery_assignments
                   ├─ rider_location_pings
                   ├─ rider_earnings_daily
                   └─ payouts ── payout_lines
                          ▲
                          └── also paid to vendors (wallets.owner_type = 'vendor')

users ── orders ─┬─ sub_orders ─┬─ order_items
                 │              └─ order_status_history
                 ├─ order_modifications
                 ├─ reviews
                 ├─ voucher_redemptions ──── vouchers
                 ├─ notifications
                 └─ order_eta_snapshots

cross-cutting: commission_rules · ledger_entries · settings · feature_flags · events
               · event_daily_stats · search_daily_stats · auth_daily_stats
               · audit_log · platform_float
```

---

## 13. Row-Level Security and privilege model

### 13.1 Who sees what

| Table | Customer | Rider | Vendor staff | Admin |
|---|---|---|---|---|
| `users` | Own row | Own row | Own row | All |
| `addresses` | Own | Own | Own | All |
| `carts`, `cart_items` | Own | Own | — | All |
| `vendors`, catalog | All active | All active | Own vendor | All |
| `vendor_schedules`, holidays | Read | Read | Own vendor | All |
| `vendor_staff` | — | — | Own vendor rows | All |
| `orders` | Own | Assigned only | Own vendor's sub-orders | All |
| `sub_orders`, `order_items` | Own order | Assigned only | Own vendor | All |
| `wallets` | — | Own rider wallet | Own vendor wallet | All |
| `ledger_entries` | **No access** | Own account | Own vendor account | All |
| `payouts` | — | Own | Own vendor | All |
| `riders` | Public fields only | Own row | — | All |
| `delivery_assignments` | Own order | Own assignments | Own vendor's orders | All |
| `rider_location_pings` | Own order | Own | Own vendor's orders | All |
| `reviews` | All non-hidden | All non-hidden | Own vendor | All |
| `feature_flags`, `settings`, `cities`, `areas`, `zones`, `fee_tiers`, `pay_rules` | Read | Read | Read | Read/write |
| `commission_rules` | Read (effective) | Read | Read | All |
| `platform_float` | — | — | — | All |
| `events`, `*_daily_stats`, `audit_log` | — | — | Own earnings only | All |

Three invariants the policies must enforce absolutely:

1. **A rider can read an order only while assigned to it.** Location history of other people's
   orders is the highest-value data in the system to an attacker and the highest-value data to
   protect from competitors.
2. **A vendor can read only its own sub-orders**, including the customer's address for delivery
   and nothing more. Address visibility must not leak the customer's other orders or reviews.
3. **A customer can never insert into `orders` directly.** RLS denies it, and `place_order_v1`
   raises `PROFILE_INCOMPLETE` when `users.profile_completed_at is null`. The profile gate has to
   hold at the data layer, not only in the app.

### 13.2 Mandatory RLS patterns

These are **not optional style**. They are the difference between an RLS layer that costs a
millisecond and one that costs a table scan on the hottest query in the product.

**Wrap every `auth.uid()` call in a scalar subquery.** An unwrapped call is evaluated once per row
scanned. On `orders` at 100,000 rows that is 100,000 JWT reads to return one customer's order.

```sql
-- WRONG: evaluated per row
create policy orders_read on orders for select using (auth.uid() = user_id);

-- RIGHT: planned once, then treated as a constant
create policy orders_read on orders for select using ((select auth.uid()) = user_id);
```

Every policy in migration 014 uses `(select auth.uid())`. A lint check in migration 022 fails the
build on a bare `auth.uid()` inside a policy.

**Put membership checks in a `security definer` helper in a `private` schema.** A policy that
subqueries another table per row is a sequential scan per row. `auth.uid()` also cannot be called
inside a security-definer function without an explicit argument, which is precisely the guard that
stops the function being used to answer "is user X a member of team Y" for an arbitrary X.

```sql
create schema if not exists private;

create or replace function private.vendor_ids_for(p_user uuid)
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select vs.vendor_id from public.vendor_staff vs where vs.user_id = p_user;
$$;

revoke execute on function private.vendor_ids_for(uuid) from public, anon, authenticated;

-- Policy becomes a single indexed membership test
create policy sub_orders_vendor_read on sub_orders for select
  using (vendor_id in (select private.vendor_ids_for((select auth.uid()))));
```

Note the shape: the caller supplies the uid, the function re-derives nothing and trusts nothing
except its argument, and `EXECUTE` is revoked from every role that does not need it.

**`set search_path = ''`, never `set search_path = public`.** Pinning to `public` still lets a
malicious object in `public` shadow a built-in. Pinning to the empty string forces every name to be
schema-qualified, which is the whole point. Every `security definer` function in this schema uses
`set search_path = ''` with fully-qualified names.

**Index every column a policy touches.** A policy filter on an unindexed column is a scan whether
or not the policy is written well. This is the other half of the FK-index rule in §14.2.

### 13.3 Least privilege

```sql
revoke all on schema public from public;
alter default privileges in schema public revoke all on tables from public, anon, authenticated;
```

Then grant deliberately. The application never connects as superuser, and `anon` gets no direct
table access at all — every read goes through an RPC, which is what makes the RPC the single place
where a permission decision is written.

| Role | Gets |
|---|---|
| `anon` | Nothing. Signed-in users only |
| `authenticated` | `USAGE` on `public`, `SELECT` on read tables, `EXECUTE` on approved RPCs. **No `DELETE` anywhere** |
| `service_role` | Full. Worker-side only, from a Worker secret |
| `postgres` | Never used by the app |

---

## 14. Operational Postgres rules

### 14.1 Partition the four prune targets

`events`, `notifications`, `rider_location_pings` and `audit_log` are all deleted by a scheduled
job on a retention window. On a free tier with limited IOPS, `DELETE` of a large range is the
expensive operation: it bloats, it blocks, and autovacuum has to clean up afterwards. A monthly
partition range turns retention into `DROP TABLE`, which is instant and leaves no dead tuples.

```sql
create table events (
  id            bigserial,
  id_uuid       uuid not null default gen_random_uuid() unique,
  type          text not null,
  aggregate_type text,
  aggregate_id  uuid,
  payload       jsonb not null,
  attempts      smallint not null default 0,
  last_error    text,
  created_at    timestamptz not null default now(),
  delivered_at  timestamptz,
  primary key (id, created_at)          -- partition key must be in the PK
) partition by range (created_at);
```

`pg_partman` 5.3.1 is available on this project and automates partition creation. If it is not
used, a `pg_cron` job creates next month's partition three days ahead.

Partitioning is **not** applied to `orders`, `order_items` or `ledger_entries`. They are not
pruned, and `ledger_entries` must stay a single queryable relation forever. Partitioning them would
break the balance computation for no gain.

### 14.2 Index every foreign key

Postgres does **not** create an index on a referencing column. An unindexed FK makes every JOIN
through it a sequential scan and every `ON DELETE CASCADE` or `SET NULL` on the parent a full scan
of the child. This schema declares 60+ foreign keys; all are indexed, added after an audit of the
DDL in this file.

The highest-value ones, because they are on hot paths:

| Index | Why it is hot |
|---|---|
| `order_items (vendor_id)` | Every vendor-facing order query |
| `voucher_redemptions (voucher_id)` | Every quote counts redemptions to enforce a usage limit |
| `sub_orders (payout_id)` | Settlement runs scan by payout |
| `payouts (account_id, created_at desc)` | "What did this vendor earn" |
| `orders (area_id)`, `orders (address_id)` | Zone and area analytics |
| `rider_location_pings (rider_id, recorded_at desc)` | Rider trip replay |
| `reviews (user_id)`, `reviews (rider_id)` | "My reviews", rider reputation |

Verify rather than trust. This query, run after migration 014, must return zero rows:

```sql
select conrelid::regclass as table_name, a.attname as fk_column
from pg_constraint c
join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
where c.contype = 'f'
  and not exists (
    select 1 from pg_index i
    where i.indrelid = c.conrelid and a.attnum = any(i.indkey)
  );
```

### 14.3 Vacuum and autovacuum

Bloat is the silent killer of a shared-CPU free plan. Nightly `VACUUM ANALYZE` on the highest-churn
tables — `orders`, `order_items`, `events`, `notifications` — plus `pg_stat_statements` (already
installed) to catch a query that regressed into a sequential scan. See `free-tier-plan.md` §3.7.

### 14.4 Queue consumers use `SKIP LOCKED`

Two places drain a queue: `claim_events_v1` for the outbox, and `claim_order_v1` for rider
acceptance. Neither may block. `claim_events_v1` uses `for update skip locked` so two cron ticks or
two Workers never wait on each other. `claim_order_v1` does not need it, because it claims one row
by primary key with a guarded `UPDATE` — the uniqueness constraint and the `where rider_id is null`
predicate are what guarantee exactly one winner, and pgTAP asserts two concurrent calls produce
one.

---

## 15. Migration order

### 15.1 Rules for every migration

From the `database-migrations` skill. These bind the files under `supabase/migrations/`.

| # | Rule | Why |
|---|---|---|
| 1 | **Schema and data migrations are separate files** | Mixing DDL and DML makes a migration un-rollable and holds a long transaction open |
| 2 | **Forward-only.** Rollback is a new forward migration, never a `down` file | Postgres DDL is rarely reversible in place. A `down` that "works" can lose data |
| 3 | **Immutable once applied.** Never edit a migration that has run | Editing it silently diverges environments |
| 4 | **No `NOT NULL` without a default** on an existing table | Rewrites every row and holds an exclusive lock |
| 5 | **`CREATE INDEX CONCURRENTLY` when the table has rows** | A plain `CREATE INDEX` blocks writes for the duration |
| 6 | **Never mix statements that need different transaction semantics in one file** | `CONCURRENTLY` cannot run inside a transaction block, so a file containing it must be applied outside one — which some runners cannot do |
| 7 | **Every table needs a backfill path from day one.** New nullable column, backfill, then add the constraint | The expand-contract pattern |
| 8 | **Test against a production-sized copy**, not 100 rows | A migration that is instant on 100 rows can lock for hours on 10M |

**Migration 001–022 all run against an empty database, so rule 5 does not apply to them.** Plain
`CREATE INDEX` is correct there and `CONCURRENTLY` would in fact fail, because the Supabase migration
runner wraps the file in a transaction. Rule 5 activates from migration 023 onward, which is where
the schema starts changing rather than being created.

### 15.2 Order

Dependency-ordered, so each step is independently deployable. `S` marks a file that is **data only**
and must not contain DDL.

| # | Migration | Contents |
|---|---|---|
| 001 | `extensions` | `pgcrypto`, `pg_trgm`, `btree_gist`, `unaccent`, `pg_partman`. Optional `postgis`, unused |
| 002 | `geo_and_config` | `cities`, `areas`, `delivery_zones`, `delivery_fee_tiers`, `settings` |
| 002s | `seed_fee_tiers` **S** | The 1/2/3-vendor tiers. Separate from 002 per rule 1 |
| 003 | `identity` | `users`, `user_roles`, `user_auth_providers`, `addresses`, `device_tokens`, `feature_flags` |
| 004 | `vendors` | `brands`, `vendors`, `vendor_areas`, `vendor_schedules`, `vendor_holidays`, `cuisines`, `vendor_cuisines`, `vendor_staff` |
| 005 | `catalog` | `menu_categories`, `menu_items`, `item_options`, `option_choices` + version triggers |
| 006 | `cart` | `carts`, `cart_items` |
| 007 | `orders` | `orders`, `sub_orders`, `order_items`, `order_status_history`, `order_modifications`, `order_eta_snapshots` |
| 008 | `riders` | `riders` (`car`, `bicycle`, `motorcycle`, `scooter`), `driver_shifts`, `delivery_assignments`, `rider_location_pings` |
| 009 | `money` | `commission_rules`, `wallets`, `ledger_entries`, `payouts`, `payout_lines`, `platform_float`, `rider_pay_rules` |
| 009s | `seed_revenue_config` **S** | The active rider cut and the inactive vendor row. The revenue line is data, not schema |
| 009t | `seed_settings` **S** | `platform_name` = Marketak, `platform_name_ar` = ماركتك, order prefix, limits |
| 010 | `engagement` | `reviews`, `favorites`, `favorite_items`, `notifications`, `notification_templates` |
| 011 | `growth` | `vouchers`, `voucher_redemptions`, `promo_slots` |
| 012 | `aggregates` | `vendor_earnings_daily`, `rider_earnings_daily`, `event_daily_stats`, `search_daily_stats`, `auth_daily_stats`, `audit_log` |
| 013 | `platform` | `events`, partitioned by month per §14.1 |
| 014 | `rls` | `private` schema, `revoke all on schema public from public`, all policies, `updated_at` triggers, ledger append-only rules, the profile-completion insert guard |
| 015 | `search` | `normalize_text_v1`, normalised generated columns, trigram indexes, `search_catalog_v1` |
| 016 | `rpc_profile` | `complete_profile_v1`, `get_profile_status_v1` |
| 017 | `rpc_core` | `quote_order_v1` (fee tiers + rider pay), `place_order_v1`, `cancel_order_v1`, `transition_order_v1` |
| 018 | `rpc_delivery` | `get_available_orders_v1`, `claim_order_v1`, `begin_collection_v1`, `collect_cash_v1`, `collect_wallet_v1`, `complete_delivery_v1` |
| 019 | `rpc_money` | `adjust_wallet_v1`, `get_wallet_balance_v1`, `run_payout_v1`, `reconcile_day_v1`, `get_platform_float_v1` |
| 020 | `rpc_read` | `get_vendor_feed_v1`, `get_vendor_dashboard_v1`, `get_earnings_v1`, `get_admin_metrics_v1`, `get_flags_v1` |
| 021 | `cron` | All `pg_cron` jobs and pruning functions |
| 022 | `rls_tests` | pgTAP. Fails the build if a tenant boundary is missing, if a policy uses a bare `auth.uid()`, or if a foreign key is unindexed |

---

## 16. Changes from the original brief

Every deviation, and why.

| Original | Change | Reason |
|---|---|---|
| `orders.vendor_id` | Removed; split into `orders` + `sub_orders` | Multi-vendor checkout is the core requirement |
| `order_items.order_id` only | Added mandatory `sub_order_id` | Per-vendor item status and payouts |
| `users.id default auth.users(id)` | **Illegal, removed.** `id` references `auth.users(id)` with no default, populated by an `on_auth_user_created` trigger | Postgres rejects a column reference in a `DEFAULT` expression. Found by applying migration 003 to the live project |
| `menu_items.price_on_selection` | **Removed**, replaced by `pricing_mode` + a dedicated `menu_item_sizes` table | A size carries a real price. As an option with a `price_modifier`, "Large" is indistinguishable from "extra cheese" on the kitchen ticket and in revenue reporting |
| 6 verticals (food, grocery, pharmacy, flowers, bakery, others) | **Kept**, gated by `settings.supported_verticals = ["food"]` | v1 is restaurant-only. A pharmacy needs dosage, batch and expiry; a grocery needs weight units, bin locations and shelf stock. None of that is modelled, deliberately. Opening another vertical is an admin toggle, not a migration |
| Item "metadata" as unspecified columns | `nutritional_info`, `allergens`, `ingredients`, `tags`, `calories`, `is_spicy`, `is_vegetarian`, `is_featured`, `is_new` | Structured columns for anything filtered or sorted; jsonb only for shapes always read whole (constitution rule 13) |
| `vendors.area_ids` JSON | Removed; `vendor_areas` join table | JSON arrays cannot be indexed; forces a scan on every availability check |
| `vendors.cuisine_types` JSON | Removed; `vendor_cuisines` + `cuisines` | Same, plus filterability |
| `vendors.estimated_delivery_time_min/max` | Removed; derived | A stored number is wrong at lunch, which is when it matters |
| `vendors.country_code` | On `cities` | One-city operation; denormalised copies drift |
| `vendors.delivery_fee_base` | `delivery_zones.delivery_base_fee` + `delivery_fee_tiers` | The fee is a zone rule with a per-vendor multiplier, not a per-vendor constant |
| `user_auth_providers` = email, google, apple, facebook | **google, apple only** | Email and phone are not credentials. Phone is collected at profile completion |
| `users.phone_number` NOT NULL | Column nullable + `profile_completed_at` + `check (profile_completed_at is null or phone_number is not null)` | A row must exist at OAuth sign-in, before a phone exists. A completed user always has one |
| `riders.vehicle_type` = bicycle, motorcycle, car | car, bicycle, motorcycle, **scooter** | Added scooter; dropped on_foot |
| `riders.max_cash_held` hardcoded | Nullable per rider, falls back to `settings.rider_max_cash_held_default` | Configuration, not a constant |
| `payment_status` = pending, paid, failed | unpaid, collected, failed, refunded | Payment happens at delivery, and the platform holds no customer money |
| Customer wallet with top-up + verification | **Deleted.** Wallets belong to vendors and riders only | The customer pays the driver directly. Removes the whole top-up fraud surface and all customer float |
| `delivery_assignments` per sub-order | Per order, one rider, one trip, N pickups, one address | Multi-vendor delivery execution |
| No cart table | `carts` + `cart_items` | A multi-vendor cart must survive app death and offline |
| No settlement model | `ledger_entries`, `payouts`, `payout_lines`, `commission_rules`, `platform_float`, `rider_pay_rules` | "Vendor earned today" and platform revenue need real records |
| Commission 0% for everyone | **Rider cut on the delivery fee is ACTIVE at launch. Vendor commission on items is off until month 3–4** | Launch strategy: charge the rider, not the merchant, or merchants will not join |
| `feature_flag` as Firebase RC | `feature_flags` table + `get_flags_v1` | One source of truth, targetable against real data |
| — | `cities`, `areas`, `delivery_zones`, `delivery_fee_tiers` | Area-based vendor matching and a configurable fee formula need real tables |
| — | `vendor_earnings_daily`, `rider_earnings_daily` | "Earned today" must be a fast read, not a live aggregation |
| — | `reviews`, `favorites`, `notifications`, `notification_templates` | Required for the funnel; not in the original DB brief |
| — | `event_daily_stats`, `search_daily_stats`, `auth_daily_stats` | Retention requirements are impossible at row level on a free tier |
| — | `order_eta_snapshots` | Promised vs actual is the only honest measure of ETA quality |
| — | `vendor_staff` multi-tenant | One person working at two vendors must not need two accounts |
| — | `users.role` column → `user_roles` | Riders are also customers |
| — | `addresses.landmark` | In this market the address alone is not navigable |
| — | `orders.address_snapshot`, `delivery_base_fee`, `delivery_multiplier_bps` | The fee inputs and the address are frozen at checkout so history cannot be rewritten by a later config change |

---

## 17. Hardening applied from `supabase-postgres-best-practices`

An audit of the DDL in §1–§11 against Supabase's own Postgres rule set found six classes of defect.
All are fixed here; the requirements are in §13.2, §13.3 and §14.

| # | Finding | Fix |
|---|---|---|
| 1 | `set search_path = public` on three `security definer` functions | `set search_path = ''` with fully-qualified names. Pinning to `public` still allows a shadowing object in `public` to hijack a built-in |
| 2 | No `(select auth.uid())` mandate, and no rule preventing a per-row membership subquery | §13.2. Mandatory scalar-subquery form, `private` schema helpers, and a lint check in migration 022 that fails on a bare `auth.uid()` in a policy |
| 3 | **18 unindexed foreign-key columns** | All indexed. Highest-value: `order_items.vendor_id`, `voucher_redemptions.voucher_id`, `sub_orders.payout_id`, `payouts.account_id`. Postgres does not auto-index FKs, so each was a sequential scan on JOIN and a full scan on cascade |
| 4 | No `private` schema, no `revoke execute` | `private.vendor_ids_for()` and friends, with `EXECUTE` revoked from `public, anon, authenticated` |
| 5 | No `revoke all on schema public from public` | §13.3. Least-privilege grants per role, no `DELETE` for `authenticated` |
| 6 | Prune targets were plain `DELETE` on an unpartitioned table | §14.1. `events`, `notifications`, `rider_location_pings`, `audit_log` partition by month so retention is `DROP TABLE`. Deliberately **not** applied to `ledger_entries`, which must stay one relation forever |

Two further defects were found by *executing* migrations 005 and 005a rather than reading them, and
are recorded here because both are invisible in review:

| # | Finding | Fix |
|---|---|---|
| 7 | `bump_menu_version()` referenced `new.item_id`, but `menu_categories` has no such column. PL/pgSQL resolves record fields at **runtime**, so the function and all five `CREATE TRIGGER` statements succeeded, and it only failed when a category was inserted | Rewritten to read the row via `to_jsonb(new)`, where an absent key yields `NULL` instead of raising. One function is then safe across all five catalog tables. Shipped as **005a**, not as an edit to 005, because 005 had already been applied |
| 8 | The sizing rules need one row-level `CHECK` (`fixed` requires a price) and one cross-table guarantee (`sized` requires at least one size). The cross-table rule cannot be a `CHECK` | `CHECK` for the row-level case; a `deferrable initially deferred` constraint trigger for the cross-table case so an item and its sizes can be inserted in one transaction in any order |
| 9 | **Deleting the last size of a `sized` item repaired it to `fixed` with `base_price = coalesce(base_price, 0)`** — which is always `0`, because a `sized` item has `base_price` NULL by definition. The item became orderable for free | Removed the repair entirely. There is no correct price to invent, so the delete is **refused** and the vendor must add a size or switch the item to `fixed` with a real price. Guessing a price is worse than refusing the operation |
| 10 | `sync_menu_item_vendor` was `BEFORE INSERT OR UPDATE **OF category_id**`, so a bare `UPDATE menu_items SET vendor_id = <other>` never re-derived it. An item could claim a vendor other than its category's owner | Dropped the column list, so any `UPDATE` re-derives. Verified: a bare `vendor_id` update is corrected back |
| 11 | `bump_menu_version` was `FOR EACH ROW`, so a 50-row catalog import ran 50 separate `UPDATE vendors` statements against the same row | Statement-level triggers over transition tables. Verified: a 50-row insert bumps `menu_version` by exactly 1. Note a transition table requires a **single** event, so `INSERT` and `UPDATE` need separate triggers — generated in a loop |
| 12 | Six money/range columns had no `CHECK`: `per_km_fee`, `delivery_fee_override`, `minimum_order_value` (×2), `price_modifier`, `max_vendors_per_order`, plus an invertible prep window. A negative `per_km_fee` makes the delivery fee **fall** as distance grows | Row-level `CHECK` on each. `price_modifier` is floored rather than pinned to zero, since a negative modifier is a legitimate discount — unbounded negative would let a choice make an item free |
| 13 | `vendor_earnings_daily`, `user_auth_providers` and `user_roles` were hard-deletable. The first is a **financial record** | `deleted_at` on the first two, `revoked_at` on `user_roles`, and `is_admin()` updated to ignore revoked grants — otherwise revocation would silently be a no-op |
| 14 | `vendors.slug` was `UNIQUE` globally while `vendors` is soft-deletable, so a deleted vendor squatted its slug permanently | Partial unique index over `deleted_at is null` |
| 15 | Nothing stopped an admin configuring 1 vendor = `12000` and 2 vendors = `10000`, which rewards a customer for splitting one order in two | Deferred constraint trigger asserting `multiplier_bps` never falls as `vendor_count` rises |

**The recurring lesson is item 9's class, not any single fix.** PL/pgSQL resolves record fields and
even table column names at *runtime*, so a trigger function that references something nonexistent
creates cleanly, creates its trigger cleanly, and fails only on the first real write. This bit the
repository three times: `new.item_id` in 005a, and `new.delivery_zone_id` (the column is `zone_id`)
in 005b. **Every trigger function in this repo now has an executed test.** A trigger that has never
run is not a trigger, it is a comment.

Also confirmed correct as written, so not changed:

- `claim_order_v1` uses a guarded single-row `UPDATE`, not `SKIP LOCKED`. The PK plus
  `where rider_id is null` is what guarantees one winner, and that is simpler to prove with pgTAP
  than a locking clause.
- `claim_events_v1` uses `for update skip locked`, which is correct for a multi-consumer drain.
- Partial indexes on `is_active`, `is_open` and `settlement_status` are already the right shape for
  these access patterns.
- Money columns are `integer`, never `numeric` or `float`.
