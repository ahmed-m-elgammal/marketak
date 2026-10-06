/**
 * `lib/order-status` - the order lifecycle, in one place.
 *
 * ## Why a module and not a type plus a local array
 *
 * The statuses are a `CHECK` constraint in the database, not an enum, so nothing in the type system ties the
 * console to them. That left two places that had to agree: the query that filters in-flight orders, and the
 * `orderStatus.*` translations, which are keyed dynamically as `` `orderStatus.${status}` `` because a
 * `StatusTag` takes a key rather than a label.
 *
 * With the list in two places, adding a status to one and not the other produced a card reading the literal
 * text `orderStatus.foo` - a rendering bug that `tsc` cannot see, because the key is a template string.
 * `tests/i18n-catalogue.test.ts` iterates this exact array and fails if a status has no translation, so the
 * two cannot drift again.
 *
 * ## Terminal statuses
 *
 * `TERMINAL_ORDER_STATUSES` is the complement of "still in flight", and is what every operations query filters
 * on. A status absent from both lists would render as an in-flight order forever, so the tests assert that
 * every status is classified.
 */

/** A status an order can never leave. */
export const TERMINAL_ORDER_STATUSES = [
  "delivered",
  "cancelled",
  "partially_cancelled",
] as const;

/** Every status the `orders.status` CHECK constraint permits, in lifecycle order. */
export const ORDER_STATUSES = [
  "pending",
  "partially_confirmed",
  "preparing",
  "ready",
  "picked_up",
  "delivering",
  "delivered",
  "partially_cancelled",
  "cancelled",
] as const;

export type OrderStatus = (typeof ORDER_STATUSES)[number];

/** A status an order is in right now, i.e. not terminal. */
export type InFlightStatus = Exclude<OrderStatus, (typeof TERMINAL_ORDER_STATUSES)[number]>;

/** Payment as stored on `orders.payment_status`, also a CHECK constraint. */
export const PAYMENT_STATUSES = ["unpaid", "collected", "failed", "refunded"] as const;

export type PaymentStatus = (typeof PAYMENT_STATUSES)[number];

/**
 * Whether an order is still moving.
 *
 * A function rather than a set membership test at each call site, because "is this order still in flight" is
 * the predicate behind every operations query and getting it wrong in one place shows a settled order as work.
 */
export function isInFlight(status: OrderStatus): boolean {
  return !TERMINAL_ORDER_STATUSES.includes(status as (typeof TERMINAL_ORDER_STATUSES)[number]);
}

/**
 * Statuses where a merchant has not accepted yet.
 *
 * `preparing` is excluded deliberately: it means the merchant *did* accept and is working on it, so a long
 * prep time is not an un-actioned order. This distinction is what separates "waiting on the shop" from
 * "waiting on the kitchen", and collapsing them sends an admin to the wrong person.
 */
export const AWAITING_MERCHANT_STATUSES: readonly OrderStatus[] = ["pending", "partially_confirmed"];