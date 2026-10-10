import { z } from "zod";
import { isoDate, nullablePiastres, piastres, uuid } from "./primitives";

/** `upsert_cart_item_v1`. */
export const upsertCartItemResultSchema = z
  .object({
    cart_item_id: uuid,
    cart_id: uuid,
    quantity: z.number().int(),
    unit_price: piastres,
    is_new: z.boolean(),
  })
  .passthrough();

/** `remove_cart_item_v1`. `remaining` is the line count left, not a boolean. */
export const removeCartItemResultSchema = z
  .object({
    cart_id: uuid,
    remaining: z.number().int(),
  })
  .passthrough();

/** `cart_items` row. Render lines from `display_snapshot`, never from a menu join. */
export const cartItemSchema = z
  .object({
    id: uuid,
    cart_id: uuid,
    vendor_id: uuid,
    menu_item_id: uuid,
    quantity: z.number().int(),
    selected_options: z.array(z.looseObject({ choice_id: uuid })).readonly(),
    special_instructions: z.string().nullable(),
    display_snapshot: z.unknown(),
    cached_price: nullablePiastres,
    cached_at: isoDate.nullable(),
    created_at: isoDate,
    updated_at: isoDate,
    selected_size_id: uuid.nullable(),
    selected_size_name: z.string().nullable(),
    selected_size_price: nullablePiastres,
  })
  .passthrough();

/**
 * `carts` row. The `quote_*` columns are the server's memo: readable to
 * restore a checkout screen, never writable.
 */
export const cartSchema = z
  .object({
    id: uuid,
    user_id: uuid,
    is_active: z.boolean(),
    last_seen_at: isoDate,
    quote_id: uuid.nullable(),
    quote_fingerprint: z.string().nullable(),
    quote_expires_at: isoDate.nullable(),
    quote_address_id: uuid.nullable(),
    quote_voucher_code: z.string().nullable(),
    quote_rider_tip: z.number().int().nullable(),
    quote_delivery_type: z.string().nullable(),
    quote_grouping: z.string().nullable(),
    quote_snapshot: z.unknown(),
  })
  .passthrough();
