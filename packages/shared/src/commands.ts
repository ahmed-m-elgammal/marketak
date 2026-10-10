/**
 * Command DTOs.
 *
 * Shapes the **client** owns and sends to the server. Every one is transcribed
 * from `pg_get_function_identity_arguments` against the live project.
 *
 * `readonly` here does not mean "you cannot build this" - it means "do not mutate
 * a params object once it is built". The failure it prevents is a retry path that
 * tweaks a field in place, which is how an idempotency key stops matching the
 * order it is meant to protect, or how an amount changes between attempt and
 * retry.
 *
 * The other job of these types is **narrowness**. A command must carry only the
 * arguments the RPC accepts, because that is what makes an illegal request
 * unrepresentable rather than merely discouraged:
 *
 * - `upsert_cart_item_v1` takes **no price**. There is no field for one, so a
 *   forged price cannot be sent even by accident. This is constitution rule 3
 *   ("never trust the client for money") expressed in the type system.
 * - `place_order_v1` re-prices server-side and raises `PRICE_CHANGED`. The
 *   command carries the `quote_id` and a fingerprint it never computes.
 * - `upsert_my_address_v1` accepts a `p_patch` with a **fixed key allow-list**;
 *   `geohash` and `geohash_prefix` are absent by construction, because the server
 *   derives them from the pin.
 *
 * Response shapes live in `dto.ts`. The two directions are never mixed in one
 * type: a type that is both readable and writable is a type where the app can
 * write back a field the server owns.
 */

import type { Piastres } from "./money.js";
import type {
  AppRole,
  DeliveryGrouping,
  DeliveryType,
  PaymentMethod,
  Platform,
  SubOrderStatus,
  VerticalType,
} from "./status.js";
import type { SelectedOption, Uuid } from "./dto.js";

/* ── profile ──────────────────────────────────────────────────────────────── */

export interface CompleteProfileArgs {
  readonly p_first_name: string;
  readonly p_last_name: string;
  readonly p_phone: string;
}

/** `update_profile_v1`'s `p_patch`. `UNKNOWN_KEY` for anything outside this set. */
export interface UpdateProfilePatch {
  readonly first_name?: string;
  readonly last_name?: string;
  readonly phone_number?: string | null;
  readonly email?: string | null;
  readonly avatar_path?: string | null;
  readonly preferred_language?: "ar" | "en";
  readonly country_code?: string;
}

/* ── addresses ────────────────────────────────────────────────────────────── */

/**
 * `upsert_my_address_v1`'s `p_patch`. Exactly the allow-list the function
 * validates - `label`, `area_id`, `latitude`, `longitude`, `area_name`,
 * `building`, `floor`, `apartment`, `landmark`, `delivery_instructions`.
 *
 * Absent on purpose: `user_id` (always `auth.uid()`), `geohash` and
 * `geohash_prefix` (derived from the pin), `is_default` (true on the first
 * address only), `area_name` is settable but the server overwrites it from
 * `areas.name`.
 */
export interface AddressPatch {
  readonly label?: "home" | "work" | "other";
  readonly area_id?: Uuid;
  readonly latitude?: number;
  readonly longitude?: number;
  readonly area_name?: string;
  readonly building?: string;
  readonly floor?: string;
  readonly apartment?: string;
  readonly landmark?: string;
  readonly delivery_instructions?: string;
}

export interface UpsertAddressArgs {
  readonly p_patch: AddressPatch;
  /** `null` inserts; an id updates. */
  readonly p_id?: Uuid | null;
}

export interface SetDefaultAddressArgs {
  readonly p_id: Uuid;
}

export interface DeleteAddressArgs {
  readonly p_id: Uuid;
}

/* ── cart ─────────────────────────────────────────────────────────────────── */

/**
 * `upsert_cart_item_v1`. There is deliberately **no price, no vendor and no
 * unit total** - the server resolves all three. `vendor_id` is synced from the
 * menu item by a trigger.
 */
export interface UpsertCartItemArgs {
  readonly p_menu_item_id: Uuid;
  readonly p_selected_options?: readonly SelectedOption[];
  readonly p_selected_size_id?: Uuid | null;
  readonly p_quantity?: number;
  readonly p_special_instructions?: string | null;
}

export interface RemoveCartItemArgs {
  readonly p_cart_item_id: Uuid;
}

/* ── quote and checkout ───────────────────────────────────────────────────── */

export interface QuoteOrderArgs {
  readonly p_cart_id: Uuid;
  readonly p_address_id: Uuid;
  readonly p_voucher_code?: string | null;
  readonly p_rider_tip?: number;
  readonly p_delivery_type?: DeliveryType;
  readonly p_grouping?: DeliveryGrouping;
}

/**
 * `place_order_v1`. `p_payment_method` is `'cash'` in v1 - the platform holds no
 * customer money, so there is no wallet or top-up channel to select.
 *
 * `p_idempotency_key` is required by the function. Generate it once per attempt
 * and reuse it across retries; a reused key raises `IDEMPOTENCY_KEY_TAKEN`
 * rather than creating a second order.
 */
