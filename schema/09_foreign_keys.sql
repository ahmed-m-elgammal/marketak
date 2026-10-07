-- =============================================================================
-- 09_foreign_keys.sql
-- All foreign keys, in dependency order. Extracted verbatim from pg_constraint.
--
-- ON DELETE policy summary:
--   CASCADE    - the child is part of the parent's lifecycle (a cart line dies
--                with its cart; a menu item dies with its vendor).
--   SET NULL   - the child must survive but the link is optional (an order line
--                outlives the menu item it names).
--   no action  - historical or financial record; the parent may not be removed.
-- =============================================================================

-- --- identity -------------------------------------------------------------
alter table public.users add constraint users_id_fkey foreign key (id) references auth.users(id) on delete cascade;

alter table public.user_roles add constraint user_roles_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.user_roles add constraint user_roles_granted_by_fkey foreign key (granted_by) references users(id);

alter table public.user_auth_providers add constraint user_auth_providers_user_id_fkey foreign key (user_id) references users(id) on delete cascade;

alter table public.addresses add constraint addresses_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.addresses add constraint addresses_area_id_fkey foreign key (area_id) references areas(id);

alter table public.device_tokens add constraint device_tokens_user_id_fkey foreign key (user_id) references users(id) on delete cascade;

-- --- geo and platform -----------------------------------------------------
alter table public.areas add constraint areas_city_id_fkey foreign key (city_id) references cities(id);

alter table public.delivery_zones add constraint delivery_zones_city_id_fkey foreign key (city_id) references cities(id);
alter table public.delivery_zones add constraint delivery_zones_area_id_fkey foreign key (area_id) references areas(id);

alter table public.delivery_fee_tiers add constraint delivery_fee_tiers_zone_id_fkey foreign key (zone_id) references delivery_zones(id) on delete cascade;

alter table public.settings add constraint settings_updated_by_fkey foreign key (updated_by) references auth.users(id);
alter table public.feature_flags add constraint feature_flags_updated_by_fkey foreign key (updated_by) references auth.users(id);

-- --- vendors and catalog --------------------------------------------------
alter table public.vendors add constraint vendors_brand_id_fkey foreign key (brand_id) references brands(id);
alter table public.vendors add constraint vendors_city_id_fkey foreign key (city_id) references cities(id);
alter table public.vendors add constraint vendors_area_id_fkey foreign key (area_id) references areas(id);

alter table public.vendor_cuisines add constraint vendor_cuisines_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;
alter table public.vendor_cuisines add constraint vendor_cuisines_cuisine_id_fkey foreign key (cuisine_id) references cuisines(id) on delete cascade;

alter table public.vendor_areas add constraint vendor_areas_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;
alter table public.vendor_areas add constraint vendor_areas_area_id_fkey foreign key (area_id) references areas(id) on delete cascade;

alter table public.vendor_staff add constraint vendor_staff_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.vendor_staff add constraint vendor_staff_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;

alter table public.vendor_schedules add constraint vendor_schedules_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;

alter table public.vendor_holidays add constraint vendor_holidays_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;

alter table public.menu_categories add constraint menu_categories_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;

alter table public.menu_items add constraint menu_items_category_id_fkey foreign key (category_id) references menu_categories(id) on delete cascade;
alter table public.menu_items add constraint menu_items_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;

alter table public.menu_item_sizes add constraint menu_item_sizes_item_id_fkey foreign key (item_id) references menu_items(id) on delete cascade;

alter table public.item_options add constraint item_options_item_id_fkey foreign key (item_id) references menu_items(id) on delete cascade;

alter table public.option_choices add constraint option_choices_option_id_fkey foreign key (option_id) references item_options(id) on delete cascade;

-- --- cart -----------------------------------------------------------------
alter table public.carts add constraint carts_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.carts add constraint carts_quote_address_id_fkey foreign key (quote_address_id) references addresses(id) on delete set null;

