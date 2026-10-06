/**
 * `tests/operations-board` - the attention queue's ordering policy.
 *
 * `buildAttention` decides what an admin sees first on the console's main screen, so its ordering is business
 * logic and gets tested as such. It is a pure function precisely so this needs no React, no i18next and no
 * queries.
 *
 * The `t` stub returns the key, so an assertion reads as the translation key rather than a sentence. That is
 * deliberate: it asserts *which* string is used, which is what could regress.
 */

import { describe, expect, it } from "vitest";

import {
  buildAttention,
  type AttentionEntry,
  type Translate,
} from "../features/operations/OperationsSections.js";
import type { AttentionItem, PendingVendorRow } from "../lib/queries/operations.js";

const t: Translate = ((key: string) => key) as Translate;

/** Formats piastres the way the dashboard does, so amounts stay readable in the output. */
const format = (amount: number): string => (amount / 100).toFixed(2);

const NO_VARIANCE = {
  hasVariance: false,
  amount: 0,
  currency: "EGP",
  date: "2026-10-06",
} as const;

function lateOrder(id: string, minutes: number): AttentionItem {
  return {
    id,
    order_number: `#${id}`,
    status: "delivering",
    promised_delivery_at: "2026-10-06T10:00:00Z",
    minutes_overdue: minutes,
    total: 12_345,
    currency: "EGP",
  };
}

function awaitingOrder(id: string, minutes: number): AttentionItem {
  return { ...lateOrder(id, minutes), status: "pending" };
}

function unpaidOrder(id: string): AttentionItem {
  return { ...lateOrder(id, 0), status: "picked_up" };
}

function vendor(id: string, minutes: number): PendingVendorRow {
  return { id, name: `Shop ${id}`, created_at: "2026-10-06T09:00:00Z", waiting_minutes: minutes };
}

describe("buildAttention", () => {
  it("returns nothing when nothing is wrong", () => {
    const entries = buildAttention({
      variance: NO_VARIANCE,
      late: [],
      awaiting: [],
      unpaid: [],
      pendingVendors: [],
      t,
      format,
    });
    expect(entries).toEqual([]);
  });

  it("puts cash variance first, ahead of every operational row", () => {
    // The ordering is the policy: a variance is money the platform cannot account for, and it is the only item
    // here that will not resolve itself.
    const entries = buildAttention({
      variance: { hasVariance: true, amount: -5_000, currency: "EGP", date: "2026-10-06" },
      late: [lateOrder("a", 40)],
      awaiting: [awaitingOrder("b", 20)],
      unpaid: [unpaidOrder("c")],
      pendingVendors: [vendor("d", 90)],
      t,
      format,
    });

    expect(entries[0]?.key).toBe("variance");
    expect(entries[0]?.tone).toBe("danger");
  });

  it("orders late orders before unaccepted orders, which before uncollected cash", () => {
    const entries = buildAttention({
      variance: NO_VARIANCE,
      late: [lateOrder("a", 40)],
      awaiting: [awaitingOrder("b", 20)],
      unpaid: [unpaidOrder("c")],
      pendingVendors: [],
      t,
      format,
    });

    expect(entries.map((entry) => entry.key)).toEqual(["late-a", "awaiting-b", "unpaid-c"]);
  });

  it("sorts vendors by how long they have waited", () => {
    const entries = buildAttention({
      variance: NO_VARIANCE,
      late: [],
      awaiting: [],
      unpaid: [],
      pendingVendors: [vendor("new", 5), vendor("old", 200)],
      t,
      format,
    });

    // Longest-waiting first. A vendor approval queue read newest-first sends an admin to the wrong person.
    expect(entries.map((entry) => entry.key)).toEqual(["vendor-old", "vendor-new"]);
  });

  it("marks late orders danger and uncollected cash info", () => {
    // Cash not yet collected is normal on a cash-on-delivery order in flight; it is not an alarm. Toning it
    // `danger` would train the operator to ignore the section that has earned the right to shout.
    const entries = buildAttention({
      variance: NO_VARIANCE,
      late: [lateOrder("a", 40)],
      awaiting: [],
      unpaid: [unpaidOrder("c")],
      pendingVendors: [],
      t,
      format,
    });

    expect(entries.find((e) => e.key === "late-a")?.tone).toBe("danger");
    expect(entries.find((e) => e.key === "unpaid-c")?.tone).toBe("info");
    expect(entries.find((e) => e.key === "awaiting-b")).toBeUndefined();
  });

  it("gives every entry a distinct key, since React keys come from it", () => {
    // One order, three categories: late, awaiting a merchant, and cash not collected all apply to the same
    // order number. A duplicate key makes React reuse one row for another, so the 40-minute-late row renders
    // with the 2-minute one's text. Two late rows for one id cannot happen - the id is the primary key - so
    // the fixture uses one late entry and one of each other category.
    const entries = buildAttention({
      variance: { hasVariance: true, amount: -5_000, currency: "EGP", date: "2026-10-06" },
      late: [lateOrder("same", 40)],
      awaiting: [awaitingOrder("same", 20)],
      unpaid: [unpaidOrder("same")],
      pendingVendors: [vendor("same", 10)],
      t,
      format,
    });

    const keys = entries.map((entry) => entry.key);
    expect(keys).toHaveLength(5);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("points every entry at a route that exists", () => {
    const entries: readonly AttentionEntry[] = buildAttention({
      variance: { hasVariance: true, amount: -5_000, currency: "EGP", date: "2026-10-06" },
      late: [lateOrder("a", 40)],
      awaiting: [awaitingOrder("b", 20)],
      unpaid: [unpaidOrder("c")],
      pendingVendors: [vendor("d", 90)],
      t,
      format,
    });

    // `/orders` and `/merchants` are rows in `app/routes.tsx` with no component yet, so they 404 until A4 and
    // A6 land. The console must still not link to a path that does not exist *in the route table*, which is a
    // distinct failure from "the screen is not built yet" - the first is a typo, the second is planned.
    for (const entry of entries) {
      expect(entry.action.href, `entry ${entry.key} has no destination`).toMatch(
        /^\/(orders|merchants|reconciliation)$/u,
      );
      expect(entry.action.label, `entry ${entry.key} has no label`).not.toBe("");
    }
  });
});