/**
 * `lib/queries/operations` - the rows behind "what needs attention right now".
 *
 * ## Why this is not `get_admin_metrics_v1`
 *
 * The metrics RPC returns one jsonb of *counts*. A count tells an operator that four orders are late; it does
 * not tell them which four, since when, or for whom. An operations screen is a work queue, not a scoreboard -
 * the first thing an admin needs is a list they can act on, so this reads rows through RLS rather than
 * aggregating. Both are used together: the RPC for the day's totals, this for the work.
 *
 * ## Why plain PostgREST and not a new RPC
 *
 * `orders`, `vendors` and `riders` all carry an admin `SELECT` policy (`is_admin()`), so the console can read
 * them directly and no new server-side function is needed. Inventing an RPC here would have been faster to
 * write and impossible to justify: there is no aggregation this needs that RLS + a `limit` cannot do.
 *
 * ## What is deliberately absent
 *
 * **Unassigned riders.** The spec asks for it and the console cannot show it, because rider-to-order
 * assignment does not exist in the schema yet - `orders` has no rider column and `sub_orders` carries vendor
 * and settlement data only. Rather than render a plausible-looking zero, `AttentionSection` omits the row
 * entirely when there is no data source for it. A metric that is always zero is worse than a missing one,
 * because it reads as "all riders are assigned" rather than "we cannot tell".
 */

import { getSupabase } from "../supabase-client.js";
import { PostgrestQueryError } from "../postgrest.js";

import { DEMO_OPERATIONS, isDemoMode } from "../demo.js";

import {
  AWAITING_MERCHANT_STATUSES,
  TERMINAL_ORDER_STATUSES,
  type OrderStatus,
  type PaymentStatus,
} from "../order-status.js";

export type { OrderStatus, PaymentStatus } from "../order-status.js";

/** One in-flight order, as the operations board needs it. */
export interface LiveOrder {
  readonly id: string;
  readonly order_number: string;
  readonly status: OrderStatus;
  readonly payment_status: PaymentStatus;
  readonly payment_method: string;
  readonly total: number;
  readonly currency: string;
  readonly vendor_count: number;
  readonly placed_at: string;
  readonly promised_delivery_at: string | null;
}

/** Minutes past `promised_delivery_at`, or `null` when the order is not late and has no promise. */
export interface AttentionItem {
  readonly id: string;
  readonly order_number: string;
  readonly status: OrderStatus;
  readonly promised_delivery_at: string;
  /** Positive when late. Negative cannot occur: the row is only included once it is past due. */
  readonly minutes_overdue: number;
  readonly total: number;
  readonly currency: string;
}

export interface PendingVendor {
  readonly id: string;
  readonly name: string;
  readonly created_at: string;
}

/** A merchant waiting on approval, with how long it has been waiting. */
export interface PendingVendorRow extends PendingVendor {
  readonly waiting_minutes: number;
}

export interface OperationsSnapshot {
  readonly liveOrders: readonly LiveOrder[];
  readonly lateOrders: readonly AttentionItem[];
  readonly awaitingVendors: readonly AttentionItem[];
  readonly unpaidOrders: readonly AttentionItem[];
  readonly pendingVendors: readonly PendingVendorRow[];
}

const TERMINAL: readonly string[] = TERMINAL_ORDER_STATUSES;

/**
 * Rows an operator can act on, plus the board behind them.
 *
 * One round trip per concern rather than one query for everything, because the attention categories have
 * different predicates and combining them would need a `CASE` in a filter, which PostgREST cannot express
 * without shipping arbitrary SQL to the client. Five small reads are cheaper to reason about than one opaque
 * one, and `Promise.all` keeps it a single round-trip *cycle*.
 */
