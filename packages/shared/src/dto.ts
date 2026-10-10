/**
 * Response DTOs.
 *
 * Shapes the **server** owns and the app reads. Every field is transcribed from
 * `pg_get_function_result` and `information_schema.columns` against the live
 * project - not from a spec - so a drift between this file and the database is a
 * real failure rather than a documentation lag.
 *
 * Everything here is `readonly`, and that is not decoration: architecture rule 5
 * says the server is the source of truth for carts, orders and addresses, and the
 * app must never mutate what it read. `readonly` is what makes the compiler
 * enforce it.
 *
 * What the app SENDS lives in `commands.ts`. One shape per RPC, one place, and
 * the two directions are never mixed in one type.
 *
 * Full signature and error-code detail: `specs-mobile/README.md` §15-16.
 */

import type { Language, Piastres } from "./money.js";
import type {
  AppRole,
  AssignedBy,
  AssignmentStatus,
  CancellationActor,
  CollectionMethod,
  DeliveryGrouping,
  DeliveryType,
  OrderStatus,
  PaymentChannel,
  PaymentMethod,
  PaymentStatus,
  Platform,
  PricingMode,
  QuoteRejectionCode,
  SettlementStatus,
  SubOrderStatus,
  VerticalType,
  VendorAvailability,
  VoucherDiscountType,
} from "./status.js";

export type Uuid = string;

/** `[{ choice_id }]`, exactly as the quote engine reads it. */
export interface SelectedOption {
  readonly choice_id: Uuid;
}

/* ── profile ──────────────────────────────────────────────────────────────── */

/**
 * Return of `get_profile_status_v1`, `complete_profile_v1` and `update_profile_v1`.
 *
 * `can_order` is the constitution's gate: a user without `profile_completed_at`
 * may browse but may not order. `missing` names what is still required, so
 * onboarding renders a checklist instead of guessing.
 *
 * Note: no profile RPC can set an address. Only `upsert_my_address_v1` creates
 * one, so a checklist that reports a missing address must call the address RPC.
 */
export interface ProfileStatus {
  readonly profile_completed_at: string | null;
  readonly has_phone: boolean;
  readonly has_address: boolean;
  readonly can_browse: boolean;
  readonly can_order: boolean;
  readonly missing: readonly string[];
}

/* ── addresses ────────────────────────────────────────────────────────────── */

/**
 * `addresses` as the app reads it. `geohash` and `geohash_prefix` are derived by
 * the server from the pin and are never sent by the client.
 */
export interface Address {
  readonly id: Uuid;
  readonly user_id: Uuid;
  readonly label: "home" | "work" | "other";
  readonly area_id: Uuid | null;
  readonly geohash: string;
  readonly geohash_prefix: string;
  readonly latitude: number;
  readonly longitude: number;
  readonly area_name: string | null;
  readonly building: string | null;
  readonly floor: string | null;
  readonly apartment: string | null;
  readonly landmark: string | null;
  readonly delivery_instructions: string | null;
  readonly is_default: boolean;
  readonly last_used_at: string | null;
  readonly created_at: string;
  readonly updated_at: string;
  readonly deleted_at: string | null;
}

/* ── cart ─────────────────────────────────────────────────────────────────── */

/** Return of `upsert_cart_item_v1`. `is_new` distinguishes an insert from a merge. */
export interface UpsertCartItemResult {
  readonly cart_item_id: Uuid;
  readonly cart_id: Uuid;
  readonly quantity: number;
  readonly unit_price: Piastres;
  readonly is_new: boolean;
}

/** Return of `remove_cart_item_v1`. */
export interface RemoveCartItemResult {
  readonly cart_id: Uuid;
  readonly remaining: number;
}

/**
 * `cart_items` as the app reads it. `vendor_id` is synced from the menu item by a
 * trigger; `display_snapshot` is the render payload, because the menu can change
 * under an open cart.
 */
