/**
 * DTOs for the RPCs the mobile app calls.
 *
 * Every field here is transcribed from the live database signature, not from a spec. The shapes
 * were read from `pg_proc` with `pg_get_function_identity_arguments` and
 * `pg_get_function_result`, so a drift between this file and the database is a real failure
 * rather than a documentation lag.
 *
 * Money is always `Piastres` from `@marketak/shared` and never a float. Postgres stores it as
 * `integer`, and the only correct client representation is an integer too — a float would lose
 * precision the moment a total is summed.
 */

import type { Piastres } from "@marketak/shared";

export type Uuid = string;

/** `selected_options` as the database stores and the quote engine reads it: `[{choice_id}]`. */
export interface SelectedOption {
  readonly choice_id: Uuid;
}

export type PaymentMethod = "cash";
export type DeliveryType = "standard" | "express";
export type Grouping = "separate" | "together";

/** `users.preferred_language`. `ar` is the database default. */
export type Language = "ar" | "en";

/* ── cart ────────────────────────────────────────────────────────────────── */

/** Return of `upsert_cart_item_v1`. `is_new` distinguishes an insert from a merge. */
export interface UpsertCartItemResult {
  readonly cart_item_id: Uuid;
  readonly cart_id: Uuid;
  readonly quantity: number;
  readonly unit_price: Piastres;
  readonly is_new: boolean;
}

/** Return of `remove_cart_item_v1`. `remaining` is the line count after deletion. */
export interface RemoveCartItemResult {
  readonly cart_id: Uuid;
  readonly remaining: number;
}

/* ── quote and order ─────────────────────────────────────────────────────── */

export interface QuoteTotals {
  readonly subtotal: Piastres;
  readonly delivery_fee: Piastres;
  readonly discount: Piastres;
  readonly rider_tip: Piastres;
  readonly total: Piastres;
}

/**
 * Return of `quote_order_v1`.
 *
 * `rejections` and `warnings` are `jsonb`, so their contents are vendor-defined rather than
 * guaranteed. They are typed `unknown` on purpose: decoding a structure the database does not
 * promise would be a guess that fails silently in production.
 */
export interface QuoteResult {
  readonly quote_id: Uuid;
  readonly expires_at: string;
  readonly fingerprint: string;
  readonly fee_breakdown: unknown;
  readonly totals: QuoteTotals;
  readonly per_vendor: unknown;
  readonly limits: unknown;
  readonly rejections: unknown;
  readonly warnings: unknown;
}

/** Return of `place_order_v1`. A checkout produces one order and N sub_orders. */
export interface PlaceOrderResult {
  readonly order_id: Uuid;
  readonly order_number: string;
  readonly sub_orders: unknown;
  readonly totals: QuoteTotals;
}

/* ── profile ─────────────────────────────────────────────────────────────── */

/**
 * Return of `complete_profile_v1`.
 *
 * `can_order` is the constitution's gate: a user without `profile_completed_at` may browse but
 * cannot order. `missing` names what is still required, so the onboarding screen renders a
 * checklist instead of guessing.
 */
export interface ProfileStatus {
  readonly profile_completed_at: string | null;
  readonly has_phone: boolean;
  readonly has_address: boolean;
  readonly can_browse: boolean;
  readonly can_order: boolean;
  readonly missing: readonly string[];
}