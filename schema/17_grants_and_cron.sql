-- =============================================================================
-- 17_grants_and_cron.sql
-- PostgREST privileges. This file is the reason "no client can write" is true.
--
-- Three roles:
--   anon          — unauthenticated. Has almost nothing. Its only grants are on
--                   trigger functions it can never usefully call (PostgREST
--                   default grants), so in practice it cannot read the schema.
--   authenticated — a signed-in user. SELECT on tables, EXECUTE on RPCs.
--   service_role  — the Worker / cron. Bypasses RLS.
--
-- The pattern to notice: `authenticated` receives SELECT and EXECUTE and
-- NOTHING else. No INSERT, no UPDATE, no DELETE on any application table,
-- because there is not a single RLS policy that would permit one. Writes are
-- only possible through a SECURITY DEFINER function that re-checks
-- authorisation itself.
-- =============================================================================

-- =============================================================================
-- Table SELECT grants
-- =============================================================================

-- Reference / configuration: readable by any signed-in user.
grant select on public.cities to authenticated;
grant select on public.areas to authenticated;
grant select on public.delivery_zones to authenticated;
grant select on public.delivery_fee_tiers to authenticated;
grant select on public.settings to authenticated;
grant select on public.feature_flags to authenticated;
grant select on public.rider_pay_rules to authenticated;
grant select on public.commission_rules to authenticated;

-- Catalogue: vendors, taxonomy, menu.
grant select on public.vendors to authenticated;
grant select on public.brands to authenticated;
grant select on public.cuisines to authenticated;
grant select on public.vendor_cuisines to authenticated;
grant select on public.vendor_areas to authenticated;
grant select on public.vendor_schedules to authenticated;
grant select on public.vendor_holidays to authenticated;
grant select on public.vendor_staff to authenticated;
grant select on public.menu_categories to authenticated;
grant select on public.menu_items to authenticated;
grant select on public.menu_item_sizes to authenticated;
grant select on public.item_options to authenticated;
grant select on public.option_choices to authenticated;

-- Identity. RLS restricts these to self (plus the rider-may-see-their-customer
-- exception on `users`).
grant select on public.users to authenticated;
grant select on public.user_roles to authenticated;
grant select on public.user_auth_providers to authenticated;
grant select on public.addresses to authenticated;
grant select on public.device_tokens to authenticated;

-- Cart and favourites.
grant select on public.carts to authenticated;
grant select on public.cart_items to authenticated;
grant select on public.favorites to authenticated;
grant select on public.favorite_items to authenticated;

-- Orders.
grant select on public.orders to authenticated;
grant select on public.sub_orders to authenticated;
grant select on public.order_items to authenticated;
grant select on public.order_status_history to authenticated;
grant select on public.order_modifications to authenticated;
grant select on public.order_eta_snapshots to authenticated;

-- Delivery.
grant select on public.driver_shifts to authenticated;
grant select on public.delivery_assignments to authenticated;
grant select on public.rider_location_pings to authenticated;
grant select on public.rider_earnings_daily to authenticated;

-- Money. RLS scopes every one of these to the owning vendor or rider.
grant select on public.wallets to authenticated;
grant select on public.ledger_entries to authenticated;
grant select on public.payouts to authenticated;
grant select on public.payout_lines to authenticated;
grant select on public.vendor_earnings_daily to authenticated;

-- Engagement.
grant select on public.reviews to authenticated;
grant select on public.vouchers to authenticated;
grant select on public.voucher_redemptions to authenticated;
grant select on public.promo_slots to authenticated;
grant select on public.notifications to authenticated;

-- THE VIEW, NOT THE TABLE. `riders` is deliberately absent from this list:
-- authenticated has no grant on it at all. The only way to see a rider is
-- through riders_public, which has already dropped user_id, the live
-- coordinates, cash_held and max_cash_held.
grant select on public.riders_public to authenticated;

-- NOT granted to authenticated: audit_log, events, event_daily_stats,
-- auth_daily_stats, search_daily_stats, platform_float, notification_templates,
-- riders. All admin-only or worker-only.

-- =============================================================================
-- service_role: full read for the Worker, the cron jobs and admin tooling.
-- service_role also bypasses RLS, so these grants are belt-and-braces.
-- =============================================================================
grant select on all tables in schema public to service_role;

-- =============================================================================
-- RPC EXECUTE grants
--
-- Note which functions are NOT granted to authenticated:
--   claim_events_v1            service_role only — the outbox Worker
--   mark_events_delivered_v1   service_role only — the outbox Worker
--   handle_new_user()          service_role only — the Auth signup trigger
--
-- And which are NOT granted to service_role, because they are only meaningful
-- with a live user JWT and service_role has no uid:
--   effective_cash_limit_v1, normalize_text_v1
--
-- Everything admin_* is granted to `authenticated`, NOT to a separate admin
-- role. The admin check is private.is_admin() inside the function body. A
-- grant to authenticated is therefore necessary but not sufficient: the
-- function itself is the authorisation boundary.
-- =============================================================================

