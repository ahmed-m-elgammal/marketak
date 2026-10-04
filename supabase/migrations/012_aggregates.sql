-- =============================================================================================
-- 012_aggregates.sql
-- =============================================================================================
-- §15.2 assigns six tables here. Only four of them are new, and one of the six is not coming:
--
--   * vendor_earnings_daily  ALREADY EXISTS, created by 004_vendors.sql. Recreating it here would
--     drop the vendor's earnings history, so §15.2's list is wrong, not the database. Noted rather
--     than duplicated.
--   * rider_earnings_daily   MISSING. 008 created riders and the delivery tables but not this, so
--     it has never existed and 012 is its first chance to be right.
--   * event_daily_stats, search_daily_stats, auth_daily_stats, audit_log   new.
--
-- Six defects in the §12 DDL are corrected below. Each is marked DEFECT n and explained; none of
-- them is a style preference, and three of them (1, 2, 3) would have shipped a data-loss or
-- integrity bug rather than merely an inconvenience.
--
-- Ordering: rider_earnings_daily before the stats tables because it references riders(id) from 008,
-- and audit_log last because it is the only partitioned table here and reuses 010's helper.
-- =============================================================================================

-- =============================================================================================
-- rider_earnings_daily
-- =============================================================================================
-- DEFECT 1 - the spec has no deleted_at, and this is a financial record.
-- constitution.md 17 requires soft delete on every business table, and §13 error 13 already ruled on
-- exactly this shape of table: "vendor_earnings_daily, user_auth_providers and user_roles were
-- hard-deletable. The first is a financial record" -> deleted_at. rider_earnings_daily holds
-- base_fees, tips, bonuses and net_payout, so it is the same class of record and 005b applied the
-- ruling to vendor_earnings_daily only because rider_earnings_daily did not exist yet. Adding it
-- here is applying an existing decision to a table that was simply created too late to receive it,
-- not making a new one.
create table public.rider_earnings_daily (
  rider_id       uuid not null references public.riders(id) on delete cascade,
  business_date  date not null,
  deliveries     integer not null default 0,
  legs           integer not null default 0,
  online_minutes integer not null default 0,
  base_fees      integer not null default 0,
  distance_fees  integer not null default 0,
  tips           integer not null default 0,
  bonuses        integer not null default 0,
  deductions     integer not null default 0,
  net_payout     integer not null default 0,
  cash_held      integer not null default 0,
  cash_remitted  integer not null default 0,
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  primary key (rider_id, business_date),

  -- DEFECT 1a - no non-negativity constraints. Every column here is default 0, so a rollup bug that
  -- emits -5 is accepted silently and the rider's "earned" figure is wrong until someone reads the
  -- screen. Additive money and count columns cannot be negative; net_payout is deliberately NOT
  -- constrained, because a clawback can legitimately make a day negative and 009's platform_float
  -- already established that a signed net figure is real money and not a bug.
  constraint rider_earnings_deliveries_nonneg     check (deliveries >= 0),
  constraint rider_earnings_legs_nonneg         check (legs >= 0),
  constraint rider_earnings_online_minutes_nonneg check (online_minutes >= 0),
  constraint rider_earnings_base_fees_nonneg    check (base_fees >= 0),
  constraint rider_earnings_distance_fees_nonneg check (distance_fees >= 0),
  constraint rider_earnings_tips_nonneg         check (tips >= 0),
  constraint rider_earnings_bonuses_nonneg      check (bonuses >= 0),
  constraint rider_earnings_deductions_nonneg   check (deductions >= 0),
  constraint rider_earnings_cash_held_nonneg    check (cash_held >= 0),
  constraint rider_earnings_cash_remitted_nonneg check (cash_remitted >= 0)
);

-- Mirrors vendor_earnings_daily_live from 005b. The primary key already serves the happy path, so
-- this exists purely so the planner can skip soft-deleted rows via the partial-index predicate.
create index rider_earnings_daily_live
  on public.rider_earnings_daily (rider_id, business_date) where deleted_at is null;

create trigger trg_rider_earnings_daily_updated_at before update on public.rider_earnings_daily
  for each row execute function public.set_updated_at();

-- Append-only is NOT applied here: this is a recomputed rollup and the rollup job legitimately
-- updates rows. Revoked from the client roles by the default privileges 005d installed, which
-- 012 re-verifies at the end.

