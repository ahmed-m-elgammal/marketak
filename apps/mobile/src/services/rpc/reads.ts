/**
 * Direct table reads — the only `supabase.from()` in the app (with `call.ts`,
 * the two halves of architecture R4). Everything here is a SELECT the RLS
 * matrix already scopes; nothing here writes (all writes go through RPCs).
 *
 * Filter predicates mirror the §19 index shapes: partial indexes only serve
 * queries carrying their predicate, so `deleted_at IS NULL` / `is_active`
 * filters are load-bearing, not hygiene. Owner-scoped tables need no
 * `user_id` filter (RLS scopes to `auth.uid()`); the orders family DOES take
 * an explicit uid — those policies resolve a customer ∪ vendor ∪ rider union
 * and the customer history screen must narrow it in the `where` (§6).
 *
 * Retry: idempotent reads retry ONCE on transport failure (cause is a
 * `TypeError`) and never on business errors. Anything else, including an
 * abort, throws immediately — a cancelled request retrying itself is how a
 * dead screen keeps spinning.
 */
import {
  AppError,
  type Area,
  type Cart,
  type CartItem,
  type Cuisine,
  type Database,
  type DeliveryZone,
  type ItemOption,
  type MenuCategory,
  type MenuItem,
  type MenuItemSize,
  type OptionChoice,
  type Order,
  type OrderItem,
  type OrderStatusHistoryEntry,
  type PromoSlot,
  type RiderAssignment,
  type RiderPublic,
  type SubOrder,
  type Vendor,
  type Voucher,
} from "@marketak/shared";
import { getSupabaseClient } from "../supabase/client";
import { decodeWith, toBusinessError } from "./call";
import { cartItemSchema, cartSchema } from "./schemas/cart";
import {
  areaSchema,
  cuisineSchema,
  deliveryZoneSchema,
  itemOptionSchema,
  menuCategorySchema,
  menuItemSchema,
  menuItemSizeSchema,
  optionChoiceSchema,
  promoSlotSchema,
  voucherSchema,
  vendorSchema,
} from "./schemas/catalog";
import { riderPublicSchema } from "./schemas/identity";
import { assignmentSchema } from "./schemas/rider";
import {
  orderItemSchema,
  orderSchema,
  orderStatusHistoryEntrySchema,
  subOrderSchema,
} from "./schemas/orders";

export interface TableQueryResult<T> {
  data: readonly T[] | null;
  error: { message: string } | null;
}

export interface TableQuery<T> extends PromiseLike<TableQueryResult<T>> {
  eq(column: string, value: string | number | boolean): TableQuery<T>;
  is(column: string, value: null): TableQuery<T>;
  in(column: string, values: readonly (string | number)[]): TableQuery<T>;
  order(column: string, options?: { ascending?: boolean }): TableQuery<T>;
  limit(count: number): TableQuery<T>;
  maybeSingle(): PromiseLike<{ data: T | null; error: { message: string } | null }>;
}

export interface TableClient {
  from(table: Extract<keyof Database["public"]["Tables"], string>): {
    select(columns: string): TableQuery<unknown>;
  };
  from(table: Extract<keyof Database["public"]["Views"], string>): {
    select(columns: string): TableQuery<unknown>;
  };
}

export interface ReadDeps {
  readonly client?: TableClient;
}

function table(deps: ReadDeps | undefined): TableClient {
  const injected = deps?.client;
  if (injected !== undefined) return injected;
  // Overload-vs-overload assignability between the real client and this seam
  // explodes tsc (TS2589): the check is undecidable, not false. Routing
  // through `unknown` keeps the seam one line and reviewed; every table
  // string sent is asserted literally in reads.test.ts, which is the check
  // that actually guards typos.
  const backend: unknown = getSupabaseClient();
  return backend as TableClient;
}

function isTransport(error: unknown): boolean {
  return error instanceof AppError && error.code === null && error.cause instanceof TypeError;
}

async function readRows<T>(
  rpcName: string,
  schema: { parse(data: unknown): T },
  build: (client: TableClient) => PromiseLike<TableQueryResult<unknown>>,
  deps?: ReadDeps,
): Promise<T> {
  const run = async (): Promise<T> => {
    let outcome: TableQueryResult<unknown>;
    try {
      outcome = await build(table(deps));
    } catch (error) {
      throw new AppError("business", null, "", error);
    }
    if (outcome.error !== null) throw toBusinessError(outcome.error);
    return decodeWith(rpcName, schema, outcome.data);
  };
  try {
    return await run();
  } catch (error) {
    if (!isTransport(error)) throw error;
    return run();
  }
}