alter table public.cart_items add constraint cart_items_cart_id_fkey foreign key (cart_id) references carts(id) on delete cascade;
alter table public.cart_items add constraint cart_items_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;
alter table public.cart_items add constraint cart_items_menu_item_id_fkey foreign key (menu_item_id) references menu_items(id) on delete cascade;
alter table public.cart_items add constraint cart_items_selected_size_id_fkey foreign key (selected_size_id) references menu_item_sizes(id) on delete set null;

alter table public.favorites add constraint favorites_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.favorites add constraint favorites_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;

alter table public.favorite_items add constraint favorite_items_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.favorite_items add constraint favorite_items_menu_item_id_fkey foreign key (menu_item_id) references menu_items(id) on delete cascade;

-- --- orders ---------------------------------------------------------------
alter table public.orders add constraint orders_user_id_fkey foreign key (user_id) references users(id);
alter table public.orders add constraint orders_address_id_fkey foreign key (address_id) references addresses(id);
alter table public.orders add constraint orders_area_id_fkey foreign key (area_id) references areas(id);
alter table public.orders add constraint orders_payment_collected_by_fkey foreign key (payment_collected_by) references users(id);
alter table public.orders add constraint orders_cancellation_actor_id_fkey foreign key (cancellation_actor_id) references users(id);

alter table public.sub_orders add constraint sub_orders_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.sub_orders add constraint sub_orders_vendor_id_fkey foreign key (vendor_id) references vendors(id);
alter table public.sub_orders add constraint sub_orders_payout_id_fkey foreign key (payout_id) references payouts(id) on delete set null;

alter table public.order_items add constraint order_items_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;
alter table public.order_items add constraint order_items_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.order_items add constraint order_items_vendor_id_fkey foreign key (vendor_id) references vendors(id);
-- SET NULL, not CASCADE: the priced line must outlive the menu item it names.
alter table public.order_items add constraint order_items_menu_item_id_fkey foreign key (menu_item_id) references menu_items(id) on delete set null;
alter table public.order_items add constraint order_items_selected_size_id_fkey foreign key (selected_size_id) references menu_item_sizes(id) on delete set null;

alter table public.order_status_history add constraint order_status_history_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.order_status_history add constraint order_status_history_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;
alter table public.order_status_history add constraint order_status_history_actor_user_id_fkey foreign key (actor_user_id) references users(id);

alter table public.order_modifications add constraint order_modifications_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.order_modifications add constraint order_modifications_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;
alter table public.order_modifications add constraint order_modifications_order_item_id_fkey foreign key (order_item_id) references order_items(id) on delete cascade;
alter table public.order_modifications add constraint order_modifications_actor_user_id_fkey foreign key (actor_user_id) references users(id);

alter table public.order_eta_snapshots add constraint order_eta_snapshots_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.order_eta_snapshots add constraint order_eta_snapshots_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;

-- --- delivery -------------------------------------------------------------
alter table public.riders add constraint riders_user_id_fkey foreign key (user_id) references users(id) on delete set null;
alter table public.riders add constraint riders_home_area_id_fkey foreign key (home_area_id) references areas(id);

alter table public.driver_shifts add constraint driver_shifts_rider_id_fkey foreign key (rider_id) references riders(id) on delete cascade;

alter table public.rider_location_pings add constraint rider_location_pings_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.rider_location_pings add constraint rider_location_pings_rider_id_fkey foreign key (rider_id) references riders(id) on delete cascade;

alter table public.delivery_assignments add constraint delivery_assignments_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.delivery_assignments add constraint delivery_assignments_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;
alter table public.delivery_assignments add constraint delivery_assignments_rider_id_fkey foreign key (rider_id) references riders(id) on delete set null;

alter table public.rider_pay_rules add constraint rider_pay_rules_city_id_fkey foreign key (city_id) references cities(id);
alter table public.rider_pay_rules add constraint rider_pay_rules_rider_id_fkey foreign key (rider_id) references riders(id);