-- =============================================================================================
-- event_daily_stats
-- =============================================================================================
-- The replacement for raw event storage. Row-level analytics does not fit the free tier, so
-- spec.md §? keeps retention at a few hundred rows per day instead of hundreds of thousands.
create table public.event_daily_stats (
  business_date date not null,
  city_id       uuid references public.cities(id),
  app_role      text,
  event_name    text not null,
  count         integer not null default 0,
  unique_users  integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (business_date, city_id, app_role, event_name),

  -- DEFECT 2 - the spec declares city_id and app_role nullable, then puts them in the PRIMARY KEY,
  -- which silently promotes both to NOT NULL. That is a contradiction in the DDL rather than a
  -- working schema: a reader cannot tell whether platform-wide events with no city are allowed, and
  -- an INSERT that omits city_id fails with a bare not-null violation that looks like a bug.
  -- Resolved in favour of the PRIMARY KEY, because §1 commits to one city at a time, so every event
  -- genuinely has one. PostgreSQL has no table-level NOT NULL constraint, so this cannot be spelled
  -- out explicitly - the PRIMARY KEY's implicit promotion IS the constraint. The column declarations
  -- above keep the spec's nullable wording precisely so the promotion stays visible rather than
  -- hidden; pg_attribute confirms both columns are attnotnull.

  -- Uses the user_roles.role vocabulary, not device_tokens.app_role. The two differ: user_roles
  -- carries 'support' and device_tokens does not, because push routing has no use for a support
  -- agent. user_roles is the superset, so it cannot reject a role the system can legitimately
  -- produce - which is the property that matters for a CHECK. Choosing the narrower set would be
  -- inventing a rule the actor table does not have.
  constraint event_daily_stats_app_role_known check (app_role in ('customer','rider','admin','support')),

  -- DEFECT 2a - no non-negativity. Same failure mode as rider_earnings_daily: a rollup bug emitting
  -- a negative event count is accepted and quietly understates the funnel.
  constraint event_daily_stats_count_nonneg        check (count >= 0),
  constraint event_daily_stats_unique_users_nonneg check (unique_users >= 0),

  -- unique_users has no CHECK beyond non-negativity and cannot get one. It is a distinct count, and
  -- an exact distinct count is NOT incrementally upsertable: incrementing it by the number of
  -- actors seen in a batch double-counts anyone appearing in two batches. 021's rollup must
  -- recompute it from raw events for the affected window rather than add to it, or it will drift
  -- upward forever. Recorded here because the column name does not warn of this.
  constraint event_daily_stats_unique_users_le_count check (unique_users <= count)
);

-- The PK already covers every filter a dashboard uses: business_date range first, then city_id and
-- app_role equality. No secondary index, deliberately - an index here would only duplicate the left
-- edge of the PK and cost write amplification on a table written by a nightly job.

-- =============================================================================================
-- search_daily_stats
-- =============================================================================================
-- The spec's own comment says "the raw text is not stored", so this table is the deliberate
-- alternative to a raw search log, per spec.md §12.
create table public.search_daily_stats (
  business_date date not null,
  city_id       uuid references public.cities(id),
  query_hash    text not null,
  results_count integer not null,
  zero_result   boolean not null default false,
  clicks        integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (business_date, city_id, query_hash),

  -- city_id is NOT NULL by promotion from the primary key, as in event_daily_stats.

  -- DEFECT 3 - THE DATA-LEAK ONE. query_hash has no format constraint, so the column's entire stated
  -- privacy property ("the raw text is not stored") is enforced by nothing. A rollup job written
  -- under time pressure that hashes nothing and assigns the query text itself produces a table of
  -- raw customer searches that looks compliant, because the column is called query_hash and the
  -- rows are hashes everywhere else. Pinning the format makes that mistake impossible to store:
  -- a raw Arabic query fails the CHECK instead of being persisted.
  --
  -- It does NOT make the hashes unguessable, and this is a residual risk, not a solved problem:
  -- md5 of a short low-entropy string is brute-forceable by anyone who can read the table, because
  -- there is no salt and no secret. Closing that properly needs a keyed HMAC whose key lives in
  -- R2 and is passed per call, which is a deploy-time secret decision for 021, not something to
  -- invent inside a migration. Search terms here are dish and category names rather than personal
  -- data, which is why it is acceptable to ship at all - but it is accepted knowingly, and
  -- search_daily_stats must stay admin-only in 014. See open question 3.17.
  constraint search_daily_stats_query_hash_is_md5 check (query_hash ~ '^[0-9a-f]{32}$'),

  -- DEFECT 3a - results_count carries no default and no CHECK, and that asymmetry is right for a
  -- reason worth stating before someone "fixes" it: every search row MUST state how many results it
  -- produced, so omitting the column should fail loudly. A default of 0 here would let a broken
  -- rollup write zero-result searches for every query and quietly destroy the most valuable column
  -- in the table. Left without a default deliberately. The CHECK is added because a negative result
  -- count is nonsense.
  constraint search_daily_stats_results_count_nonneg check (results_count >= 0),
  constraint search_daily_stats_clicks_nonneg       check (clicks >= 0),

  -- zero_result and results_count describe the same fact from two angles, so the database should
  -- hold them consistent instead of trusting the job to remember. This is the one CHECK in 012 that
  -- can fail a future nightly rollup: 021 must set zero_result from results_count in the same
  -- statement. A 3am failure here is the intended outcome, because the alternative is a table whose
  -- zero-result rate is wrong with no signal that anything failed.
  constraint search_daily_stats_zero_result_consistent check (zero_result = (results_count = 0)),

  -- clicks cannot exceed results: a search cannot have been clicked more times than it returned
  -- results, and clicks > results means the job double-counted or the hash collided across queries.
  constraint search_daily_stats_clicks_le_results check (clicks <= results_count)
);