async function singleRow<T>(
  rpcName: string,
  schema: { parse(data: unknown): T },
  build: (client: TableClient) => PromiseLike<{ data: unknown; error: { message: string } | null }>,
  deps?: ReadDeps,
): Promise<T | null> {
  let outcome: { data: unknown; error: { message: string } | null };
  try {
    outcome = await build(table(deps));
  } catch (error) {
    throw new AppError("business", null, "", error);
  }
  if (outcome.error !== null) throw toBusinessError(outcome.error);
  if (outcome.data === null) return null;
  return decodeWith(rpcName, schema, outcome.data);
}

function rows<T>(schema: { parse(data: unknown): T }): { parse(data: unknown): readonly T[] } {
  return {
    parse(data: unknown): readonly T[] {
      if (!Array.isArray(data)) throw new Error(`expected array, got ${typeof data}`);
      return data.map((row) => schema.parse(row));
    },
  };
}

/* ── geography ────────────────────────────────────────────────────────────── */

export async function listAreas(deps?: ReadDeps): Promise<readonly Area[]> {
  return readRows(
    "areas.read",
    rows(areaSchema),
    (client) =>
      client
        .from("areas")
        .select("id,city_id,slug,name,name_ar,geohash_prefix,center_lat,center_lng,radius_km,is_active")
        .eq("is_active", true)
        .order("name"),
    deps,
  );
}

export async function listDeliveryZones(deps?: ReadDeps): Promise<readonly DeliveryZone[]> {
  return readRows(
    "delivery_zones.read",
    rows(deliveryZoneSchema),
    (client) =>
      client
        .from("delivery_zones")
        .select(
          "id,city_id,area_id,name,name_ar,currency,delivery_base_fee,free_radius_km,per_km_fee,max_vendors_per_order,min_order_value,max_distance_km,peak_hours,is_active",
        )
        .eq("is_active", true),
    deps,
  );
}

export async function listCuisines(deps?: ReadDeps): Promise<readonly Cuisine[]> {
  return readRows(
    "cuisines.read",
    rows(cuisineSchema),
    (client) =>
      client
        .from("cuisines")
        .select("id,code,name,name_ar,sort_order")
        .is("deleted_at", null)
        .order("sort_order"),
    deps,
  );
}

/* ── catalogue ────────────────────────────────────────────────────────────── */

export async function getVendor(vendorId: string, deps?: ReadDeps): Promise<Vendor | null> {
  return singleRow(
    "vendors.read",
    vendorSchema,
    (client) =>
      client
        .from("vendors")
        .select(
          "id,slug,name,name_ar,legal_name,brand_id,vertical_type,city_id,area_id,latitude,longitude,geohash_prefix,delivery_radius_km,is_open,is_busy,auto_open,is_approved,is_active,capacity_per_slot,reject_rate,delivery_fee_override,minimum_order_value,prep_time_minutes,prep_time_max_minutes,rating_avg,rating_count,menu_version,logo_path,description,description_ar,contact_phone,contact_landline",
        )
        .eq("id", vendorId)
        .eq("is_active", true)
        .eq("is_approved", true)
        .is("deleted_at", null)
        .maybeSingle(),
    deps,
  );
}

export async function listMenuCategories(vendorId: string, deps?: ReadDeps): Promise<readonly MenuCategory[]> {
  return readRows(
    "menu_categories.read",
    rows(menuCategorySchema),
    (client) =>
      client
        .from("menu_categories")
        .select("id,vendor_id,name,name_ar,description,display_order,is_available")
        .eq("vendor_id", vendorId)
        .is("deleted_at", null)
        .order("display_order"),
    deps,
  );
}

export async function listMenuItems(vendorId: string, deps?: ReadDeps): Promise<readonly MenuItem[]> {
  return readRows(
    "menu_items.read",
    rows(menuItemSchema),
    (client) =>
      client
        .from("menu_items")
        .select(
          "id,category_id,vendor_id,name,name_ar,description,description_ar,pricing_mode,base_price,is_available,stock_count,preparation_time_minutes,image_path,display_order,nutritional_info,allergens,ingredients,tags,calories,is_spicy,is_vegetarian,is_featured,is_new",
        )
        .eq("vendor_id", vendorId)
        .is("deleted_at", null)
        .order("display_order"),
    deps,
  );
}

