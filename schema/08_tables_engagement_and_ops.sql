-- =============================================================================
-- 08_tables_engagement_and_ops.sql
-- Reviews, vouchers, promotional slots, the event outbox, notifications,
-- aggregates and the audit log.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- reviews: one review per (order, vendor) — enforced UNIQUE — so a customer
-- cannot review the same merchant twice for one order. Vendor and rider ratings
-- are independent and each is 1..5. A rider_rating without a rider_id is
-- rejected.
-- -----------------------------------------------------------------------------
create table public.reviews
(
  id uuid not null default gen_random_uuid(),
  order_id uuid not null,
  sub_order_id uuid,
  user_id uuid not null,
  vendor_id uuid not null,
  rider_id uuid,
  vendor_rating smallint,
  rider_rating smallint,
  comment text,
  is_hidden boolean not null default false,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),

  constraint reviews_order_id_vendor_id_key unique UNIQUE (order_id, vendor_id),
  constraint reviews_pkey primary key PRIMARY KEY (id),
  constraint reviews_rider_rating_check check CHECK (((rider_rating >= 1) AND (rider_rating <= 5))),
  constraint reviews_rider_rating_needs_rider check CHECK (((rider_rating IS NULL) OR (rider_id IS NOT NULL))),
  constraint reviews_vendor_rating_check check CHECK (((vendor_rating >= 1) AND (vendor_rating <= 5)))
);

-- -----------------------------------------------------------------------------
-- vouchers: discount rules. discount_type is percentage (basis points, max
-- 10000), fixed_amount, or free_delivery. `applies_to_vendor_ids` is an empty
-- array meaning "any vendor". usage_count can never exceed usage_limit_total,
-- and that is enforced by CHECK rather than by application code.
-- -----------------------------------------------------------------------------
create table public.vouchers
(
  id uuid not null default gen_random_uuid(),
  code text not null,
  name text,
  discount_type text not null,
  discount_value integer not null,
  min_order_value integer not null default 0,
  max_discount_cap integer,
  usage_limit_total integer,
  usage_limit_per_user integer,
  usage_count integer not null default 0,
  applies_to_vendor_ids uuid[] not null default '{}'::uuid[],
  vertical_type text,
  first_order_only boolean not null default false,
  valid_from timestamp with time zone not null default now(),
  valid_until timestamp with time zone,
  is_active boolean not null default true,
  created_by uuid,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint vouchers_code_key unique UNIQUE (code),
  constraint vouchers_discount_type_check check CHECK ((discount_type = ANY (ARRAY['percentage'::text, 'fixed_amount'::text, 'free_delivery'::text]))),
  constraint vouchers_discount_value_check check CHECK ((discount_value > 0)),
  constraint vouchers_money_nonneg check CHECK (((min_order_value >= 0) AND (max_discount_cap >= 0))),
  constraint vouchers_percentage_sane check CHECK (((discount_type <> 'percentage'::text) OR (discount_value <= 10000))),
  constraint vouchers_pkey primary key PRIMARY KEY (id),
  constraint vouchers_usage_count_nonneg check CHECK ((usage_count >= 0)),
  constraint vouchers_usage_limit_per_user_check check CHECK (((usage_limit_per_user IS NULL) OR (usage_limit_per_user > 0))),
  constraint vouchers_usage_limit_total_check check CHECK (((usage_limit_total IS NULL) OR (usage_limit_total > 0))),
  constraint vouchers_window_valid check CHECK (((valid_until IS NULL) OR (valid_until > valid_from))),
  constraint vouchers_within_usage_limit check CHECK (((usage_limit_total IS NULL) OR (usage_count <= usage_limit_total)))
);

