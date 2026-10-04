-- T0.1a follow-up. Six defects found by AUDITING THE APPLIED SCHEMA, each reproduced on the live
-- database before being fixed here. 005 and 005a are already applied, so this is a new migration
-- rather than an edit to them.
--
--   A. A 'sized' item that lost every size became a 'fixed' item priced ZERO. Sellable for free.
--   B. menu_items.vendor_id could be desynced from its category, listing an item under a
--      competitor's storefront.
--   C. bump_menu_version was a row-level trigger: one UPDATE vendors per catalog row, so a
--      200-row import ran 200 UPDATEs against the same row.
--   D. Four money columns had no non-negative CHECK. A negative per_km_fee makes the delivery
--      fee fall as the distance grows.
--   E. vendor_earnings_daily, user_auth_providers and user_roles were hard-deletable. The first
--      is a financial record.
--   F. vendors.slug was UNIQUE globally while vendors is soft-deletable, so a deleted vendor
--      squatted its slug forever.
--   G. Nothing forced delivery_fee_tiers.multiplier_bps to rise with vendor_count, so adding a
--      second vendor could make delivery cheaper.

-- =============================================================================================
-- A. Deleting the last size must not invent a price
-- =============================================================================================
-- 005 shipped repair_item_when_last_size_removed, which flipped the item to 'fixed' and set
-- base_price = coalesce(base_price, 0). A 'sized' item has base_price NULL by definition, so the
-- repair always produced a ZERO price: a free, orderable item.
--
-- The fix is to stop repairing. There is no correct price to invent, so the deletion is rejected
-- and the vendor must make a decision: add a size, or switch the item to 'fixed' with a real
-- price. Deferring to COMMIT lets a multi-step edit delete two sizes and add a replacement in one
-- transaction.
create or replace function public.assert_item_still_sized()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_item uuid;
begin
  v_item := old.item_id;

  -- The parent item is gone, so this was a cascade from deleting the item. Nothing to protect.
  if not exists (select 1 from public.menu_items where id = v_item) then
    return null;
  end if;

  if exists (select 1 from public.menu_items where id = v_item and pricing_mode = 'sized')
     and not exists (select 1 from public.menu_item_sizes where item_id = v_item) then
    raise exception
      'LAST_SIZE_REMOVED: item % is sized but would have no sizes left. Add a size, or set the item to fixed with a price.',
      v_item using errcode = 'P0001';
  end if;
  return null;
end $$;

drop trigger if exists trg_repair_on_last_size_removed on public.menu_item_sizes;
drop function if exists public.repair_item_when_last_size_removed();

create constraint trigger trg_item_still_sized
  after delete on public.menu_item_sizes
  deferrable initially deferred
  for each row execute function public.assert_item_still_sized();

-- A CHECK cannot express this, but it can cheaply forbid the state the trigger guards against:
-- a fixed item must carry a price. Kept as the row-level half of the pair.
alter table public.menu_items drop constraint if exists fixed_item_has_price;
alter table public.menu_items
  add constraint fixed_item_has_price
  check (pricing_mode <> 'fixed' or base_price is not null);

-- =============================================================================================
-- B. vendor_id must be derived on every write, not only when category_id changes
-- =============================================================================================
-- sync_menu_item_vendor was BEFORE INSERT OR UPDATE OF category_id, so a bare
-- `UPDATE menu_items SET vendor_id = <other>` never re-derived the value and the denormalised
-- copy drifted. Reproduced: an item under vendor A's category claimed vendor B.
create or replace function public.sync_menu_item_vendor()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- No UPDATE OF column list. Any UPDATE re-derives, so the column can never drift.
  new.vendor_id := (select c.vendor_id from public.menu_categories c where c.id = new.category_id);
  return new;
end $$;

drop trigger if exists trg_menu_item_vendor on public.menu_items;
create trigger trg_menu_item_vendor before insert or update on public.menu_items
for each row execute function public.sync_menu_item_vendor();

-- =============================================================================================
-- C. One menu_version bump per statement, not per row
-- =============================================================================================
-- The row-level version ran a separate UPDATE vendors for every catalog row touched. Four
-- statement-level triggers with transition tables do the same work in one UPDATE each.
--
-- The row-level function is dropped rather than left unused: no dead code.
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

drop trigger if exists trg_bump_menu_version_categories on public.menu_categories;
drop trigger if exists trg_bump_menu_version_items on public.menu_items;
drop trigger if exists trg_bump_menu_version_sizes on public.menu_item_sizes;
drop trigger if exists trg_bump_menu_version_options on public.item_options;
drop trigger if exists trg_bump_menu_version_choices on public.option_choices;
drop function if exists public.bump_menu_version();

-- AFTER only: a statement trigger cannot fire BEFORE, and none of these read the row again.
--
-- A transition table is only permitted on a trigger with a SINGLE event, so INSERT and UPDATE
-- each need their own trigger. Generated in a loop rather than written out ten times by hand.
do $$
declare
  r record;
