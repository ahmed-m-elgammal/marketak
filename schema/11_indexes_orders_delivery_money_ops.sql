-- =============================================================================
-- 11_indexes_orders_delivery_money_ops.sql
-- Extracted verbatim from pg_indexes. See 10_indexes_*.sql for how to read these.
-- =============================================================================

-- --- orders ---------------------------------------------------------------
CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id);
CREATE UNIQUE INDEX orders_order_number_key ON public.orders USING btree (order_number);
-- Idempotent checkout. Partial, because most orders never carry a key and NULL
-- would collide in a plain unique index.
CREATE UNIQUE INDEX orders_idempotency_key_key ON public.orders USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);

CREATE INDEX orders_user_placed ON public.orders USING btree (user_id, placed_at DESC);
CREATE INDEX orders_placed ON public.orders USING btree (placed_at DESC);
CREATE INDEX orders_status_placed ON public.orders USING btree (status, placed_at DESC);
CREATE INDEX orders_address_id ON public.orders USING btree (address_id);
CREATE INDEX orders_area_id ON public.orders USING btree (area_id);
CREATE INDEX orders_geohash_status ON public.orders USING btree (delivery_geohash_prefix, status);
CREATE INDEX orders_payment_collected_by ON public.orders USING btree (payment_collected_by);
CREATE INDEX orders_cancellation_actor ON public.orders USING btree (cancellation_actor_id);

-- --- sub_orders -----------------------------------------------------------
CREATE UNIQUE INDEX sub_orders_pkey ON public.sub_orders USING btree (id);
-- A vendor appears at most once per checkout.
CREATE UNIQUE INDEX sub_orders_order_id_vendor_id_key ON public.sub_orders USING btree (order_id, vendor_id);
CREATE UNIQUE INDEX sub_orders_order_sequence ON public.sub_orders USING btree (order_id, sequence);

