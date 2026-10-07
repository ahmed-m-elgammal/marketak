-- =============================================================================
-- 10_indexes_geo_identity_vendors.sql
-- Extracted verbatim from pg_indexes. `*_pkey` and `*_key` entries back the
-- PRIMARY KEY / UNIQUE constraints already declared in the table files and are
-- listed for completeness; recreating them there is harmless (they are
-- IF NOT EXISTS-equivalent by name).
--
-- Read this file for the three index patterns the design leans on:
--   1. Partial indexes carrying the live-row predicate (deleted_at IS NULL,
--      is_active). Soft-deleted rows stay in the table but stay out of the
--      hot index.
--   2. GIN + gin_trgm_ops over a normalized column, for bilingual search.
--   3. UNIQUE partial indexes that encode a business invariant in the index
--      itself (one default address, one default size, one active cart).
-- =============================================================================

-- --- cities ---------------------------------------------------------------
CREATE UNIQUE INDEX cities_pkey ON public.cities USING btree (id);
CREATE UNIQUE INDEX cities_code_key ON public.cities USING btree (code);
-- At most one primary city can ever exist.
CREATE UNIQUE INDEX cities_one_primary ON public.cities USING btree (is_primary) WHERE is_primary;

-- --- areas ----------------------------------------------------------------
CREATE UNIQUE INDEX areas_pkey ON public.areas USING btree (id);
CREATE UNIQUE INDEX areas_city_id_slug_key ON public.areas USING btree (city_id, slug);
CREATE INDEX areas_city_id_idx ON public.areas USING btree (city_id) WHERE is_active;
CREATE INDEX areas_geohash_prefix_idx ON public.areas USING btree (geohash_prefix);

-- --- delivery_zones / fee tiers -------------------------------------------
CREATE UNIQUE INDEX delivery_zones_pkey ON public.delivery_zones USING btree (id);
CREATE INDEX delivery_zones_city_id_idx ON public.delivery_zones USING btree (city_id);
CREATE INDEX delivery_zones_area_id_idx ON public.delivery_zones USING btree (area_id) WHERE is_active;
CREATE UNIQUE INDEX delivery_fee_tiers_pkey ON public.delivery_fee_tiers USING btree (zone_id, vendor_count);

-- --- settings / feature flags --------------------------------------------
CREATE UNIQUE INDEX settings_pkey ON public.settings USING btree (key);
CREATE INDEX settings_updated_by_idx ON public.settings USING btree (updated_by) WHERE (updated_by IS NOT NULL);
CREATE UNIQUE INDEX feature_flags_pkey ON public.feature_flags USING btree (id);
CREATE UNIQUE INDEX feature_flags_flag_key_key ON public.feature_flags USING btree (flag_key);
CREATE INDEX feature_flags_updated_by_idx ON public.feature_flags USING btree (updated_by) WHERE (updated_by IS NOT NULL);

-- --- users ----------------------------------------------------------------
CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id);
CREATE UNIQUE INDEX users_phone_number_key ON public.users USING btree (phone_number);
CREATE INDEX users_last_seen_at_idx ON public.users USING btree (last_seen_at DESC) WHERE (is_active AND (profile_completed_at IS NOT NULL));

-- --- user_roles / auth providers -----------------------------------------
CREATE UNIQUE INDEX user_roles_pkey ON public.user_roles USING btree (user_id, role);
CREATE INDEX user_roles_role_idx ON public.user_roles USING btree (role);
CREATE INDEX user_roles_active ON public.user_roles USING btree (user_id) WHERE (revoked_at IS NULL);
CREATE INDEX user_roles_granted_by_idx ON public.user_roles USING btree (granted_by) WHERE (granted_by IS NOT NULL);

CREATE UNIQUE INDEX user_auth_providers_pkey ON public.user_auth_providers USING btree (id);
CREATE UNIQUE INDEX user_auth_providers_provider_type_provider_id_key ON public.user_auth_providers USING btree (provider_type, provider_id);
CREATE INDEX user_auth_providers_user_id_idx ON public.user_auth_providers USING btree (user_id);
-- Only live links are matched, so a soft-deleted provider can be relinked.
CREATE UNIQUE INDEX user_auth_providers_provider_active ON public.user_auth_providers USING btree (provider_type, provider_id) WHERE (deleted_at IS NULL);

