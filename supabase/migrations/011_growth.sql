-- T0.1a: 011 growth. data-model.md §9 - vouchers, voucher_redemptions, promo_slots.
--
-- constitution.md III.3, the same correction 009 made to commission_rules.value:
--   "Money is integer piastres plus a currency column. No floats, no numeric for balances.
--    Percentages and multipliers are basis points."
--
-- FLAGGED - vouchers.discount_value is numeric(12,2) in §9. That is a float rate and it breaks
-- rule III.3 twice: a numeric where none is allowed, and a percentage that is not basis points.
-- Changed to integer, on the same basis as commission_rules:
--   percentage    -> basis points (2000 = 20%)
--   fixed_amount  -> piastres
--   free_delivery -> see below
--
-- FLAGGED - §9 requires discount_value > 0 for EVERY discount_type, including free_delivery, where a
-- magnitude is meaningless. Not silently changed: a free-delivery voucher still has to carry *some*
-- positive value to satisfy the column, and deciding what it should be is a product question. Left as
-- specced so nothing rejects a row the spec allows.
--
-- FLAGGED - vouchers.applies_to_vendor_ids is uuid[], which is `vendors.area_ids` renamed, and
-- constitution III.13 names that exact pattern: "Anything that is filtered, joined or sorted on is a
-- real column or a real table, never a JSON array." It is filtered on, so the primary clause applies.
-- BUT the rationale III.13 gives - "JSON arrays cannot be indexed; forces a scan on every
-- availability check" - is weaker here, and measured rather than assumed: a GIN index on uuid[] does
-- work on Postgres 17, and one is created below, so the membership branch of the lookup is indexed.
-- What GIN still cannot serve is the other branch, `applies_to_vendor_ids = '{}'`, which means ALL
-- vendors. A join table also cannot express "all vendors" without a sentinel, which is why this is
-- not converted unilaterally. Recorded as an open question rather than resolved here.
--
-- FLAGGED - vouchers.usage_count is a cached counter with nothing keeping it equal to
-- count(voucher_redemptions), and usage_limit_total was previously enforced by application logic
-- alone. A CHECK now bounds usage_count by the limit, so the cap holds at the database rather than in
-- whichever RPC remembers to check. The counter can still drift from the redemptions; making it
-- derived or trigger-maintained is a larger change and is flagged.
--
-- FLAGGED - vouchers.code is UNIQUE case-sensitively, so "save20" and "SAVE20" would both be
-- redeemable. A second unique index on upper(code) makes codes case-insensitively unique without
-- changing how a code is stored or displayed. Voucher codes are typed by hand from a poster, so this
-- is a real ambiguity rather than a theoretical one.

-- =============================================================================================
-- vouchers
-- =============================================================================================
create table public.vouchers (
  id                 uuid primary key default gen_random_uuid(),

  -- Stored as typed, but compared case-insensitively by vouchers_code_upper below.
  code               text not null unique,
  name               text,

  discount_type      text not null check (discount_type in ('percentage','fixed_amount','free_delivery')),

  -- integer, not numeric: see the header note. percentage -> basis points, fixed_amount -> piastres.
  discount_value     integer not null check (discount_value > 0),
  min_order_value    integer not null default 0,
  max_discount_cap   integer,

  -- null = unlimited. Both are ceilings rather than counts, so a zero would mean "never redeemable",
  -- which is what is_active is for.
  usage_limit_total  integer check (usage_limit_total is null or usage_limit_total > 0),
  usage_limit_per_user integer check (usage_limit_per_user is null or usage_limit_per_user > 0),

  -- Cached count of redemptions. See the header note on drift.
  usage_count        integer not null default 0,

  applies_to_vendor_ids uuid[] not null default '{}',   -- empty = all vendors
  vertical_type      text,                              -- null = all verticals
  first_order_only   boolean not null default false,
  valid_from         timestamptz not null default now(),
  valid_until        timestamptz,
  is_active          boolean not null default true,
  created_by         uuid references public.users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint vouchers_window_valid check (valid_until is null or valid_until > valid_from),

  -- A discount cannot exceed the order. 10000 bps is 100%, so anything above it is not a discount.
  -- Only meaningful for percentage, which is why it is scoped by the type rather than applied to
  -- every row: a fixed_amount of 250000 piastres is a perfectly valid 2,500 EGP off a large order.
  constraint vouchers_percentage_sane check (
    discount_type <> 'percentage' or discount_value <= 10000
  ),

  constraint vouchers_money_nonneg check (min_order_value >= 0 and max_discount_cap >= 0),

  -- The cap, enforced in the database. Before this, nothing stopped usage_count passing
  -- usage_limit_total except whichever RPC remembered to look.
  constraint vouchers_within_usage_limit check (
    usage_limit_total is null or usage_count <= usage_limit_total
  ),
  constraint vouchers_usage_count_nonneg check (usage_count >= 0)
);

