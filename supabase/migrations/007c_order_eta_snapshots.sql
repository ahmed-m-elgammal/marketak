-- T0.1a: 007c order_eta_snapshots. Completes data-model.md §6, which declares this table in the
-- orders domain and lists it against migration 007 in §15.2. 007 shipped without it.
--
-- Exists so one question is a query rather than an argument: "were we late?". For every snapshot,
-- promised_at is what the customer was shown and predicted_at is what the system believed at
-- computed_at. The gap between predicted_at and promised_at is the ETA error, and it is the only
-- honest measure of whether quoted ETAs can be trusted.
--
-- Deliberately a plain DDL translation with no additions, which is not how 006, 007 or 008 were
-- written. Three reasons, recorded so the omission is a decision rather than an oversight:
--
--   * No money columns. The CHECK discipline 007 established has nothing to guard here.
--   * No append-only revoke. This table is pruned by age rather than archived, and grants to anon
--     and authenticated stay revoked until 014 anyway. Adding a revoke now would collide with the
--     policies 014 writes, and inventing a security control the spec does not describe is exactly
--     what AGENTS.md warns against.
--   * No "computed_at is not in the future" CHECK, even though 008 added the equivalent guard on
--     rider_location_pings.recorded_at. That constraint protects a trip-duration calculation; this
--     table feeds a diagnostic query, where a few minutes of clock skew costs nothing and a
--     constraint that blocks an analytics write costs debugging.
--
-- sub_order_id is nullable: null is an order-level snapshot, set is a per-vendor one. §6 budgets
-- three rows per order, which is one envelope plus the vendors that have accepted.

create table public.order_eta_snapshots (
  id           uuid primary key default gen_random_uuid(),

  order_id     uuid not null references public.orders(id) on delete cascade,
  sub_order_id uuid references public.sub_orders(id) on delete cascade,

  -- What the customer was shown at quote time.
  promised_at  timestamptz not null,

  -- What the system believed when this snapshot was taken. The gap to promised_at is the error.
  predicted_at timestamptz not null,

  computed_at  timestamptz not null default now()
);

-- Both foreign keys are covered as leading columns, per §14.2: order_id here, sub_order_id below.
create index order_eta_snapshots_order on public.order_eta_snapshots (order_id, computed_at desc);
create index order_eta_snapshots_sub_order on public.order_eta_snapshots (sub_order_id)
  where sub_order_id is not null;