-- --- addresses ------------------------------------------------------------
CREATE UNIQUE INDEX addresses_pkey ON public.addresses USING btree (id);
CREATE INDEX addresses_area_id_idx ON public.addresses USING btree (area_id);
CREATE INDEX addresses_geohash_prefix_idx ON public.addresses USING btree (geohash_prefix);
CREATE INDEX addresses_user_id_last_used_at_idx ON public.addresses USING btree (user_id, last_used_at DESC) WHERE (deleted_at IS NULL;
-- A user can have at most ONE default address. Enforced in the index, not in
-- application code, so a concurrent insert cannot produce two defaults.
CREATE UNIQUE INDEX addresses_one_default ON public.addresses USING btree (user_id) WHERE (is_default AND (deleted_at IS NULL));

-- --- device_tokens --------------------------------------------------------
CREATE UNIQUE INDEX device_tokens_pkey ON public.device_tokens USING btree (id);
CREATE UNIQUE INDEX device_tokens_token_key ON public.device_tokens USING btree (token);
CREATE INDEX device_tokens_user_id_app_role_idx ON public.device_tokens USING btree (user_id, app_role);

-- --- brands ---------------------------------------------------------------
CREATE UNIQUE INDEX brands_pkey ON public.brands USING btree (id);

-- --- cuisines -------------------------------------------------------------
CREATE UNIQUE INDEX cuisines_pkey ON public.cuisines USING btree (id);
CREATE UNIQUE INDEX cuisines_code_key ON public.cuisines USING btree (code);
CREATE INDEX cuisines_name_trgm ON public.cuisines USING gin (name_normalized gin_trgm_ops);
CREATE INDEX cuisines_name_ar_trgm ON public.cuisines USING gin (name_ar_normalized gin_trgm_ops);

-- --- vendors --------------------------------------------------------------
CREATE UNIQUE INDEX vendors_pkey ON public.vendors USING btree (id);
-- A slug is reusable once the vendor is soft-deleted.
CREATE UNIQUE INDEX vendors_slug_live ON public.vendors USING btree (slug) WHERE (deleted_at IS NULL;
CREATE INDEX vendors_city_id_idx ON public.vendors USING btree (city_id) WHERE is_active;
CREATE INDEX vendors_area_id_vertical_type_idx ON public.vendors USING btree (area_id, vertical_type) WHERE (is_active AND is_approved);
CREATE INDEX vendors_geohash_prefix_idx ON public.vendors USING btree (geohash_prefix) WHERE is_active;
CREATE INDEX vendors_brand_id_idx ON public.vendors USING btree (brand_id) WHERE (brand_id IS NOT NULL);
CREATE INDEX vendors_rating_avg_idx ON public.vendors USING btree (rating_avg DESC) WHERE (is_active AND is_approved;
CREATE INDEX vendors_city_id_is_open_deleted_at_idx ON public.vendors USING btree (city_id, is_open, deleted_at);
-- Bilingual trigram search, restricted to storefronts a customer may see.
CREATE INDEX vendors_name_trgm ON public.vendors USING gin (name_normalized gin_trgm_ops) WHERE (is_active AND is_approved AND (deleted_at IS NULL));
CREATE INDEX vendors_name_ar_trgm ON public.vendors USING gin (name_ar_normalized gin_trgm_ops) WHERE (is_active AND is_approved AND (deleted_at IS NULL));
CREATE INDEX vendors_description_trgm ON public.vendors USING gin (description_normalized gin_trgm_ops) WHERE (is_active AND is_approved AND (deleted_at IS NULL));

-- --- vendor edges ---------------------------------------------------------
CREATE UNIQUE INDEX vendor_cuisines_pkey ON public.vendor_cuisines USING btree (vendor_id, cuisine_id);
CREATE INDEX vendor_cuisines_cuisine_id_idx ON public.vendor_cuisines USING btree (cuisine_id);

CREATE UNIQUE INDEX vendor_areas_pkey ON public.vendor_areas USING btree (vendor_id, area_id);
CREATE INDEX vendor_areas_area_id_idx ON public.vendor_areas USING btree (area_id) WHERE is_active;
CREATE INDEX vendor_areas_live ON public.vendor_areas USING btree (vendor_id) WHERE (deleted_at IS NULL);

CREATE UNIQUE INDEX vendor_staff_pkey ON public.vendor_staff USING btree (id);
CREATE UNIQUE INDEX vendor_staff_user_id_vendor_id_key ON public.vendor_staff USING btree (user_id, vendor_id);
CREATE INDEX vendor_staff_vendor_id_idx ON public.vendor_staff USING btree (vendor_id);
CREATE INDEX vendor_staff_not_deleted ON public.vendor_staff USING btree (vendor_id) WHERE (deleted_at IS NULL;

CREATE UNIQUE INDEX vendor_schedules_pkey ON public.vendor_schedules USING btree (id);
CREATE UNIQUE INDEX vendor_schedules_vendor_id_day_of_week_slot_key ON public.vendor_schedules USING btree (vendor_id, day_of_week, slot);
CREATE INDEX vendor_schedules_vendor_id_day_of_week_idx ON public.vendor_schedules USING btree (vendor_id, day_of_week);

CREATE UNIQUE INDEX vendor_holidays_pkey ON public.vendor_holidays USING btree (id);
CREATE UNIQUE INDEX vendor_holidays_vendor_id_holiday_date_key ON public.vendor_holidays USING btree (vendor_id, holiday_date);
CREATE INDEX vendor_holidays_holiday_date_idx ON public.vendor_holidays USING btree (holiday_date);

-- --- menu -----------------------------------------------------------------
CREATE UNIQUE INDEX menu_categories_pkey ON public.menu_categories USING btree (id);
CREATE INDEX menu_categories_vendor_id_idx ON public.menu_categories USING btree (vendor_id) WHERE (is_available AND (deleted_at IS NULL));
CREATE INDEX menu_categories_vendor_id_display_order_idx ON public.menu_categories USING btree (vendor_id, display_order) WHERE (deleted_at IS NULL;
CREATE INDEX menu_categories_name_trgm ON public.menu_categories USING gin (name_normalized gin_trgm_ops) WHERE (is_available AND (deleted_at IS NULL));
CREATE INDEX menu_categories_name_ar_trgm ON public.menu_categories USING gin (name_ar_normalized gin_trgm_ops) WHERE (is_available AND (deleted_at IS NULL));

CREATE UNIQUE INDEX menu_items_pkey ON public.menu_items USING btree (id);
CREATE INDEX menu_items_category_id_display_order_idx ON public.menu_items USING btree (category_id, display_order) WHERE (deleted_at IS NULL;
CREATE INDEX menu_items_vendor_id_is_available_display_order_idx ON public.menu_items USING btree (vendor_id, is_available, display_order) WHERE (deleted_at IS NULL;
CREATE INDEX menu_items_tags_idx ON public.menu_items USING gin (tags) WHERE (deleted_at IS NULL;
CREATE INDEX menu_items_name_trgm ON public.menu_items USING gin (name_normalized gin_trgm_ops) WHERE (is_available AND (deleted_at IS NULL));
CREATE INDEX menu_items_name_ar_trgm ON public.menu_items USING gin (name_ar_normalized gin_trgm_ops) WHERE (is_available AND (deleted_at IS NULL));
CREATE INDEX menu_items_ingredients_trgm ON public.menu_items USING gin (ingredients_normalized gin_trgm_ops) WHERE (is_available AND (deleted_at IS NULL);

CREATE UNIQUE INDEX menu_item_sizes_pkey ON public.menu_item_sizes USING btree (id);
CREATE INDEX menu_item_sizes_item ON public.menu_item_sizes USING btree (item_id);
CREATE INDEX menu_item_sizes_item_id_display_order_idx ON public.menu_item_sizes USING btree (item_id, display_order);
-- Exactly one default size per sized item.
CREATE UNIQUE INDEX menu_item_sizes_one_default ON public.menu_item_sizes USING btree (item_id) WHERE is_default;

CREATE UNIQUE INDEX item_options_pkey ON public.item_options USING btree (id);
CREATE INDEX item_options_item_id_display_order_idx ON public.item_options USING btree (item_id, display_order);

CREATE UNIQUE INDEX option_choices_pkey ON public.option_choices USING btree (id);
CREATE INDEX option_choices_option ON public.option_choices USING btree (option_id);
CREATE INDEX option_choices_option_id_display_order_idx ON public.option_choices USING btree (option_id, display_order);

-- --- cart -----------------------------------------------------------------
CREATE UNIQUE INDEX carts_pkey ON public.carts USING btree (id);
-- One live cart per user. Historical carts are retained with is_active = false.
CREATE UNIQUE INDEX carts_one_active ON public.carts USING btree (user_id) WHERE (is_active;
CREATE INDEX carts_user_created ON public.carts USING btree (user_id, created_at DESC);

CREATE UNIQUE INDEX cart_items_pkey ON public.cart_items USING btree (id);
CREATE INDEX cart_items_cart_id ON public.cart_items USING btree (cart_id);
CREATE INDEX cart_items_menu_item_id ON public.cart_items USING btree (menu_item_id);
CREATE INDEX cart_items_vendor_id ON public.cart_items USING btree (vendor_id);
CREATE INDEX cart_items_cart_vendor ON public.cart_items USING btree (cart_id, vendor_id);
-- The same item with the same options is one line; quantity is bumped instead.
CREATE UNIQUE INDEX cart_items_line_identity ON public.cart_items USING btree (cart_id, menu_item_id, md5((selected_options)::text));

CREATE UNIQUE INDEX favorites_pkey ON public.favorites USING btree (user_id, vendor_id);
CREATE INDEX favorites_vendor_id ON public.favorites USING btree (vendor_id);
CREATE UNIQUE INDEX favorite_items_pkey ON public.favorite_items USING btree (user_id, menu_item_id);
CREATE INDEX favorite_items_menu_item_id ON public.favorite_items USING btree (menu_item_id);