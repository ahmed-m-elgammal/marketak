/**
 * Incoming-notification routing (specs-mobile §8a).
 *
 * The Worker decides who gets what (7 routing rows, live-verified); this
 * module decides where a received push lands in the app. Keys route by
 * (template, registration role): a rider key on a customer registration —
 * or any vendor key, the merchant console being out of scope — routes
 * nowhere (`null`), and unknown keys route nowhere. Routes carry ids only:
 * pharmacy payloads are sealed copy (§14), so there is deliberately no
 * field here that could hold an item name.
 */
import type { AppRole } from "@marketak/shared";

export interface IncomingNotification {
  readonly templateKey: string;
  readonly orderId?: string;
}

const CUSTOMER_ORDER_KEYS = [
  "order.placed",
  "order.vendor_accepted",
  "order.vendor_rejected",
  "order.preparing",
  "order.ready",
  "order.arriving",
  "order.picked_up",
  "order.delivered",
  "order.cancelled",
] as const;

const RIDER_KEYS = [
  "rider.order_assigned",
  "rider.new_offer",
  "rider.customer_cancelled",
  "rider.cash_limit_warning",
  "rider.payout_paid",
] as const;

export function routeForNotification(notification: IncomingNotification, role: AppRole): string | null {
  const key = notification.templateKey;
  if ((CUSTOMER_ORDER_KEYS as readonly string[]).includes(key)) {
    if (role !== "customer") return null;
    return notification.orderId === undefined ? "/(customer)/orders" : `/(customer)/orders/${notification.orderId}`;
  }
  if ((RIDER_KEYS as readonly string[]).includes(key)) {
    if (role !== "rider") return null;
    return "/(rider)/offers";
  }
  if (key === "voucher.available") {
    if (role !== "customer") return null;
    return "/(customer)/home";
  }
  return null;
}
