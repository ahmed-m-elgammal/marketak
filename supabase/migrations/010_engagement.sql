-- T0.1a: 010 engagement. data-model.md §10.
--
-- The first migration that partitions, and the first where the partition key decision is not
-- deferred. rider_location_pings is empty until Phase 8 so its partitioning was pushed to whenever
-- the tracking API lands; notifications are written from the first order, so it has to be right here.
--
-- §14.1 gives the pattern explicitly for events:
--
--   primary key (id, created_at)          -- partition key must be in the PK
--   ) partition by range (created_at);
--
-- That line is the whole reason this migration has a PK anyone would query twice. On a partitioned
-- table a UNIQUE constraint must include the partition key, so `id bigserial primary key` as §10
-- writes it is illegal. The consequence is that notifications.id is unique only WITHIN a month, and
-- that is acceptable here for a specific reason worth stating: nothing has a foreign key to
-- notifications, and both of its access paths are already time-scoped - the inbox is
-- (user_id, created_at desc) and retention is an age sweep. A globally unique row id would buy
-- nothing that those two queries do not already use.
--
-- The same defect is latent in §11's `events`, which declares `id bigserial primary key` AND
-- `id_uuid uuid not null ... unique` - two constraints that both become illegal the moment events is
-- partitioned. Not fixed here; §14.1 already shows the corrected form. Flagged for 013.
--
-- constitution.md III.13: anything filtered, joined or sorted on is a real column, never a JSON
-- array. Three jsonb columns here are kept, and each is read whole rather than queried:
--   notifications.title / .body   {"ar":"...","en":"..."} - rendered, never filtered on
--   notification_templates.variables  a list of placeholder names - consumed whole when rendering
-- So none of them is an III.13 violation. What IS unenforced is the vocabulary: contracts.md §4
-- lists 19 notification keys, and nothing stops a row carrying a `type` that matches no template.
-- Recorded as an open question rather than constrained here, because a hardcoded CHECK would be a
-- second source of truth that drifts from contracts.md, and an FK is impossible while templates are
-- unique per (key, channel, lang) rather than per key.

-- =============================================================================================
-- reviews
-- =============================================================================================
-- Vendor and rider ratings are two independent numbers about one delivery, and conflating them makes
-- both useless: a customer who loves the food and hates the driver has no way to say so.
create table public.reviews (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders(id) on delete cascade,
  sub_order_id uuid references public.sub_orders(id) on delete cascade,
  user_id      uuid not null references public.users(id),
  vendor_id    uuid not null references public.vendors(id),
  rider_id     uuid references public.riders(id),

  vendor_rating smallint check (vendor_rating between 1 and 5),
  rider_rating  smallint check (rider_rating between 1 and 5),
  comment      text,

  -- Moderation, not deletion. A hidden review is excluded from every read path by the partial index
  -- below rather than by a WHERE clause scattered across queries, which is the failure mode that
  -- eventually leaks a hidden review onto a public page.
  is_hidden    boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  -- FLAGGED: not in §10. A rider rating with no rider to attach it to is incoherent - the number has
  -- nothing to aggregate against on riders.rating_avg.
  constraint reviews_rider_rating_needs_rider check (rider_rating is null or rider_id is not null),

  -- One review per vendor per order. A customer editing their review is an UPDATE of this row, not a
  -- second one, which is why updated_at exists alongside created_at.
  unique (order_id, vendor_id)
);

-- §10's indexes. order_id is covered by the unique constraint above, so §14.2 is satisfied.
create index reviews_vendor_created on public.reviews (vendor_id, created_at desc) where not is_hidden;
create index reviews_user_created on public.reviews (user_id, created_at desc);
create index reviews_rider on public.reviews (rider_id) where rider_id is not null;
create index reviews_sub_order on public.reviews (sub_order_id) where sub_order_id is not null;

create trigger trg_reviews_updated_at before update on public.reviews
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- favorites / favorite_items
-- =============================================================================================
-- Two different things a customer can save: the vendor, and a specific dish. Separate tables rather
-- than one nullable pair, because "favourites" in the app is both lists concatenated.
create table public.favorites (
  user_id    uuid not null references public.users(id) on delete cascade,
  vendor_id  uuid not null references public.vendors(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, vendor_id)
);

-- §14.2: the PK leads with user_id, so vendor_id - a foreign key - is not covered. Needed for "how many
-- customers favourite this vendor", which is the number a vendor dashboard opens on.
create index favorites_vendor_id on public.favorites (vendor_id);

create table public.favorite_items (
  user_id     uuid not null references public.users(id) on delete cascade,
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, menu_item_id)
);

