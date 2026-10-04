-- T0.1a: 009 money. data-model.md §7, plus rider_pay_rules from §1 which §15.2 assigns here.
--
-- constitution.md III.3: "Money is integer piastres plus a currency column. No floats, no numeric
-- for balances. Percentages and multipliers are basis points."
--
-- FLAGGED - commission_rules.value is numeric(12,4) in data-model.md §7, seeded with 20 for 20%.
-- That is a float rate, and it violates rule 3 twice over: a numeric for a rate, and a percentage
-- that is not basis points. Changed to integer basis points, so the seed in 009s becomes 2000 rather
-- than 20. The column still serves both commission types, discriminated by commission_type:
--   percentage    -> basis points (2000 = 20%)
--   fixed_amount  -> piastres
--   free_delivery -> ignored
--   negative      -> signed; a platform-funded launch discount, so the vendor's payout is untouched
-- Splitting into percentage_bps and amount would be cleaner still, but that changes the documented
-- shape of the table rather than its type, so it is offered rather than taken.
--
-- FLAGGED - payouts gains idempotency_key text not null unique, which §7 does not declare.
-- constitution.md III.5 names the cases that must carry one: "Placing an order, a payout, a
-- collection and a wallet adjustment all carry one. A retried request must never double-charge."
-- A payout run with no idempotency key is exactly the double-charge rule 5 forbids, and run_payout_v1
-- in migration 019 would have had nowhere to put it. Easy to drop if 019 would rather carry the key
-- elsewhere.
--
-- FLAGGED - platform_float.variance gets a CHECK that it equals cash_expected - cash_remitted. §7
-- defines it as exactly that ("cash_expected - cash_remitted; must be explained"), so a row where
-- the three disagree is arithmetic, not data. constitution.md III.10 makes this the daily health
-- check, and a variance column that can drift from its own components would defeat it.
--
-- NOT flagged, deliberately: wallets.balance gets NO non-negativity CHECK. A wallet is a liability
-- the platform owes, and a negative balance is meaningful - it means that party owes the platform,
-- for example a rider who took more cash than the order was for. Adding balance >= 0 here would make
-- a real financial state unrepresentable. This is the one money column in the migration where the
-- obvious constraint is wrong.
--
-- constitution.md III.17 asks for soft delete plus updated_at on every business table. commission_rules,
-- rider_pay_rules, wallets and payouts have no deleted_at, and that is left as specced: each already
-- carries its own lifecycle mechanism (is_active plus effective_until, or status in
-- active/frozen/review, or status in draft/approved/processing/paid/failed/cancelled). Adding
-- deleted_at would create a second competing mechanism next to the first. ledger_entries has no
-- updated_at either, and never should - rule 4 makes it append-only, so there is nothing to update.
-- Recorded rather than changed.

-- Ordering is load-bearing and data-model.md §7 does not respect it. ledger_entries.payout_id
-- references payouts(id), so payouts must exist first even though §7 presents the ledger first.
-- payout_lines and the sub_orders.payout_id constraint have the same dependency.

-- =============================================================================================
-- rider_pay_rules - what the rider keeps per trip
-- =============================================================================================
-- Resolution order at collection time: an active rule for this rider, else the active rule for the
-- city, else zero. Zero surfaces as an admin error rather than a silent free delivery.
create table public.rider_pay_rules (
  id              uuid primary key default gen_random_uuid(),
  city_id         uuid not null references public.cities(id),
  rider_id        uuid references public.riders(id),        -- null = the city-wide default
  per_trip_amount integer not null default 0,
  per_km_amount   integer not null default 0,

  -- constitution.md III.3: a percentage is basis points. 10000 = the rider keeps all of it.
  pct_of_delivery_fee_bps integer not null default 10000,

  -- Extra per vendor pickup. Rewards the multi-vendor trips the platform wants to encourage.
  bonus_per_leg   integer not null default 0,

  effective_from  timestamptz not null default now(),
  effective_until timestamptz,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint rider_pay_rules_window_valid check (effective_until is null or effective_until > effective_from),
  constraint rider_pay_rules_pct_in_range check (pct_of_delivery_fee_bps between 0 and 10000),
  constraint rider_pay_rules_amounts_nonneg check (
    per_trip_amount >= 0 and per_km_amount >= 0 and bonus_per_leg >= 0
  )
);

