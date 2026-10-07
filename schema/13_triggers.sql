-- =============================================================================
-- 13_triggers.sql
-- 72 triggers. Grouped by the job they do, not by table.
--
-- The database is the enforcement layer. Anything that MUST be true is a
-- CHECK constraint or a trigger here — never a rule the application is trusted
-- to remember.
--
-- Four families:
--   A. set_updated_at()            — mechanical, 45 tables
--   B. menu_version bumps          — cache invalidation for catalog writes
--   C. invariant assertions        — deny the write rather than fix it up
--   D. denormalisation sync        — keep a duplicated column true
-- =============================================================================

-- =============================================================================
-- A. set_updated_at(): BEFORE UPDATE on every table carrying updated_at
-- =============================================================================
CREATE TRIGGER trg_addresses_updated_at BEFORE UPDATE ON "public.addresses" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_areas_updated_at BEFORE UPDATE ON "public.areas" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_auth_daily_stats_updated_at BEFORE UPDATE ON "public.auth_daily_stats" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_brands_updated_at BEFORE UPDATE ON "public.brands" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_cart_items_updated_at BEFORE UPDATE ON "public.cart_items" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_carts_updated_at BEFORE UPDATE ON "public.carts" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_cities_updated_at BEFORE UPDATE ON "public.cities" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_commission_rules_updated_at BEFORE UPDATE ON "public.commission_rules" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_cuisines_updated_at BEFORE UPDATE ON "public.cuisines" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_delivery_assignments_updated_at BEFORE UPDATE ON "public.delivery_assignments" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_delivery_fee_tiers_updated_at BEFORE UPDATE ON "public.delivery_fee_tiers" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_delivery_zones_updated_at BEFORE UPDATE ON "public.delivery_zones" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_event_daily_stats_updated_at BEFORE UPDATE ON "public.event_daily_stats" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_feature_flags_updated_at BEFORE UPDATE ON "public.feature_flags" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_item_options_updated_at BEFORE UPDATE ON "public.item_options" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_menu_categories_updated_at BEFORE UPDATE ON "public.menu_categories" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_menu_item_sizes_updated_at BEFORE UPDATE ON "public.menu_item_sizes" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_menu_items_updated_at BEFORE UPDATE ON "public.menu_items" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_notification_templates_updated_at BEFORE UPDATE ON "public.notification_templates" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_option_choices_updated_at BEFORE UPDATE ON "public.option_choices" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated_at BEFORE UPDATE ON "public.orders" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_payouts_updated_at BEFORE UPDATE ON "public.payouts" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_platform_float_updated_at BEFORE UPDATE ON "public.platform_float" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_promo_slots_updated_at BEFORE UPDATE ON "public.promo_slots" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_reviews_updated_at BEFORE UPDATE ON "public.reviews" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_rider_earnings_daily_updated_at BEFORE UPDATE ON "public.rider_earnings_daily" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_rider_pay_rules_updated_at BEFORE UPDATE ON "public.rider_pay_rules" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_riders_updated_at BEFORE UPDATE ON "public.riders" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_search_daily_stats_updated_at BEFORE UPDATE ON "public.search_daily_stats" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_settings_updated_at BEFORE UPDATE ON "public.settings" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sub_orders_updated_at BEFORE UPDATE ON "public.sub_orders" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON "public.users" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vendor_areas_updated_at BEFORE UPDATE ON "public.vendor_areas" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vendor_cuisines_updated_at BEFORE UPDATE ON "public.vendor_cuisines" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vendor_earnings_daily_updated_at BEFORE UPDATE ON "public.vendor_earnings_daily" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vendor_holidays_updated_at BEFORE UPDATE ON "public.vendor_holidays" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vendor_schedules_updated_at BEFORE UPDATE ON "public.vendor_schedules" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vendor_staff_updated_at BEFORE UPDATE ON "public.vendor_staff" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vendors_updated_at BEFORE UPDATE ON "public.vendors" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vouchers_updated_at BEFORE UPDATE ON "public.vouchers" FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_wallets_updated_at BEFORE UPDATE ON "public.wallets" FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- B. menu_version bumps. Clients cache a vendor's menu keyed on
-- vendors.menu_version; any catalog write to that vendor's tree must bump it.
-- These are FOR EACH STATEMENT so a bulk edit bumps once, not per row.
-- =============================================================================