-- §14.2: same reason as above - menu_item_id is not the leading column of the PK.
create index favorite_items_menu_item_id on public.favorite_items (menu_item_id);

-- =============================================================================================
-- notification_templates
-- =============================================================================================
-- Rendered server-side in the user's preferred_language, per contracts.md §4. The catalogue there is
-- the vocabulary; these rows are its ar/en realisations.
create table public.notification_templates (
  id        uuid primary key default gen_random_uuid(),
  key       text not null,
  channel   text not null default 'push' check (channel in ('push','inapp','sms')),
  lang      text not null check (lang in ('ar','en')),
  title     text not null,
  body      text not null,

  -- Placeholder names, read whole when rendering. See the header note on III.13.
  variables jsonb not null default '[]'::jsonb
              check (jsonb_typeof(variables) = 'array'),
  is_active boolean not null default true,
  updated_at timestamptz not null default now(),

  unique (key, channel, lang)
);

create trigger trg_notification_templates_updated_at before update on public.notification_templates
  for each row execute function public.set_updated_at();

-- =============================================================================================
-- notifications - PARTITIONED BY MONTH
-- =============================================================================================
-- §14.1: pruned at 30 days (spec.md §9, prune_notifications daily). On a free tier, DELETE of a large
-- range bloats the table, blocks, and leaves autovacuum cleanup behind. DROP TABLE is instant and
-- leaves no dead tuples. This table earns ~6 rows per order, so it is the second-largest prune target
-- after events.
create table public.notifications (
  id           bigserial,
  user_id      uuid not null references public.users(id) on delete cascade,
  order_id     uuid references public.orders(id) on delete cascade,
  sub_order_id uuid references public.sub_orders(id) on delete cascade,

  -- See the header note: unenforced vocabulary, tracked as an open question.
  type         text not null,

  -- Already rendered in the user's language by the time it lands here, which is why this is jsonb and
  -- not a template reference: the notification must render identically forever, even if the template
  -- is later reworded.
  title        jsonb not null check (jsonb_typeof(title) = 'object'),
  body         jsonb not null check (jsonb_typeof(body) = 'object'),
  data         jsonb,

  read_at      timestamptz,
  created_at   timestamptz not null default now(),

  -- §14.1: the partition key must be in the primary key.
  primary key (id, created_at)
) partition by range (created_at);

create index notifications_user_created on public.notifications (user_id, created_at desc);
create index notifications_created_at on public.notifications (created_at);          -- retention sweep
create index notifications_order on public.notifications (order_id) where order_id is not null;
create index notifications_sub_order on public.notifications (sub_order_id) where sub_order_id is not null;

-- =============================================================================================
-- partition management
-- =============================================================================================
-- §14.1: "pg_partman 5.3.1 is available on this project and automates partition creation. If it is not
-- used, a pg_cron job creates next month's partition three days ahead." Taking the second option, so
-- that 010 does not acquire a dependency on an extension whose configuration surface and retention
-- semantics are its own; the fallback is self-contained and testable now. 021 wires the pg_cron job
-- to call it.
--
-- private, not public: this function builds a table name and executes DDL, so PostgREST must not be
-- able to reach it. That is the same reasoning 005e used for private.is_admin().
--
-- The whitelist is not decoration. The table name is interpolated into DDL, so without it this
-- function would create a partition of anything the caller named. §14.1 fixes the prune-target list at
-- four tables, so an explicit list is both the safety property and the specification.
create or replace function private.ensure_month_partition(p_table text, p_month date)
returns void language plpgsql set search_path = '' as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_child text := p_table || '_' || to_char(v_start, 'YYYY_MM');
begin
  if p_table not in ('events', 'notifications', 'rider_location_pings', 'audit_log') then
    raise exception 'NOT_A_PARTITIONED_TABLE: %', p_table using errcode = 'P0001';
  end if;

  if to_regclass('public.' || v_child) is null then
    execute format(
      'create table public.%I partition of public.%I for values from (%L) to (%L)',
      v_child, p_table, v_start, v_end
    );
  end if;
end $$;

revoke execute on function private.ensure_month_partition(text, date) from public, anon, authenticated;

-- Current month and next. A partitioned table with no matching partition REJECTS every insert, so
-- shipping notifications partitioned and empty would be a trap for whoever writes the first insert.
-- The cast is required: current_date + interval yields timestamp, not date, and the function takes
-- date. Found by running the file rather than reading it.
select private.ensure_month_partition('notifications', current_date);
select private.ensure_month_partition('notifications', (current_date + interval '1 month')::date);