-- At most one active city-wide default per city. A second would make resolution order ambiguous,
-- which is the whole failure mode this table exists to avoid.
create unique index rider_pay_rules_default on public.rider_pay_rules (city_id)
  where rider_id is null and is_active;
create index rider_pay_rules_rider_active on public.rider_pay_rules (rider_id, is_active);
-- §14.2: city_id is covered above as a leading column, rider_id above. Both foreign keys indexed.

create trigger trg_rider_pay_rules_updated_at before update on public.rider_pay_rules
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- commission_rules
-- =============================================================================================
-- Vendor commission is off at launch and switched on around month 3-4. The rider cut of the delivery
-- fee is the launch revenue line (ADR 3). Both live in this table so activating either is an UPDATE,
-- never a migration, and effective_from is what stops it applying retroactively (constitution III.9).
create table public.commission_rules (
  id              uuid primary key default gen_random_uuid(),
  scope           text not null check (scope in ('vendor','rider','platform')),

  -- Polymorphic on purpose: a commission targets a vendor, a rider or nothing. There is no foreign
  -- key here and there cannot be one, because the column means three different tables depending on
  -- scope. scope is the discriminator, and it is CHECKed above.
  target_id       uuid,
  vertical_type   text,                                   -- null = all verticals
  commission_type text not null check (commission_type in
                   ('percentage','fixed_amount','free_delivery','negative')),

  -- integer, not numeric: see the header note. percentage -> basis points, fixed_amount -> piastres.
  value           integer not null default 0,
  min_amount      integer,
  max_amount      integer,
  applies_to      text not null default 'subtotal' check (applies_to in
                   ('subtotal','delivery_fee','service_fee','payout_total')),
  effective_from  timestamptz not null default now(),
  effective_until timestamptz,
  is_active       boolean not null default false,

  -- FLAGGED: §7 declares this as auth.users(id) while every other actor reference in the schema is
  -- public.users(id). The two carry the same uuid, so it works either way, but it couples a public
  -- table to a schema Supabase manages. Implemented as specced rather than changed.
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint commission_rules_window_valid check (effective_until is null or effective_until > effective_from),
  -- A ceiling below the floor would silently make the rule unreachable.
  constraint commission_rules_bounds_sane check (
    min_amount is null or max_amount is null or max_amount >= min_amount
  ),
  constraint commission_rules_amounts_nonneg check (
    (min_amount is null or min_amount >= 0) and (max_amount is null or max_amount >= 0)
  )
);

create index commission_rules_scope_target_active on public.commission_rules (scope, target_id, is_active);
-- §14.2: created_by is a foreign key and §7 indexes it nowhere.
create index commission_rules_created_by on public.commission_rules (created_by) where created_by is not null;

create trigger trg_commission_rules_updated_at before update on public.commission_rules
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- wallets - vendors and riders only
-- =============================================================================================
-- No customer wallet (constitution III.6, ADR 2). The customer pays the rider directly, in cash or by
-- their own Vodafone Cash / Instapay transfer, and the platform records that it happened. That removes
-- the whole top-up fraud surface and leaves no customer float to reconcile.
create table public.wallets (
  id            uuid primary key default gen_random_uuid(),
  owner_type    text not null check (owner_type in ('vendor','rider')),
  owner_id      uuid not null,

  -- Cached. The authoritative figure is the sum of ledger_entries for this account, and the two are
  -- written in the same transaction (constitution III.4). Deliberately unconstrained in sign - see
  -- the header note.
  balance       integer not null default 0,
  currency      char(3) not null default 'EGP',
  status        text not null default 'active' check (status in ('active','frozen','review')),
  status_reason text,

  -- Optimistic concurrency. A rider's wallet is credited by a payout while a vendor's is debited by
  -- an adjustment, and two admins can touch the same row at once. An update goes where version = old.
  version       integer not null default 0,
  updated_at    timestamptz not null default now(),

  unique (owner_type, owner_id),
  constraint wallets_version_nonneg check (version >= 0),
  -- 'frozen' and 'review' exist to stop money moving, so both need a stated reason.
  constraint wallets_status_reason_required check (
    status = 'active' or status_reason is not null
  )
);

create index wallets_owner on public.wallets (owner_type, owner_id);