-- =============================================================================================
-- auth_daily_stats
-- =============================================================================================
-- DEFECT 4 - CONSTITUTION CONFLICT, and the most important correction in this migration.
-- The spec's CHECK is:
--     check (event_name in ('signup','login','login_failed','otp_requested','logout','password_reset'))
-- constitution.md 18 is unambiguous: "Authentication is Google and Apple only. No email, no
-- password, no phone OTP." Two of those six events describe flows this product does not have, and
-- their presence in the CHECK is worse than their absence: it advertises them as part of the
-- identity model, so a future engineer could reasonably build an otp_requested counter and a
-- password_reset handler on the strength of a schema constraint. constitution.md 20 makes Supabase
-- Auth the only identity system, so nothing in this platform can emit either event.
--
-- Resolved in favour of the constitution, which outranks data-model.md. The four survivors -
-- signup, login, login_failed, logout - are all reachable through Google and Apple sign-in.
create table public.auth_daily_stats (
  business_date date not null,
  event_name    text not null check (event_name in
                  ('signup','login','login_failed','logout')),
  count         integer not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (business_date, event_name),

  constraint auth_daily_stats_count_nonneg check (count >= 0)
);

-- Deliberately has no city_id, unlike event_daily_stats and search_daily_stats. Sign-in is a
-- platform-level fact and a user has no city until they complete a profile, so a city dimension here
-- would be mostly NULL and would force the NOT NULL that DEFECT 2 just had to reason about. If the
-- business later goes multi-city, signups-per-city comes from users.city_id at read time.

-- =============================================================================================
-- audit_log
-- =============================================================================================
-- DEFECT 5 - THE ONE THAT LOSES DATA. The spec is:
--     id bigserial primary key
-- but §14.1 lists audit_log as one of the four tables partitioned by month, and on a partitioned
-- table every UNIQUE constraint must include the partition key. `id bigserial primary key` is
-- therefore not merely suboptimal, it is a syntax error against a partitioned parent - the exact
-- failure 010 already had to correct for notifications. Fixed to §14.1's shape, primary key
-- (id, created_at).
--
-- Consequence worth naming: id is then unique only WITHIN a partition, not across the table. The
-- spec gives audit_log no id_uuid to restore global uniqueness, unlike events. Nothing needs it -
-- every documented query filters on entity or created_at - so none was invented.
create table public.audit_log (
  id            bigserial,
  actor_user_id uuid,
  action        text not null,
  entity_type   text not null,
  entity_id     uuid,
  before        jsonb,
  after         jsonb,
  created_at    timestamptz not null default now(),
  primary key (id, created_at),

  -- DEFECT 5a - THE ACCOUNT-DELETION BUG. `actor_user_id uuid references users(id)` with no ON
  -- DELETE clause defaults to NO ACTION, which means one audit row referencing a user makes that
  -- user permanently undeletable. Not "difficult to delete" - undeletable, by any route, forever,
  -- including the cascade from auth.users. An audit log that can wedge account deletion is an
  -- operational landmine, and the failure surfaces at the worst possible moment.
  --
  -- on delete set null is the correct semantics for an audit trail: the record of what happened
  -- SURVIVES its actor, and the actor reference is released. before/after already hold the
  -- snapshot, so no information is lost. It also aligns with constitution.md 17 - deletion is
  -- soft and reversible in spirit, not a hard FK block.
  constraint audit_log_actor_user_id_fkey foreign key (actor_user_id)
    references public.users(id) on delete set null
) partition by range (created_at);