export interface CartItem {
  readonly id: Uuid;
  readonly cart_id: Uuid;
  readonly vendor_id: Uuid;
  readonly menu_item_id: Uuid;
  readonly quantity: number;
  readonly selected_options: readonly SelectedOption[];
  readonly special_instructions: string | null;
  readonly display_snapshot: unknown;
  readonly cached_price: Piastres | null;
  readonly cached_at: string | null;
  readonly created_at: string;
  readonly updated_at: string;
  readonly selected_size_id: Uuid | null;
  readonly selected_size_name: string | null;
  readonly selected_size_price: Piastres | null;
}

/* ── quote ────────────────────────────────────────────────────────────────── */

/** `quote_order_v1` → `totals`. `discount_amount` equals `voucher_discount` in v1. */
export interface QuoteTotals {
  readonly subtotal: Piastres;
  readonly discount_amount: Piastres;
  readonly voucher_discount: Piastres;
  readonly voucher_code: string | null;
  readonly delivery_fee: Piastres;
  readonly service_fee: Piastres;
  readonly rider_tip: Piastres;
  readonly total: Piastres;
}

/**
 * `quote_order_v1` → `fee_breakdown`. The whole answer to "why is delivery this
 * much", and the only place a fee explanation is allowed to come from.
 */
export interface QuoteFeeBreakdown {
  readonly delivery_base_fee: Piastres;
  readonly vendor_count: number;
  readonly vendor_multiplier_bps: number;
  readonly distance_km: number;
  readonly free_radius_km: number;
  readonly per_km_fee: Piastres;
  readonly distance_charge: Piastres;
  readonly delivery_fee: Piastres;
  readonly service_fee: Piastres;
  readonly service_fee_enabled: boolean;
  readonly rider_tip: Piastres;
  readonly currency: string;
}

/** `quote_order_v1` → `per_vendor[]`. Reporting split, not a charge. */
export interface QuoteVendorSplit {
  readonly vendor_id: Uuid;
  readonly subtotal: Piastres;
  readonly delivery_fee_share: Piastres;
  readonly service_fee_share: Piastres;
  readonly discount_share: Piastres;
  readonly commission_amount: Piastres;
  readonly vendor_net_payout: Piastres;
  readonly prep_estimate_minutes: number;
  readonly ready_estimate_minutes: number;
  /** Always `true`. The real check is `rejections`, not this field. */
  readonly meets_minimum: boolean;
  /** Always `true`. Same caveat. */
  readonly in_delivery_range: boolean;
}

export interface QuoteLimits {
  readonly vendor_count: number;
  readonly max_vendors_per_order: number;
}

/** `quote_order_v1` → `rejections[]`. One entry per vendor, plus order-wide ones with a null id. */
export interface QuoteRejection {
  readonly vendor_id: Uuid | null;
  readonly code: QuoteRejectionCode;
  /** Arabic only. The server ships no English; the app supplies it from `code`. */
  readonly message_ar: string;
}

/** `quote_order_v1` return. `fingerprint` is logged, never displayed. */
export interface QuoteResult {
  readonly quote_id: Uuid;
  readonly expires_at: string;
  readonly fingerprint: string;
  readonly fee_breakdown: QuoteFeeBreakdown;
  readonly totals: QuoteTotals;
  readonly per_vendor: readonly QuoteVendorSplit[];
  readonly limits: QuoteLimits;
  readonly rejections: readonly QuoteRejection[];
  readonly warnings: readonly unknown[];
}

/** `place_order_v1` return. One checkout is one order and N sub_orders. */
export interface PlaceOrderResult {
  readonly order_id: Uuid;
  readonly order_number: string;
  readonly sub_orders: readonly Uuid[];
  readonly totals: QuoteTotals;
}

/* ── orders ───────────────────────────────────────────────────────────────── */

