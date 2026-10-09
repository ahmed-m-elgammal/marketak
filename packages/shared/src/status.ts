/**
 * Status vocabularies.
 *
 * The database has **no Postgres enums**. Every status and category column is
 * `text` guarded by a `CHECK` constraint, so a wrong string fails at runtime,
 * not at compile time, and there is no database type to catch it. That is the
 * single largest source of drift in this system.
 *
 * Each vocabulary below is therefore declared three times in one place: a
 * `const` tuple (the runtime array), a type union derived from it (the compile
 * surface), and a predicate that narrows an unknown `string` to the union (the
 * boundary). One source, three consumers, no drift between them.
 *
 * `npm run check:status-types` (`scripts/check-status-types.mjs`) compares these
 * arrays against the live `CHECK` constraints and fails on any difference. That
 * is architecture rule 4: the type is transcribed from the database, and the
 * transcription is verified rather than trusted.
 *
 * Source of truth: `specs-mobile/README.md` §4–5, read from `pg_constraint`.
 */

/**
 * Builds a vocabulary from a tuple: the runtime array, the union type, and the
 * narrowing predicate, all from one declaration.
 */
function vocabulary<const T extends readonly string[]>(values: T) {
  const list = values as readonly string[];
  return {
    values: values,
    list,
    is(value: string): value is T[number] {
      return list.includes(value);
    },
  } as const;
}

/* ── Orders ───────────────────────────────────────────────────────────────── */

/** `orders.status`. Derived from `sub_orders.status` by `trg_sub_orders_sync_order_status`. Never write it. */
export const ORDER_STATUS = vocabulary([
  "pending",
  "partially_confirmed",
  "preparing",
  "ready",
  "picked_up",
  "delivering",
  "delivered",
  "partially_cancelled",
  "cancelled",
] as const);
export type OrderStatus = (typeof ORDER_STATUS.values)[number];

/**
 * `sub_orders.status`. Note `orders` and `sub_orders` do **not** share a set:
 * `sub_orders` has `accepted` and `rejected`, which `orders` has no equivalent of.
 */
export const SUB_ORDER_STATUS = vocabulary([
  "pending",
  "accepted",
  "preparing",
  "ready",
  "picked_up",
  "delivering",
  "delivered",
  "rejected",
  "cancelled",
] as const);
export type SubOrderStatus = (typeof SUB_ORDER_STATUS.values)[number];

/**
 * `delivery_assignments.status`. `at_first_vendor`, `picking_up` and `arrived`
 * exist here and nowhere else in the schema.
 */
export const ASSIGNMENT_STATUS = vocabulary([
  "unassigned",
  "assigned",
  "at_first_vendor",
  "picking_up",
  "picked_up",
  "delivering",
  "arrived",
  "delivered",
  "failed",
  "cancelled",
] as const);
export type AssignmentStatus = (typeof ASSIGNMENT_STATUS.values)[number];

/** `orders.payment_status`. */
export const PAYMENT_STATUS = vocabulary(["unpaid", "collected", "failed", "refunded"] as const);
export type PaymentStatus = (typeof PAYMENT_STATUS.values)[number];

/** `sub_orders.settlement_status`. */
export const SETTLEMENT_STATUS = vocabulary(["payable", "in_payout", "settled", "void"] as const);
export type SettlementStatus = (typeof SETTLEMENT_STATUS.values)[number];

/** `orders.payment_method`. Cash is the launch method; the platform holds no customer money. */
export const PAYMENT_METHOD = vocabulary(["cash", "wallet"] as const);
export type PaymentMethod = (typeof PAYMENT_METHOD.values)[number];

/** `orders.payment_channel` and `delivery_assignments.collection_channel`. */
export const PAYMENT_CHANNEL = vocabulary(["cod", "vodafone_cash", "instapay", "gateway"] as const);
export type PaymentChannel = (typeof PAYMENT_CHANNEL.values)[number];

/** `delivery_assignments.collection_method`. `none` is the state before anything is collected. */
export const COLLECTION_METHOD = vocabulary(["cash", "wallet", "none"] as const);
export type CollectionMethod = (typeof COLLECTION_METHOD.values)[number];

/** `orders.delivery_type`. */
export const DELIVERY_TYPE = vocabulary(["delivery", "pickup"] as const);
export type DeliveryType = (typeof DELIVERY_TYPE.values)[number];

/** `orders.delivery_grouping`. */
export const DELIVERY_GROUPING = vocabulary(["together", "separate"] as const);
export type DeliveryGrouping = (typeof DELIVERY_GROUPING.values)[number];

/** `order_items.item_status`. */
export const ITEM_STATUS = vocabulary([
  "confirmed",
  "out_of_stock",
  "price_updated",
  "limited_stock",
  "replacement",
] as const);
export type ItemStatus = (typeof ITEM_STATUS.values)[number];

/** `order_status_history.actor_role`. */
export const ACTOR_ROLE = vocabulary(["customer", "rider", "vendor", "admin", "system"] as const);
export type ActorRole = (typeof ACTOR_ROLE.values)[number];

