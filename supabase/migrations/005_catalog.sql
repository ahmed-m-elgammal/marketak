-- 005_catalog.sql
-- Catalog. Restaurant menus only in v1: category -> item -> sizes + add-on options.
--
-- Hierarchy, per the confirmed structure:
--     vendor -> many menu_categories -> many menu_items
--     menu_item -> many menu_item_sizes   (intrinsic portion variants: S/M/L)
--     menu_item -> many item_options      (add-ons: extra cheese, spice level)
--                     -> many option_choices
--
-- SIZES ARE NOT OPTIONS. A size is intrinsic to the item and carries a real price, so it is a
-- row in menu_item_sizes rather than an item_option with a price_modifier. That distinction
-- matters in three places: the kitchen ticket must print the size, price filtering needs a real
-- price rather than base + modifier, and reporting must separate "they chose a large" from
-- "they added extra cheese".
--
-- GROCERY AND PHARMACY ARE OUT OF SCOPE FOR v1. A pharmacy needs dosage, batch and expiry; a
-- grocery needs weight units, aisle/bin locations and shelf stock. None of that is modelled,
-- deliberately. vendors.vertical_type keeps all six values from the brief, and
-- settings.supported_verticals gates the app to food so opening another vertical later is an
-- admin toggle rather than a migration.

-- ---------------------------------------------------------------------------
-- menu_categories
-- ---------------------------------------------------------------------------
create table menu_categories (
  id            uuid primary key default gen_random_uuid(),
  vendor_id     uuid not null references vendors(id) on delete cascade,
  name          text not null,
  name_ar       text,
  description   text,
  display_order integer not null default 0,
  is_available  boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);
create index on menu_categories (vendor_id, display_order) where deleted_at is null;
create index on menu_categories (vendor_id) where is_available and deleted_at is null;

-- ---------------------------------------------------------------------------
-- menu_items
-- vendor_id is denormalised from the category, kept consistent by the trigger below, for two
-- reasons: RLS policies need to filter items by vendor without a join, and the cart and quote
-- RPCs need vendor_id on the item row to group a multi-vendor basket.
--
-- pricing_mode makes the price/size relationship explicit and enforceable in a row-level CHECK:
--   'fixed' -> base_price is required, and the item has no sizes
--   'sized' -> prices come from menu_item_sizes; base_price may be null, because the displayed
--              price is the smallest available size and is derived, not stored
-- ---------------------------------------------------------------------------
create table menu_items (
  id                      uuid primary key default gen_random_uuid(),
  category_id             uuid not null references menu_categories(id) on delete cascade,
  vendor_id               uuid not null references vendors(id) on delete cascade,
  name                    text not null,
  name_ar                 text,
  description             text,
  description_ar          text,

  pricing_mode            text not null default 'fixed'
                            check (pricing_mode in ('fixed','sized')),
  base_price              integer check (base_price is null or base_price >= 0),
  is_available            boolean not null default true,
  stock_count             integer check (stock_count is null or stock_count >= 0),  -- null = unlimited

  preparation_time_minutes integer,
  image_path              text,
  display_order           integer not null default 0,

  -- metadata. Structured columns for anything filtered or sorted on; jsonb only for shapes that
  -- are always read whole (constitution rule 13).
  nutritional_info        jsonb,      -- {calories, protein_g, carbs_g, fat_g, sodium_mg}
  allergens               jsonb,      -- ["gluten","dairy",...]
  ingredients             jsonb,      -- ordered list, vendor-authored
  tags                    text[] not null default '{}',
  calories                integer,
  is_spicy                boolean not null default false,
  is_vegetarian           boolean not null default false,
  is_featured             boolean not null default false,
  is_new                  boolean not null default false,

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  deleted_at              timestamptz,

  -- A fixed item must carry a price. Enforced here because it is row-level; the reverse
  -- ("a sized item must have at least one size") is cross-table and handled by trigger below.
  constraint fixed_item_has_price
    check (pricing_mode <> 'fixed' or base_price is not null)
);
create index on menu_items (vendor_id, is_available, display_order) where deleted_at is null;
create index on menu_items (category_id, display_order) where deleted_at is null;
create index on menu_items using gin (tags) where deleted_at is null;
-- Name search is NOT indexed here. Migration 015 adds normalised generated columns plus
-- trigram indexes, because searching Arabic needs diacritic and alef normalisation first, and
-- an index on raw lower(name) would never be used by that query.

-- Keep vendor_id consistent with the category, so it can never drift.
create or replace function public.sync_menu_item_vendor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.vendor_id := (select c.vendor_id from public.menu_categories c where c.id = new.category_id);
  return new;
