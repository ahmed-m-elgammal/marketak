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
  DeliveryGrouping,
  DeliveryType,
  OrderStatus,
  PaymentChannel,
  PaymentMethod,
  PaymentStatus,
  Platform,
  QuoteRejectionCode,
  VerticalType,
  VendorAvailability,
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