CREATE INDEX sub_orders_vendor_created ON public.sub_orders USING btree (vendor_id, created_at DESC);
-- The vendor console's live queue: only states a vendor must act on.
CREATE INDEX sub_orders_vendor_open ON public.sub_orders USING btree (vendor_id, status) WHERE (status = ANY (ARRAY['pending'::text, 'accepted'::text, 'preparing'::text, 'ready'::text]));
CREATE INDEX sub_orders_status_created ON public.sub_orders USING btree (status, created_at) WHERE (status = ANY (ARRAY['pending'::text, 'accepted'::text]));
-- Partial indexes keyed on settlement_status: the payout run scans only
-- 'payable', the in-flight view only 'in_payout'. Neither touches settled rows.
CREATE INDEX sub_orders_payable_vendor ON public.sub_orders USING btree (vendor_id) WHERE (settlement_status = 'payable'::text);
CREATE INDEX sub_orders_settlement_payable ON public.sub_orders USING btree (settlement_status) WHERE (settlement_status = 'payable'::text;
CREATE INDEX sub_orders_in_payout_vendor ON public.sub_orders USING btree (vendor_id) WHERE (settlement_status = 'in_payout'::text;
CREATE INDEX sub_orders_payout_id ON public.sub_orders USING btree (payout_id) WHERE (payout_id IS NOT NULL;

-- --- order_items ----------------------------------------------------------
CREATE UNIQUE INDEX order_items_pkey ON public.order_items USING btree (id);
CREATE INDEX order_items_order_id ON public.order_items USING btree (order_id);
CREATE INDEX order_items_sub_order_id ON public.order_items USING btree (sub_order_id);
CREATE INDEX order_items_vendor_id ON public.order_items USING btree (vendor_id);
CREATE INDEX order_items_menu_item_id ON public.order_items USING btree (menu_item_id) WHERE (menu_item_id IS NOT NULL;

-- --- order_status_history -------------------------------------------------
CREATE UNIQUE INDEX order_status_history_pkey ON public.order_status_history USING btree (id);
CREATE INDEX order_status_history_order ON public.order_status_history USING btree (order_id, created_at);
CREATE INDEX order_status_history_sub_order ON public.order_status_history USING btree (sub_order_id, created_at);
CREATE INDEX order_status_history_actor ON public.order_status_history USING btree (actor_user_id);

-- --- order_modifications --------------------------------------------------
CREATE UNIQUE INDEX order_modifications_pkey ON public.order_modifications USING btree (id);
CREATE INDEX order_modifications_order ON public.order_modifications USING btree (order_id);
CREATE INDEX order_modifications_sub_order ON public.order_modifications USING btree (sub_order_id);
CREATE INDEX order_modifications_order_item ON public.order_modifications USING btree (order_item_id);
CREATE INDEX order_modifications_actor ON public.order_modifications USING btree (actor_user_id);

-- --- order_eta_snapshots --------------------------------------------------
CREATE UNIQUE INDEX order_eta_snapshots_pkey ON public.order_eta_snapshots USING btree (id);
CREATE INDEX order_eta_snapshots_order ON public.order_eta_snapshots USING btree (order_id, computed_at DESC);
CREATE INDEX order_eta_snapshots_sub_order ON public.order_eta_snapshots USING btree (sub_order_id) WHERE (sub_order_id IS NOT NULL;
CREATE INDEX order_eta_snapshots_computed_at ON public.order_eta_snapshots USING btree (computed_at);

-- --- riders ---------------------------------------------------------------
CREATE UNIQUE INDEX riders_pkey ON public.riders USING btree (id);
CREATE UNIQUE INDEX riders_phone_number_key ON public.riders USING btree (phone_number);
CREATE INDEX riders_user_id ON public.riders USING btree (user_id) WHERE (user_id IS NOT NULL;
CREATE INDEX riders_home_area_id ON public.riders USING btree (home_area_id) WHERE (home_area_id IS NOT NULL;
CREATE INDEX riders_status_online ON public.riders USING btree (status) WHERE (is_online;
CREATE INDEX riders_active_verified ON public.riders USING btree (home_area_id, status) WHERE (is_active AND (is_verified);
-- Dispatch's hot lookup: online + active, geohash-prefixed.
CREATE INDEX riders_online_status_geohash ON public.riders USING btree (is_online, status, current_geohash) WHERE (is_active;

-- --- driver_shifts --------------------------------------------------------
CREATE UNIQUE INDEX driver_shifts_pkey ON public.driver_shifts USING btree (id);
CREATE INDEX driver_shifts_rider_starts ON public.driver_shifts USING btree (rider_id, starts_at DESC);
CREATE INDEX driver_shifts_active_window ON public.driver_shifts USING btree (starts_at, ends_at) WHERE is_active;
-- EXCLUDE constraint, not a plain unique index. `EXCLUDE ... WITH &&` is what
-- actually forbids two active shifts whose time ranges overlap; a unique index
-- on the same columns would only forbid byte-identical rows and would let a
-- rider be double-booked. This is the one object in the schema that needs
-- btree_gist (to make `uuid` gist-comparable).
ALTER TABLE public.driver_shifts ADD CONSTRAINT driver_shifts_no_overlap
  EXCLUDE USING gist (rider_id WITH =, tstzrange(starts_at, ends_at, '[)'::text) WITH &&)
  WHERE (is_active);

-- --- rider_location_pings -------------------------------------------------
CREATE UNIQUE INDEX rider_location_pings_pkey ON public.rider_location_pings USING btree (id);
CREATE INDEX rider_location_pings_order ON public.rider_location_pings USING btree (order_id, recorded_at DESC);
CREATE INDEX rider_location_pings_rider ON public.rider_location_pings USING btree (rider_id, recorded_at DESC);
-- Serves the retention sweep, which scans by time, not by order.
CREATE INDEX rider_location_pings_recorded_at ON public.rider_location_pings USING btree (recorded_at);

-- --- delivery_assignments -------------------------------------------------
CREATE UNIQUE INDEX delivery_assignments_pkey ON public.delivery_assignments USING btree (id);
-- One live trip per order. Terminal states are excluded, so a redelivery of the
-- same order is allowed once the first trip is closed.
CREATE UNIQUE INDEX delivery_assignments_one_active ON public.delivery_assignments USING btree (order_id) WHERE (status <> ALL (ARRAY['delivered'::text, 'failed'::text, 'cancelled'::text]);
-- The rider-claim offer pool.
CREATE INDEX delivery_assignments_offer_pool ON public.delivery_assignments USING btree (assigned_at) WHERE ((rider_id IS NULL) AND (status = 'unassigned'::text));
CREATE INDEX delivery_assignments_open ON public.delivery_assignments USING btree (rider_id, status) WHERE (status = ANY (ARRAY['assigned'::text, 'at_first_vendor'::text, 'picking_up'::text, 'picked_up'::text, 'delivering'::text, 'arrived'::text]));
CREATE INDEX delivery_assignments_rider_history ON public.delivery_assignments USING btree (rider_id, assigned_at DESC);
CREATE INDEX delivery_assignments_delivered_rider ON public.delivery_assignments USING btree (rider_id, delivered_at) WHERE (status = 'delivered'::text;
CREATE INDEX delivery_assignments_sub_order ON public.delivery_assignments USING btree (sub_order_id) WHERE (sub_order_id IS NOT NULL;

-- --- rider_pay_rules ------------------------------------------------------
CREATE UNIQUE INDEX rider_pay_rules_pkey ON public.rider_pay_rules USING btree (id);
-- At most one city-wide default rule at a time.
CREATE UNIQUE INDEX rider_pay_rules_default ON public.rider_pay_rules USING btree (city_id) WHERE ((rider_id IS NULL) AND (is_active));
CREATE INDEX rider_pay_rules_rider_active ON public.rider_pay_rules USING btree (rider_id, is_active);

-- --- wallets --------------------------------------------------------------
CREATE UNIQUE INDEX wallets_pkey ON public.wallets USING btree (id);
CREATE UNIQUE INDEX wallets_owner_type_owner_id_key ON public.wallets USING btree (owner_type, owner_id);

-- --- ledger_entries -------------------------------------------------------
CREATE UNIQUE INDEX ledger_entries_pkey ON public.ledger_entries USING btree (id);
-- The idempotency guarantee for all money movement.
CREATE UNIQUE INDEX ledger_entries_idempotency_key_key ON public.ledger_entries USING btree (idempotency_key);
CREATE INDEX ledger_entries_account_created ON public.ledger_entries USING btree (account_type, account_id, created_at DESC);
CREATE INDEX ledger_entries_created_at ON public.ledger_entries USING btree (created_at);
CREATE INDEX ledger_entries_order ON public.ledger_entries USING btree (order_id);
CREATE INDEX ledger_entries_sub_order ON public.ledger_entries USING btree (sub_order_id);
CREATE INDEX ledger_entries_payout ON public.ledger_entries USING btree (payout_id);

-- --- payouts --------------------------------------------------------------
CREATE UNIQUE INDEX payouts_pkey ON public.payouts USING btree (id);
CREATE UNIQUE INDEX payouts_idempotency_key_key ON public.payouts USING btree (idempotency_key);
CREATE INDEX payouts_account_created ON public.payouts USING btree (account_id, created_at DESC);
CREATE INDEX payouts_type_status_period ON public.payouts USING btree (payout_type, status, period_end DESC);
CREATE INDEX payouts_approved_by ON public.payouts USING btree (approved_by) WHERE (approved_by IS NOT NULL;

-- --- payout_lines ---------------------------------------------------------
CREATE UNIQUE INDEX payout_lines_pkey ON public.payout_lines USING btree (id);
CREATE INDEX payout_lines_payout ON public.payout_lines USING btree (payout_id);
-- One earning line per sub_order, one trip line per assignment: the same
-- invariant the payout_lines_shape CHECK expresses, made index-enforced so a
-- concurrent payout run cannot produce a duplicate.
CREATE UNIQUE INDEX payout_lines_sub_order_unique ON public.payout_lines USING btree (sub_order_id) WHERE (sub_order_id IS NOT NULL;
CREATE UNIQUE INDEX payout_lines_assignment_unique ON public.payout_lines USING btree (assignment_id, payout_line_type) WHERE (assignment_id IS NOT NULL;

-- --- platform_float / commission_rules -----------------------------------
CREATE UNIQUE INDEX platform_float_pkey ON public.platform_float USING btree (id);
CREATE UNIQUE INDEX platform_float_business_date_key ON public.platform_float USING btree (business_date);
CREATE UNIQUE INDEX commission_rules_pkey ON public.commission_rules USING btree (id);
CREATE INDEX commission_rules_scope_target_active ON public.commission_rules USING btree (scope, target_id, is_active);
CREATE INDEX commission_rules_created_by ON public.commission_rules USING btree (created_by) WHERE (created_by IS NOT NULL;

-- --- reviews --------------------------------------------------------------
CREATE UNIQUE INDEX reviews_pkey ON public.reviews USING btree (id);
CREATE UNIQUE INDEX reviews_order_id_vendor_id_key ON public.reviews USING btree (order_id, vendor_id);
CREATE INDEX reviews_user_created ON public.reviews USING btree (user_id, created_at DESC);
CREATE INDEX reviews_vendor_created ON public.reviews USING btree (vendor_id, created_at DESC) WHERE (NOT (is_hidden);
CREATE INDEX reviews_sub_order ON public.reviews USING btree (sub_order_id) WHERE (sub_order_id IS NOT NULL;
CREATE INDEX reviews_rider ON public.reviews USING btree (rider_id) WHERE (rider_id IS NOT NULL;

-- --- vouchers -------------------------------------------------------------
CREATE UNIQUE INDEX vouchers_pkey ON public.vouchers USING btree (id);
CREATE UNIQUE INDEX vouchers_code_key ON public.vouchers USING btree (code);
-- Codes are matched case-insensitively, so uniqueness must be too.
CREATE UNIQUE INDEX vouchers_code_upper ON public.vouchers USING btree (upper(code));
CREATE INDEX vouchers_active_window ON public.vouchers USING btree (is_active, valid_from, valid_until);
CREATE INDEX vouchers_applies_to_vendor_ids ON public.vouchers USING gin (applies_to_vendor_ids);
CREATE INDEX vouchers_created_by ON public.vouchers USING btree (created_by) WHERE (created_by IS NOT NULL;

CREATE UNIQUE INDEX voucher_redemptions_pkey ON public.voucher_redemptions USING btree (id);
-- One redemption per voucher per order.
CREATE UNIQUE INDEX voucher_redemption_order ON public.voucher_redemptions USING btree (voucher_id, order_id) WHERE (order_id IS NOT NULL;
CREATE INDEX voucher_redemptions_order ON public.voucher_redemptions USING btree (order_id) WHERE (order_id IS NOT NULL;
CREATE INDEX voucher_redemptions_sub_order ON public.voucher_redemptions USING btree (sub_order_id) WHERE (sub_order_id IS NOT NULL;
CREATE INDEX voucher_redemptions_user ON public.voucher_redemptions USING btree (user_id);
CREATE INDEX voucher_redemptions_voucher_user ON public.voucher_redemptions USING btree (voucher_id, user_id);

-- --- promo_slots ----------------------------------------------------------
CREATE UNIQUE INDEX promo_slots_pkey ON public.promo_slots USING btree (id);
CREATE UNIQUE INDEX promo_slots_city_id_slot_key_key ON public.promo_slots USING btree (city_id, slot_key);
CREATE INDEX promo_slots_active_sort ON public.promo_slots USING btree (city_id, sort_order) WHERE (is_active;

-- --- events (the outbox) --------------------------------------------------
CREATE UNIQUE INDEX events_pkey ON public.events USING btree (id);
CREATE UNIQUE INDEX events_id_uuid_key ON public.events USING btree (id_uuid);
-- The Worker's claim scan. Partial on delivered_at IS NULL so it never reads
-- the delivered backlog.
CREATE INDEX events_undelivered ON public.events USING btree (created_at) WHERE (delivered_at IS NULL;
CREATE INDEX events_delivered_at ON public.events USING btree (delivered_at, created_at);
CREATE INDEX events_aggregate ON public.events USING btree (aggregate_id, created_at);

-- --- notifications (partitioned parent + children) ------------------------
CREATE UNIQUE INDEX notifications_pkey ON ONLY public.notifications USING btree (id, created_at);
CREATE INDEX notifications_user_created ON ONLY public.notifications USING btree (user_id, created_at DESC);
CREATE INDEX notifications_order ON ONLY public.notifications USING btree (order_id) WHERE (order_id IS NOT NULL;
CREATE INDEX notifications_sub_order ON ONLY public.notifications USING btree (sub_order_id) WHERE (sub_order_id IS NOT NULL;
CREATE INDEX notifications_created_at ON ONLY public.notifications USING btree (created_at);

CREATE UNIQUE INDEX notifications_2026_10_pkey ON public.notifications_2026_10 USING btree (id, created_at);
CREATE INDEX notifications_2026_10_user_id_created_at_idx ON public.notifications_2026_10 USING btree (user_id, created_at DESC);
CREATE INDEX notifications_2026_10_order_id_idx ON public.notifications_2026_10 USING btree (order_id) WHERE (order_id IS NOT NULL;
CREATE INDEX notifications_2026_10_sub_order_id_idx ON public.notifications_2026_10 USING btree (sub_order_id) WHERE (sub_order_id IS NOT NULL;
CREATE INDEX notifications_2026_10_created_at_idx ON public.notifications_2026_10 USING btree (created_at);

CREATE UNIQUE INDEX notifications_2026_11_pkey ON public.notifications_2026_11 USING btree (id, created_at);
CREATE INDEX notifications_2026_11_user_id_created_at_idx ON public.notifications_2026_11 USING btree (user_id, created_at DESC);
CREATE INDEX notifications_2026_11_order_id_idx ON public.notifications_2026_11 USING btree (order_id) WHERE (order_id IS NOT NULL;
CREATE INDEX notifications_2026_11_sub_order_id_idx ON public.notifications_2026_11 USING btree (sub_order_id) WHERE (sub_order_id IS NOT NULL;
CREATE INDEX notifications_2026_11_created_at_idx ON public.notifications_2026_11 USING btree (created_at);

-- --- notification_templates -----------------------------------------------
CREATE UNIQUE INDEX notification_templates_pkey ON public.notification_templates USING btree (id);
CREATE UNIQUE INDEX notification_templates_key_channel_lang_key ON public.notification_templates USING btree (key, channel, lang);

-- --- audit_log (partitioned parent + children) ----------------------------
CREATE UNIQUE INDEX audit_log_pkey ON ONLY public.audit_log USING btree (id, created_at);
CREATE INDEX audit_log_created_at ON ONLY public.audit_log USING btree (created_at);
CREATE INDEX audit_log_actor_user ON ONLY public.audit_log USING btree (actor_user_id, created_at DESC) WHERE (actor_user_id IS NOT NULL;
CREATE INDEX audit_log_entity ON ONLY public.audit_log USING btree (entity_type, entity_id, created_at DESC);

CREATE UNIQUE INDEX audit_log_2026_10_pkey ON public.audit_log_2026_10 USING btree (id, created_at);
CREATE INDEX audit_log_2026_10_created_at_idx ON public.audit_log_2026_10 USING btree (created_at);
CREATE INDEX audit_log_2026_10_actor_user_id_created_at_idx ON public.audit_log_2026_10 USING btree (actor_user_id, created_at DESC) WHERE (actor_user_id IS NOT NULL;
CREATE INDEX audit_log_2026_10_entity_type_entity_id_created_at_idx ON public.audit_log_2026_10 USING btree (entity_type, entity_id, created_at DESC);

CREATE UNIQUE INDEX audit_log_2026_11_pkey ON public.audit_log_2026_11 USING btree (id, created_at);
CREATE INDEX audit_log_2026_11_created_at_idx ON public.audit_log_2026_11 USING btree (created_at);
CREATE INDEX audit_log_2026_11_actor_user_id_created_at_idx ON public.audit_log_2026_11 USING btree (actor_user_id, created_at DESC) WHERE (actor_user_id IS NOT NULL;
CREATE INDEX audit_log_2026_11_entity_type_entity_id_created_at_idx ON public.audit_log_2026_11 USING btree (entity_type, entity_id, created_at DESC);

-- --- daily rollups --------------------------------------------------------
CREATE UNIQUE INDEX event_daily_stats_pkey ON public.event_daily_stats USING btree (business_date, city_id, app_role, event_name);
CREATE UNIQUE INDEX auth_daily_stats_pkey ON public.auth_daily_stats USING btree (business_date, event_name);
CREATE UNIQUE INDEX search_daily_stats_pkey ON public.search_daily_stats USING btree (business_date, city_id, query_hash);
CREATE UNIQUE INDEX vendor_earnings_daily_pkey ON public.vendor_earnings_daily USING btree (vendor_id, business_date);
CREATE INDEX vendor_earnings_daily_live ON public.vendor_earnings_daily USING btree (vendor_id, business_date) WHERE (deleted_at IS NULL;
CREATE UNIQUE INDEX rider_earnings_daily_pkey ON public.rider_earnings_daily USING btree (rider_id, business_date);
CREATE INDEX rider_earnings_daily_live ON public.rider_earnings_daily USING btree (rider_id, business_date) WHERE (deleted_at IS NULL;