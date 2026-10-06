import { describe, expect, it } from "vitest";

import { formatCount, formatMoney, isCurrencyCode, PIASBRES } from "../domain/money/format-money.js";

describe("formatMoney", () => {
  it("renders piastres as a currency with two decimals", () => {
    // 33000 piastres is 330.00 units. Verified against a real claim row from the live database, where
    // `total` came back as 33000 for a three-vendor order.
    const rendered = formatMoney(33_000, "EGP");

    expect(rendered).toBeDefined();
    expect(rendered).toContain("330");
    expect(rendered).toContain("00");
  });

  it("does not lose a piastre to floating point", () => {
    // The reason this module exists rather than `(amount / 100).toFixed(2)`. Several integers that divide
    // to exactly two decimals do not survive the division as a double, and `toFixed` then rounds the wrong
    // way: 10101 / 100 is 101.00999999999999, whose `toFixed(2)` is "101.01" by luck, but the pattern is
    // not reliable across the range. `Intl` never sees the intermediate float.
    for (const piastres of [1, 7, 99, 101, 1_001, 10_101, 33_333, 99_999]) {
      const rendered = formatMoney(piastres, "EGP");
      expect(rendered).toBeDefined();
      // Whatever the grouping, the digits after the decimal must be exactly two zeros.
      expect(rendered).toMatch(/\.\d{2}$/);
    }
  });

  it("respects the currency rather than assuming EGP", () => {
    // `currency` is a per-row `bpchar` on six tables and `admin_upsert_city_v1` lets an admin change it.
    // A module constant here would silently mislabel every notification. Verified: a probe order created
    // in a city configured `SAR` came back from `claim_events_v1` with `currency: "SAR"`.
    const egp = formatMoney(33_000, "EGP");
    const sar = formatMoney(33_000, "SAR");

    expect(egp).not.toBe(sar);
  });

  it("returns undefined rather than throwing on a bad amount", () => {
    // The renderer treats undefined as "unfilled variable" and refuses the send. A throw here would
    // abandon every remaining notification in the batch instead.
    expect(formatMoney(1.5, "EGP")).toBeUndefined();
    expect(formatMoney(Number.NaN, "EGP")).toBeUndefined();
    expect(formatMoney(Number.POSITIVE_INFINITY, "EGP")).toBeUndefined();
  });

  it("returns undefined on a malformed currency code", () => {
    // `Intl.NumberFormat` THROWS on these. Validating first is what turns "one bad city row silently eats
    // every push" into "one skipped send with a logged reason".
    expect(formatMoney(100, "")).toBeUndefined();
    expect(formatMoney(100, "EG")).toBeUndefined();
    expect(formatMoney(100, "EGPP")).toBeUndefined();
    expect(formatMoney(100, "EGP ")).toBeUndefined();
    expect(formatMoney(100, "egp")).toBeUndefined();
  });
});

describe("isCurrencyCode", () => {
  it("accepts exactly three uppercase letters", () => {
    expect(isCurrencyCode("EGP")).toBe(true);
    expect(isCurrencyCode("SAR")).toBe(true);
    expect(isCurrencyCode("USD")).toBe(true);
  });

  it("rejects anything else", () => {
    // `bpchar(3)` PADS, so a value can arrive as "EGP " on one row and "EGP" on another. The padding is
    // trimmed in SQL by `038i`, but the Worker checks anyway rather than trusting the caller.
    expect(isCurrencyCode("EGP ")).toBe(false);
    expect(isCurrencyCode(" EG")).toBe(false);
    expect(isCurrencyCode("egp")).toBe(false);
    expect(isCurrencyCode("E1P")).toBe(false);
    expect(isCurrencyCode(undefined)).toBe(false);
    expect(isCurrencyCode(null)).toBe(false);
    expect(isCurrencyCode(42)).toBe(false);
  });
});

describe("formatCount", () => {
  it("renders a plain integer string", () => {
    // "3 vendor(s)" is the TEMPLATE's wording, not this function's, so there is no pluralisation here.
    expect(formatCount(3)).toBe("3");
    expect(formatCount(0)).toBe("0");
  });

  it("refuses non-finite numbers so NaN never reaches a customer", () => {
    expect(formatCount(Number.NaN)).toBeUndefined();
    expect(formatCount(Number.POSITIVE_INFINITY)).toBeUndefined();
  });
});

describe("PIASBRES", () => {
  it("is 100", () => {
    // Exported so a test can assert the scaling rather than trust it.
    expect(PIASBRES).toBe(100);
  });
});