/** `orders` as the app reads it. `address_snapshot` is the receipt - render from it, never from `addresses`. */
export interface Order {
  readonly id: Uuid;
  readonly order_number: string;
  readonly user_id: Uuid;
  readonly status: OrderStatus;
  readonly subtotal: Piastres;
  readonly delivery_base_fee: Piastres;
  readonly delivery_multiplier_bps: number;
  readonly distance_km: number | null;
  readonly delivery_fee: Piastres;
  readonly service_fee: Piastres;
  readonly discount_amount: Piastres;
  readonly voucher_code: string | null;
  readonly voucher_discount: Piastres;
  readonly rider_tip: Piastres;
  readonly rider_pay_total: Piastres;
  readonly platform_revenue: Piastres;
  readonly total: Piastres;
  readonly currency: string;
  readonly price_fingerprint: string | null;
  readonly pricing_version: number;
  readonly payment_method: PaymentMethod | null;
  readonly payment_channel: PaymentChannel | null;
  readonly payment_status: PaymentStatus;
  readonly payment_collected_at: string | null;
  readonly payment_collected_by: Uuid | null;
  readonly payment_reference: string | null;
  readonly payment_proof_path: string | null;
  readonly delivery_type: DeliveryType;
  readonly delivery_grouping: DeliveryGrouping;
  readonly vendor_limit_applied: number | null;
  readonly address_id: Uuid | null;
  readonly address_snapshot: unknown;
  readonly delivery_latitude: number | null;
  readonly delivery_longitude: number | null;
  readonly delivery_geohash_prefix: string | null;
  readonly area_id: Uuid | null;
  readonly is_contactless: boolean;
  readonly access_note: string | null;
  readonly scheduled_delivery_time: string | null;
  readonly promised_delivery_at: string | null;
  readonly eta_minutes: number | null;
  readonly eta_maxutes: number | null;
  readonly vendor_count: number;
  readonly item_count: number;
  readonly placed_at: string;
  readonly confirmed_at: string | null;
  readonly first_picked_up_at: string | null;
  readonly completed_at: string | null;
  readonly cancelled_at: string | null;
  readonly cancellation_reason: string | null;
}

/** One status change. The customer's order timeline is built from these, not from `orders.status`. */
export interface OrderStatusHistoryEntry {
  readonly id: Uuid;
  readonly order_id: Uuid;
  readonly sub_order_id: Uuid | null;
  readonly from_status: string | null;
  readonly to_status: string;
  readonly actor_user_id: Uuid | null;
  readonly actor_role: string;
  readonly reason: string | null;
  readonly metadata: unknown;
  readonly created_at: string;
}

/** `order_items` as the app reads it. Name and image are denormalised on purpose. */
export interface OrderItem {
  readonly id: Uuid;
  readonly sub_order_id: Uuid;
  readonly order_id: Uuid;
  readonly vendor_id: Uuid;
  readonly menu_item_id: Uuid | null;
  readonly item_name: string;
  readonly item_name_ar: string | null;
  readonly image_path: string | null;
  readonly quantity: number;
  readonly unit_price: Piastres;
  readonly total_price: Piastres;
  readonly selected_options: readonly SelectedOption[];
  readonly special_instructions: string | null;
  readonly item_status: string;
  readonly created_at: string;
  readonly selected_size_id: Uuid | null;
  readonly selected_size_name: string | null;
  readonly selected_size_price: Piastres | null;
}

/** `cancel_order_v1` return. `outcome` says which happened. */
export interface CancelOrderResult {
  readonly outcome: string;
  readonly cancelled_count: number;
  readonly refund_amount: Piastres;
  readonly refund_currency: string;
}

/* ── rider ────────────────────────────────────────────────────────────────── */

