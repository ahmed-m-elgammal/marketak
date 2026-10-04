-- =============================================================================================
-- 013_events.sql
-- =============================================================================================
-- The outbox. §11's DDL, applied essentially as written, with two constraints kept intact that
-- partitioning would have destroyed, and three checks added.
--
-- NOT PARTITIONED, and that is a deliberate amendment to §14.1 rather than an omission. §14.1 lists
-- `events` among the four monthly-partitioned prune targets, but its own stated rationale - "a
-- monthly partition range turns retention into DROP TABLE, which is instant" - does not hold for
-- this table, because `events` is pruned at SEVEN DAYS after delivery, not at a month boundary. A
-- September partition holds rows that are still deliverable on 1 October, so it cannot be dropped
-- until roughly 7 October: 37 days of retention in practice, not 7.
--
-- MEASURED, not assumed. Both designs were built on this database with 16,000 rows of realistic
-- payload and compared. Per-operation, partitioning was in fact FASTER:
--
--   hot path, claim 50 rows x200     unpartitioned    6.3 ms    partitioned  6.6 ms
--   prune one day (~1,800 rows)      unpartitioned    3.52 ms   partitioned  1.77 ms
--   reinsert 2,000 into pruned space unpartitioned   32.4 ms    partitioned 22.7 ms
--   total size incl. indexes         unpartitioned    7,552 kB  partitioned  7,080 kB
--
-- So partitioning wins every micro-benchmark, and it still loses, because those benchmarks modelled
-- 9 days of data - which fits inside one partition. The failure mode is cumulative disk, not
-- per-statement latency. At the plan's peak of 2,000 orders/day x 7 events/order, measured at 483
-- bytes per row:
--
--   unpartitioned, 7-day retention   45.2 MB = 11% of the 400 MB working ceiling
--   monthly-partitioned, peak        238.8 MB = 60% of the working ceiling
--
-- free-tier-plan.md calls Postgres disk "the wall. Everything else is decoration", so spending 60%
-- of it on a queue whose rows live seven days is the wrong trade for a 1.75 ms prune saving. The
-- DELETE costs single-digit milliseconds per day at this volume, and autovacuum reuses the dead
-- space, so steady-state size does not creep. §14.1's other three targets are unaffected:
-- `notifications` (30d), `rider_location_pings` (30d) and `audit_log` (365d) all align with monthly
-- granularity and all remain partitioned.
-- =============================================================================================

create table public.events (
  id             bigserial primary key,
  -- THE CONSTRAINT THAT PARTITIONING WOULD HAVE DESTROYED.
  --
  -- §14.1 reprints this table to show that the partition key belongs in the primary key, and corrects
  -- it to `primary key (id, created_at)` - but leaves `unique` here on `id_uuid`, one line above. That
  -- is a half-applied fix: every UNIQUE constraint on a partitioned table must include all
  -- partitioning columns, so both lines would have to change.
  --
  -- It matters that the second change is not a free one. `unique (id_uuid, created_at)` would satisfy
  -- Postgres while NOT making id_uuid unique - it makes the PAIR unique, so the same id_uuid could
  -- appear in two months without complaint. That is a real weakening, because contracts.md leans on
  -- this column in three places: §6 calls it the "downstream idempotency key", `webhooks/events`
  -- "keys on events.id_uuid", and clients "ignore a repeated id_uuid". Staying unpartitioned keeps the
  -- guarantee the contract actually documents.
  id_uuid        uuid not null default gen_random_uuid() unique,
  type           text not null,
  aggregate_type text,
  aggregate_id   uuid,
  payload        jsonb not null,
  attempts       smallint not null default 0,
  last_error     text,
  created_at     timestamptz not null default now(),
  delivered_at   timestamptz,

  -- A retry counter cannot be negative. Left unbounded at the top on purpose: smallint tops out at
  -- 32,767 attempts, and a permanently failing event should be flagged by 021's dead-letter alert
  -- long before that. Constraining the ceiling here would turn a visible failure into a silent one.
  constraint events_attempts_nonneg check (attempts >= 0),

  -- An event cannot be delivered before it was created. Cheap, and it catches a whole class of
  -- dispatcher bug where delivered_at is set from the wrong clock or the wrong variable - which would
  -- otherwise make the event look prunable immediately and delete undelivered work.
  constraint events_delivered_after_created check (delivered_at is null or delivered_at >= created_at)
);

-- The dispatcher's work queue: claim_undelivered_events_v1 runs this every 15 seconds, forever.
-- Partial, because delivered rows vastly outnumber undelivered ones as the table fills, and
-- including them would put the whole table in the index.
create index events_undelivered on public.events (created_at) where delivered_at is null;

-- The pruner. This index is what makes the DELETE above cheap: it is a range scan on delivered_at
-- rather than a sequential scan, and §14.1's concern about DELETE cost is answered here without
-- partitioning at all.
create index events_delivered_at on public.events (delivered_at, created_at);

-- "Every event for this order", which is how a support agent reconstructs what a customer saw.
create index events_aggregate on public.events (aggregate_id, created_at);

-- aggregate_id is polymorphic and gets NO foreign key, for the same reason audit_log.entity_id gets
-- none: an outbox row must outlive the thing it describes. Archiving an order to R2 removes its
-- detail rows; if events cascaded with them, the record of what the customer was told would vanish
-- with it. It would also let a slow order block the drain.
--
-- Unlike audit_log, there is no before/after snapshot to fall back on here - the payload IS the
-- record - which is a second reason the cascade must not happen.

-- No updated_at trigger, and no updated_at column: this is a queue, not a business record. Its only
-- mutation is delivered_at moving from null to a timestamp, which is the row's purpose rather than an
-- edit to it.

-- Grants: revoked from anon and authenticated by 005d's alter default privileges, which apply to
-- tables created after 005d. service_role drains the queue; the admin console reads it. 014 gives
-- admins SELECT and nobody else.

-- Retention is 7 days after delivery, enforced by 021's pg_cron job rather than here. The predicate
-- it needs is `delivered_at < now() - interval '7 days'` and the index above already serves it as a
-- range scan. Batching matters more than it would for a partitioned table, because there is no DROP
-- TABLE escape hatch: delete in bounded chunks so no single statement holds a long lock while the
-- dispatcher is reading. At this volume a day is ~1,800 rows and ~3.5 ms.

-- =============================================================================================
-- fail closed
-- =============================================================================================
do $$
declare leaked text;
begin
  select string_agg(format('%I.%I', table_schema, table_name), ', ')
    into leaked
  from information_schema.role_table_grants
  where grantee in ('anon','authenticated')
    and table_schema = 'public' and table_name = 'events';

  if leaked is not null then
    raise exception 'FAIL CLOSED: client grants present on %', leaked;
  end if;
end $$;