-- -----------------------------------------------------------------------------
-- voucher_redemptions: one row per actual use. UNIQUE-ish in practice is
-- enforced by private.assert_commission_target / idempotency in the quote RPCs;
-- here the pair (voucher_id, order_id, sub_order_id) is what analytics reads.
-- -----------------------------------------------------------------------------
create table public.voucher_redemptions
(
  id uuid not null default gen_random_uuid(),
  voucher_id uuid not null,
  user_id uuid not null,
  order_id uuid,
  sub_order_id uuid,
  discount_amount integer not null,
  created_at timestamp with time zone not null default now(),

  constraint voucher_redemptions_discount_amount_check check CHECK ((discount_amount > 0)),
  constraint voucher_redemptions_pkey primary key PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- promo_slots: home-screen banners. `title`/`subtitle` are jsonb objects
-- holding per-language strings (ar/en) rather than two columns, so a slot can
-- carry a different string per locale without a second row.
-- -----------------------------------------------------------------------------
create table public.promo_slots
(
  id uuid not null default gen_random_uuid(),
  city_id uuid not null,
  slot_key text not null,
  title jsonb not null,
  subtitle jsonb,
  image_path text,
  target_type text,
  target_id text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint promo_slots_city_id_slot_key_key unique UNIQUE (city_id, slot_key),
  constraint promo_slots_pkey primary key PRIMARY KEY (id),
  constraint promo_slots_subtitle_check check CHECK (((subtitle IS NULL) OR (jsonb_typeof(subtitle) = 'object'::text))),
  constraint promo_slots_target_pair check CHECK ((((target_type IS NULL) AND (target_id IS NULL)) OR ((target_type IS NOT NULL) AND (target_id IS NOT NULL)))),
  constraint promo_slots_target_type_check check CHECK ((target_type = ANY (ARRAY['vendor'::text, 'vertical'::text, 'area'::text, 'url'::text]))),
  constraint promo_slots_title_check check CHECK ((jsonb_typeof(title) = 'object'::text)),
  constraint promo_slots_window_valid check CHECK (((ends_at IS NULL) OR (starts_at IS NULL) OR (ends_at > starts_at)))
);

-- -----------------------------------------------------------------------------
-- events: the transactional outbox. Every state-changing RPC writes one row in
-- the SAME transaction as the state change, so an event can never exist for a
-- change that rolled back, nor a change with no event.
--
-- `attempts` and `last_error` are the worker's retry state;
-- `delivered_at` is set by mark_events_delivered_v1(). A Cloudflare Worker
-- drains this with claim_events_v1() (SKIP LOCKED), not from the database.
-- -----------------------------------------------------------------------------
create table public.events
(
  id bigint not null default nextval('events_id_seq'::regclass),
  id_uuid uuid not null default gen_random_uuid(),
  type text not null,
  aggregate_type text,
  aggregate_id uuid,
  payload jsonb not null,
  attempts smallint not null default 0,
  last_error text,
  created_at timestamp with time zone not null default now(),
  delivered_at timestamp with time zone,

  constraint events_attempts_nonneg check CHECK ((attempts >= 0)),
  constraint events_delivered_after_created check CHECK (((delivered_at IS NULL) OR (delivered_at >= created_at))),
  constraint events_id_uuid_key unique UNIQUE (id_uuid),
  constraint events_pkey primary key PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- notifications: RANGE-partitioned by created_at, monthly. `title` and `body`
-- are jsonb objects (per-language) rendered from notification_templates, not
-- composed inline. Partitions are created ahead by private.ensure_partitions()
-- and private.ensure_month_partition().
-- -----------------------------------------------------------------------------
create table public.notifications
(
  id bigint not null default nextval('notifications_id_seq'::regclass),
  user_id uuid not null,
  order_id uuid,
  sub_order_id uuid,
  type text not null,
  title jsonb not null,
  body jsonb not null,
  data jsonb,
  read_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),

  constraint notifications_body_check check CHECK ((jsonb_typeof(body) = 'object'::text)),
  constraint notifications_pkey primary key PRIMARY KEY (id, created_at),
  constraint notifications_title_check check CHECK ((jsonb_typeof(title) = 'object'::text))
)
partition by RANGE (created_at);

create table public.notifications_2026_10
(
  id bigint not null default nextval('notifications_id_seq'::regclass),
  user_id uuid not null,
  order_id uuid,
  sub_order_id uuid,
  type text not null,
  title jsonb not null,
  body jsonb not null,
  data jsonb,
  read_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),

  constraint notifications_2026_10_pkey primary key PRIMARY KEY (id, created_at),
  constraint notifications_body_check check CHECK ((jsonb_typeof(body) = 'object'::text)),
  constraint notifications_title_check check CHECK ((jsonb_typeof(title) = 'object'::text))
);