/** `get_my_rider_profile_v1` return. `effective_cash_limit` is resolved server-side - do not re-derive. */
export interface RiderProfile {
  readonly rider_id: Uuid;
  readonly first_name: string;
  readonly last_name: string | null;
  readonly phone_number: string;
  readonly country_code: string;
  readonly vehicle_type: string;
  readonly vehicle_plate: string | null;
  readonly home_area_id: Uuid | null;
  readonly status: string;
  readonly is_online: boolean;
  readonly is_active: boolean;
  readonly is_verified: boolean;
  readonly rating_avg: number;
  readonly rating_count: number;
  readonly completed_deliveries: number;
  readonly cancelled_deliveries: number;
  readonly cash_held: Piastres;
  readonly effective_cash_limit: Piastres;
  readonly current_latitude: number | null;
  readonly current_longitude: number | null;
  readonly last_location_at: string | null;
  readonly created_at: string;
}

/**
 * `delivery_assignments` row, read directly with `rider_id = <own id>` in the
 * `where` — never a bare select. The policy resolves the customer ∪ vendor ∪
 * rider union, so reading without the rider predicate leaks other roles'
 * rows onto rider screens (mobile README §6, union trap).
 *
 * Operational subset for the trip: identity, progression timestamps, pay
 * figures (rendered as returned, never recomputed) and proof pointers
 * (opaque paths until the signing worker lands).
 */
export interface RiderAssignment {
  readonly id: Uuid;
  readonly order_id: Uuid;
  readonly sub_order_id: Uuid | null;
  readonly rider_id: Uuid;
  readonly status: AssignmentStatus;
  readonly stop_sequence: unknown;
  readonly assigned_by: AssignedBy;
  readonly assigned_at: string;
  readonly claimed_at: string | null;
  readonly arrived_vendor_at: string | null;
  readonly picked_up_at: string | null;
  readonly arrived_at: string | null;
  readonly delivered_at: string | null;
  readonly distance_km: number | null;
  readonly eta_minutes: number | null;
  readonly rider_pay_base: Piastres;
  readonly rider_pay_distance: Piastres;
  readonly rider_pay_bonus: Piastres;
  readonly rider_pay_total: Piastres;
  readonly platform_revenue: Piastres;
  readonly collected_amount: Piastres;
  readonly collection_method: CollectionMethod;
  readonly collection_channel: PaymentChannel | null;
  readonly collection_reference: string | null;
  readonly proof_path: string | null;
  readonly signature_path: string | null;
}

/** `get_available_orders_v1` return row. */
export interface AvailableOrder {
  readonly assignment_id: Uuid;
  readonly order_id: Uuid;
  readonly order_number: string;
  readonly vendor_count: number;
  readonly area_id: Uuid | null;
  readonly pickup_km: number;
  readonly dropoff_km: number;
  readonly est_pickup_minutes: number;
  readonly total: Piastres;
  readonly currency: string;
  readonly placed_at: string;
}

/** `claim_order_v1` return row. `has_pay_rule = false` means the city has no default pay rule. */
export interface ClaimOrderResult {
  readonly order_id: Uuid;
  readonly assignment_id: Uuid;
  readonly rider_id: Uuid;
  readonly rider_pay_base: Piastres;
  readonly rider_pay_distance: Piastres;
  readonly rider_pay_bonus: Piastres;
  readonly rider_pay_total: Piastres;
  readonly platform_revenue: Piastres;
  readonly distance_km: number;
  readonly eta_minutes: number;
  readonly has_pay_rule: boolean;
}

/** `begin_collection_v1` return row. Call it before collecting, not after being blocked. */
export interface BeginCollectionResult {
  readonly amount_due: Piastres;
  readonly can_collect_cash: boolean;
  readonly can_collect_wallet: boolean;
  readonly cash_held: Piastres;
  readonly effective_cash_limit: Piastres;
  readonly currency: string;
  readonly already_collected: boolean;
}

/** `collect_cash_v1` return row. */
export interface CollectCashResult {
  readonly order_id: Uuid;
  readonly collected_amount: Piastres;
  readonly cash_held: Piastres;
  readonly ledger_entry_id: Uuid;
  readonly reference: string | null;
  readonly currency: string;
}