-- menu_items and menu_categories carry vendor_id directly.
CREATE TRIGGER trg_bump_v_menu_items_ins BEFORE INSERT OR UPDATE ON "public.menu_items" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_direct_vendor();
CREATE TRIGGER trg_bump_v_menu_items_upd BEFORE UPDATE ON "public.menu_items" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_direct_vendor();
CREATE TRIGGER trg_bump_v_menu_categories_ins BEFORE INSERT OR UPDATE ON "public.menu_categories" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_direct_vendor();
CREATE TRIGGER trg_bump_v_menu_categories_upd BEFORE UPDATE ON "public.menu_categories" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_direct_vendor();

-- menu_item_sizes and item_options must walk up item_id -> vendor_id.
CREATE TRIGGER trg_bump_v_menu_item_sizes_ins BEFORE INSERT OR UPDATE ON "public.menu_item_sizes" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_items_of();
CREATE TRIGGER trg_bump_v_menu_item_sizes_upd BEFORE UPDATE ON "public.menu_item_sizes" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_items_of();
CREATE TRIGGER trg_bump_v_item_options_ins BEFORE INSERT OR UPDATE ON "public.item_options" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_items_of();
CREATE TRIGGER trg_bump_v_item_options_upd BEFORE UPDATE ON "public.item_options" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_items_of();

-- option_choices must walk option_id -> item_id -> vendor_id: two hops.
CREATE TRIGGER trg_bump_v_option_choices_ins BEFORE INSERT OR UPDATE ON "public.option_choices" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_choices();
CREATE TRIGGER trg_bump_v_option_choices_upd BEFORE UPDATE ON "public.option_choices" FOR EACH STATEMENT EXECUTE FUNCTION bump_version_for_choices();

-- =============================================================================
-- C. Invariant assertions. These RAISE; they never silently repair.
--
-- ALL FIVE ARE `DEFERRABLE INITIALLY DEFERRED`. This is load-bearing, not
-- decoration, and it is the only reason they can work at all.
--
-- Four of the five check a property of a ROW'S SIBLINGS, so an immediate check
-- would fire against a half-built state:
--
--   trg_fee_tiers_monotonic   compares the new tier against the tiers for
--                              LOWER vendor counts. Updating tier 2 to a value
--                              below tier 1 must fail, but only once the whole
--                              set is visible.
--   trg_item_still_sized      asks whether the item has any size row LEFT. On a
--                              BEFORE DELETE it sees the row still present, so
--                              an immediate check would pass every time and the
--                              guard would do nothing.
--   trg_item_has_sizes        asks whether sizes EXIST. Creating a 'sized' item
--                              and its first size in one transaction fails
--                              immediately unless deferred.
--   trg_cart_item_orderable   validates against live menu state that a
--                              preceding statement in the same transaction may
--                              be changing.
--   trg_history_scope         validates the order/sub_order pairing the caller
--                              is about to write.
--
-- Deferring moves the check to COMMIT. A violation still aborts the
-- transaction — it just aborts once the write is coherent, instead of
-- rejecting a legitimate multi-statement operation. Reproducing the five as
-- pg_constraint rows of type 't' confirms the deferral is set on the trigger,
-- not in its body.
-- =============================================================================

-- A delivery fee may never get cheaper as vendors are added to the basket.
CREATE TRIGGER trg_fee_tiers_monotonic BEFORE INSERT OR UPDATE ON "public.delivery_fee_tiers" FOR EACH ROW EXECUTE FUNCTION assert_fee_tiers_monotonic() DEFERRABLE INITIALLY DEFERRED;

-- A cart line may only reference an item that is currently orderable.
CREATE TRIGGER trg_cart_item_orderable BEFORE INSERT OR UPDATE ON "public.cart_items" FOR EACH ROW EXECUTE FUNCTION assert_cart_item_orderable() DEFERRABLE INITIALLY DEFERRED;

-- pricing_mode = 'sized' requires at least one size row to exist.
CREATE TRIGGER trg_item_has_sizes BEFORE INSERT OR UPDATE ON "public.menu_items" FOR EACH ROW EXECUTE FUNCTION assert_item_has_sizes() DEFERRABLE INITIALLY DEFERRED;

-- The last size row of a 'sized' item may not be deleted — the item would
-- become unsellable with no size to fall back on.
CREATE TRIGGER trg_item_still_sized BEFORE DELETE OR UPDATE ON "public.menu_item_sizes" FOR EACH ROW EXECUTE FUNCTION assert_item_still_sized() DEFERRABLE INITIALLY DEFERRED;