-- Profile and identity.
grant execute on function public.get_profile_status_v1() to authenticated;
grant execute on function public.complete_profile_v1(p_first_name text, p_last_name text, p_phone text) to authenticated;
grant execute on function public.update_profile_v1(p_patch jsonb) to authenticated;
grant execute on function public.register_device_token_v1(p_token text, p_platform text, p_app_role text, p_app_version text) to authenticated;
grant execute on function public.effective_cash_limit_v1(p_rider_id uuid) to authenticated;

-- Checkout.
grant execute on function public.quote_order_v1(p_cart_id uuid, p_address_id uuid, p_voucher_code text, p_rider_tip integer, p_delivery_type text, p_grouping text) to authenticated;
grant execute on function public.place_order_v1(p_quote_id uuid, p_payment_method text, p_idempotency_key text, p_payment_channel text) to authenticated;

-- Order lifecycle.
grant execute on function public.transition_order_v1(p_order_id uuid, p_sub_order_id uuid, p_to_status text, p_reason text) to authenticated;
grant execute on function public.cancel_order_v1(p_order_id uuid, p_sub_order_id uuid, p_reason text) to authenticated;

-- Delivery.
grant execute on function public.get_available_orders_v1(p_lat numeric, p_lng numeric, p_radius_km numeric) to authenticated;
grant execute on function public.claim_order_v1(p_assignment_id uuid, p_rider_id uuid) to authenticated;
grant execute on function public.complete_delivery_v1(p_order_id uuid, p_proof_path text, p_lat numeric, p_lng numeric) to authenticated;

-- Payment collection. This is where cash is recorded, and it is the reason the
-- platform needs no customer wallet: the rider collects, these functions record.
grant execute on function public.begin_collection_v1(p_order_id uuid, p_payment_method text, p_channel text) to authenticated;
grant execute on function public.collect_cash_v1(p_order_id uuid, p_amount integer, p_reference text, p_proof_path text) to authenticated;
grant execute on function public.collect_wallet_v1(p_order_id uuid, p_channel text, p_reference text) to authenticated;

-- Money reads and the payout run.
grant execute on function public.get_wallet_balance_v1(p_owner_type text, p_owner_id uuid) to authenticated;
grant execute on function public.adjust_wallet_v1(p_owner_type text, p_owner_id uuid, p_amount integer, p_reason text, p_reference text, p_idempotency_key text) to authenticated;
grant execute on function public.freeze_wallet_v1(p_owner_type text, p_owner_id uuid, p_reason text, p_idempotency_key text) to authenticated;
grant execute on function public.list_frozen_v1() to authenticated;
grant execute on function public.get_platform_float_v1(p_from date, p_to date) to authenticated;
grant execute on function public.reconcile_day_v1(p_date date, p_explanation text) to authenticated;
grant execute on function public.run_payout_v1(p_payout_type text, p_account_id uuid, p_period_start date, p_period_end date, p_action text, p_payout_id uuid, p_method text, p_reference text) to authenticated;

-- Earnings reports.
grant execute on function public.get_rider_earnings_v1(p_from date, p_to date) to authenticated;
grant execute on function public.get_vendor_earnings_v1(p_from date, p_to date) to authenticated;
grant execute on function public.get_vendor_dashboard_v1(p_vendor_id uuid) to authenticated;

-- Catalogue reads and search.
grant execute on function public.search_catalog_v1(p_query text, p_area_id uuid, p_filters jsonb, p_limit integer) to authenticated;
grant execute on function public.get_vendor_feed_v1(p_area_id uuid, p_vertical text, p_open_only boolean, p_query text, p_offset integer, p_limit integer, p_sort text) to authenticated;
grant execute on function public.get_flags_v1(p_app_role text, p_app_version text) to authenticated;
grant execute on function public.get_fee_rules_v1(p_zone_id uuid) to authenticated;

-- Shared pure helpers. IMMUTABLE or STABLE, no table access.
grant execute on function public.haversine_km(p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric) to authenticated;
grant execute on function public.normalize_text_v1(p_text text) to authenticated;
grant execute on function public.normalize_text_v1(p_value jsonb) to authenticated;
grant execute on function public.semver_gte(p_have text, p_need text) to authenticated;

-- Money configuration. authorised inside the function by is_admin().
grant execute on function public.set_fee_tier_v1(p_zone_id uuid, p_vendor_count smallint, p_multiplier_bps integer) to authenticated;
grant execute on function public.set_commission_rule_v1(p_scope text, p_applies_to text, p_value_bps integer, p_effective_from timestamp with time zone, p_target_id uuid, p_commission_type text) to authenticated;
grant execute on function public.get_commission_v1(p_scope text, p_target_id uuid) to authenticated;
grant execute on function public.get_admin_metrics_v1(p_date date) to authenticated;

