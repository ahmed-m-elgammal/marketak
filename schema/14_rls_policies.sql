-- =============================================================================
-- 14_rls_policies.sql
-- 115 policies across 62 tables and partitions.
--
-- THE SHAPE OF THIS SCHEMA'S SECURITY MODEL
--
-- Every policy below is FOR SELECT. There is not one INSERT, UPDATE or DELETE
-- policy in the entire application schema. That is the whole design:
--
--   - READS go through PostgREST directly, filtered by RLS.
--   - WRITES go exclusively through `security definer` RPCs, which run as the
--     function owner, re-check authorisation themselves, and write the audit /
--     event row in the same transaction.
--
-- The consequence: no client can ever issue a direct write, so no client can
-- invent a price, set a wallet balance, or move money. PostgREST exposes the
-- tables for SELECT and the functions for everything else.
--
-- Note also that `to authenticated` appears everywhere. Even "public catalogue"
-- reads require a signed-in user — a user with no `profile_completed_at` can
-- browse but is still authenticated.
--
-- Two private helper families resolve identity inside policies:
--   private.is_admin()                       — role check, no table scan
--   private.vendor_ids_for(uid)              — vendors where the user is staff
--   private.rider_ids_for(uid)               — riders linked to the user
--   private.account_ids_for(uid)             — vendor/rider ids for wallet/ledger
--   private.visible_order_ids(uid)           — owned OR assigned orders
--   private.owned_or_assigned_order_ids(uid) — order or sub_order visibility
--   private.rider_order_ids(uid)             — orders delivered by this rider
--
-- These are STABLE SECURITY DEFINER functions with a pinned search_path, so
-- reading a policy does not recurse into the table being protected.
-- =============================================================================