begin
  for r in
    select * from (values
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

-- =============================================================================================
-- D. Guard every money column at the row level
-- =============================================================================================
-- per_km_fee was the dangerous one: a negative value makes the delivery fee DECREASE as the
-- distance grows, and can drive the order total negative.
alter table public.delivery_zones drop constraint if exists per_km_fee_nonneg;
alter table public.delivery_zones add constraint per_km_fee_nonneg check (per_km_fee >= 0);

alter table public.delivery_zones drop constraint if exists min_order_value_nonneg;
alter table public.delivery_zones add constraint min_order_value_nonneg check (min_order_value >= 0);

alter table public.delivery_zones drop constraint if exists max_vendors_per_order_range;
alter table public.delivery_zones add constraint max_vendors_per_order_range
  check (max_vendors_per_order between 1 and 10);

-- A negative override would subtract from the delivery fee the customer is quoted.
alter table public.vendors drop constraint if exists delivery_fee_override_valid;
alter table public.vendors add constraint delivery_fee_override_valid
  check (delivery_fee_override is null or delivery_fee_override >= 0);

alter table public.vendors drop constraint if exists minimum_order_value_nonneg;
alter table public.vendors add constraint minimum_order_value_nonneg check (minimum_order_value >= 0);

-- An inverted prep window would make the quoted ready-by time earlier than the minimum.
alter table public.vendors drop constraint if exists prep_window_valid;
alter table public.vendors add constraint prep_window_valid
  check (prep_time_max_minutes is null or prep_time_minutes is null
         or prep_time_max_minutes >= prep_time_minutes);

-- price_modifier may legitimately be negative for a discount, so it is floored rather than
-- pinned to zero: unbounded negative would let a choice make an item free.
alter table public.option_choices drop constraint if exists price_modifier_floor;
alter table public.option_choices add constraint price_modifier_floor check (price_modifier >= -100000);

-- =============================================================================================
-- E. Stop destroying business records
-- =============================================================================================
-- vendor_earnings_daily is money. A hard DELETE there is unrecoverable and unauditable.
alter table public.vendor_earnings_daily add column if not exists deleted_at timestamptz;
create index if not exists vendor_earnings_daily_live
  on public.vendor_earnings_daily (vendor_id, business_date) where deleted_at is null;

-- user_auth_providers is the record of which identity provider authenticated a person. Deleting
-- it destroys audit evidence and silently breaks re-login for that provider.
alter table public.user_auth_providers add column if not exists deleted_at timestamptz;
create unique index if not exists user_auth_providers_provider_active
  on public.user_auth_providers (provider_type, provider_id) where deleted_at is null;

-- user_roles gets a revoke timestamp instead of a DELETE, so a stripped permission leaves a
-- record that it ever existed and when it was taken away.
alter table public.user_roles add column if not exists revoked_at timestamptz;
create index if not exists user_roles_active on public.user_roles (user_id) where revoked_at is null;

-- The admin check must ignore revoked grants, or revocation would be a no-op.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles r
    where r.user_id = (select auth.uid()) and r.role = 'admin' and r.revoked_at is null
  );
$$;

grant execute on function public.is_admin() to authenticated;

-- =============================================================================================
-- F. A soft-deleted vendor must not squat its slug forever
-- =============================================================================================
-- The global UNIQUE on slug still applies to soft-deleted rows, so a name could never be reused.
alter table public.vendors drop constraint if exists vendors_slug_key;
create unique index vendors_slug_live on public.vendors (slug) where deleted_at is null;

-- =============================================================================================
-- G. A bigger basket may not make delivery cheaper
-- =============================================================================================
-- Nothing stopped an admin from setting 1 vendor = 12000 and 2 vendors = 10000, which would
-- reward the customer for splitting one order into two. Enforced as a trigger because it spans
-- the rows of a tier set.
create or replace function public.assert_fee_tiers_monotonic()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_zone uuid;
begin
  v_zone := coalesce(new.delivery_zone_id, old.delivery_zone_id);

  if exists (
    select 1 from public.delivery_fee_tiers a
    join public.delivery_fee_tiers b on b.delivery_zone_id = a.delivery_zone_id
    where a.delivery_zone_id = v_zone
      and a.vendor_count < b.vendor_count
      and a.multiplier_bps > b.multiplier_bps
  ) then
    raise exception
      'FEE_TIER_NOT_MONOTONIC: zone % has a lower vendor_count with a higher multiplier_bps', v_zone
      using errcode = 'P0001';
  end if;
  return null;
end $$;

create constraint trigger trg_fee_tiers_monotonic
  after insert or update on public.delivery_fee_tiers
  deferrable initially deferred
  for each row execute function public.assert_fee_tiers_monotonic();