-- Admin: geo.
grant execute on function public.admin_upsert_city_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_area_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_delete_city_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_area_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_city_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_area_v1(p_id uuid, p_reason text) to authenticated;

-- Admin: vendors and taxonomy.
grant execute on function public.admin_upsert_vendor_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_brand_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_cuisine_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_vendor_cuisine_v1(p_patch jsonb, p_vendor_id uuid, p_cuisine_id uuid) to authenticated;
grant execute on function public.admin_upsert_vendor_area_v1(p_patch jsonb, p_vendor_id uuid, p_area_id uuid) to authenticated;
grant execute on function public.admin_upsert_vendor_schedule_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_vendor_holiday_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_vendor_staff_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_delete_vendor_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_brand_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_cuisine_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_vendor_cuisine_v1(p_vendor_id uuid, p_cuisine_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_vendor_area_v1(p_vendor_id uuid, p_area_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_vendor_schedule_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_vendor_holiday_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_vendor_staff_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_vendor_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_brand_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_cuisine_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_vendor_cuisine_v1(p_vendor_id uuid, p_cuisine_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_vendor_area_v1(p_vendor_id uuid, p_area_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_vendor_schedule_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_vendor_holiday_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_vendor_staff_v1(p_id uuid, p_reason text) to authenticated;

-- Admin: menu.
grant execute on function public.admin_upsert_menu_category_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_menu_item_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_menu_item_size_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_item_option_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_upsert_option_choice_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_delete_menu_category_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_menu_item_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_menu_item_size_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_item_option_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_delete_option_choice_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_menu_category_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_menu_item_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_menu_item_size_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_item_option_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_option_choice_v1(p_id uuid, p_reason text) to authenticated;

-- Admin: vouchers.
grant execute on function public.admin_upsert_voucher_v1(p_patch jsonb, p_id uuid) to authenticated;
grant execute on function public.admin_delete_voucher_v1(p_id uuid, p_reason text) to authenticated;
grant execute on function public.admin_restore_voucher_v1(p_id uuid, p_reason text) to authenticated;

-- The outbox. service_role ONLY — a client must never be able to claim or
-- mark events, or it could suppress a push notification or replay history.
grant execute on function public.claim_events_v1(p_limit integer) to service_role;
grant execute on function public.mark_events_delivered_v1(p_ids bigint[], p_result jsonb) to service_role;

-- Auth signup trigger.
grant execute on function public.handle_new_user() to service_role;

-- =============================================================================
-- RLS helper grants. private.* is not exposed through PostgREST, but the
-- functions must be executable by `authenticated` so the policies can call
-- them during a read.
-- =============================================================================
grant execute on function private.is_admin() to authenticated;
grant execute on function private.vendor_ids_for(p_user uuid) to authenticated;
grant execute on function private.rider_ids_for(p_user uuid) to authenticated;
grant execute on function private.account_ids_for(p_user uuid) to authenticated;
grant execute on function private.visible_order_ids(p_user uuid) to authenticated;
grant execute on function private.owned_or_assigned_order_ids(p_user uuid) to authenticated;
grant execute on function private.rider_order_ids(p_user uuid) to authenticated;

-- =============================================================================
-- pg_cron schedule. Six jobs, all off-peak, all batched.
--
-- The minute offsets are staggered on purpose. Events, ETA snapshots,
-- notifications and location pings each prune hourly or daily; running them
-- all at :00 would stack four concurrent sweeps on the same connection pool.
-- =============================================================================
select cron.schedule('ensure-partitions-monthly', '10 0 1 * *', 'select private.ensure_partitions()');
select cron.schedule('prune-events-hourly',       '7 * * * *',  'select private.prune_events()');
select cron.schedule('prune-eta-hourly',          '13 * * * *', 'select private.prune_order_eta_snapshots()');
select cron.schedule('prune-notifications-daily', '23 3 * * *', 'select private.prune_notifications()');
select cron.schedule('prune-pings-daily',         '41 3 * * *', 'select private.prune_rider_location_pings()');
select cron.schedule('vacuum-hot-nightly',        '37 4 * * *', 'vacuum (analyze) public.events, public.orders, public.order_items, public.cart_items');

-- Retention windows, in one place:
--   events                 delivered and older than  7 days
--   order_eta_snapshots    older than 24 hours
--   notifications          older than 30 days
--   rider_location_pings   older than 30 days
--   audit_log              NOT pruned automatically. An audit trail that
--                           silently deletes itself is not an audit trail.
--   orders and everything below it are never pruned.