end;
$$;

create trigger trg_menu_item_vendor
  before insert or update of category_id on menu_items
  for each row execute function public.sync_menu_item_vendor();

-- ---------------------------------------------------------------------------
-- menu_item_sizes
-- A size carries a REAL price, not a modifier. Exactly one size may be the default.
-- ---------------------------------------------------------------------------
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
create unique index menu_item_sizes_one_default on menu_item_sizes (item_id)
  where is_default;

-- ---------------------------------------------------------------------------
-- item_options  (add-ons, NOT sizes)
-- min/max selections allow "choose up to 3" and "choose exactly 1".
-- ---------------------------------------------------------------------------
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
  constraint option_selections_sane check (
    max_selections >= min_selections
    and (max_selections > 0 or min_selections = 0)
  )
);
create index on item_options (item_id, display_order);

-- ---------------------------------------------------------------------------
-- option_choices
-- ---------------------------------------------------------------------------
create table option_choices (
  id            uuid primary key default gen_random_uuid(),
  option_id     uuid not null references item_options(id) on delete cascade,
  name          text not null,
  name_ar       text,
  price_modifier integer not null default 0,      -- may be negative for a discount option
  is_default    boolean not null default false,
  is_available  boolean not null default true,
  stock_count   integer,
  calories      integer,
  display_order integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on option_choices (option_id, display_order);

-- ---------------------------------------------------------------------------
-- Snapshot invalidation
-- Any catalog change bumps vendors.menu_version, which changes the R2 snapshot URL and tells
-- every device its cached menu is stale. One place, so it cannot be forgotten.
-- ---------------------------------------------------------------------------
create or replace function public.bump_menu_version()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_item uuid;
  v_vendor uuid;
begin
  v_item := case when tg_table_name = 'menu_items'
                 then coalesce(new.id, old.id)
                 else coalesce(new.item_id, old.item_id) end;

  if tg_table_name = 'option_choices' then
    v_item := (select o.item_id from public.item_options o where o.id = coalesce(new.option_id, old.option_id));
  end if;

  select mi.vendor_id into v_vendor from public.menu_items mi where mi.id = v_item;

  if v_vendor is not null then
    update public.vendors set menu_version = menu_version + 1, updated_at = now() where id = v_vendor;
  end if;

  return null;
end;
$$;

create trigger trg_bump_menu_version_items
  after insert or update or delete on menu_items
  for each row execute function public.bump_menu_version();

create trigger trg_bump_menu_version_sizes
  after insert or update or delete on menu_item_sizes
  for each row execute function public.bump_menu_version();

create trigger trg_bump_menu_version_options
  after insert or update or delete on item_options
  for each row execute function public.bump_menu_version();

create trigger trg_bump_menu_version_choices
  after insert or update or delete on option_choices
  for each row execute function public.bump_menu_version();

create trigger trg_bump_menu_version_categories
  after insert or update or delete on menu_categories
  for each row execute function public.bump_menu_version();

-- ---------------------------------------------------------------------------
-- Sizing integrity
--
-- Two rules that a row-level CHECK cannot express because they cross tables:
--   1. an item with pricing_mode = 'sized' must have at least one size
--   2. deleting the last size of a 'sized' item would leave it unsellable
--
-- Rule 1 is a DEFERRABLE constraint trigger so an item and its sizes can be inserted in one
-- transaction in any order. Rule 2 repairs rather than rejects, because the vendor deleting a
-- size mid-edit should not lose the item.
-- ---------------------------------------------------------------------------
create or replace function public.assert_item_has_sizes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.pricing_mode = 'sized'
     and not exists (select 1 from public.menu_item_sizes where item_id = new.id) then
    raise exception 'ITEM_SIZED_BUT_NO_SIZES: %', new.id using errcode = 'P0001';
  end if;
  return null;
end;
$$;

create constraint trigger trg_item_has_sizes
  after insert or update on menu_items
  deferrable initially deferred
  for each row execute function public.assert_item_has_sizes();

create or replace function public.repair_item_when_last_size_removed()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.menu_item_sizes where item_id = old.item_id) then
    update public.menu_items
       set pricing_mode = 'fixed',
           base_price = coalesce(base_price, 0),
           updated_at = now()
     where id = old.item_id
       and pricing_mode = 'sized';
  end if;
  return null;
end;
$$;

create trigger trg_repair_on_last_size_removed
  after delete on menu_item_sizes
  for each row execute function public.repair_item_when_last_size_removed();
