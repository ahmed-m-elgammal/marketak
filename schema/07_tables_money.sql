-- =============================================================================
-- 07_tables_money.sql
-- Wallets, ledger, payouts, platform float and commission configuration.
--
-- The platform holds no customer money. There is no customer wallet and no
-- top-up flow. `wallets.owner_type` is restricted to 'vendor' and 'rider' by
-- CHECK. What the platform tracks is the CASH the rider physically holds for
-- cash-on-delivery orders, which is a liability to reconcile, not a balance to
-- top up.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- wallets: one balance per vendor or rider. `version` is the optimistic-lock
-- counter; `status` can be frozen pending review, and a non-active wallet must
-- carry a reason.
-- -----------------------------------------------------------------------------
create table public.wallets
(
  id uuid not null default gen_random_uuid(),
  owner_type text not null,
  owner_id uuid not null,
  balance integer not null default 0,
  currency character(3) not null default 'EGP'::bpchar,
  status text not null default 'active'::text,
  status_reason text,
  version integer not null default 0,
  updated_at timestamp with time zone not null default now(),

  constraint wallets_owner_type_check check CHECK ((owner_type = ANY (ARRAY['vendor'::text, 'rider'::text]))),
  constraint wallets_owner_type_owner_id_key unique UNIQUE (owner_type, owner_id),
  constraint wallets_pkey primary key PRIMARY KEY (id),
  constraint wallets_status_check check CHECK ((status = ANY (ARRAY['active'::text, 'frozen'::text, 'review'::text]))),
  constraint wallets_status_reason_required check CHECK (((status = 'active'::text) OR (status_reason IS NOT NULL))),
  constraint wallets_version_nonneg check CHECK ((version >= 0))
);

-- -----------------------------------------------------------------------------
-- ledger_entries: the append-only double-entry-ish journal. Every money
-- movement in the system writes here with a UNIQUE idempotency_key, so a
-- retried RPC cannot double-post.
--
--   account_type : vendor | rider | platform | platform_earnings
--   account_id   : required for vendor/rider, must be NULL for platform
--   signed_amount: must be non-zero; the sign carries direction
--
-- 'platform' and 'platform_earnings' are two distinct platform accounts — the
-- former is the operating float, the latter accumulated earnings.
-- -----------------------------------------------------------------------------
create table public.ledger_entries
(
  id uuid not null default gen_random_uuid(),
  account_type text not null,
  account_id uuid,
  entry_type text not null,
  signed_amount integer not null,
  currency character(3) not null default 'EGP'::bpchar,
  order_id uuid,
  sub_order_id uuid,
  payout_id uuid,
  idempotency_key text not null,
  note text,
  metadata jsonb,
  created_at timestamp with time zone not null default now(),

  constraint ledger_entries_account_required check CHECK ((((account_type = ANY (ARRAY['vendor'::text, 'rider'::text])) AND (account_id IS NOT NULL)) OR ((account_type = ANY (ARRAY['platform'::text, 'platform_earnings'::text])) AND (account_id IS NULL)))),
  constraint ledger_entries_account_type_check check CHECK ((account_type = ANY (ARRAY['vendor'::text, 'rider'::text, 'platform'::text, 'platform_earnings'::text]))),
  constraint ledger_entries_entry_type_check check CHECK ((entry_type = ANY (ARRAY['rider_cut'::text, 'cash_collected'::text, 'cash_remitted'::text, 'delivery_fee'::text, 'service_fee'::text, 'commission'::text, 'refund'::text, 'reversal'::text, 'vendor_payout'::text, 'rider_payout'::text, 'adjustment'::text, 'float_sweep'::text]))),
  constraint ledger_entries_idempotency_key_key unique UNIQUE (idempotency_key),
  constraint ledger_entries_pkey primary key PRIMARY KEY (id),
  constraint ledger_entries_signed_amount_check check CHECK ((signed_amount <> 0))
);

-- -----------------------------------------------------------------------------
-- payouts: a batch settlement to one vendor or one rider over a date range.
--   net_amount = gross_amount - fee_amount
-- A payout may not reach 'paid' or 'processing' without a named approver.
-- `idempotency_key` is UNIQUE so a retried payout run is a no-op.
-- -----------------------------------------------------------------------------
create table public.payouts
(
  id uuid not null default gen_random_uuid(),
  payout_type text not null,
  account_id uuid not null,
  period_start date not null,
  period_end date not null,
  gross_amount integer not null default 0,
  fee_amount integer not null default 0,
  net_amount integer not null default 0,
  currency character(3) not null default 'EGP'::bpchar,
  method text,
  status text not null default 'draft'::text,
  reference text,
  approved_by uuid,
  approved_at timestamp with time zone,
  paid_at timestamp with time zone,
  failure_reason text,
  idempotency_key text not null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),

  constraint payouts_amounts_sane check CHECK (((gross_amount >= 0) AND (fee_amount >= 0) AND (net_amount = (gross_amount - fee_amount)))),
  constraint payouts_failure_has_reason check CHECK (((status <> 'failed'::text) OR (failure_reason IS NOT NULL))),
  constraint payouts_idempotency_key_key unique UNIQUE (idempotency_key),
  constraint payouts_paid_is_approved check CHECK (((status <> ALL (ARRAY['paid'::text, 'processing'::text])) OR ((approved_by IS NOT NULL) AND (approved_at IS NOT NULL)))),
  constraint payouts_payout_type_check check CHECK ((payout_type = ANY (ARRAY['vendor'::text, 'rider'::text]))),
  constraint payouts_period_valid check CHECK ((period_end >= period_start)),
  constraint payouts_pkey primary key PRIMARY KEY (id),
  constraint payouts_status_check check CHECK ((status = ANY (ARRAY['draft'::text, 'approved'::text, 'processing'::text, 'paid'::text, 'failed'::text, 'cancelled'::text])))
);