/** `complete_delivery_v1` return row. The ledger, not an estimate. */
export interface CompleteDeliveryResult {
  readonly order_id: Uuid;
  readonly delivered_at: string;
  readonly rider_pay_total: Piastres;
  readonly platform_revenue: Piastres;
  readonly tips: Piastres;
  readonly rider_gross_total: Piastres;
  readonly vendor_payable: Piastres;
  readonly currency: string;
}

/* ── discovery ────────────────────────────────────────────────────────────── */

/**
 * `get_vendor_feed_v1` → `items[]`.
 *
 * `availability` is ONE string, not two booleans. `is_open` and `is_busy` are
 * three states, not two, and a UI switching on the flags separately will render
 * one of them wrongly.
 */
export interface VendorFeedItem {
  readonly id: Uuid;
  readonly slug: string;
  readonly name: string;
  readonly name_ar: string;
  readonly vertical_type: VerticalType;
  readonly logo_path: string | null;
  readonly rating_avg: number;
  readonly rating_count: number;
  readonly minimum_order_value: Piastres;
  readonly prep_time_minutes: number;
  readonly availability: VendorAvailability;
  readonly menu_version: number;
}

export interface VendorFeed {
  readonly items: readonly VendorFeedItem[];
  readonly next_offset: number | null;
  readonly has_more: boolean;
}

/** `search_catalog_v1` return row. `kind` discriminates a vendor hit from an item hit. */
export interface CatalogSearchHit {
  readonly kind: "vendor" | "item";
  readonly vendor_id: Uuid;
  readonly vendor_name: string;
  readonly vendor_name_ar: string;
  readonly item_id: Uuid | null;
  readonly item_category_id: Uuid | null;
  readonly item_name: string | null;
  readonly item_name_ar: string | null;
  readonly item_image_path: string | null;
  readonly item_price: Piastres | null;
  readonly score: number;
  readonly is_open: boolean;
  readonly distance_km: number | null;
  readonly rating_avg: number;
  readonly rating_count: number;
  readonly minimum_order_value: Piastres;
  readonly prep_time_minutes: number;
}

/* ── device ───────────────────────────────────────────────────────────────── */

/** `device_tokens` as the app reads it. `language` is per registration, not per account. */
export interface DeviceToken {
  readonly id: Uuid;
  readonly user_id: Uuid;
  readonly token: string;
  readonly platform: Platform;
  readonly app_role: AppRole;
  readonly app_version: string | null;
  readonly language: Language;
  readonly last_seen_at: string;
  readonly created_at: string;
}

/* ── catalogue reads ──────────────────────────────────────────────────────── */

/**
 * `vendors` as the app reads it. Column presence and nullability transcribed
 * from `information_schema.columns` against the live project. Reads filter
 * `is_active AND is_approved AND deleted_at IS NULL` — the RLS policy will
 * not do the soft-delete filtering for you.
 */
export interface Vendor {
  readonly id: Uuid;
  readonly slug: string;
  readonly name: string;
  readonly name_ar: string;
  readonly legal_name: string | null;
  readonly brand_id: Uuid | null;
  readonly vertical_type: VerticalType;
  readonly city_id: Uuid;
  readonly area_id: Uuid;
  readonly latitude: number;
  readonly longitude: number;
  readonly geohash_prefix: string;
  readonly delivery_radius_km: number;
  readonly is_open: boolean;
  readonly is_busy: boolean;
  readonly auto_open: boolean;
  readonly is_approved: boolean;
  readonly is_active: boolean;
  readonly capacity_per_slot: number | null;
  readonly reject_rate: number;
  readonly delivery_fee_override: Piastres | null;
  readonly minimum_order_value: Piastres;
  readonly prep_time_minutes: number;
  readonly prep_time_max_minutes: number;
  readonly rating_avg: number;
  readonly rating_count: number;
  readonly menu_version: number;
  readonly logo_path: string | null;
  readonly description: string | null;
  readonly description_ar: string | null;
  readonly contact_phone: string | null;
  readonly contact_landline: string | null;
}