export async function listMenuItemSizes(
  itemIds: readonly string[],
  deps?: ReadDeps,
): Promise<readonly MenuItemSize[]> {
  return readRows(
    "menu_item_sizes.read",
    rows(menuItemSizeSchema),
    (client) =>
      client
        .from("menu_item_sizes")
        .select("id,item_id,name,name_ar,price,is_default,is_available,calories,display_order")
        .in("item_id", itemIds)
        .is("deleted_at", null)
        .order("display_order"),
    deps,
  );
}

export async function listItemOptions(
  itemIds: readonly string[],
  deps?: ReadDeps,
): Promise<readonly ItemOption[]> {
  return readRows(
    "item_options.read",
    rows(itemOptionSchema),
    (client) =>
      client
        .from("item_options")
        .select("id,item_id,name,name_ar,is_required,min_selections,max_selections,display_order,is_available")
        .in("item_id", itemIds)
        .is("deleted_at", null)
        .order("display_order"),
    deps,
  );
}

export async function listOptionChoices(
  optionIds: readonly string[],
  deps?: ReadDeps,
): Promise<readonly OptionChoice[]> {
  return readRows(
    "option_choices.read",
    rows(optionChoiceSchema),
    (client) =>
      client
        .from("option_choices")
        .select("id,option_id,name,name_ar,price_modifier,is_default,is_available,stock_count,calories,display_order")
        .in("option_id", optionIds)
        .is("deleted_at", null)
        .order("display_order"),
    deps,
  );
}

/* ── cart ─────────────────────────────────────────────────────────────────── */

export async function myActiveCart(deps?: ReadDeps): Promise<Cart | null> {
  return singleRow(
    "carts.read",
    cartSchema,
    (client) =>
      client
        .from("carts")
        .select(
          "id,user_id,is_active,last_seen_at,quote_id,quote_fingerprint,quote_expires_at,quote_address_id,quote_voucher_code,quote_rider_tip,quote_delivery_type,quote_grouping,quote_snapshot",
        )
        .eq("is_active", true)
        .maybeSingle(),
    deps,
  );
}

export async function myCartItems(cartId: string, deps?: ReadDeps): Promise<readonly CartItem[]> {
  return readRows(
    "cart_items.read",
    rows(cartItemSchema),
    (client) =>
      client
        .from("cart_items")
        .select(
          "id,cart_id,vendor_id,menu_item_id,quantity,selected_options,special_instructions,display_snapshot,cached_price,cached_at,created_at,updated_at,selected_size_id,selected_size_name,selected_size_price",
        )
        .eq("cart_id", cartId),
    deps,
  );
}

/* ── orders ───────────────────────────────────────────────────────────────── */

export async function myOrders(userId: string, deps?: ReadDeps): Promise<readonly Order[]> {
  return readRows(
    "orders.read",
    rows(orderSchema),
    (client) =>
      client
        .from("orders")
        .select(
          "id,order_number,user_id,status,subtotal,delivery_base_fee,delivery_multiplier_bps,distance_km,delivery_fee,service_fee,discount_amount,voucher_code,voucher_discount,rider_tip,rider_pay_total,platform_revenue,total,currency,price_fingerprint,pricing_version,payment_method,payment_channel,payment_status,payment_collected_at,payment_collected_by,payment_reference,payment_proof_path,delivery_type,delivery_grouping,vendor_limit_applied,address_id,address_snapshot,delivery_latitude,delivery_longitude,delivery_geohash_prefix,area_id,is_contactless,access_note,scheduled_delivery_time,promised_delivery_at,eta_minutes,eta_maxutes,vendor_count,item_count,placed_at,confirmed_at,first_picked_up_at,completed_at,cancelled_at,cancellation_reason",
        )
        .eq("user_id", userId)
        .order("placed_at", { ascending: false }),
    deps,
  );
}

