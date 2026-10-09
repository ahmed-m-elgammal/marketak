import { describe, expect, it } from "vitest";
import {
  PIASTRES_PER_UNIT,
  addPiastres,
  bpsToPercent,
  formatCount,
  formatMoney,
  formatMoneyWithCurrency,
  formatRate,
  formatRateBps,
  fromPiastres,
  multiplierFromBps,
  multiplyByCount,
  multiplyByRateBps,
  percentToBps,
  sumPiastres,
  toPiastres,
} from "./money.js";

describe("piastres", () => {
  it("refuses a non-integer, because money is not a float", () => {
    expect(() => toPiastres(29.5)).toThrow(/PIASTRES_NOT_INTEGER/u);
    expect(() => toPiastres(0.1 + 0.2)).toThrow(/PIASTRES_NOT_INTEGER/u);
  });

  it("treats 100 piastres as one unit", () => {
    expect(PIASTRES_PER_UNIT).toBe(100);
    expect(toPiastres(2950)).toBe(2950);
  });

  it("round-trips through fromPiastres without drift", () => {
    const original = 1234567;
    expect(fromPiastres(toPiastres(original))).toBe(original);
  });

  it("adds and sums without introducing a fraction", () => {
    expect(addPiastres(toPiastres(2950), toPiastres(1550))).toBe(4500);
    expect(sumPiastres([toPiastres(2950), toPiastres(1550), toPiastres(500)])).toBe(5000);
    expect(sumPiastres([])).toBe(0);
  });

  it("multiplies by a count", () => {
    expect(multiplyByCount(toPiastres(2950), 3)).toBe(8850);
    expect(() => multiplyByCount(toPiastres(2950), 1.5)).toThrow(/COUNT_NOT_INTEGER/u);
  });
});

/**
 * The important one. `quote_order_v1` computes
 * `round(base * multiplier_bps / 10000)` in SQL against a `numeric`, which rounds
 * half away from zero. If this module disagreed on an exact half, the delivery fee
 * the app rendered would not be the fee the database charged - and nothing in the
 * app would have failed to explain it.
 */
describe("multiplyByRateBps", () => {
  it("matches Postgres round-half-away-from-zero on exact halves", () => {
    // 5 piastres at 10000 bps is 5. 5 at 11000 bps is 5.5, which must go to 6.
    expect(multiplyByRateBps(toPiastres(5), 11000)).toBe(6);
    // 15 at 11000 = 16.5 → 17, not 16. Math.round(16.5) is 17, but 15 * 1.1 in a
    // float is 16.499999999999996, which would round to 16. This is the trap.
    expect(multiplyByRateBps(toPiastres(15), 11000)).toBe(17);
    // 25 at 11000 = 27.5 → 28.
    expect(multiplyByRateBps(toPiastres(25), 11000)).toBe(28);
  });

  it("handles the identity and zero rates", () => {
    expect(multiplyByRateBps(toPiastres(2950), 10000)).toBe(2950);
    expect(multiplyByRateBps(toPiastres(2950), 0)).toBe(0);
  });

  it("rejects a malformed rate", () => {
    expect(() => multiplyByRateBps(toPiastres(100), -1)).toThrow(/RATE_BPS_INVALID/u);
    expect(() => multiplyByRateBps(toPiastres(100), 1.5)).toThrow(/RATE_BPS_INVALID/u);
  });

  it("converts between bps and percent exactly", () => {
    expect(bpsToPercent(11000)).toBe(110);
    expect(percentToBps(110)).toBe(11000);
    expect(multiplierFromBps(11000)).toBe(1.1);
    expect(() => percentToBps(110.005)).toThrow(/PERCENT_NOT_EXACT/u);
  });
});

/**
 * Digits are a contract, not a nicety. The design system renders Eastern
 * Arabic-Indic digits (the rider card shows ٤٫٨ and a plate of ١٢٣٤), so the
 * numbering system is pinned rather than inherited from the runtime locale,
 * which differs between Hermes, iOS and Android.
 */
describe("formatting", () => {
  it("renders Arabic in Arabic-Indic digits with the Arabic grouping and decimal marks", () => {
    // Grouping is ON deliberately. Money is integer piastres, so a total of 45000
    // is 450 EGP, and an ungrouped `٤٥٠٠٠` is a string a shopper has to count
    // digits in. `Intl` supplies the Arabic thousands separator `٬` (U+066C), which
    // is not the Latin comma - asserting it here pins the distinction.
    expect(formatMoney(toPiastres(2950), "ar")).toBe("٢٬٩٥٠");
    expect(formatMoney(toPiastres(45000), "ar")).toBe("٤٥٬٠٠٠");
    expect(formatRate(4.8, "ar")).toBe("٤٫٨");
    expect(formatCount(1234, "ar")).toBe("١٬٢٣٤");
  });

  it("renders English in Latin digits with the Latin grouping mark", () => {
    expect(formatMoney(toPiastres(2950), "en")).toBe("2,950");
    expect(formatMoney(toPiastres(45000), "en")).toBe("45,000");
    expect(formatRate(4.8, "en")).toBe("4.8");
    expect(formatCount(1234, "en")).toBe("1,234");
  });

  it("defaults to Arabic, because Arabic is the primary language", () => {
    expect(formatMoney(toPiastres(100))).toBe("١٠٠");
  });

  it("appends the currency for receipts", () => {
    expect(formatMoneyWithCurrency(toPiastres(250000), "EGP", "en")).toBe("250,000 EGP");
  });

  it("formats a rate in bps as a percentage", () => {
    expect(formatRateBps(11000, "en")).toBe("110%");
    expect(formatRateBps(11000, "ar")).toBe("١١٠٪");
  });
});