-- DEFECT 5b - THE MISSING INDEX THAT TURNS DELETION INTO A FULL SCAN. There is no index on
-- actor_user_id anywhere in the spec. Deleting a user must find every audit row naming them to null
-- it out, and with no index that is a sequential scan of EVERY partition - on a table retained for
-- 365 days. Partial, because system-generated rows carry a null actor and would otherwise bloat
-- the index with nothing useful in it. This also serves the admin "what did this user do" query,
-- which is the actual reason an audit log gets read.
create index audit_log_actor_user on public.audit_log (actor_user_id, created_at desc)
  where actor_user_id is not null;

create index audit_log_entity on public.audit_log (entity_type, entity_id, created_at desc);
create index audit_log_created_at on public.audit_log (created_at);

-- DEFECT 5c - entity_id is polymorphic and gets NO integrity trigger, deliberately, and this is the
-- one place in the schema where skipping 011a's pattern is the whole point. 011a added triggers so
-- wallets.owner_id and payouts.account_id could not name a row that does not exist. Applying that
-- here would be actively wrong: an audit row must outlive the thing it describes. Deleting a user
-- must not delete the record that they changed a vendor's status, and a trigger that rejects a
-- dangling entity_id would make deletion fail on its own audit trail. before/after make each row
-- self-contained, which is why no back-reference is needed to read it.

-- `before` and `after` are legal column names - both are non-reserved in PostgreSQL - and they are
-- kept rather than renamed because contracts.md and any admin export reference them. They cannot
-- collide with OLD/NEW inside a trigger body, which is what would have been the real hazard.

-- Append-only. An UPDATE or DELETE rewrites the record of an event, which is the single thing an
-- audit trail exists to prevent. Same mechanism and same reasoning as 007's
-- order_status_history and order_modifications, and like ledger_entries there is deliberately no
-- updated_at: an append-only row has nothing to update, and a mutable audit timestamp would imply
-- the row can change when it cannot. Retention runs through DROP TABLE, not DELETE, so this does
-- not obstruct the retention job.
revoke update, delete on public.audit_log from anon, authenticated;

-- Both grants revoked from anon and authenticated by the 005d default privileges, including on the
-- partitions, since a partition inherits nothing and the parent's empty grant is not inherited.
-- service_role reaches it as the Worker side of the audit write, and 014 gives admin SELECT only.

-- Partitions. private.ensure_month_partition already whitelists audit_log - 010 fixed the list at
-- §14.1's four tables - so this reuses 010's helper rather than adding a second mechanism. Current
-- and next month, because a partitioned table with no matching partition REJECTS every insert, and
-- shipping an empty partitioned audit log would be a trap for whoever writes the first admin action.
select private.ensure_month_partition('audit_log', current_date);
select private.ensure_month_partition('audit_log', (current_date + interval '1 month')::date);

-- =============================================================================================
-- updated_at triggers
-- =============================================================================================
-- Every table above with an updated_at gets the trigger, so the rollup's upserts cannot leave a
-- stale timestamp behind - which is what makes an incremental export correct.
-- audit_log is excluded on purpose: it has no updated_at because it is append-only.
create trigger trg_event_daily_stats_updated_at before update on public.event_daily_stats
  for each row execute function public.set_updated_at();

create trigger trg_search_daily_stats_updated_at before update on public.search_daily_stats
  for each row execute function public.set_updated_at();

create trigger trg_auth_daily_stats_updated_at before update on public.auth_daily_stats
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- fail closed
-- =============================================================================================
-- 005d installed alter default privileges revoke all on tables from anon, authenticated, so these
-- six tables should already be unreachable by clients. Asserting it rather than trusting it, because
-- the whole security argument for 001-013 rests on that default having applied.
do $$
declare leaked text;
begin
  select string_agg(format('%I.%I', table_schema, table_name), ', ')
    into leaked
  from information_schema.role_table_grants
  where grantee in ('anon','authenticated')
    and table_schema = 'public'
    and table_name in ('rider_earnings_daily','event_daily_stats','search_daily_stats',
                       'auth_daily_stats','audit_log');

  if leaked is not null then
    raise exception 'FAIL CLOSED: client grants present on %', leaked;
  end if;
end $$;