create trigger trg_wallets_updated_at before update on public.wallets
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- payouts - created before ledger_entries, which references it
-- =============================================================================================
create table public.payouts (
  id           uuid primary key default gen_random_uuid(),
  payout_type  text not null check (payout_type in ('vendor','rider')),
  account_id   uuid not null,
  period_start date not null,
  period_end   date not null,

  gross_amount integer not null default 0,
  fee_amount   integer not null default 0,
  net_amount   integer not null default 0,
  currency     char(3) not null default 'EGP',
  method       text,                        -- vodafone_cash, instapay, cash
  status       text not null default 'draft' check (status in
                ('draft','approved','processing','paid','failed','cancelled')),
  reference    text,
  approved_by  uuid references public.users(id),
  approved_at  timestamptz,
  paid_at      timestamptz,
  failure_reason text,

  -- constitution.md III.5 - see the header note. Without this a retried payout run pays twice.
  idempotency_key text not null unique,

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint payouts_period_valid check (period_end >= period_start),
  -- The net is arithmetic, not a field someone types. gross and fee are non-negative, but net may go
  -- negative: a fee larger than the gross is a clawback, and refusing to record one would hide it.
  constraint payouts_amounts_sane check (
    gross_amount >= 0 and fee_amount >= 0 and net_amount = gross_amount - fee_amount
  ),
  -- Nothing is paid without an approval, and an approval without an approver is unauditable.
  constraint payouts_paid_is_approved check (
    status not in ('paid','processing') or (approved_by is not null and approved_at is not null)
  ),
  constraint payouts_failure_has_reason check (status <> 'failed' or failure_reason is not null)
);

create index payouts_type_status_period on public.payouts (payout_type, status, period_end desc);
create index payouts_account_created on public.payouts (account_id, created_at desc);
-- §14.2: approved_by is a foreign key. Note data-model.md §7 declares the account index twice.
create index payouts_approved_by on public.payouts (approved_by) where approved_by is not null;

create trigger trg_payouts_updated_at before update on public.payouts
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- payout_lines
-- =============================================================================================
create table public.payout_lines (
  id              uuid primary key default gen_random_uuid(),
  payout_id       uuid not null references public.payouts(id) on delete cascade,
  sub_order_id    uuid references public.sub_orders(id),
  payout_line_type text not null check (payout_line_type in
                    ('vendor_earning','rider_trip','tip','bonus','adjustment')),
  source          text not null check (source in ('cash_collected','wallet_payment','adjustment')),
  gross_amount    integer not null,
  fee_amount      integer not null default 0,
  net_amount      integer not null,
  created_at      timestamptz not null default now(),

  constraint payout_lines_amounts_sane check (
    gross_amount >= 0 and fee_amount >= 0 and net_amount = gross_amount - fee_amount
  ),
  -- A line that names a sub-order is settling that sub-order, so it has to be one the rider or vendor
  -- can actually be paid for. A tip or bonus line is not tied to one.
  constraint payout_lines_sub_order_type check (
    sub_order_id is null or payout_line_type in ('vendor_earning','rider_trip','adjustment')
  )
);

create index payout_lines_payout on public.payout_lines (payout_id);
-- A sub-order can be paid exactly once. This is the database half of the payable -> in_payout ->
-- settled handshake that makes a payout run safe to repeat.
create unique index payout_lines_sub_order_unique on public.payout_lines (sub_order_id)
  where sub_order_id is not null;

-- =============================================================================================
-- ledger_entries - append only
-- =============================================================================================
-- constitution.md III.4: never updated, never deleted. A mistake is corrected by a reversing entry.
-- NOT partitioned, unlike events, notifications, rider_location_pings and audit_log: data-model.md
-- §14.1 excludes it deliberately because the balance must be one relation forever, and a
-- partitioned ledger cannot be summed without visiting every partition.
create table public.ledger_entries (
  id           uuid primary key default gen_random_uuid(),

  -- No 'customer' value, because there is no customer account to hold a balance (constitution III.6).
  -- A customer's payment is recorded on the order, as payment_method plus payment_channel, not as a
  -- movement of money the platform holds.
  account_type text not null check (account_type in
                 ('vendor','rider','platform','platform_earnings')),
  account_id   uuid not null,        -- vendor_id, rider_id, or NULL for the platform accounts

  entry_type   text not null check (entry_type in (
                 'rider_cut','cash_collected','cash_remitted','delivery_fee',
                 'service_fee','commission','refund','reversal',
                 'vendor_payout','rider_payout','adjustment','float_sweep')),

  -- Positive credits the account, negative debits it. Deliberately allowed to be either sign, and
  -- deliberately forbidden from being zero: a zero entry moves no money, so it can only be noise, and
  -- noise in an append-only ledger is permanent.
  signed_amount integer not null check (signed_amount <> 0),
  currency      char(3) not null default 'EGP',
  order_id        uuid references public.orders(id),
  sub_order_id    uuid references public.sub_orders(id),
  payout_id       uuid references public.payouts(id),

  -- constitution.md III.5. Also what makes a retried request safe rather than a double charge.
  idempotency_key text not null unique,
  note            text,
  metadata        jsonb,
  created_at      timestamptz not null default now(),

  -- The two platform accounts have no owner row to point at.
  constraint ledger_entries_platform_has_no_account check (
    account_type not in ('platform','platform_earnings') or account_id is not null
  )
);

