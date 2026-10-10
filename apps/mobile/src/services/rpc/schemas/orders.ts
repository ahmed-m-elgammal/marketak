import { z } from "zod";
import {
  DELIVERY_GROUPING,
  DELIVERY_TYPE,
  PAYMENT_CHANNEL,
  PAYMENT_METHOD,
  type CancellationActor,
  type OrderStatus,
  type PaymentStatus,
  type SettlementStatus,
  type SubOrderStatus,
} from "@marketak/shared";
import { currency, isoDate, nullablePiastres, piastres, uuid } from "./primitives";

/**
 * `orders` row. `status` is a display vocabulary (primitives header): the
 * timeline is built from `order_status_history`, so an unseen status
 * renders rather than throws. Money stays strict.
 */
export const orderSchema = z
  .object({
    id: uuid,
    order_number: z.string(),
    user_id: uuid,
    status: z.string().transform((value): OrderStatus => value as OrderStatus),
    subtotal: piastres,
    delivery_base_fee: piastres,
    delivery_multiplier_bps: z.number().int(),
    distance_km: z.number().nullable(),
    delivery_fee: piastres,
    service_fee: piastres,
    discount_amount: piastres,
    voucher_code: z.string().nullable(),
    voucher_discount: piastres,
    rider_tip: piastres,
    rider_pay_total: piastres,
    platform_revenue: piastres,
    total: piastres,
    currency,
    price_fingerprint: z.string().nullable(),
    pricing_version: z.number().int(),
    payment_method: z.enum(PAYMENT_METHOD.values),
    payment_channel: z.enum(PAYMENT_CHANNEL.values),
    payment_status: z.string().transform((value): PaymentStatus => value as PaymentStatus),
    payment_collected_at: isoDate.nullable(),
    payment_collected_by: uuid.nullable(),
    payment_reference: z.string().nullable(),
    payment_proof_path: z.string().nullable(),
    delivery_type: z.enum(DELIVERY_TYPE.values),
    delivery_grouping: z.enum(DELIVERY_GROUPING.values),
    vendor_limit_applied: z.number().int().nullable(),
    address_id: uuid.nullable(),
    address_snapshot: z.unknown(),
    delivery_latitude: z.number().nullable(),
    delivery_longitude: z.number().nullable(),
    delivery_geohash_prefix: z.string().nullable(),
    area_id: uuid.nullable(),
    is_contactless: z.boolean(),
    access_note: z.string().nullable(),
    scheduled_delivery_time: isoDate.nullable(),
    promised_delivery_at: isoDate.nullable(),
    eta_minutes: z.number().int().nullable(),
    eta_maxutes: z.number().int().nullable(),
    vendor_count: z.number().int(),
    item_count: z.number().int(),
    placed_at: isoDate,
    confirmed_at: isoDate.nullable(),
    first_picked_up_at: isoDate.nullable(),
    completed_at: isoDate.nullable(),
    cancelled_at: isoDate.nullable(),
    cancellation_reason: z.string().nullable(),
  })
  .passthrough();

/** `sub_orders` row. */
export const subOrderSchema = z
  .object({
    id: uuid,
    order_id: uuid,
    vendor_id: uuid,
    sequence: z.number().int(),
    status: z.string().transform((value): SubOrderStatus => value as SubOrderStatus),
    subtotal: piastres,
    delivery_fee_share: piastres,
    service_fee_share: piastres,
    discount_share: piastres,
    commission_amount: piastres,
    platform_fee_amount: piastres,
    vendor_net_payout: piastres,
    menu_version_snapshot: z.number().int().nullable(),
    prep_estimate_minutes: z.number().int(),
    prep_actual_minutes: z.number().int().nullable(),
    ready_at: isoDate.nullable(),
    accepted_at: isoDate.nullable(),
    preparing_at: isoDate.nullable(),
    picked_up_at: isoDate.nullable(),
    delivered_at: isoDate.nullable(),
    cancelled_at: isoDate.nullable(),
    cancellation_reason: z.string().nullable(),
    cancellation_actor: z
      .string()
      .nullable()
      .transform((value): CancellationActor | null => (value === null ? null : (value as CancellationActor))),
    rejection_reason: z.string().nullable(),
    settlement_status: z.string().transform((value): SettlementStatus => value as SettlementStatus),
    payout_id: uuid.nullable(),
  })
  .passthrough();

/**
 * `order_status_history` row — the spine of the tracking timeline. Statuses
 * are display vocabulary: presence-checked, never union-gated.
 */
export const orderStatusHistoryEntrySchema = z
  .object({
    id: uuid,
    order_id: uuid,
    sub_order_id: uuid.nullable(),
    from_status: z.string().nullable(),
    to_status: z.string(),
    actor_user_id: uuid.nullable(),
    actor_role: z.string(),
    reason: z.string().nullable(),
    metadata: z.unknown(),
    created_at: isoDate,
  })
  .passthrough();

/** `order_items` row. Names are denormalised snapshots — render them, never re-join. */
export const orderItemSchema = z
  .object({
    id: uuid,
    sub_order_id: uuid,
    order_id: uuid,
    vendor_id: uuid,
    menu_item_id: uuid.nullable(),
    item_name: z.string(),
    item_name_ar: z.string().nullable(),
    image_path: z.string().nullable(),
    quantity: z.number().int(),
    unit_price: piastres,
    total_price: piastres,
    selected_options: z.array(z.looseObject({ choice_id: uuid })).readonly(),
    special_instructions: z.string().nullable(),
    item_status: z.string(),
    created_at: isoDate,
    selected_size_id: uuid.nullable(),
    selected_size_name: z.string().nullable(),
    selected_size_price: nullablePiastres,
  })
  .passthrough();