create index vouchers_active_window on public.vouchers (is_active, valid_from, valid_until);

-- Case-insensitive uniqueness, so "save20" and "SAVE20" cannot both exist. Additional to the
-- case-sensitive unique on code itself, which stays so the stored value round-trips exactly.
create unique index vouchers_code_upper on public.vouchers (upper(code));

-- Serves the "= ANY(applies_to_vendor_ids)" branch of the applicability lookup. It cannot serve the
-- "= '{}'" branch - all vendors - which is half the reason this column is still an open question.
create index vouchers_applies_to_vendor_ids on public.vouchers using gin (applies_to_vendor_ids);

-- §14.2: created_by is a foreign key and §9 indexes it nowhere.
create index vouchers_created_by on public.vouchers (created_by) where created_by is not null;

create trigger trg_vouchers_updated_at before update on public.vouchers
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- voucher_redemptions
-- =============================================================================================
create table public.voucher_redemptions (
  id               uuid primary key default gen_random_uuid(),
  voucher_id       uuid not null references public.vouchers(id) on delete cascade,
  user_id          uuid not null references public.users(id) on delete cascade,
  order_id         uuid references public.orders(id) on delete set null,
  sub_order_id     uuid references public.sub_orders(id) on delete set null,

  -- What this voucher actually took off. Money, so guarded. Zero would mean a redemption that
  -- discounted nothing, which is either a bug or a voucher applied to a zero-value order.
  discount_amount  integer not null check (discount_amount > 0),
  created_at       timestamptz not null default now()
);

-- Stops a double-submit consuming two redemptions, which is what would otherwise happen on a retry.
create unique index voucher_redemption_order on public.voucher_redemptions (voucher_id, order_id)
  where order_id is not null;

-- §14.2: voucher_id leads both indexes above. user_id and order_id lead none of them, so neither is
-- covered and both need their own. "Which vouchers has this customer used" and "what was spent on
-- this order" are both real questions the redemption table is asked.
create index voucher_redemptions_user on public.voucher_redemptions (user_id);
create index voucher_redemptions_order on public.voucher_redemptions (order_id)
  where order_id is not null;
create index voucher_redemptions_voucher_user on public.voucher_redemptions (voucher_id, user_id);
create index voucher_redemptions_sub_order on public.voucher_redemptions (sub_order_id)
  where sub_order_id is not null;

-- =============================================================================================
-- promo_slots
-- =============================================================================================
-- Modelled but unsold - open-questions.md §5.7 records that ads revenue is deliberately not a v1
-- line. The table exists so the app's home screen has a stable shape and so selling a slot later is
-- a data change rather than a release.
create table public.promo_slots (
  id          uuid primary key default gen_random_uuid(),
  city_id     uuid not null references public.cities(id),
  slot_key    text not null,                 -- 'home_banner_1'

  -- {"ar":"...","en":"..."} - rendered whole, never filtered on, so an object is correct here under
  -- III.13. The shape is still constrained so a string cannot land in a column every reader expects
  -- to be a dictionary.
  title       jsonb not null check (jsonb_typeof(title) = 'object'),
  subtitle    jsonb check (subtitle is null or jsonb_typeof(subtitle) = 'object'),
  image_path  text,

  -- Polymorphic, and therefore not a foreign key: target_id names a vendor, a vertical, an area or
  -- a URL depending on target_type, and one column cannot carry four constraints. Same class as
  -- wallets.owner_id and commission_rules.target_id - open question 3.14.
  target_type text check (target_type in ('vendor','vertical','area','url')),
  target_id   text,

  starts_at   timestamptz,
  ends_at     timestamptz,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  unique (city_id, slot_key),
  -- city_id leads the unique constraint, so §14.2 is already satisfied for that foreign key.
  constraint promo_slots_window_valid check (ends_at is null or starts_at is null or ends_at > starts_at),
  -- A slot that names a target type but no target id cannot be navigated to, and one that names an
  -- id with no type cannot be interpreted.
  constraint promo_slots_target_pair check (
    (target_type is null and target_id is null) or (target_type is not null and target_id is not null)
  )
);

create index promo_slots_active_sort on public.promo_slots (city_id, sort_order)
  where is_active;

create trigger trg_promo_slots_updated_at before update on public.promo_slots
  for each row execute function public.set_updated_at();