export async function orderSubOrders(orderId: string, deps?: ReadDeps): Promise<readonly SubOrder[]> {
  return readRows(
    "sub_orders.read",
    rows(subOrderSchema),
    (client) =>
      client
        .from("sub_orders")
        .select(
          "id,order_id,vendor_id,sequence,status,subtotal,delivery_fee_share,service_fee_share,discount_share,commission_amount,platform_fee_amount,vendor_net_payout,menu_version_snapshot,prep_estimate_minutes,prep_actual_minutes,ready_at,accepted_at,preparing_at,picked_up_at,delivered_at,cancelled_at,cancellation_reason,cancellation_actor,rejection_reason,settlement_status,payout_id",
        )
        .eq("order_id", orderId)
        .order("sequence"),
    deps,
  );
}

export async function orderItems(orderId: string, deps?: ReadDeps): Promise<readonly OrderItem[]> {
  return readRows(
    "order_items.read",
    rows(orderItemSchema),
    (client) =>
      client
        .from("order_items")
        .select(
          "id,sub_order_id,order_id,vendor_id,menu_item_id,item_name,item_name_ar,image_path,quantity,unit_price,total_price,selected_options,special_instructions,item_status,created_at,selected_size_id,selected_size_name,selected_size_price",
        )
        .eq("order_id", orderId),
    deps,
  );
}

export async function orderHistory(orderId: string, deps?: ReadDeps): Promise<readonly OrderStatusHistoryEntry[]> {
  return readRows(
    "order_status_history.read",
    rows(orderStatusHistoryEntrySchema),
    (client) =>
      client
        .from("order_status_history")
        .select("id,order_id,sub_order_id,from_status,to_status,actor_user_id,actor_role,reason,metadata,created_at")
        .eq("order_id", orderId)
        .order("created_at"),
    deps,
  );
}

/* ── growth ───────────────────────────────────────────────────────────────── */

export async function activeVouchers(deps?: ReadDeps): Promise<readonly Voucher[]> {
  return readRows(
    "vouchers.read",
    rows(voucherSchema),
    (client) =>
      client
        .from("vouchers")
        .select(
          "id,code,name,discount_type,discount_value,min_order_value,max_discount_cap,usage_limit_total,usage_limit_per_user,usage_count,applies_to_vendor_ids,vertical_type,first_order_only,valid_from,valid_until,is_active",
        )
        .eq("is_active", true),
    deps,
  );
}

export async function promoSlots(cityId: string, deps?: ReadDeps): Promise<readonly PromoSlot[]> {
  return readRows(
    "promo_slots.read",
    rows(promoSlotSchema),
    (client) =>
      client
        .from("promo_slots")
        .select(
          "id,city_id,slot_key,title,subtitle,image_path,target_type,target_id,starts_at,ends_at,sort_order,is_active",
        )
        .eq("city_id", cityId)
        .eq("is_active", true)
        .order("sort_order"),
    deps,
  );
}

/* ── rider surface ────────────────────────────────────────────────────────── */

export async function riderPublic(riderId: string, deps?: ReadDeps): Promise<RiderPublic | null> {
  return singleRow(
    "riders_public.read",
    riderPublicSchema,
    (client) =>
      client
        .from("riders_public")
        .select("id,first_name,last_name,phone_number,vehicle_type,vehicle_plate,rating_avg,rating_count")
        .eq("id", riderId)
        .maybeSingle(),
    deps,
  );
}

/**
 * The rider's assignments, scoped in the `where` — the other half of the
 * union trap. `delivery_assignments` resolves the same customer ∪ vendor ∪
 * rider union as `orders`; without `rider_id = <own id>` a rider screen
 * reads rows they merely touch as a customer.
 */
export async function riderAssignments(riderId: string, deps?: ReadDeps): Promise<readonly RiderAssignment[]> {
  return readRows(
    "delivery_assignments.read",
    rows(assignmentSchema),
    (client) =>
      client
        .from("delivery_assignments")
        .select(
          "id,order_id,sub_order_id,rider_id,status,stop_sequence,assigned_by,assigned_at,claimed_at,arrived_vendor_at,picked_up_at,arrived_at,delivered_at,distance_km,eta_minutes,rider_pay_base,rider_pay_distance,rider_pay_bonus,rider_pay_total,platform_revenue,collected_amount,collection_method,collection_channel,collection_reference,proof_path,signature_path",
        )
        .eq("rider_id", riderId)
        .order("assigned_at", { ascending: false }),
    deps,
  );
}