/** `menu_categories` as the app reads it. */
export interface MenuCategory {
  readonly id: Uuid;
  readonly vendor_id: Uuid;
  readonly name: string;
  readonly name_ar: string | null;
  readonly description: string | null;
  readonly display_order: number;
  readonly is_available: boolean;
}

/** `menu_items` as the app reads it. */
export interface MenuItem {
  readonly id: Uuid;
  readonly category_id: Uuid;
  readonly vendor_id: Uuid;
  readonly name: string;
  readonly name_ar: string | null;
  readonly description: string | null;
  readonly description_ar: string | null;
  readonly pricing_mode: PricingMode;
  readonly base_price: Piastres | null;
  readonly is_available: boolean;
  readonly stock_count: number | null;
  readonly preparation_time_minutes: number | null;
  readonly image_path: string | null;
  readonly display_order: number;
  readonly nutritional_info: unknown;
  readonly allergens: unknown;
  readonly ingredients: unknown;
  readonly tags: readonly string[];
  readonly calories: number | null;
  readonly is_spicy: boolean;
  readonly is_vegetarian: boolean;
  readonly is_featured: boolean;
  readonly is_new: boolean;
}

/** `menu_item_sizes` as the app reads it. */
export interface MenuItemSize {
  readonly id: Uuid;
  readonly item_id: Uuid;
  readonly name: string;
  readonly name_ar: string | null;
  readonly price: Piastres;
  readonly is_default: boolean;
  readonly is_available: boolean;
  readonly calories: number | null;
  readonly display_order: number;
}

/** `item_options` as the app reads it. */
export interface ItemOption {
  readonly id: Uuid;
  readonly item_id: Uuid;
  readonly name: string;
  readonly name_ar: string | null;
  readonly is_required: boolean;
  readonly min_selections: number;
  readonly max_selections: number;
  readonly display_order: number;
  readonly is_available: boolean;
}

/**
 * `option_choices` as the app reads it. `price_modifier` is a plain integer,
 * not `Piastres`: it can be negative (a discount), so it is not an amount held.
 */
export interface OptionChoice {
  readonly id: Uuid;
  readonly option_id: Uuid;
  readonly name: string;
  readonly name_ar: string | null;
  readonly price_modifier: number;
  readonly is_default: boolean;
  readonly is_available: boolean;
  readonly stock_count: number | null;
  readonly calories: number | null;
  readonly display_order: number;
}

/* ── geography reads ──────────────────────────────────────────────────────── */

/** `areas` as the app reads it. The client resolves pins against these rows (§6). */
export interface Area {
  readonly id: Uuid;
  readonly city_id: Uuid;
  readonly slug: string;
  readonly name: string;
  readonly name_ar: string;
  readonly geohash_prefix: string;
  readonly center_lat: number;
  readonly center_lng: number;
  readonly radius_km: number;
  readonly is_active: boolean;
}

/**
 * `delivery_zones` as the app reads it. `peak_hours` is an `int4range` on the
 * wire, which PostgREST renders as text (`[9,12)`), so it is a string here.
 */
export interface DeliveryZone {
  readonly id: Uuid;
  readonly city_id: Uuid;
  readonly area_id: Uuid;
  readonly name: string;
  readonly name_ar: string;
  readonly currency: string;
  readonly delivery_base_fee: Piastres;
  readonly free_radius_km: number;
  readonly per_km_fee: Piastres;
  readonly max_vendors_per_order: number;
  readonly min_order_value: Piastres;
  readonly max_distance_km: number;
  readonly peak_hours: string | null;
  readonly is_active: boolean;
}

/** `cuisines` as the app reads it. Filter chips. */
export interface Cuisine {
  readonly id: Uuid;
  readonly code: string;
  readonly name: string;
  readonly name_ar: string;
  readonly sort_order: number;
}

