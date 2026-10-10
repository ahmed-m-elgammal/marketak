import { z } from "zod";
import { PRICING_MODE, VERTICAL_TYPE, VOUCHER_DISCOUNT_TYPE } from "@marketak/shared";
import { currency, isoDate, nullablePiastres, piastres, uuid } from "./primitives";

/**
 * Catalogue and geography rows for direct reads. Pricing-affecting
 * vocabularies (`pricing_mode`, `vertical_type`, `discount_type`) are
 * closed unions: they choose price sources and theme registries, so an
 * unclassifiable value throws instead of pricing from the wrong column.
 */
export const vendorSchema = z
  .object({
    id: uuid,
    slug: z.string(),
    name: z.string(),
    name_ar: z.string(),
    legal_name: z.string().nullable(),
    brand_id: uuid.nullable(),
    vertical_type: z.enum(VERTICAL_TYPE.values),
    city_id: uuid,
    area_id: uuid,
    latitude: z.number(),
    longitude: z.number(),
    geohash_prefix: z.string(),
    delivery_radius_km: z.number(),
    is_open: z.boolean(),
    is_busy: z.boolean(),
    auto_open: z.boolean(),
    is_approved: z.boolean(),
    is_active: z.boolean(),
    capacity_per_slot: z.number().int().nullable(),
    reject_rate: z.number(),
    delivery_fee_override: nullablePiastres,
    minimum_order_value: piastres,
    prep_time_minutes: z.number().int(),
    prep_time_max_minutes: z.number().int(),
    rating_avg: z.number(),
    rating_count: z.number().int(),
    menu_version: z.number().int(),
    logo_path: z.string().nullable(),
    description: z.string().nullable(),
    description_ar: z.string().nullable(),
    contact_phone: z.string().nullable(),
    contact_landline: z.string().nullable(),
  })
  .passthrough();

export const menuCategorySchema = z
  .object({
    id: uuid,
    vendor_id: uuid,
    name: z.string(),
    name_ar: z.string().nullable(),
    description: z.string().nullable(),
    display_order: z.number().int(),
    is_available: z.boolean(),
  })
  .passthrough();

export const menuItemSchema = z
  .object({
    id: uuid,
    category_id: uuid,
    vendor_id: uuid,
    name: z.string(),
    name_ar: z.string().nullable(),
    description: z.string().nullable(),
    description_ar: z.string().nullable(),
    pricing_mode: z.enum(PRICING_MODE.values),
    base_price: nullablePiastres,
    is_available: z.boolean(),
    stock_count: z.number().int().nullable(),
    preparation_time_minutes: z.number().int().nullable(),
    image_path: z.string().nullable(),
    display_order: z.number().int(),
    nutritional_info: z.unknown(),
    allergens: z.unknown(),
    ingredients: z.unknown(),
    tags: z.array(z.string()).readonly(),
    calories: z.number().int().nullable(),
    is_spicy: z.boolean(),
    is_vegetarian: z.boolean(),
    is_featured: z.boolean(),
    is_new: z.boolean(),
  })
  .passthrough();

export const menuItemSizeSchema = z
  .object({
    id: uuid,
    item_id: uuid,
    name: z.string(),
    name_ar: z.string().nullable(),
    price: piastres,
    is_default: z.boolean(),
    is_available: z.boolean(),
    calories: z.number().int().nullable(),
    display_order: z.number().int(),
  })
  .passthrough();

export const itemOptionSchema = z
  .object({
    id: uuid,
    item_id: uuid,
    name: z.string(),
    name_ar: z.string().nullable(),
    is_required: z.boolean(),
    min_selections: z.number().int(),
    max_selections: z.number().int(),
    display_order: z.number().int(),
    is_available: z.boolean(),
  })
  .passthrough();

export const optionChoiceSchema = z
  .object({
    id: uuid,
    option_id: uuid,
    name: z.string(),
    name_ar: z.string().nullable(),
    price_modifier: z.number().int(),
    is_default: z.boolean(),
    is_available: z.boolean(),
    stock_count: z.number().int().nullable(),
    calories: z.number().int().nullable(),
    display_order: z.number().int(),
  })
  .passthrough();

export const areaSchema = z
  .object({
    id: uuid,
    city_id: uuid,
    slug: z.string(),
    name: z.string(),
    name_ar: z.string(),
    geohash_prefix: z.string(),
    center_lat: z.number(),
    center_lng: z.number(),
    radius_km: z.number(),
    is_active: z.boolean(),
  })
  .passthrough();

export const deliveryZoneSchema = z
  .object({
    id: uuid,
    city_id: uuid,
    area_id: uuid,
    name: z.string(),
    name_ar: z.string(),
    currency,
    delivery_base_fee: piastres,
    free_radius_km: z.number(),
    per_km_fee: piastres,
    max_vendors_per_order: z.number().int(),
    min_order_value: piastres,
    max_distance_km: z.number(),
    peak_hours: z.string().nullable(),
    is_active: z.boolean(),
  })
  .passthrough();

export const cuisineSchema = z
  .object({
    id: uuid,
    code: z.string(),
    name: z.string(),
    name_ar: z.string(),
    sort_order: z.number().int(),
  })
  .passthrough();

export const voucherSchema = z
  .object({
    id: uuid,
    code: z.string(),
    name: z.string().nullable(),
    discount_type: z.enum(VOUCHER_DISCOUNT_TYPE.values),
    discount_value: z.number().int(),
    min_order_value: piastres,
    max_discount_cap: nullablePiastres,
    usage_limit_total: z.number().int().nullable(),
    usage_limit_per_user: z.number().int().nullable(),
    usage_count: z.number().int(),
    applies_to_vendor_ids: z.array(uuid).readonly(),
    vertical_type: z.enum(VERTICAL_TYPE.values).nullable(),
    first_order_only: z.boolean(),
    valid_from: isoDate,
    valid_until: isoDate.nullable(),
    is_active: z.boolean(),
  })
  .passthrough();

export const promoSlotSchema = z
  .object({
    id: uuid,
    city_id: uuid,
    slot_key: z.string(),
    title: z.unknown(),
    subtitle: z.unknown(),
    image_path: z.string().nullable(),
    target_type: z.string().nullable(),
    target_id: z.string().nullable(),
    starts_at: isoDate.nullable(),
    ends_at: isoDate.nullable(),
  sort_order: z.number().int(),
  is_active: z.boolean(),
})
  .passthrough();