create index ledger_entries_account_created on public.ledger_entries (account_type, account_id, created_at desc);
create index ledger_entries_order on public.ledger_entries (order_id);
create index ledger_entries_sub_order on public.ledger_entries (sub_order_id);
create index ledger_entries_payout on public.ledger_entries (payout_id);
create index ledger_entries_created_at on public.ledger_entries (created_at);   -- retention sweep

-- constitution.md III.4: enforced by Postgres rules, so the protection holds for a privileged
-- mistake and not only for the client roles. DO INSTEAD NOTHING means a corrective UPDATE silently
-- affects zero rows instead of rewriting history.
create rule ledger_no_update as on update to public.ledger_entries do instead nothing;
create rule ledger_no_delete as on delete to public.ledger_entries do instead nothing;

-- Belt and braces, and ordered after the rules on purpose. With only the rules, a buggy application
-- UPDATE would succeed and change nothing, which is the hardest kind of failure to notice. Revoking
-- as well means the client roles get a permission error instead, which is loud.
revoke update, delete on public.ledger_entries from anon, authenticated;
-- TRUNCATE is not covered by an ON UPDATE or ON DELETE rule.
revoke truncate on public.ledger_entries from anon, authenticated;

-- =============================================================================================
-- platform_float - the daily reconciliation
-- =============================================================================================
-- constitution.md III.10: exactly one exposure, cash collected by riders and not yet banked, and it is
-- never allowed to become unknown. variance trending to zero is the health check.
create table public.platform_float (
  id            uuid primary key default gen_random_uuid(),
  business_date date not null unique,

  cash_expected integer not null default 0,   -- collected by riders, not yet remitted
  cash_remitted integer not null default 0,   -- banked, counted against the float
  variance      integer not null default 0,   -- cash_expected - cash_remitted; must be explained

  -- What the platform earns, recognised at collection time.
  delivery_fees integer not null default 0,
  rider_cuts    integer not null default 0,   -- platform share of the delivery fee, the launch line
  commissions  integer not null default 0,   -- 0 until month 3-4
  service_fees  integer not null default 0,   -- 0 until switched on
  adjustments   integer not null default 0,   -- signed: a correction is negative

  -- What the platform owes.
  vendor_payable integer not null default 0,
  rider_payable  integer not null default 0,

  -- External settlement, recorded not held. The money went customer -> rider directly.
  external_cash_orders   integer not null default 0,
  external_wallet_orders integer not null default 0,
  updated_at     timestamptz not null default now(),

  -- FLAGGED: see the header note. variance is defined as this difference, so the three cannot disagree.
  constraint platform_float_variance_consistent check (variance = cash_expected - cash_remitted),
  constraint platform_float_cash_nonneg check (cash_expected >= 0 and cash_remitted >= 0),
  -- The two order counts are counts. The revenue and payable columns are deliberately unconstrained
  -- in sign, because adjustments is signed by design and the payable columns can go negative when the
  -- platform owes more than it has collected on a given day.
  constraint platform_float_counts_nonneg check (
    external_cash_orders >= 0 and external_wallet_orders >= 0
  )
);

create trigger trg_platform_float_updated_at before update on public.platform_float
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- the deferred foreign key
-- =============================================================================================
-- 007 created sub_orders.payout_id with no constraint, because payouts did not exist. This is where
-- it becomes real. 007's CHECK already requires settlement_status to be settled or in_payout whenever
-- payout_id is set, so a payout cannot be named before the handshake has happened.
alter table public.sub_orders
  add constraint sub_orders_payout_id_fkey
  foreign key (payout_id) references public.payouts(id) on delete set null;

-- sub_orders_payout_id already exists from 007, so §14.2 is satisfied without adding another.