-- A history row must be scoped to exactly one order or sub_order, never both
-- and never neither.
CREATE TRIGGER trg_history_scope BEFORE INSERT OR UPDATE ON "public.order_status_history" FOR EACH ROW EXECUTE FUNCTION assert_history_scope() DEFERRABLE INITIALLY DEFERRED;

-- Polymorphic reference integrity. These four columns have no FK by design;
-- these triggers are what makes that safe.
CREATE TRIGGER trg_wallets_assert_owner BEFORE INSERT OR UPDATE ON "public.wallets" FOR EACH ROW EXECUTE FUNCTION private.assert_wallet_owner();
CREATE TRIGGER trg_ledger_entries_assert_account BEFORE INSERT OR UPDATE ON "public.ledger_entries" FOR EACH ROW EXECUTE FUNCTION private.assert_ledger_account();
CREATE TRIGGER trg_payouts_assert_account BEFORE INSERT OR UPDATE ON "public.payouts" FOR EACH ROW EXECUTE FUNCTION private.assert_payout_account();
CREATE TRIGGER trg_commission_rules_assert_target BEFORE INSERT OR UPDATE ON "public.commission_rules" FOR EACH ROW EXECUTE FUNCTION private.assert_commission_target();

-- =============================================================================
-- D. Denormalisation sync. These keep a duplicated column true so reads never
-- need the join, and so the order header cannot disagree with its children.
-- =============================================================================

-- menu_items.vendor_id must equal its category's vendor.
CREATE TRIGGER trg_menu_item_vendor BEFORE INSERT OR UPDATE ON "public.menu_items" FOR EACH ROW EXECUTE FUNCTION sync_menu_item_vendor();

-- cart_items.vendor_id must equal the item's vendor.
CREATE TRIGGER trg_cart_items_sync_vendor BEFORE INSERT OR UPDATE ON "public.cart_items" FOR EACH ROW EXECUTE FUNCTION sync_cart_item_vendor();

-- order_items.order_id must equal its sub_order's order_id: a line cannot
-- belong to one order while its sub_order belongs to another.
CREATE TRIGGER trg_order_items_sync_parent BEFORE INSERT OR UPDATE ON "public.order_items" FOR EACH ROW EXECUTE FUNCTION sync_order_item_parent();

-- orders.vendor_count / item_count are recomputed from the children on every
-- statement touching order_items.
CREATE TRIGGER trg_order_items_aggregates_ins BEFORE INSERT OR UPDATE ON "public.order_items" FOR EACH STATEMENT EXECUTE FUNCTION sync_order_item_aggregates_ins();
CREATE TRIGGER trg_order_items_aggregates_upd BEFORE UPDATE ON "public.order_items" FOR EACH STATEMENT EXECUTE FUNCTION sync_order_item_aggregates_upd();
CREATE TRIGGER trg_order_items_aggregates_del BEFORE DELETE OR UPDATE ON "public.order_items" FOR EACH STATEMENT EXECUTE FUNCTION sync_order_item_aggregates_del();

-- orders.status is derived from the sub_orders. The application does not write
-- it directly; this trigger is the only writer.
CREATE TRIGGER trg_sub_orders_sync_order_status_ins BEFORE INSERT OR UPDATE ON "public.sub_orders" FOR EACH STATEMENT EXECUTE FUNCTION sync_order_status();
CREATE TRIGGER trg_sub_orders_sync_order_status_upd BEFORE UPDATE ON "public.sub_orders" FOR EACH STATEMENT EXECUTE FUNCTION sync_order_status();

-- Cart activity timestamp, kept fresh by statement-level touch.
CREATE TRIGGER trg_cart_items_touch_ins BEFORE INSERT OR UPDATE ON "public.cart_items" FOR EACH STATEMENT EXECUTE FUNCTION touch_cart_from_new_rows();
CREATE TRIGGER trg_cart_items_touch_upd BEFORE UPDATE ON "public.cart_items" FOR EACH STATEMENT EXECUTE FUNCTION touch_cart_from_new_rows();

-- Contact details must agree across the user profile and the rider record.
-- The customer pays the rider at the door, so a stale number is a real failure.
CREATE TRIGGER trg_user_contact_to_rider BEFORE UPDATE ON "public.users" FOR EACH ROW EXECUTE FUNCTION private.push_user_contact_to_rider();
CREATE TRIGGER trg_rider_contact_from_user BEFORE INSERT OR UPDATE ON "public.riders" FOR EACH ROW EXECUTE FUNCTION private.sync_rider_contact_from_user();