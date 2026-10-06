/**
 * `lib/demo` - a local fixture mode for looking at the console without a database.
 *
 * ## Why this exists
 *
 * Every screen renders behind an admin session and reads live tables through RLS. Without a session, the only
 * way to see a screen is to sign in with Google as a real admin - which means the design review of a layout
 * happens *after* authentication, and a layout is exactly the thing you want to iterate on. Worse: against a
 * database holding one order and near-zero totals, every screen renders empty, and "it looks empty" and "it is
 * empty" are indistinguishable in a screenshot.
 *
 * So: fixtures, shaped exactly like the real return types, so a design can be judged under load.
 *
 * ## What it must never do
 *
 * **Reach a production build.** `isDemoMode` is false unless the flag is exactly `"1"`, and Vite inlines env
 * values at build time - so a production bundle carries the answer, not the variable name.
 * `scripts/check-no-demo-in-build.mjs` greps `dist/` for the string to prove it.
 *
 * **Change API behaviour.** This module is only ever consulted from the three places that start a request:
 * `getSession`, `signOut`, and the query functions. Nothing here alters a request shape, an RPC name, or an
 * argument.
 */

import { DEMO_ENV_KEY, isDemoMode } from "./demo-mode.js";
import type { MetricsPayload } from "./queries/metrics.js";
import type { LiveOrder, OperationsSnapshot, PendingVendorRow } from "./queries/operations.js";
import type { VendorRow } from "./queries/vendors.js";

export { DEMO_ENV_KEY, isDemoMode };

const HOUR = 3_600_000;

/**
 * Peak service, 14:36 on a Tuesday, Cairo time (UTC+2).
 *
 * Shaped by the real interface rather than by what would look good: `avg_signed_error_min` is signed and
 * positive, `float_variance` is deliberately non-zero so the variance row is actually exercised, and `open`
 * is 19 while six orders are listed - the count comes from the server, the board from a capped query.
 */
export const DEMO_METRICS: MetricsPayload = {
  business_date: "2026-10-06",
  timezone: "Africa/Cairo",
  funnel: {
    signups: 31,
    logins: 128,
    searches_with_clicks: 264,
    zero_result_rate_bps: 410,
  },
  orders: {
    placed: 214,
    delivered: 186,
    cancelled: 9,
    open: 19,
    completion_rate_bps: 9180,
  },
  revenue: {
    currency: "EGP",
    rider_tips: 78_000,
    cash_expected: 1_245_000,
    cash_remitted: 1_210_000,
    // Negative: riders banked less than the day required. Non-zero on purpose.
    float_variance: -35_000,
  },
  cancellation: {
    order_rate_bps: 420,
    sub_orders_cancelled: 11,
    sub_orders_rejected: 3,
  },
  eta_accuracy: {
    on_time_rate_bps: 9100,
    // Positive means arriving late. Signed, because dropping the sign would print "+4 min late" and "4 min
    // early" identically.
    avg_signed_error_min: 3,
    p50_signed_error_min: 2,
    p90_signed_error_min: 11,
  },
  vendors: {
    active_approved: 24,
    open_now: 11,
    paused: 2,
    pending_approval: 3,
  },
  riders: {
    active: 18,
    online_now: 12,
    verified_online: 9,
  },
};

/** Local Cairo wall clock to an ISO instant. `at(14, 4)` is 14:04 in Cairo. */
function at(hours: number, minutes: number): string {
  return new Date(Date.UTC(2026, 9, 6, hours - 2, minutes)).toISOString();
}

export const DEMO_LIVE_ORDERS: readonly LiveOrder[] = [
  {
    id: "11111111-1111-4111-8111-111111111111",
    order_number: "#1042",
    status: "delivering",
    payment_status: "unpaid",
    payment_method: "cash",
    total: 18_400,
    currency: "EGP",
    vendor_count: 3,
    placed_at: at(13, 41),
    promised_delivery_at: at(14, 4),
  },
  {
    id: "22222222-2222-4222-8222-222222222222",
    order_number: "#1051",
    status: "preparing",
    payment_status: "unpaid",
    payment_method: "cash",
    total: 9_650,
    currency: "EGP",
    vendor_count: 1,
    placed_at: at(13, 58),
    promised_delivery_at: at(14, 21),
  },
  {
    id: "33333333-3333-4333-8333-333333333333",
    order_number: "#1055",
    status: "pending",
    payment_status: "unpaid",
    payment_method: "wallet",
    total: 24_000,
    currency: "EGP",
    vendor_count: 2,
    placed_at: at(14, 6),
    promised_delivery_at: at(15, 20),
  },
  {
    id: "44444444-4444-4444-8444-444444444444",
    order_number: "#1057",
    status: "ready",
    payment_status: "unpaid",
    payment_method: "cash",
    total: 15_800,
    currency: "EGP",
    vendor_count: 1,
    placed_at: at(14, 11),
    promised_delivery_at: at(15, 35),
  },
  {
    id: "55555555-5555-4555-8555-555555555555",
    order_number: "#1058",
    status: "picked_up",
    payment_status: "collected",
    payment_method: "cash",
    total: 31_275,
    currency: "EGP",
    vendor_count: 4,
    placed_at: at(14, 13),
    promised_delivery_at: at(15, 48),
  },
  {
    id: "66666666-6666-4666-8666-666666666666",
    order_number: "#1059",
    status: "delivering",
    payment_status: "collected",
    payment_method: "wallet",
    total: 12_900,
    currency: "EGP",
    vendor_count: 2,
    placed_at: at(14, 18),
    promised_delivery_at: at(16, 2),
  },
];

