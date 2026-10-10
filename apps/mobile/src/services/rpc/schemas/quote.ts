import { z } from "zod";
import { QUOTE_REJECTION } from "@marketak/shared";
import { currency, isoDate, piastres, uuid } from "./primitives";

/** `quote_order_v1` → `totals`. */
export const quoteTotalsSchema = z
  .object({
    subtotal: piastres,
    discount_amount: piastres,
    voucher_discount: piastres,
    voucher_code: z.string().nullable(),
    delivery_fee: piastres,
    service_fee: piastres,
    rider_tip: piastres,
    total: piastres,
  })
  .passthrough();

/** `quote_order_v1` → `fee_breakdown`. The whole "why is delivery this much". */
export const quoteFeeBreakdownSchema = z
  .object({
    delivery_base_fee: piastres,
    vendor_count: z.number().int(),
    vendor_multiplier_bps: z.number().int(),
    distance_km: z.number(),
    free_radius_km: z.number(),
    per_km_fee: piastres,
    distance_charge: piastres,
    delivery_fee: piastres,
    service_fee: piastres,
    service_fee_enabled: z.boolean(),
    rider_tip: piastres,
    currency,
  })
  .passthrough();

/** `quote_order_v1` → `per_vendor[]`. Reporting split, not a charge. */
export const quoteVendorSplitSchema = z
  .object({
    vendor_id: uuid,
    subtotal: piastres,
    delivery_fee_share: piastres,
    service_fee_share: piastres,
    discount_share: piastres,
    commission_amount: piastres,
    vendor_net_payout: piastres,
    prep_estimate_minutes: z.number().int(),
    ready_estimate_minutes: z.number().int(),
    meets_minimum: z.boolean(),
    in_delivery_range: z.boolean(),
  })
  .passthrough();

export const quoteLimitsSchema = z
  .object({
    vendor_count: z.number().int(),
    max_vendors_per_order: z.number().int(),
  })
  .passthrough();

/**
 * `quote_order_v1` → `rejections[]`. The code is a CLOSED union on purpose:
 * it drives branches and the English copy at checkout, so a code the app
 * cannot classify throws into the mismatch path instead of guessing.
 * `message_ar` is Arabic only; English comes from `code` at the screen.
 */
export const quoteRejectionSchema = z
  .object({
    vendor_id: uuid.nullable(),
    code: z.enum(QUOTE_REJECTION.values),
    message_ar: z.string(),
  })
  .passthrough();

/** `quote_order_v1` return. Placeability is `rejections.length === 0`. */
export const quoteResultSchema = z
  .object({
    quote_id: uuid,
    expires_at: isoDate,
    fingerprint: z.string(),
    fee_breakdown: quoteFeeBreakdownSchema,
    totals: quoteTotalsSchema,
    per_vendor: z.array(quoteVendorSplitSchema).readonly(),
    limits: quoteLimitsSchema,
    rejections: z.array(quoteRejectionSchema).readonly(),
    warnings: z.array(z.unknown()).readonly(),
  })
  .passthrough();

/** `place_order_v1` return. */
export const placeOrderResultSchema = z
  .object({
    order_id: uuid,
    order_number: z.string(),
    sub_orders: z.array(uuid).readonly(),
    totals: quoteTotalsSchema,
  })
  .passthrough();