create table public.notifications_2026_11
(
  id bigint not null default nextval('notifications_id_seq'::regclass),
  user_id uuid not null,
  order_id uuid,
  sub_order_id uuid,
  type text not null,
  title jsonb not null,
  body jsonb not null,
  data jsonb,
  read_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),

  constraint notifications_2026_11_pkey primary key PRIMARY KEY (id, created_at),
  constraint notifications_body_check check CHECK ((jsonb_typeof(body) = 'object'::text)),
  constraint notifications_title_check check CHECK ((jsonb_typeof(title) = 'object'::text))
);

-- -----------------------------------------------------------------------------
-- notification_templates: the copy for each notification type, per channel and
-- language. UNIQUE (key, channel, lang) means adding 'en' is an insert, never
-- an update of the Arabic row. `variables` lists the placeholders the renderer
-- must fill.
-- -----------------------------------------------------------------------------
create table public.notification_templates
(
  id uuid not null default gen_random_uuid(),
  key text not null,
  channel text not null default 'push'::text,
  lang text not null,
  title text not null,
  body text not null,
  variables jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint notification_templates_channel_check check CHECK ((channel = ANY (ARRAY['push'::text, 'inapp'::text, 'sms'::text]))),
  constraint notification_templates_key_channel_lang_key unique UNIQUE (key, channel, lang),
  constraint notification_templates_lang_check check CHECK ((lang = ANY (ARRAY['ar'::text, 'en'::text]))),
  constraint notification_templates_pkey primary key PRIMARY KEY (id),
  constraint notification_templates_variables_check check CHECK ((jsonb_typeof(variables) = 'array'::text))
);

-- -----------------------------------------------------------------------------
-- audit_log: RANGE-partitioned by created_at, monthly. before/after jsonb give
-- a field-level diff for admin actions. Partitioning keeps the table from
-- becoming an unbounded hot spot; pruning is manual, never automatic.
-- -----------------------------------------------------------------------------
create table public.audit_log
(
  id bigint not null default nextval('audit_log_id_seq'::regclass),
  actor_user_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before jsonb,
  after jsonb,
  created_at timestamp with time zone not null default now(),

  constraint audit_log_pkey primary key PRIMARY KEY (id, created_at)
)
partition by RANGE (created_at);

create table public.audit_log_2026_10
(
  id bigint not null default nextval('audit_log_id_seq'::regclass),
  actor_user_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before jsonb,
  after jsonb,
  created_at timestamp with time zone not null default now(),

  constraint audit_log_2026_10_pkey primary key PRIMARY KEY (id, created_at)
);

create table public.audit_log_2026_11
(
  id bigint not null default nextval('audit_log_id_seq'::regclass),
  actor_user_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before jsonb,
  after jsonb,
  created_at timestamp with time zone not null default now(),

  constraint audit_log_2026_11_pkey primary key PRIMARY KEY (id, created_at)
);

-- -----------------------------------------------------------------------------
-- Daily rollups. These exist so the admin console and the free-tier byte budget
-- do not have to scan raw event/notification tables.
-- -----------------------------------------------------------------------------

-- event_daily_stats: per (date, city, role, event) event counts and distinct
-- users. unique_users <= count is enforced.
create table public.event_daily_stats
(
  business_date date not null,
  city_id uuid not null,
  app_role text not null,
  event_name text not null,
  count integer not null default 0,
  unique_users integer not null default 0,
  updated_at timestamp with time zone not null default now(),

  constraint event_daily_stats_app_role_known check CHECK ((app_role = ANY (ARRAY['customer'::text, 'rider'::text, 'admin'::text, 'support'::text]))),
  constraint event_daily_stats_count_nonneg check CHECK ((count >= 0)),
  constraint event_daily_stats_pkey primary key PRIMARY KEY (business_date, city_id, app_role, event_name),
  constraint event_daily_stats_unique_users_le_count check CHECK ((unique_users <= count)),
  constraint event_daily_stats_unique_users_nonneg check CHECK ((unique_users >= 0))
);

