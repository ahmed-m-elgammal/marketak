/**
 * `tests/order-status` - the order lifecycle.
 *
 * The statuses come from a `CHECK` constraint in the database, which TypeScript cannot see. That is the whole
 * reason this file exists: without it, adding a status to the query layer and not to the translations produces
 * a card reading the literal text `orderStatus.foo`, and adding one to neither produces an order that renders
 * as in-flight forever.
 */

import { describe, expect, it } from "vitest";

import {
  AWAITING_MERCHANT_STATUSES,
  ORDER_STATUSES,
  PAYMENT_STATUSES,
  TERMINAL_ORDER_STATUSES,
  isInFlight,
} from "../lib/order-status.js";

/** Mirrors the `CHECK` constraint read from `pg_constraint` on the live project. */
const DATABASE_STATUSES = [
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

const DATABASE_PAYMENT_STATUSES = ["unpaid", "collected", "failed", "refunded"] as const;

describe("order status", () => {
  it("matches the database CHECK constraint exactly", () => {
    // Either direction of drift is a bug: a status the console knows but the database rejects, or one the
    // database accepts that renders as a blank label.
    expect([...ORDER_STATUSES].sort()).toEqual([...DATABASE_STATUSES].sort());
    expect([...PAYMENT_STATUSES].sort()).toEqual([...DATABASE_PAYMENT_STATUSES].sort());
  });

  it("has no duplicate statuses", () => {
    expect(new Set(ORDER_STATUSES).size).toBe(ORDER_STATUSES.length);
    expect(new Set(PAYMENT_STATUSES).size).toBe(PAYMENT_STATUSES.length);
  });

  it("classifies every status as terminal or in flight", () => {
    // A status in neither list would appear on the operations board forever. The assertion is over the union
    // rather than a count, so adding a status without classifying it fails here by name.
    const classified = new Set<string>([...TERMINAL_ORDER_STATUSES, ...ORDER_STATUSES.filter((s) => isInFlight(s))]);
    for (const status of ORDER_STATUSES) {
      expect(classified.has(status), `${status} is neither terminal nor in flight`).toBe(true);
    }
  });

  it("treats only the three settled statuses as terminal", () => {
    expect(isInFlight("delivered")).toBe(false);
    expect(isInFlight("cancelled")).toBe(false);
    expect(isInFlight("partially_cancelled")).toBe(false);
    expect(isInFlight("picked_up")).toBe(true);
    expect(isInFlight("pending")).toBe(true);
  });

  it("treats preparing as in flight, not as awaiting a merchant", () => {
    // The distinction this encodes: `preparing` means the merchant *did* accept and is working on it. Counting
    // it as unaccepted sends an admin to a shop that has already confirmed.
    expect(AWAITING_MERCHANT_STATUSES).toContain("pending");
    expect(AWAITING_MERCHANT_STATUSES).toContain("partially_confirmed");
    expect(AWAITING_MERCHANT_STATUSES).not.toContain("preparing");
  });

  it("keeps every awaiting-merchant status a real status", () => {
    for (const status of AWAITING_MERCHANT_STATUSES) {
      expect(ORDER_STATUSES).toContain(status);
    }
  });
});