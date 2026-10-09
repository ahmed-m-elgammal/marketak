/**
 * Typed wrappers for the RPCs the mobile app calls.
 *
 * Each function is a thin translation from a domain-shaped argument to the database's exact
 * parameter names, verified against `pg_proc`. Keeping them here means a feature never sees a
 * `p_`-prefixed name, and a parameter rename on the server is a one-file change.
 *
 * No business logic lives in this file. Pricing, eligibility and the profile gate are all
 * enforced inside the transaction by the database, because a client that decides those can be
 * bypassed by anyone with the publishable key.
 */

import { callRpc } from "@/services/rpc/call";
import type {
  DeliveryType,
  Grouping,
  PlaceOrderResult,
  ProfileStatus,
  QuoteResult,
  RemoveCartItemResult,
  SelectedOption,
  UpsertCartItemResult,
  Uuid,
} from "@/services/rpc/dto";
import type { Piastres } from "@marketak/shared";

/* ── profile ─────────────────────────────────────────────────────────────── */

/**
 * Reads the caller's profile state and orders what is still missing.
 *
 * `can_order` here is the same gate `place_order_v1` enforces, so this is for deciding whether
 * to show onboarding — not an authorisation check. The database decides.
 */
export function fetchProfileStatus(): Promise<ProfileStatus | null> {
  return callRpc<ProfileStatus>("complete_profile_v1", {
    p_first_name: null,
    p_last_name: null,
    p_phone: null,
  });
}

/**
 * Completes the profile. The name and phone are collected after sign-in because the phone is a
 * profile field, never a credential (constitution 18).
 */
export function completeProfile(input: {
  readonly firstName: string;
  readonly lastName: string;
  readonly phone: string;
}): Promise<ProfileStatus | null> {
  return callRpc<ProfileStatus>("complete_profile_v1", {
    p_first_name: input.firstName,
    p_last_name: input.lastName,
    p_phone: input.phone,
  });
}

/* ── cart ────────────────────────────────────────────────────────────────── */

/**
 * Adds a line to the caller's active cart, or merges into an identical one.
 *
 * Sends only intent: the item id, the chosen options, the quantity. Never a price. The server
 * resolves the price and rejects a stale or retired item, which is what makes the client
 * untrusted by construction (constitution 3).
 */
export function upsertCartItem(input: {
  readonly menuItemId: Uuid;
  readonly selectedOptions: readonly SelectedOption[];
  readonly selectedSizeId: Uuid | null;
  readonly quantity: number;
  readonly specialInstructions: string | null;
}): Promise<UpsertCartItemResult | null> {
  return callRpc<UpsertCartItemResult>("upsert_cart_item_v1", {
    p_menu_item_id: input.menuItemId,
    p_selected_options: input.selectedOptions,
    p_selected_size_id: input.selectedSizeId,
    p_quantity: input.quantity,
    p_special_instructions: input.specialInstructions,
  });
}

/** Removes a line. The server refuses a line belonging to another caller. */
export function removeCartItem(cartItemId: Uuid): Promise<RemoveCartItemResult | null> {
  return callRpc<RemoveCartItemResult>("remove_cart_item_v1", {
    p_cart_item_id: cartItemId,
  });
}

/* ── quote and order ─────────────────────────────────────────────────────── */

/**
 * Prices the cart and parks the result on the cart for five minutes.
 *
 * Nothing here is a commitment. The quote is a snapshot with a fingerprint; `place_order_v1`
 * re-prices inside its own transaction and aborts with `PRICE_CHANGED` if anything moved. This
 * is the two-phase commit in constitution 2.
 */
export function quoteOrder(input: {
  readonly cartId: Uuid;
  readonly addressId: Uuid | null;
  readonly voucherCode: string | null;
  readonly riderTip: Piastres;
  readonly deliveryType: DeliveryType;
  readonly grouping: Grouping;
}): Promise<QuoteResult | null> {
  return callRpc<QuoteResult>("quote_order_v1", {
    p_cart_id: input.cartId,
    p_address_id: input.addressId,
    p_voucher_code: input.voucherCode,
    p_rider_tip: input.riderTip,
    p_delivery_type: input.deliveryType,
    p_grouping: input.grouping,
  });
}

/**
 * Places the order the shopper explicitly confirmed.
 *
 * `idempotencyKey` is required, not optional: a retry on a flaky connection must not create a
 * second order, and the server rejects a reused key with `IDEMPOTENCY_KEY_TAKEN`. The caller
 * generates it once per checkout attempt and reuses it across retries.
 *
 * `paymentMethod` is `cash` only in v1. The platform holds no customer money; the shopper pays
 * the rider directly.
 */
export function placeOrder(input: {
  readonly quoteId: Uuid;
  readonly idempotencyKey: string;
  readonly paymentChannel: string;
}): Promise<PlaceOrderResult | null> {
  return callRpc<PlaceOrderResult>("place_order_v1", {
    p_quote_id: input.quoteId,
    p_payment_method: "cash",
    p_idempotency_key: input.idempotencyKey,
    p_payment_channel: input.paymentChannel,
  });
}