export interface PlaceOrderArgs {
  readonly p_quote_id: Uuid;
  readonly p_payment_method: PaymentMethod;
  readonly p_payment_channel?: string | null;
  readonly p_idempotency_key: string;
}

export interface CancelOrderArgs {
  readonly p_order_id: Uuid;
  /** `null` cancels the whole order; an id cancels one vendor's part. */
  readonly p_sub_order_id?: Uuid | null;
  readonly p_reason?: string | null;
}

/* ── discovery ────────────────────────────────────────────────────────────── */

/**
 * `get_vendor_feed_v1`. `p_limit` is clamped 1-40 (default 12) and `p_offset`
 * 0-2000 server-side, so an out-of-range value is a silent clamp, not an error.
 *
 * `p_sort` accepts `rating | name | prep_time | min_order` and **falls back to
 * `rating`** for anything else, so an unknown sort string silently reorders the
 * feed rather than failing.
 */
export interface VendorFeedArgs {
  readonly p_area_id?: Uuid | null;
  readonly p_vertical?: VerticalType | null;
  readonly p_open_only?: boolean;
  readonly p_query?: string;
  readonly p_offset?: number;
  readonly p_limit?: number;
  readonly p_sort?: "rating" | "name" | "prep_time" | "min_order";
}

export interface SearchCatalogArgs {
  readonly p_query: string;
  readonly p_area_id?: Uuid | null;
  readonly p_filters?: Readonly<Record<string, unknown>>;
  readonly p_limit?: number;
}

/* ── rider ────────────────────────────────────────────────────────────────── */

/**
 * `get_available_orders_v1`. `p_lat`/`p_lng` are the **device's** position and
 * take priority over the stored `riders.current_latitude` - the stored value is
 * only a fallback, so a rider with no stored location can still open the pool.
 *
 * Note this is a **write**: it backfills `delivery_assignments` before selecting.
 * Poll at a sane interval, not on a timer that outlives the screen.
 */
export interface AvailableOrdersArgs {
  readonly p_lat?: number | null;
  readonly p_lng?: number | null;
  readonly p_radius_km?: number;
}

export interface ClaimOrderArgs {
  readonly p_assignment_id: Uuid;
  readonly p_rider_id: Uuid;
}

/**
 * `transition_order_v1`. `p_sub_order_id = null` transitions the whole order; an
 * id transitions one vendor's part. `order_status` comes back re-derived, so
 * there is no need to re-read `orders`.
 */
export interface TransitionOrderArgs {
  readonly p_order_id: Uuid;
  readonly p_sub_order_id?: Uuid | null;
  readonly p_to_status: SubOrderStatus;
  readonly p_reason?: string | null;
}

/** `begin_collection_v1`. Call this **before** collecting - it is the pre-flight. */
export interface BeginCollectionArgs {
  readonly p_order_id: Uuid;
  readonly p_payment_method: PaymentMethod;
  readonly p_channel: string;
}

/**
 * `collect_cash_v1`. `p_amount` must match what `begin_collection_v1` reported as
 * `amount_due`; a mismatch raises `AMOUNT_MISMATCH`. `p_proof_path` is a path, not
 * a URL - a Worker signs it.
 */
export interface CollectCashArgs {
  readonly p_order_id: Uuid;
  readonly p_amount: Piastres;
  readonly p_reference?: string | null;
  readonly p_proof_path?: string | null;
}

export interface CollectWalletArgs {
  readonly p_order_id: Uuid;
  readonly p_channel: string;
  readonly p_reference?: string | null;
}

/** `complete_delivery_v1`. `p_lat`/`p_lng` are taken at the door. */
export interface CompleteDeliveryArgs {
  readonly p_order_id: Uuid;
  readonly p_proof_path?: string | null;
  readonly p_lat?: number | null;
  readonly p_lng?: number | null;
}

export interface EffectiveCashLimitArgs {
  readonly p_rider_id: Uuid;
}

/* ── device ───────────────────────────────────────────────────────────────── */

/**
 * `get_flags_v1`. Both arguments are nullable with server-side targeting
 * resolution — pass the device's real role and semver.
 */
export interface GetFlagsArgs {
  readonly p_app_role?: AppRole | null;
  readonly p_app_version?: string | null;
}

/**
 * `register_device_token_v1`. Call on launch **and on every sign-in**: `language`
 * and `app_version` are per-registration, and a stale one makes a live device
 * look dead to the dispatcher.
 */
export interface RegisterDeviceTokenArgs {
  readonly p_token: string;
  readonly p_platform: Platform;
  readonly p_app_role: AppRole;
  readonly p_app_version: string;
}

/* ── generic ──────────────────────────────────────────────────────────────── */

/** A `p_from`/`p_to` date window. `p_to >= p_from` is enforced server-side. */
export interface DateWindowArgs {
  readonly p_from: string;
  readonly p_to: string;
}