export async function getOperationsSnapshot(): Promise<OperationsSnapshot> {
  if (isDemoMode()) {
    return DEMO_OPERATIONS;
  }
  const db = getSupabase();

  const [live, late, awaiting, unpaid, vendors] = await Promise.all([
    db
      .from("orders")
      .select(
        "id, order_number, status, payment_status, payment_method, total, currency, vendor_count, placed_at, promised_delivery_at",
      )
      .not("status", "in", `(${TERMINAL.join(",")})`)
      // Newest first is wrong here. The order that has been in `pending` longest is the one that has been
      // waiting longest, and that is the row at the top of a queue.
      .order("placed_at", { ascending: true })
      .limit(25),

    // Late: past the promise the customer was given. `lte("now")` compares against the server clock, not the
    // operator's tablet, so a device with a skewed clock does not invent or hide an overdue order.
    db
      .from("orders")
      .select("id, order_number, status, promised_delivery_at, total, currency")
      .not("status", "in", `(${TERMINAL.join(",")})`)
      .not("promised_delivery_at", "is", null)
      .lte("promised_delivery_at", new Date().toISOString())
      .order("promised_delivery_at", { ascending: true })
      .limit(25),

    // Awaiting a vendor: `pending` and `partially_confirmed` are the statuses where a merchant has not yet
    // accepted. `preparing` means they did accept, so it is deliberately excluded - a long prep time is the
    // rider's problem, an unaccepted order is the merchant's.
    db
      .from("orders")
      .select("id, order_number, status, promised_delivery_at, total, currency")
      .in("status", [...AWAITING_MERCHANT_STATUSES])
      .not("promised_delivery_at", "is", null)
      .lte("promised_delivery_at", new Date().toISOString())
      .order("promised_delivery_at", { ascending: true })
      .limit(25),

    // Unpaid. The platform holds no customer money, so "unpaid" means cash that a rider has not yet
    // collected - it is an operational fact about a delivery in progress, not a failed card payment.
    db
      .from("orders")
      .select("id, order_number, status, promised_delivery_at, total, currency")
      .eq("payment_status", "unpaid")
      .not("status", "in", `(${TERMINAL.join(",")})`)
      .order("promised_delivery_at", { ascending: true, nullsFirst: false })
      .limit(25),

    db
      .from("vendors")
      .select("id, name, created_at")
      .eq("is_approved", false)
      .is("deleted_at", null)
      .order("created_at", { ascending: true })
      .limit(25),
  ]);

  const [liveError, lateError, awaitingError, unpaidError, vendorError] = [
    live.error,
    late.error,
    awaiting.error,
    unpaid.error,
    vendors.error,
  ];
  if (
    liveError !== null ||
    lateError !== null ||
    awaitingError !== null ||
    unpaidError !== null ||
    vendorError !== null
  ) {throw new PostgrestQueryError(liveError ?? lateError ?? awaitingError ?? unpaidError ?? vendorError);
  }

  const now = Date.now();

  return {
    liveOrders: live.data ?? [],
    lateOrders: toAttention(late.data, now),
    awaitingVendors: toAttention(awaiting.data, now),
    unpaidOrders: toAttention(unpaid.data, now),
    pendingVendors: ((vendors.data ?? []) as PendingVendor[]).map((row) => ({
      ...row,
      waiting_minutes: Math.max(0, Math.round((now - Date.parse(row.created_at)) / 60_000)),
    })),
  };
}

/**
 * PostgREST returns `null` for `promised_delivery_at` on a row the filter already excluded, because the two
 * predicates are applied independently. Those rows are dropped rather than rendered with a fabricated time.
 */
function toAttention(rows: unknown, now: number): readonly AttentionItem[] {
  const list = (rows ?? []) as ReadonlyArray<Omit<AttentionItem, "minutes_overdue"> & {
    readonly promised_delivery_at: string | null;
  }>;
  return list
    .filter((row): row is AttentionItem => row.promised_delivery_at !== null)
    .map((row) => ({
      ...row,
      minutes_overdue: Math.max(0, Math.round((now - Date.parse(row.promised_delivery_at)) / 60_000)),
    }));
}
