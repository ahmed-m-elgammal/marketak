import { describe, expect, it } from "vitest";
import { AppError } from "@marketak/shared";
import { getOverride, resolveBehaviour } from "./overrides";

describe("getOverride", () => {
  it("re-quotes place PRICE_CHANGED and waits for consent, never silent", () => {
    expect(getOverride("place_order_v1", "PRICE_CHANGED")).toEqual({
      kind: "re-quote-consent",
      insteadOf: "conflict",
    });
  });

  it("reads cancel/claim NOT_AUTHORIZED as not-your-order, not sign-in", () => {
    expect(getOverride("cancel_order_v1", "NOT_AUTHORIZED")).toEqual({
      kind: "not-your-order",
      insteadOf: "sign-in",
    });
    expect(getOverride("claim_order_v1", "NOT_AUTHORIZED")).toEqual({
      kind: "cannot-claim-as-other",
      insteadOf: "sign-in",
    });
  });

  it("re-quotes any quote failure and lets the shopper choose", () => {
    expect(getOverride("quote_order_v1", "GROUPING_INVALID")).toEqual({
      kind: "re-quote-choose",
      insteadOf: "invalid-input",
    });
    expect(getOverride("quote_order_v1", "TIP_INVALID")?.kind).toBe("re-quote-choose");
    expect(getOverride("quote_order_v1", "CART_EMPTY")?.kind).toBe("re-quote-choose");
  });

  it("never overrides authentication away, except the two named situations", () => {
    expect(getOverride("place_order_v1", "NOT_AUTHORIZED")).toBeNull();
    expect(getOverride("quote_order_v1", "AUTH_REQUIRED")).toBeNull();
    expect(getOverride("quote_order_v1", "NOT_AUTHORIZED")).toBeNull();
    expect(getOverride("cancel_order_v1", "AUTH_REQUIRED")).toBeNull();
  });

  it("returns null with no code, no call match, or no code match", () => {
    expect(getOverride("place_order_v1", null)).toBeNull();
    expect(getOverride("place_order_v1", "")).toBeNull();
    expect(getOverride("upsert_cart_item_v1", "PRICE_CHANGED")).toBeNull();
    expect(getOverride("place_order_v1", "QUOTE_EXPIRED")).toBeNull();
  });
});

describe("resolveBehaviour", () => {
  it("prefers the override, then the default", () => {
    expect(resolveBehaviour("place_order_v1", new AppError("conflict", "PRICE_CHANGED", "تغير السعر"))).toBe(
      "re-quote-consent",
    );
    expect(resolveBehaviour("cancel_order_v1", new AppError("unauthenticated", "NOT_AUTHORIZED", "غير مصرح"))).toBe(
      "not-your-order",
    );
    expect(resolveBehaviour("upsert_cart_item_v1", new AppError("invalid-input", "SIZE_REQUIRED", "اختر المقاس"))).toBe(
      "invalid-input",
    );
    expect(resolveBehaviour("get_flags_v1", new AppError("business", null, ""))).toBe("business");
  });
});
