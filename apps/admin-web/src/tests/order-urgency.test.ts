/**
 * `tests/order-urgency` - how urgent a live order is.
 *
 * `orderUrgency` decides whether the focus card gets a danger edge, a warning edge, or neither, so a wrong
 * answer either hides an overdue order or cries wolf on a healthy one. Both failures are expensive: one is an
 * operator not finding a breach, the other is the console losing the operator's trust in its own alarms.
 *
 * The threshold case is the interesting one, so the tests use instants either side of the window rather than
 * round numbers, and they pin the *reason* the window exists - a 20-minute promise is not a 2-minute promise.
 */

import { describe, expect, it } from "vitest";

import { orderUrgency, SOON_WINDOW_MS } from "../features/operations/OperationsSections.js";

const NOW = Date.parse("2026-10-06T12:00:00Z");

function at(offsetMinutes: number): string {
  return new Date(NOW + offsetMinutes * 60_000).toISOString();
}

describe("orderUrgency", () => {
  it("calls an order overdue once its promise has passed", () => {
    expect(orderUrgency({ status: "delivering", promised_delivery_at: at(-1) }, NOW)).toBe("overdue");
  });

  it("calls an order on time while its promise is comfortably ahead", () => {
    expect(orderUrgency({ status: "delivering", promised_delivery_at: at(45) }, NOW)).toBe("ontime");
  });

  it("calls an order due imminently 'soon' rather than comfortable", () => {
    // The window's whole purpose. An order 5 minutes from its promise is not the same as one with 45 - the
    // operator needs to see the difference while there is still time to act on it.
    expect(orderUrgency({ status: "delivering", promised_delivery_at: at(5) }, NOW)).toBe("soon");
  });

  it("treats exactly the window edge as still comfortable", () => {
    // One millisecond past the boundary flips it, so the boundary itself belongs to 'ontime'. The asymmetry is
    // deliberate: calling an order 'soon' a moment early is harmless; calling one 'ontime' a moment late is not.
    const justOutside = new Date(NOW + SOON_WINDOW_MS + 1).toISOString();
    expect(orderUrgency({ status: "delivering", promised_delivery_at: justOutside }, NOW)).toBe("ontime");
    expect(
      orderUrgency({ status: "delivering", promised_delivery_at: at(SOON_WINDOW_MS / 60_000) }, NOW),
    ).toBe("soon");
  });

  it("treats an order with no promise as soon, never as on time", () => {
    // Nobody has been given a deadline yet, so claiming it is comfortably on time would be reassuring fiction.
    // 'soon' is the honest reading: there is nothing to compare against, so watch it.
    expect(orderUrgency({ status: "preparing", promised_delivery_at: null }, NOW)).toBe("soon");
  });

  it("treats an overdue order as overdue whatever its status", () => {
    // Status does not modify urgency. A `preparing` order that has blown its promise is exactly as late as a
    // `delivering` one that has.
    for (const status of ["pending", "preparing", "picked_up", "delivering"] as const) {
      expect(orderUrgency({ status, promised_delivery_at: at(-30) }, NOW), status).toBe("overdue");
    }
  });
});