-- =============================================================================
-- Public catalogue: readable by any signed-in user, filtered to what is
-- actually purchasable. Admins see everything via the paired _admin_read.
-- =============================================================================
create policy cities_read on cities for select to authenticated using ((is_active OR ( SELECT private.is_admin() AS is_admin)));
create policy cities_admin_read on cities for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy areas_read on areas for select to authenticated using ((is_active OR ( SELECT private.is_admin() AS is_admin)));
create policy areas_admin_read on areas for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy delivery_zones_read on delivery_zones for select to authenticated using ((is_active OR ( SELECT private.is_admin() AS is_admin)));
create policy delivery_zones_admin_read on delivery_zones for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Fee tiers are public: a client may see what the multiplier will be.
create policy delivery_fee_tiers_read on delivery_fee_tiers for select to authenticated using (true);
create policy delivery_fee_tiers_admin_read on delivery_fee_tiers for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy settings_read on settings for select to authenticated using (true);
create policy settings_admin_read on settings for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy feature_flags_read on feature_flags for select to authenticated using ((is_active OR ( SELECT private.is_admin() AS is_admin)));
create policy feature_flags_admin_read on feature_flags for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy cuisines_read on cuisines for select to authenticated using (true);
create policy cuisines_admin_read on cuisines for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy brands_read on brands for select to authenticated using (is_active);
create policy brands_admin_read on brands for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy vendor_cuisines_read on vendor_cuisines for select to authenticated using (true);
create policy vendor_cuisines_admin_read on vendor_cuisines for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy vendor_areas_read on vendor_areas for select to authenticated using (true);
create policy vendor_areas_admin_read on vendor_areas for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy vendor_schedules_read on vendor_schedules for select to authenticated using (true);
create policy vendor_schedules_admin_read on vendor_schedules for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy vendor_holidays_read on vendor_holidays for select to authenticated using (true);
create policy vendor_holidays_admin_read on vendor_holidays for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- A vendor is visible only when active AND approved AND not soft-deleted.
create policy vendors_read on vendors for select to authenticated using (((is_active AND is_approved AND (deleted_at IS NULL)) OR ( SELECT private.is_admin() AS is_admin)));
create policy vendors_admin_read on vendors for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Vendor staff roster is NOT public — only that vendor's own staff and admins.
create policy vendor_staff_read on vendor_staff for select to authenticated using (((vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy vendor_staff_admin_read on vendor_staff for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Catalog: a category/item is visible if it is purchasable AND its vendor is
-- live, OR the reader manages that vendor, OR the reader is an admin.
-- The EXISTS on vendors is what stops a soft-deleted vendor's menu from being
-- browsable through its own rows.
create policy menu_categories_read on menu_categories for select to authenticated using (((is_available AND (deleted_at IS NULL) AND (EXISTS ( SELECT 1
   FROM vendors v
  WHERE ((v.id = menu_categories.vendor_id) AND v.is_active AND v.is_approved AND (v.deleted_at IS NULL))))) OR (vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy menu_categories_admin_read on menu_categories for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy menu_items_read on menu_items for select to authenticated using (((is_available AND (deleted_at IS NULL) AND (EXISTS ( SELECT 1
   FROM vendors v
  WHERE ((v.id = menu_items.vendor_id) AND v.is_active AND v.is_approved AND (v.deleted_at IS NULL))))) OR (vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy menu_items_admin_read on menu_items for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Sizes and options: available rows are public, plus full visibility for the
-- managing vendor (they need to see unavailable rows to edit them).
create policy menu_item_sizes_read on menu_item_sizes for select to authenticated using ((is_available OR (EXISTS ( SELECT 1
   FROM menu_items mi
  WHERE ((mi.id = menu_item_sizes.item_id) AND (mi.vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for))))) OR ( SELECT private.is_admin() AS is_admin)));
create policy menu_item_sizes_admin_read on menu_item_sizes for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy item_options_read on item_options for select to authenticated using (((is_available AND (deleted_at IS NULL)) OR (EXISTS ( SELECT 1
   FROM menu_items mi
  WHERE ((mi.id = item_options.item_id) AND (mi.vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for))))) OR ( SELECT private.is_admin() AS is_admin)));
create policy item_options_admin_read on item_options for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy option_choices_read on option_choices for select to authenticated using ((is_available OR (EXISTS ( SELECT 1
   FROM (item_options io
     JOIN menu_items mi ON ((mi.id = io.item_id)))
  WHERE ((io.id = option_choices.option_id) AND (mi.vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for))))) OR ( SELECT private.is_admin() AS is_admin)));
create policy option_choices_admin_read on option_choices for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- =============================================================================
-- Identity: strictly self-or-admin.
-- =============================================================================

-- A customer may read their own row. So may a RIDER, but only for the
-- customers whose orders they are delivering — private.rider_order_ids()
-- resolves that, so a rider learns a name and phone only when they must
-- actually call the customer.
create policy users_read on users for select to authenticated using (((id = ( SELECT auth.uid() AS uid)) OR (id IN ( SELECT o.user_id
   FROM orders o
  WHERE ((o.user_id IS NOT NULL) AND (o.id IN ( SELECT private.rider_order_ids(( SELECT auth.uid() AS uid)) AS rider_order_ids)))))) OR ( SELECT private.is_admin() AS is_admin));
create policy users_admin_read on users for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy user_roles_read on user_roles for select to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_admin() AS is_admin)));
create policy user_roles_admin_read on user_roles for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy user_auth_providers_read on user_auth_providers for select to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_admin() AS is_admin)));
create policy user_auth_providers_admin_read on user_auth_providers for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy addresses_read on addresses for select to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_admin() AS is_admin)));
create policy addresses_admin_read on addresses for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Push tokens are the most sensitive thing a device holds: self-only.
create policy device_tokens_read on device_tokens for select to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy device_tokens_admin_read on device_tokens for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- =============================================================================
-- Cart and favourites: self-only.
-- =============================================================================
create policy carts_read on carts for select to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_admin() AS is_admin)));
create policy carts_admin_read on carts for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Cart lines are reached through their cart, not through user_id.
create policy cart_items_read on cart_items for select to authenticated using (((cart_id IN ( SELECT c.id
   FROM carts c
  WHERE (c.user_id = ( SELECT auth.uid() AS uid)))) OR ( SELECT private.is_admin() AS is_admin)));