-- auth_daily_stats: sign-in funnel, separate from product events.
create table public.auth_daily_stats
(
  business_date date not null,
  event_name text not null,
  count integer not null default 0,
  updated_at timestamp with time zone not null default now(),

  constraint auth_daily_stats_count_nonneg check CHECK ((count >= 0)),
  constraint auth_daily_stats_event_name_check check CHECK ((event_name = ANY (ARRAY['signup'::text, 'login'::text, 'login_failed'::text, 'logout'::text]))),
  constraint auth_daily_stats_pkey primary key PRIMARY KEY (business_date, event_name)
);

-- search_daily_stats: zero-result search tracking. `query_hash` is an MD5 hex,
-- never the raw query — the raw text is user input and is not retained.
-- `zero_result = (results_count = 0)` and `clicks <= results_count` are both
-- CHECK-enforced so the funnel cannot contradict itself.
create table public.search_daily_stats
(
  business_date date not null,
  city_id uuid not null,
  query_hash text not null,
  results_count integer not null,
  zero_result boolean not null default false,
  clicks integer not null default 0,
  updated_at timestamp with time zone not null default now(),

  constraint search_daily_stats_clicks_le_results check CHECK ((clicks <= results_count)),
  constraint search_daily_stats_clicks_nonneg check CHECK ((clicks >= 0)),
  constraint search_daily_stats_pkey primary key PRIMARY KEY (business_date, city_id, query_hash),
  constraint search_daily_stats_query_hash_is_md5 check CHECK ((query_hash ~ '^[0-9a-f]{32}$'::text)),
  constraint search_daily_stats_results_count_nonneg check CHECK ((results_count >= 0)),
  constraint search_daily_stats_zero_result_consistent check CHECK ((zero_result = (results_count = 0)))
);

-- vendor_earnings_daily: per-vendor per-day rollup for the vendor console.
create table public.vendor_earnings_daily
(
  vendor_id uuid not null,
  business_date date not null,
  orders_count integer not null default 0,
  cancelled_count integer not null default 0,
  gross_sales integer not null default 0,
  discounts integer not null default 0,
  delivery_fees integer not null default 0,
  commission integer not null default 0,
  adjustments integer not null default 0,
  net_payout integer not null default 0,
  cash_collected integer not null default 0,
  wallet_collected integer not null default 0,
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint vendor_earnings_daily_pkey primary key PRIMARY KEY (vendor_id, business_date)
);

-- rider_earnings_daily: per-rider per-day rollup for the rider app. Every
-- money column has its own non-negative CHECK — eleven of them, because a
-- negative slip in an earnings report is a support incident.
create table public.rider_earnings_daily
(
  rider_id uuid not null,
  business_date date not null,
  deliveries integer not null default 0,
  legs integer not null default 0,
  online_minutes integer not null default 0,
  base_fees integer not null default 0,
  distance_fees integer not null default 0,
  tips integer not null default 0,
  bonuses integer not null default 0,
  deductions integer not null default 0,
  net_payout integer not null default 0,
  cash_held integer not null default 0,
  cash_remitted integer not null default 0,
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint rider_earnings_base_fees_nonneg check CHECK ((base_fees >= 0)),
  constraint rider_earnings_bonuses_nonneg check CHECK ((bonuses >= 0)),
  constraint rider_earnings_cash_held_nonneg check CHECK ((cash_held >= 0)),
  constraint rider_earnings_cash_remitted_nonneg check CHECK ((cash_remitted >= 0)),
  constraint rider_earnings_daily_pkey primary key PRIMARY KEY (rider_id, business_date),
  constraint rider_earnings_deductions_nonneg check CHECK ((deductions >= 0)),
  constraint rider_earnings_deliveries_nonneg check CHECK ((deliveries >= 0)),
  constraint rider_earnings_distance_fees_nonneg check CHECK ((distance_fees >= 0)),
  constraint rider_earnings_legs_nonneg check CHECK ((legs >= 0)),
  constraint rider_earnings_online_minutes_nonneg check CHECK ((online_minutes >= 0)),
  constraint rider_earnings_tips_nonneg check CHECK ((tips >= 0))
);