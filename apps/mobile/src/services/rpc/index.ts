/**
 * The RPC barrel — the only importable entry of the data layer (R4).
 *
 * Features import from here and nowhere deeper: `call.ts` and `schemas/*`
 * are internals (enforced by `no-restricted-imports` + the cruiser rule).
 * There is no `dto/` folder in this layer — DTO shapes live once in
 * `@marketak/shared` (rule 11); this barrel only maps calls to them.
 *
 * Argument objects pass through untouched: optional args the caller omits
 * stay omitted, so server-side defaults apply (contract defaults table).
 * Writes never retry inside here — a retry reuses the caller's idempotency
 * key explicitly (F-04 retry policy).
 *
 * Three RPCs decode as `unknown` with an explicit TODO (mobile README §8):
 * they were never executed against the live database, and a guessed schema
 * is worse than an unknown. Each TODO names the RPC; removing one means
 * executing that RPC live and writing the schema from its real shape.
 */
import { z } from "zod";
import { AppError } from "@marketak/shared";
import type {
  Address,
  CancelOrderArgs,
  CompleteProfileArgs,
  DeleteAddressArgs,
  DeviceToken,
  FlagRow,
  GetFlagsArgs,
  PlaceOrderArgs,
  PlaceOrderResult,
  ProfileStatus,
  QuoteOrderArgs,
  QuoteResult,
  RegisterDeviceTokenArgs,
  RemoveCartItemArgs,
  RemoveCartItemResult,
  RiderProfile,
  SearchCatalogArgs,
  SetDefaultAddressArgs,
  UpsertAddressArgs,
  UpsertCartItemArgs,
  UpsertCartItemResult,
  UpdateProfilePatch,
  VendorFeedArgs,
} from "@marketak/shared";
import { callRpc, type RpcDeps } from "./call";
import { addressListSchema, addressSchema, deleteAddressSchema } from "./schemas/addresses";
import { flagListSchema } from "./schemas/flags";
import { profileStatusSchema } from "./schemas/profile";
import { deviceTokenListSchema } from "./schemas/push";
import { placeOrderResultSchema, quoteResultSchema } from "./schemas/quote";
import { removeCartItemResultSchema, upsertCartItemResultSchema } from "./schemas/cart";
import { riderProfileSchema } from "./schemas/rider";

/* ── profile ──────────────────────────────────────────────────────────────── */

export async function getProfileStatus(deps?: RpcDeps): Promise<ProfileStatus> {
  return callRpc("get_profile_status_v1", {}, profileStatusSchema, { ...deps, single: true });
}

export async function completeProfile(args: CompleteProfileArgs, deps?: RpcDeps): Promise<ProfileStatus> {
  return callRpc("complete_profile_v1", { ...args }, profileStatusSchema, { ...deps, single: true });
}

export async function updateProfile(patch: UpdateProfilePatch, deps?: RpcDeps): Promise<ProfileStatus> {
  return callRpc("update_profile_v1", { p_patch: { ...patch } }, profileStatusSchema, { ...deps, single: true });
}

/* ── addresses ────────────────────────────────────────────────────────────── */

export async function myAddresses(deps?: RpcDeps): Promise<readonly Address[]> {
  return callRpc("list_my_addresses_v1", {}, addressListSchema, deps);
}

export async function upsertAddress(args: UpsertAddressArgs, deps?: RpcDeps): Promise<Address> {
  return callRpc("upsert_my_address_v1", { p_patch: { ...args.p_patch }, p_id: args.p_id ?? null }, addressSchema, deps);
}

export async function setDefaultAddress(args: SetDefaultAddressArgs, deps?: RpcDeps): Promise<Address> {
  return callRpc("set_default_address_v1", { ...args }, addressSchema, deps);
}

export async function deleteAddress(args: DeleteAddressArgs, deps?: RpcDeps): Promise<boolean> {
  return callRpc("delete_address_v1", { ...args }, deleteAddressSchema, deps);
}

/* ── cart ─────────────────────────────────────────────────────────────────── */

export async function upsertCartItem(
  args: UpsertCartItemArgs,
  deps?: RpcDeps,
): Promise<UpsertCartItemResult> {
  return callRpc("upsert_cart_item_v1", { ...args }, upsertCartItemResultSchema, { ...deps, single: true });
}

export async function removeCartItem(
  args: RemoveCartItemArgs,
  deps?: RpcDeps,
): Promise<RemoveCartItemResult> {
  return callRpc("remove_cart_item_v1", { ...args }, removeCartItemResultSchema, { ...deps, single: true });
}

/* ── checkout ─────────────────────────────────────────────────────────────── */

export async function quoteOrder(args: QuoteOrderArgs, deps?: RpcDeps): Promise<QuoteResult> {
  return callRpc("quote_order_v1", { ...args }, quoteResultSchema, { ...deps, single: true });
}

export async function placeOrder(args: PlaceOrderArgs, deps?: RpcDeps): Promise<PlaceOrderResult> {
  return callRpc("place_order_v1", { ...args }, placeOrderResultSchema, { ...deps, single: true });
}

// TODO: decode with a Zod schema once executed against the live database (mobile README §8).
export async function cancelOrder(args: CancelOrderArgs, deps?: RpcDeps): Promise<unknown> {
  return callRpc("cancel_order_v1", { ...args }, z.unknown(), deps);
}

/* ── discovery ────────────────────────────────────────────────────────────── */

// TODO: decode with a Zod schema once executed against the live database (mobile README §8).
export async function vendorFeed(args: VendorFeedArgs, deps?: RpcDeps): Promise<unknown> {
  return callRpc("get_vendor_feed_v1", { ...args }, z.unknown(), deps);
}

// TODO: decode with a Zod schema once executed against the live database (mobile README §8).
export async function searchCatalog(args: SearchCatalogArgs, deps?: RpcDeps): Promise<unknown> {
  return callRpc("search_catalog_v1", { ...args }, z.unknown(), deps);
}

/* ── flags ────────────────────────────────────────────────────────────────── */

export async function getFlags(args: GetFlagsArgs, deps?: RpcDeps): Promise<readonly FlagRow[]> {
  return callRpc("get_flags_v1", { ...args }, flagListSchema, deps);
}

/* ── rider probe ──────────────────────────────────────────────────────────── */

/**
 * The role probe (mobile README §6): a row means rider, `NOT_A_RIDER` means
 * customer-only. The mapping lives here so the hook stays a cache lookup;
 * any other failure rethrows — a transport collapse is not "not a rider".
 */
export async function riderProfile(deps?: RpcDeps): Promise<RiderProfile | null> {
  try {
    return await callRpc("get_my_rider_profile_v1", {}, riderProfileSchema, { ...deps, single: true });
  } catch (error) {
    if (error instanceof AppError && error.code === "NOT_A_RIDER") return null;
    throw error;
  }
}

/* ── device ───────────────────────────────────────────────────────────────── */

export async function registerDeviceToken(
  args: RegisterDeviceTokenArgs,
  deps?: RpcDeps,
): Promise<readonly DeviceToken[]> {
  return callRpc("register_device_token_v1", { ...args }, deviceTokenListSchema, deps);
}