create policy cart_items_admin_read on cart_items for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy favorites_read on favorites for select to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_admin() AS is_admin)));
create policy favorites_admin_read on favorites for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy favorite_items_read on favorite_items for select to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_admin() AS is_admin)));
create policy favorite_items_admin_read on favorite_items for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- =============================================================================
-- Orders: three-way visibility, resolved by private.visible_order_ids().
-- An order is visible to its customer, to the rider assigned to it, and to
-- admins. A vendor never sees the ORDER — only its own sub_orders.
-- =============================================================================
create policy orders_read on orders for select to authenticated using (((id IN ( SELECT private.visible_order_ids(( SELECT auth.uid() AS uid)) AS visible_order_ids)) OR ( SELECT private.is_admin() AS is_admin)));
create policy orders_admin_read on orders for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- A vendor sees its own sub_orders; a customer sees all sub_orders of their
-- own order; a rider sees sub_orders of orders they are assigned.
create policy sub_orders_read on sub_orders for select to authenticated using (((vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for)) OR (order_id IN ( SELECT private.owned_or_assigned_order_ids(( SELECT auth.uid() AS uid)) AS owned_or_assigned_order_ids)) OR ( SELECT private.is_admin() AS is_admin)));
create policy sub_orders_admin_read on sub_orders for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Order lines inherit either from the vendor or from the order.
create policy order_items_read on order_items for select to authenticated using (((vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for)) OR (order_id IN ( SELECT private.owned_or_assigned_order_ids(( SELECT auth.uid() AS uid)) AS owned_or_assigned_order_ids)) OR ( SELECT private.is_admin() AS is_admin)));
create policy order_items_admin_read on order_items for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- History, modifications and ETA snapshots are all keyed on the order.
create policy order_status_history_read on order_status_history for select to authenticated using (((order_id IN ( SELECT private.visible_order_ids(( SELECT auth.uid() AS uid)) AS visible_order_ids)) OR ( SELECT private.is_admin() AS is_admin)));
create policy order_status_history_admin_read on order_status_history for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy order_modifications_read on order_modifications for select to authenticated using (((order_id IN ( SELECT private.visible_order_ids(( SELECT auth.uid() AS uid)) AS visible_order_ids)) OR ( SELECT private.is_admin() AS is_admin)));
create policy order_modifications_admin_read on order_modifications for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy order_eta_snapshots_read on order_eta_snapshots for select to authenticated using (((order_id IN ( SELECT private.visible_order_ids(( SELECT auth.uid() AS uid)) AS visible_order_ids)) OR ( SELECT private.is_admin() AS is_admin)));
create policy order_eta_snapshots_admin_read on order_eta_snapshots for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- =============================================================================
-- Delivery. Note `riders` itself has NO select policy — a raw table read of
-- riders returns nothing. Riders are visible through the `riders_public` VIEW,
-- which is granted separately and drops the sensitive columns. This is the
-- mechanism that keeps cash_held out of a customer's reach while still letting
-- them see the name and phone of the person bringing their food.
-- =============================================================================