-- -----------------------------------------------------------------------------
-- payout_lines: the composition of a payout. The `payout_lines_shape` CHECK is
-- the interesting one: it forces each line type to reference exactly the right
-- source row, so a vendor earning can never be attributed to a trip and a tip
-- can never be orphaned.
--   vendor_earning -> sub_order_id set,  assignment_id null
--   rider_trip     -> assignment_id set,  sub_order_id null
--   tip / bonus    -> assignment_id set,  sub_order_id null
--   adjustment     -> both null
-- -----------------------------------------------------------------------------
create table public.payout_lines
(
  id uuid not null default gen_random_uuid(),
  payout_id uuid not null,
  sub_order_id uuid,
  payout_line_type text not null,
  source text not null,
  gross_amount integer not null,
  fee_amount integer not null default 0,
  net_amount integer not null,
  created_at timestamp with time zone not null default now(),
  assignment_id uuid,

  constraint payout_lines_amounts_sane check CHECK (((gross_amount >= 0) AND (fee_amount >= 0) AND (net_amount = (gross_amount - fee_amount)))),
  constraint payout_lines_payout_line_type_check check CHECK ((payout_line_type = ANY (ARRAY['vendor_earning'::text, 'rider_trip'::text, 'tip'::text, 'bonus'::text, 'adjustment'::text]))),
  constraint payout_lines_pkey primary key PRIMARY KEY (id),
  constraint payout_lines_shape check CHECK ((((payout_line_type = 'vendor_earning'::text) AND (sub_order_id IS NOT NULL) AND (assignment_id IS NULL)) OR ((payout_line_type = 'rider_trip'::text) AND (sub_order_id IS NULL) AND (assignment_id IS NOT NULL)) OR ((payout_line_type = ANY (ARRAY['tip'::text, 'bonus'::text])) AND (sub_order_id IS NULL) AND (assignment_id IS NOT NULL)) OR ((payout_line_type = 'adjustment'::text) AND (sub_order_id IS NULL) AND (assignment_id IS NULL)))),
  constraint payout_lines_source_check check CHECK ((source = ANY (ARRAY['cash_collected'::text, 'wallet_payment'::text, 'adjustment'::text])))
);

-- -----------------------------------------------------------------------------
-- platform_float: one row per business date reconciling cash in vs cash
-- remitted. `variance = cash_expected - cash_remitted` is derived and
CHECK-
-- enforced, so a discrepancy can never be stored without being visible.
-- The variance may be explained (reconcile_day_v1) but never silently closed.
-- -----------------------------------------------------------------------------
create table public.platform_float
(
  id uuid not null default gen_random_uuid(),
  business_date date not null,
  cash_expected integer not null default 0,
  cash_remitted integer not null default 0,
  variance integer not null default 0,
  delivery_fees integer not null default 0,
  rider_cuts integer not null default 0,
  commissions integer not null default 0,
  service_fees integer not null default 0,
  adjustments integer not null default 0,
  vendor_payable integer not null default 0,
  rider_payable integer not null default 0,
  external_cash_orders integer not null default 0,
  external_wallet_orders integer not null default 0,
  updated_at timestamp with time zone not null default now(),
  variance_explained_at timestamp with time zone,
  variance_explained_amount integer,
  variance_explanation text,

  constraint platform_float_business_date_key unique UNIQUE (business_date),
  constraint platform_float_cash_nonneg check CHECK (((cash_expected >= 0) AND (cash_remitted >= 0))),
  constraint platform_float_counts_nonneg check CHECK (((external_cash_orders >= 0) AND (external_wallet_orders >= 0))),
  constraint platform_float_pkey primary key PRIMARY KEY (id),
  constraint platform_float_variance_consistent check CHECK ((variance = (cash_expected - cash_remitted)))
);

-- -----------------------------------------------------------------------------
-- commission_rules: configurable platform commission. Resolution is most
-- specific wins: vendor/rider target beats scope-only, then vertical_type.
-- `value` is basis points for 'percentage', minor units for 'fixed_amount';
-- 'negative' lets a rule REDUCE the commission. All rows ship inactive and
-- must be activated deliberately.
-- -----------------------------------------------------------------------------
create table public.commission_rules
(
  id uuid not null default gen_random_uuid(),
  scope text not null,
  target_id uuid,
  vertical_type text,
  commission_type text not null,
  value integer not null default 0,
  min_amount integer,
  max_amount integer,
  applies_to text not null default 'subtotal'::text,
  effective_from timestamp with time zone not null default now(),
  effective_until timestamp with time zone,
  is_active boolean not null default false,
  created_by uuid,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),

  constraint commission_rules_amounts_nonneg check CHECK ((((min_amount IS NULL) OR (min_amount >= 0)) AND ((max_amount IS NULL) OR (max_amount >= 0)))),
  constraint commission_rules_applies_to_check check CHECK ((applies_to = ANY (ARRAY['subtotal'::text, 'delivery_fee'::text, 'service_fee'::text, 'payout_total'::text]))),
  constraint commission_rules_bounds_sane check CHECK (((min_amount IS NULL) OR (max_amount IS NULL) OR (max_amount >= min_amount))),
  constraint commission_rules_commission_type_check check CHECK ((commission_type = ANY (ARRAY['percentage'::text, 'fixed_amount'::text, 'free_delivery'::text, 'negative'::text]))),
  constraint commission_rules_pkey primary key PRIMARY KEY (id),
  constraint commission_rules_scope_check check CHECK ((scope = ANY (ARRAY['vendor'::text, 'rider'::text, 'platform'::text]))),
  constraint commission_rules_window_valid check CHECK (((effective_until IS NULL) OR (effective_until > effective_from)))
);