/* ── cart memo + sub-orders ───────────────────────────────────────────────── */

/**
 * `carts` as the app reads it. The `quote_*` columns are the server's memo of
 * the last quote: readable to restore a checkout screen, never writable.
 */
export interface Cart {
  readonly id: Uuid;
  readonly user_id: Uuid;
  readonly is_active: boolean;
  readonly last_seen_at: string;
  readonly quote_id: Uuid | null;
  readonly quote_fingerprint: string | null;
  readonly quote_expires_at: string | null;
  readonly quote_address_id: Uuid | null;
  readonly quote_voucher_code: string | null;
  readonly quote_rider_tip: number | null;
  readonly quote_delivery_type: string | null;
  readonly quote_grouping: string | null;
  readonly quote_snapshot: unknown;
}

/** `sub_orders` as the app reads it. One per vendor per order. */
export interface SubOrder {
  readonly id: Uuid;
  readonly order_id: Uuid;
  readonly vendor_id: Uuid;
  readonly sequence: number;
  readonly status: SubOrderStatus;
  readonly subtotal: Piastres;
  readonly delivery_fee_share: Piastres;
  readonly service_fee_share: Piastres;
  readonly discount_share: Piastres;
  readonly commission_amount: Piastres;
  readonly platform_fee_amount: Piastres;
  readonly vendor_net_payout: Piastres;
  readonly menu_version_snapshot: number | null;
  readonly prep_estimate_minutes: number;
  readonly prep_actual_minutes: number | null;
  readonly ready_at: string | null;
  readonly accepted_at: string | null;
  readonly preparing_at: string | null;
  readonly picked_up_at: string | null;
  readonly delivered_at: string | null;
  readonly cancelled_at: string | null;
  readonly cancellation_reason: string | null;
  readonly cancellation_actor: CancellationActor | null;
  readonly rejection_reason: string | null;
  readonly settlement_status: SettlementStatus;
  readonly payout_id: Uuid | null;
}

/* ── growth reads ─────────────────────────────────────────────────────────── */

/** `vouchers` as the app reads it. Active, in-window rows only. */
export interface Voucher {
  readonly id: Uuid;
  readonly code: string;
  readonly name: string | null;
  readonly discount_type: VoucherDiscountType;
  readonly discount_value: number;
  readonly min_order_value: Piastres;
  readonly max_discount_cap: Piastres | null;
  readonly usage_limit_total: number | null;
  readonly usage_limit_per_user: number | null;
  readonly usage_count: number;
  readonly applies_to_vendor_ids: readonly Uuid[];
  readonly vertical_type: VerticalType | null;
  readonly first_order_only: boolean;
  readonly valid_from: string;
  readonly valid_until: string | null;
  readonly is_active: boolean;
}

/** `promo_slots` as the app reads it. `title`/`subtitle` are language objects. */
export interface PromoSlot {
  readonly id: Uuid;
  readonly city_id: Uuid;
  readonly slot_key: string;
  readonly title: unknown;
  readonly subtitle: unknown;
  readonly image_path: string | null;
  readonly target_type: string | null;
  readonly target_id: string | null;
  readonly starts_at: string | null;
  readonly ends_at: string | null;
  readonly sort_order: number;
  readonly is_active: boolean;
}

/** `get_flags_v1` row. `value` shape varies per flag — decode per use. */
export interface FlagRow {
  readonly flag_key: string;
  readonly value: unknown;
}

/**
 * `riders_public` view: the only readable rider surface (what a customer sees
 * on tracking). Every column is nullable on the wire (LEFT JOINs) — verified
 * live via `information_schema`. Never assume a name is present.
 */
export interface RiderPublic {
  readonly id: Uuid | null;
  readonly first_name: string | null;
  readonly last_name: string | null;
  readonly phone_number: string | null;
  readonly vehicle_type: string | null;
  readonly vehicle_plate: string | null;
  readonly rating_avg: number | null;
  readonly rating_count: number | null;
}