-- `riders` and `riders_public`: only admins may read the base table.
create policy riders_admin_read on riders for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy driver_shifts_read on driver_shifts for select to authenticated using (((rider_id IN ( SELECT private.rider_ids_for(( SELECT auth.uid() AS uid)) AS rider_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy driver_shifts_admin_read on driver_shifts for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Location pings are readable only by the parties to the trip. This is the
-- table that would leak a rider's movement if it were admin-only-or-nothing,
-- because the customer's own map needs it.
create policy rider_location_pings_read on rider_location_pings for select to authenticated using (((order_id IN ( SELECT private.visible_order_ids(( SELECT auth.uid() AS uid)) AS visible_order_ids)) OR ( SELECT private.is_admin() AS is_admin)));
create policy rider_location_pings_admin_read on rider_location_pings for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy delivery_assignments_read on delivery_assignments for select to authenticated using (((order_id IN ( SELECT private.visible_order_ids(( SELECT auth.uid() AS uid)) AS visible_order_ids)) OR ( SELECT private.is_admin() AS is_admin)));
create policy delivery_assignments_admin_read on delivery_assignments for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy rider_earnings_daily_read on rider_earnings_daily for select to authenticated using (((rider_id IN ( SELECT private.rider_ids_for(( SELECT auth.uid() AS uid)) AS rider_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy rider_earnings_daily_admin_read on rider_earnings_daily for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Pay rules: the city-wide default is public (a rider must be able to see it);
-- a rider-specific rule is visible only to that rider.
create policy rider_pay_rules_read on rider_pay_rules for select to authenticated using (((rider_id IS NULL) OR (rider_id IN ( SELECT private.rider_ids_for(( SELECT auth.uid() AS uid)) AS rider_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy rider_pay_rules_admin_read on rider_pay_rules for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- =============================================================================
-- Money. A vendor or rider sees ONLY their own money. platform_float is
-- admin-only, and note its `*_read` policy is identical to its
-- `*_admin_read` — there is no non-admin path at all.
-- =============================================================================
create policy wallets_read on wallets for select to authenticated using (((owner_id IN ( SELECT private.account_ids_for(( SELECT auth.uid() AS uid)) AS account_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy wallets_admin_read on wallets for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy ledger_entries_read on ledger_entries for select to authenticated using ((((account_type = ANY (ARRAY['vendor'::text, 'rider'::text])) AND (account_id IN ( SELECT private.account_ids_for(( SELECT auth.uid() AS uid)) AS account_ids_for))) OR ( SELECT private.is_admin() AS is_admin)));
create policy ledger_entries_admin_read on ledger_entries for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy payouts_read on payouts for select to authenticated using (((account_id IN ( SELECT private.account_ids_for(( SELECT auth.uid() AS uid)) AS account_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy payouts_admin_read on payouts for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy payout_lines_read on payout_lines for select to authenticated using (((payout_id IN ( SELECT p.id
   FROM payouts p
  WHERE (p.account_id IN ( SELECT private.account_ids_for(( SELECT auth.uid() AS uid)) AS account_ids_for)))) OR ( SELECT private.is_admin() AS is_admin)));
create policy payout_lines_admin_read on payout_lines for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy platform_float_read on platform_float for select to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy platform_float_admin_read on platform_float for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- A commission rule is readable when it is active AND inside its effective
-- window. Inactive drafts are admin-only.
create policy commission_rules_read on commission_rules for select to authenticated using ((is_active AND (effective_from <= now()) AND ((effective_until IS NULL) OR (effective_until > now()))));
create policy commission_rules_admin_read on commission_rules for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy vendor_earnings_daily_read on vendor_earnings_daily for select to authenticated using (((vendor_id IN ( SELECT private.vendor_ids_for(( SELECT auth.uid() AS uid)) AS vendor_ids_for)) OR ( SELECT private.is_admin() AS is_admin)));
create policy vendor_earnings_daily_admin_read on vendor_earnings_daily for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- =============================================================================
-- Engagement and ops.
-- =============================================================================

-- Hidden reviews stay visible to admins for moderation.
create policy reviews_read on reviews for select to authenticated using (((NOT is_hidden) OR ( SELECT private.is_admin() AS is_admin)));
create policy reviews_admin_read on reviews for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- An active voucher inside its window is public, because the customer needs to
-- see the terms before they have an order to attach it to.
create policy vouchers_read on vouchers for select to authenticated using (((is_active AND (valid_from <= now()) AND ((valid_until IS NULL) OR (valid_until > now()))) OR ( SELECT private.is_admin() AS is_admin)));
create policy vouchers_admin_read on vouchers for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Redemptions are private to the redeeming customer: they reveal order volume.
create policy voucher_redemptions_read on voucher_redemptions for select to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_admin() AS is_admin)));
create policy voucher_redemptions_admin_read on voucher_redemptions for select to authenticated using (( SELECT private.is_admin() AS is_admin));

create policy promo_slots_read on promo_slots for select to authenticated using ((is_active OR ( SELECT private.is_admin() AS is_admin)));
create policy promo_slots_admin_read on promo_slots for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Notification copy is admin-only: it is not customer-facing data.
create policy notification_templates_admin_read on notification_templates for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Notifications: own rows only, on the parent and on every partition.
-- Partitions carry their own policies because RLS is per-relation, not
-- inherited — a policy on `notifications` does not cover its children.
create policy notifications_user_read on notifications for select to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy notifications_admin_read on notifications for select to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy notifications_2026_10_user_read on notifications_2026_10 for select to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy notifications_2026_10_admin_read on notifications_2026_10 for select to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy notifications_2026_11_user_read on notifications_2026_11 for select to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy notifications_2026_11_admin_read on notifications_2026_11 for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- The outbox is admin-read only. Workers reach it with the service_role key
-- through claim_events_v1(), which is SKIP LOCKED, not through a client read.
create policy events_admin_read on events for select to authenticated using (( SELECT private.is_admin() AS is_admin));

-- Rollups and the audit log are operational data: admin only, no exceptions.
create policy event_daily_stats_admin_read on event_daily_stats for select to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy auth_daily_stats_admin_read on auth_daily_stats for select to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy search_daily_stats_admin_read on search_daily_stats for select to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy audit_log_admin_read on audit_log for select to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy audit_log_2026_10_admin_read on audit_log_2026_10 for select to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy audit_log_2026_11_admin_read on audit_log_2026_11 for select to authenticated using (( SELECT private.is_admin() AS is_admin));