/** `sub_orders.cancellation_actor`. */
export const CANCELLATION_ACTOR = vocabulary(["customer", "vendor", "admin", "system"] as const);
export type CancellationActor = (typeof CANCELLATION_ACTOR.values)[number];

/* ── Riders ───────────────────────────────────────────────────────────────── */

/** `riders.status`. Derived column `is_online` is `status <> 'offline'` - one act, not two toggles. */
export const RIDER_STATUS = vocabulary(["offline", "available", "assigned", "on_break"] as const);
export type RiderStatus = (typeof RIDER_STATUS.values)[number];

export const VEHICLE_TYPE = vocabulary(["car", "bicycle", "motorcycle", "scooter"] as const);
export type VehicleType = (typeof VEHICLE_TYPE.values)[number];

/** `delivery_assignments.assigned_by`. `rider_claim` stamps `claimed_at`. */
export const ASSIGNED_BY = vocabulary(["system", "rider_claim", "admin"] as const);
export type AssignedBy = (typeof ASSIGNED_BY.values)[number];

/* ── Accounts ─────────────────────────────────────────────────────────────── */

/** `user_roles.role`. */
export const USER_ROLE = vocabulary(["customer", "rider", "admin", "support"] as const);
export type UserRole = (typeof USER_ROLE.values)[number];

/** `device_tokens.app_role`. The mobile app only ever writes `customer` or `rider`. */
export const APP_ROLE = vocabulary(["customer", "rider", "admin"] as const);
export type AppRole = (typeof APP_ROLE.values)[number];

export const PLATFORM = vocabulary(["android", "ios"] as const);
export type Platform = (typeof PLATFORM.values)[number];

export const AUTH_PROVIDER = vocabulary(["google", "apple"] as const);
export type AuthProvider = (typeof AUTH_PROVIDER.values)[number];

/* ── Catalogue ────────────────────────────────────────────────────────────── */

/**
 * `vendors.vertical_type`. Six values, not four - the design's four category
 * chips (restaurants, bakery, grocery, pharmacy) understate the range. Read from
 * the live `CHECK` constraint: `food, grocery, pharmacy, flowers, bakery, others`.
 *
 * ARCHITECTURE RULE 7: accent, icon and card variant live in ONE registry keyed
 * by this type. If a vertical needs different *behaviour* (prescriptions, for
 * example), stop and ask - the specification has no support for it.
 */
export const VERTICAL_TYPE = vocabulary([
  "food",
  "grocery",
  "pharmacy",
  "flowers",
  "bakery",
  "others",
] as const);
export type VerticalType = (typeof VERTICAL_TYPE.values)[number];

/** `menu_items.pricing_mode`. `sized` makes a size mandatory - `assert_item_has_sizes` enforces it. */
export const PRICING_MODE = vocabulary(["fixed", "sized"] as const);
export type PricingMode = (typeof PRICING_MODE.values)[number];

export const ADDRESS_LABEL = vocabulary(["home", "work", "other"] as const);
export type AddressLabel = (typeof ADDRESS_LABEL.values)[number];

export const VENDOR_AVAILABILITY = vocabulary(["open", "paused", "closed"] as const);
export type VendorAvailability = (typeof VENDOR_AVAILABILITY.values)[number];

/* ── Money and settlement ─────────────────────────────────────────────────── */

export const WALLET_OWNER_TYPE = vocabulary(["vendor", "rider"] as const);
export type WalletOwnerType = (typeof WALLET_OWNER_TYPE.values)[number];

export const WALLET_STATUS = vocabulary(["active", "frozen", "review"] as const);
export type WalletStatus = (typeof WALLET_STATUS.values)[number];

export const LEDGER_ACCOUNT_TYPE = vocabulary([
  "vendor",
  "rider",
  "platform",
  "platform_earnings",
] as const);
export type LedgerAccountType = (typeof LEDGER_ACCOUNT_TYPE.values)[number];

export const LEDGER_ENTRY_TYPE = vocabulary([
  "rider_cut",
  "cash_collected",
  "cash_remitted",
  "delivery_fee",
  "service_fee",
  "commission",
  "refund",
  "reversal",
  "vendor_payout",
  "rider_payout",
  "adjustment",
  "float_sweep",
] as const);
export type LedgerEntryType = (typeof LEDGER_ENTRY_TYPE.values)[number];

export const PAYOUT_TYPE = vocabulary(["vendor", "rider"] as const);
export type PayoutType = (typeof PAYOUT_TYPE.values)[number];

export const PAYOUT_STATUS = vocabulary([
  "draft",
  "approved",
  "processing",
  "paid",
  "failed",
  "cancelled",
] as const);
export type PayoutStatus = (typeof PAYOUT_STATUS.values)[number];

export const PAYOUT_LINE_TYPE = vocabulary([
  "vendor_earning",
  "rider_trip",
  "tip",
  "bonus",
  "adjustment",
] as const);
export type PayoutLineType = (typeof PAYOUT_LINE_TYPE.values)[number];

export const PAYOUT_LINE_SOURCE = vocabulary(["cash_collected", "wallet_payment", "adjustment"] as const);
export type PayoutLineSource = (typeof PAYOUT_LINE_SOURCE.values)[number];