-- --- money ----------------------------------------------------------------
alter table public.ledger_entries add constraint ledger_entries_order_id_fkey foreign key (order_id) references orders(id);
alter table public.ledger_entries add constraint ledger_entries_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id);
alter table public.ledger_entries add constraint ledger_entries_payout_id_fkey foreign key (payout_id) references payouts(id);

alter table public.payouts add constraint payouts_approved_by_fkey foreign key (approved_by) references users(id);

alter table public.payout_lines add constraint payout_lines_payout_id_fkey foreign key (payout_id) references payouts(id) on delete cascade;
alter table public.payout_lines add constraint payout_lines_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id);
alter table public.payout_lines add constraint payout_lines_assignment_id_fkey foreign key (assignment_id) references delivery_assignments(id);

alter table public.commission_rules add constraint commission_rules_created_by_fkey foreign key (created_by) references auth.users(id);

-- NOTE: `wallets.owner_id` and `payouts.account_id` have NO foreign key. They are
-- polymorphic across vendor and rider, so referential integrity is asserted by
-- private.assert_wallet_owner() / assert_payout_account() inside the RPCs.

-- --- engagement and ops ---------------------------------------------------
alter table public.reviews add constraint reviews_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.reviews add constraint reviews_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;
alter table public.reviews add constraint reviews_user_id_fkey foreign key (user_id) references users(id);
alter table public.reviews add constraint reviews_vendor_id_fkey foreign key (vendor_id) references vendors(id);
alter table public.reviews add constraint reviews_rider_id_fkey foreign key (rider_id) references riders(id);

alter table public.vouchers add constraint vouchers_created_by_fkey foreign key (created_by) references users(id);

alter table public.voucher_redemptions add constraint voucher_redemptions_voucher_id_fkey foreign key (voucher_id) references vouchers(id) on delete cascade;
alter table public.voucher_redemptions add constraint voucher_redemptions_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.voucher_redemptions add constraint voucher_redemptions_order_id_fkey foreign key (order_id) references orders(id) on delete set null;
alter table public.voucher_redemptions add constraint voucher_redemptions_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete set null;

alter table public.promo_slots add constraint promo_slots_city_id_fkey foreign key (city_id) references cities(id);

alter table public.event_daily_stats add constraint event_daily_stats_city_id_fkey foreign key (city_id) references cities(id);
alter table public.search_daily_stats add constraint search_daily_stats_city_id_fkey foreign key (city_id) references cities(id);

alter table public.vendor_earnings_daily add constraint vendor_earnings_daily_vendor_id_fkey foreign key (vendor_id) references vendors(id) on delete cascade;
alter table public.rider_earnings_daily add constraint rider_earnings_daily_rider_id_fkey foreign key (rider_id) references riders(id) on delete cascade;

-- --- partitioned children -------------------------------------------------
alter table public.notifications add constraint notifications_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.notifications add constraint notifications_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.notifications add constraint notifications_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;

alter table public.notifications_2026_10 add constraint notifications_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.notifications_2026_10 add constraint notifications_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.notifications_2026_10 add constraint notifications_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;

alter table public.notifications_2026_11 add constraint notifications_user_id_fkey foreign key (user_id) references users(id) on delete cascade;
alter table public.notifications_2026_11 add constraint notifications_order_id_fkey foreign key (order_id) references orders(id) on delete cascade;
alter table public.notifications_2026_11 add constraint notifications_sub_order_id_fkey foreign key (sub_order_id) references sub_orders(id) on delete cascade;

alter table public.audit_log add constraint audit_log_actor_user_id_fkey foreign key (actor_user_id) references users(id) on delete set null;
alter table public.audit_log_2026_10 add constraint audit_log_actor_user_id_fkey foreign key (actor_user_id) references users(id) on delete set null;
alter table public.audit_log_2026_11 add constraint audit_log_actor_user_id_fkey foreign key (actor_user_id) references users(id) on delete set null;