export const DEMO_PENDING_VENDORS: readonly PendingVendorRow[] = [
  { id: "a1a1a1a1-a1a1-41a1-8a1a-a1a1a1a1a1a1", name: "Atef Grill House", created_at: at(12, 40), waiting_minutes: 116 },
  { id: "b2b2b2b2-b2b2-42b2-8b2b-b2b2b2b2b2b2", name: "El Nil Grocery", created_at: at(13, 55), waiting_minutes: 41 },
  { id: "c3c3c3c3-c3c3-43c3-8c3c-c3c3c3c3c3c3", name: "Cairo Pharmacy", created_at: at(14, 20), waiting_minutes: 16 },
];

export const DEMO_OPERATIONS: OperationsSnapshot = {
  liveOrders: DEMO_LIVE_ORDERS,
  lateOrders: [
    attentionAt(0, "#1042", "delivering", at(14, 4), 32, 18_400),
    attentionAt(1, "#1051", "preparing", at(14, 21), 15, 9_650),
  ],
  awaitingVendors: [attentionAt(2, "#1055", "pending", at(15, 20), 0, 24_000)],
  unpaidOrders: [
    attentionAt(3, "#1057", "ready", at(15, 35), 0, 15_800),
    attentionAt(5, "#1059", "delivering", at(16, 2), 0, 12_900),
  ],
  pendingVendors: DEMO_PENDING_VENDORS,
};

/** An attention row for the order at `index` of `DEMO_LIVE_ORDERS`. */
function attentionAt(
  index: number,
  orderNumber: string,
  status: "delivering" | "preparing" | "pending" | "ready",
  promised: string,
  minutesOverdue: number,
  total: number,
): {
  readonly id: string;
  readonly order_number: string;
  readonly status: "delivering" | "preparing" | "pending" | "ready";
  readonly promised_delivery_at: string;
  readonly minutes_overdue: number;
  readonly total: number;
  readonly currency: string;
} {
  return {
    id: DEMO_LIVE_ORDERS[index]?.id ?? "",
    order_number: orderNumber,
    status,
    promised_delivery_at: promised,
    minutes_overdue: minutesOverdue,
    total,
    currency: "EGP",
  };
}

/**
 * The session `getSession` returns in demo mode.
 *
 * Structurally a real `Session`: the auth machine reads `session.user.email` and `.id`, so a partial object
 * would throw inside `resolveAuthStatus` rather than render a screen.
 */
export const DEMO_SESSION = {
  access_token: "demo",
  token_type: "bearer",
  expires_in: 3600,
  expires_at: Math.floor(Date.now() / 1000) + HOUR,
  refresh_token: "demo",
  user: {
    id: "00000000-0000-4000-8000-000000000001",
    aud: "",
    role: "authenticated",
    email: "ops.demo@marketak.eg",
    email_confirmed_at: at(0, 0),
    phone: "",
    confirmed_at: at(0, 0),
    last_sign_in_at: at(13, 30),
    app_metadata: {},
    user_metadata: {},
    identities: [],
    created_at: at(0, 0),
    updated_at: at(0, 0),
  },
} as const;

/**
 * Merchants for the list screen.
 *
 * The three rows cover the states worth designing against: approved and open, approved and open in a second
 * vertical, and unapproved and closed - which is the row that has to be readable at a glance. `name_ar` is real
 * Arabic rather than a transliteration, because a fixture with Latin in the Arabic slot hides exactly the RTL
 * bug it is meant to expose.
 */
export const DEMO_VENDORS: readonly VendorRow[] = [
  {
    id: "11111111-1111-4111-8111-111111111111",
    name: "Atef Grill House",
    name_ar: "مشويات الأتاف",
    slug: "atef-grill",
    vertical_type: "food",
    city_id: "3ded57c7-3111-46cf-ae77-3c1abea61d9e",
    is_open: true,
    is_approved: true,
    is_active: true,
    prep_time_minutes: 15,
    rating_avg: 4.6,
    rating_count: 312,
    created_at: at(4, 12),
    deleted_at: null,
  },
  {
    id: "d4d4d4d4-d4d4-44d4-8d4d-d4d4d4d4d4d4",
    name: "El Nil Grocery",
    name_ar: "بقالة النيل",
    slug: "el-nil-grocery",
    vertical_type: "grocery",
    city_id: "3ded57c7-3111-46cf-ae77-3c1abea61d9e",
    is_open: true,
    is_approved: true,
    is_active: true,
    prep_time_minutes: 10,
    rating_avg: 4.2,
    rating_count: 88,
    created_at: at(4, 40),
    deleted_at: null,
  },
  {
    id: "e5e5e5e5-e5e5-45e5-8e5e-e5e5e5e5e5e5",
    name: "Cairo Pharmacy",
    name_ar: "صيدلية القاهرة",
    slug: "cairo-pharmacy",
    vertical_type: "pharmacy",
    city_id: "3ded57c7-3111-46cf-ae77-3c1abea61d9e",
    is_open: false,
    is_approved: false,
    is_active: true,
    prep_time_minutes: 8,
    rating_avg: 0,
    rating_count: 0,
    created_at: at(11, 5),
    deleted_at: null,
  },
];

/**
 * `total` is 24 rather than 3 on purpose: the pager reads "1-20 of 24", and a fixture whose total equals its
 * own row count makes pagination look broken when it is only untested.
 */
export const DEMO_VENDOR_LIST = { rows: DEMO_VENDORS, total: 24 } as const;