export const COMMISSION_TYPE = vocabulary([
  "percentage",
  "fixed_amount",
  "free_delivery",
  "negative",
] as const);
export type CommissionType = (typeof COMMISSION_TYPE.values)[number];

export const COMMISSION_SCOPE = vocabulary(["vendor", "rider", "platform"] as const);
export type CommissionScope = (typeof COMMISSION_SCOPE.values)[number];

export const COMMISSION_APPLIES_TO = vocabulary([
  "subtotal",
  "delivery_fee",
  "service_fee",
  "payout_total",
] as const);
export type CommissionAppliesTo = (typeof COMMISSION_APPLIES_TO.values)[number];

export const VOUCHER_DISCOUNT_TYPE = vocabulary([
  "percentage",
  "fixed_amount",
  "free_delivery",
] as const);
export type VoucherDiscountType = (typeof VOUCHER_DISCOUNT_TYPE.values)[number];

/* ── Staff ────────────────────────────────────────────────────────────────── */

export const STAFF_ROLE = vocabulary(["owner", "manager", "staff", "cashier"] as const);
export type StaffRole = (typeof STAFF_ROLE.values)[number];

/* ── Rejections from `quote_order_v1` ─────────────────────────────────────── */

/**
 * `private.compute_quote` folds a per-line problem into one of these codes on the
 * *vendor*, not the line. The Arabic message ships with it; the English does not,
 * so the app supplies English from this code.
 */
export const QUOTE_REJECTION = vocabulary([
  "ITEM_RETIRED",
  "VENDOR_UNAVAILABLE",
  "ITEM_UNAVAILABLE",
  "OUT_OF_STOCK",
  "SIZE_REQUIRED",
  "SIZE_UNAVAILABLE",
  "OPTION_UNAVAILABLE",
  "OUT_OF_RANGE",
  "VENDOR_LIMIT_EXCEEDED",
  "VOUCHER_UNKNOWN",
  "VOUCHER_EXPIRED",
  "VOUCHER_EXHAUSTED",
  "VOUCHER_MINIMUM_NOT_MET",
  "VOUCHER_FIRST_ORDER_ONLY",
  "VOUCHER_NOT_APPLICABLE",
] as const);
export type QuoteRejectionCode = (typeof QUOTE_REJECTION.values)[number];

/**
 * Every vocabulary the status-type checker verifies. Adding a vocabulary here is
 * what makes `npm run check:status-types` cover it; omitting it silently
 * un-verifies the type.
 */
export const STATUS_VOCABULARIES = {
  "orders.status": ORDER_STATUS,
  "sub_orders.status": SUB_ORDER_STATUS,
  "delivery_assignments.status": ASSIGNMENT_STATUS,
  "orders.payment_status": PAYMENT_STATUS,
  "sub_orders.settlement_status": SETTLEMENT_STATUS,
  "orders.payment_method": PAYMENT_METHOD,
  "orders.payment_channel": PAYMENT_CHANNEL,
  "delivery_assignments.collection_method": COLLECTION_METHOD,
  "delivery_assignments.collection_channel": PAYMENT_CHANNEL,
  "delivery_assignments.assigned_by": ASSIGNED_BY,
  "orders.delivery_type": DELIVERY_TYPE,
  "orders.delivery_grouping": DELIVERY_GROUPING,
  "order_items.item_status": ITEM_STATUS,
  "order_status_history.actor_role": ACTOR_ROLE,
  "sub_orders.cancellation_actor": CANCELLATION_ACTOR,
  "riders.status": RIDER_STATUS,
  "riders.vehicle_type": VEHICLE_TYPE,
  "user_roles.role": USER_ROLE,
  "device_tokens.app_role": APP_ROLE,
  "device_tokens.platform": PLATFORM,
  "user_auth_providers.provider_type": AUTH_PROVIDER,
  "vendors.vertical_type": VERTICAL_TYPE,
  "menu_items.pricing_mode": PRICING_MODE,
  "addresses.label": ADDRESS_LABEL,
  "wallets.owner_type": WALLET_OWNER_TYPE,
  "wallets.status": WALLET_STATUS,
  "ledger_entries.account_type": LEDGER_ACCOUNT_TYPE,
  "ledger_entries.entry_type": LEDGER_ENTRY_TYPE,
  "payouts.payout_type": PAYOUT_TYPE,
  "payouts.status": PAYOUT_STATUS,
  "payout_lines.payout_line_type": PAYOUT_LINE_TYPE,
  "payout_lines.source": PAYOUT_LINE_SOURCE,
  "commission_rules.commission_type": COMMISSION_TYPE,
  "commission_rules.scope": COMMISSION_SCOPE,
  "commission_rules.applies_to": COMMISSION_APPLIES_TO,
  "vouchers.discount_type": VOUCHER_DISCOUNT_TYPE,
  "vendor_staff.staff_role": STAFF_ROLE,
  "users.preferred_language": ["ar", "en"],
} as const;

export type StatusVocabularyName = keyof typeof STATUS_VOCABULARIES;
