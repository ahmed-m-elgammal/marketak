/**
 * `lib/queries/finance` - reconciliation, cash variance history, and feature flags.
 *
 * ## Every field here was read off the live function body
 *
 * `get_platform_float_v1`, `reconcile_day_v1` and `get_flags_v1` were read from `pg_proc` on 2026-10-06 rather
 * than inferred from the plan. `supabase.rpc` is typed `any` because the return shape lives in the database,
 * so each function narrows it into a named interface here, at the boundary. A `null` renders the empty state;
 * a throw renders the error state — and an operator told "something went wrong" about a schema change is being
 * told the wrong thing.
 *
 * ## `reconcile_day_v1` is not a read
 *
 * It takes `p_explanation` and writes it to `platform_float.variance_explanation`. So this module carries a
 * query and a mutation, and the naming keeps them apart on purpose: `getReconciliation` is a query,
 * `explainVariance` is a mutation. A screen that calls the mutating one from a render is then visibly wrong.
 *
 * ## Why no date is sent for "today"
 *
 * The RPCs default to "today in `cities.timezone`". Sending the browser's date instead would be wrong by up to
 * a day in Cairo, and would silently disagree with the number the RPC computed beside it.
 */

import { rpcRows } from "../postgrest.js";

/** One row of `reconcile_day_v1`, or `null` when the day has no settlement row. */
export interface Reconciliation {
  readonly business_date: string;
  readonly cash_expected: number;
  readonly cash_remitted: number;
  readonly variance: number;
  readonly external_cash_orders: number;
  readonly external_wallet_orders: number;
  readonly rider_payable: number;
  readonly vendor_payable: number;
  readonly in_flight_payouts: number;
  readonly open_payout_net: number;
  readonly balanced: boolean;
}

/** One row of `get_platform_float_v1`. */
export interface FloatDay {
  readonly business_date: string;
  readonly cash_expected: number;
  readonly cash_remitted: number;
  readonly variance: number;
  readonly delivery_fees: number;
  readonly rider_cuts: number;
  readonly commissions: number;
  readonly service_fees: number;
  readonly adjustments: number;
  readonly vendor_payable: number;
  readonly rider_payable: number;
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function asString(value: unknown, fallback: string): string {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === "boolean" ? value : fallback;
}

/** The narrow for a reconciliation row, shared by the read and the mutation so the two cannot drift. */
function toReconciliation(row: Record<string, unknown>): Reconciliation {
  return {
    business_date: asString(row["business_date"], ""),
    cash_expected: asNumber(row["cash_expected"]),
    cash_remitted: asNumber(row["cash_remitted"]),
    variance: asNumber(row["variance"]),
    external_cash_orders: asNumber(row["external_cash_orders"]),
    external_wallet_orders: asNumber(row["external_wallet_orders"]),
    rider_payable: asNumber(row["rider_payable"]),
    vendor_payable: asNumber(row["vendor_payable"]),
    in_flight_payouts: asNumber(row["in_flight_payouts"]),
    open_payout_net: asNumber(row["open_payout_net"]),
    balanced: asBoolean(row["balanced"]),
  };
}

/** Today's reconciliation. Sends no date, so the RPC applies its own city-timezone default. */
export async function getReconciliation(): Promise<Reconciliation | null> {
  const rows = await rpcRows("reconcile_day_v1");
  const first = rows[0];
  return first === undefined ? null : toReconciliation(first);
}

/**
 * Explains a day's variance. **This is a mutation**, not a read.
 *
 * `p_explanation` is required by the UI, because a variance explanation that explains nothing looks resolved
 * and is worse than an unexplained variance.
 *
 * Re-explaining is refused by the RPC (`VARIANCE_ALREADY_EXPLAINED`), which is correct: an explanation is a
 * justification, and silently overwriting one destroys the record of what was originally claimed. The dialog
 * says so rather than letting an operator be refused after the fact.
 */
export async function explainVariance(
  date: string,
  explanation: string,
): Promise<Reconciliation | null> {
  const rows = await rpcRows("reconcile_day_v1", { p_date: date, p_explanation: explanation });
  const first = rows[0];
  return first === undefined ? null : toReconciliation(first);
}

/**
 * Cash variance over a window, oldest first.
 *
 * `p_to` is omitted so the RPC defaults to today in the city timezone. `p_from` is required by the signature,
 * so a caller has to choose the window deliberately rather than accidentally receiving one row.
 */
export async function getFloatHistory(fromDate: string): Promise<readonly FloatDay[]> {
  const rows = await rpcRows("get_platform_float_v1", { p_from: fromDate });
  return rows.map((row) => ({
    business_date: asString(row["business_date"], ""),
    cash_expected: asNumber(row["cash_expected"]),
    cash_remitted: asNumber(row["cash_remitted"]),
    variance: asNumber(row["variance"]),
    delivery_fees: asNumber(row["delivery_fees"]),
    rider_cuts: asNumber(row["rider_cuts"]),
    commissions: asNumber(row["commissions"]),
    service_fees: asNumber(row["service_fees"]),
    adjustments: asNumber(row["adjustments"]),
    vendor_payable: asNumber(row["vendor_payable"]),
    rider_payable: asNumber(row["rider_payable"]),
  }));
}

/** One feature flag. `value` is the targeting document, read verbatim. */
export interface Flag {
  readonly flag_key: string;
  readonly value: unknown;
}

/** Feature flags, read through `get_flags_v1`. No arguments, so every flag the app can see. */
export async function getFlags(): Promise<readonly Flag[]> {
  const rows = await rpcRows("get_flags_v1");
  return rows.map((row) => ({
    flag_key: asString(row["flag_key"], ""),
    value: row["value"],
  }));
}