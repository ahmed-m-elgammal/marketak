import { describe, expect, it } from "vitest";
import { AppError } from "@marketak/shared";
import { createQueryClient, shouldRetry } from "./queryClient";
import {
  customerAddressesKey,
  customerOrdersKey,
  riderOffersKey,
  riderProfileKey,
  sessionKey,
} from "./query-keys";

describe("query keys", () => {
  it("scopes every role key with the user id", () => {
    expect(sessionKey()).toEqual(["session"]);
    expect(riderProfileKey("u1")).toEqual(["rider", "profile", "u1"]);
    expect(customerOrdersKey("u1")).toEqual(["customer", "orders", "u1"]);
    expect(customerAddressesKey("u1")).toEqual(["customer", "addresses", "u1"]);
    expect(riderOffersKey("u1", 30.05, 31.25)).toEqual([
      "rider",
      "offers",
      "u1",
      { latitude: 30.05, longitude: 31.25 },
    ]);
  });

  it("keeps role namespaces disjoint for scoped clearing", () => {
    expect(customerOrdersKey("u1")[0]).toBe("customer");
    expect(riderProfileKey("u1")[0]).toBe("rider");
    expect(sessionKey()[0]).toBe("session");
  });
});

describe("retry policy", () => {
  const transport = new AppError("business", null, "", new TypeError("fetch failed"));
  const business = new AppError("conflict", "PRICE_CHANGED", "تغير السعر");

  it("retries a transport collapse once, never business", () => {
    expect(shouldRetry(0, transport)).toBe(true);
    expect(shouldRetry(1, transport)).toBe(false);
    expect(shouldRetry(0, business)).toBe(false);
    expect(shouldRetry(0, new Error("boom"))).toBe(false);
  });

  it("installs the policy as the client default", () => {
    const client = createQueryClient();
    expect(client.getDefaultOptions().queries?.staleTime).toBe(10_000);
    expect(client.getDefaultOptions().queries?.retry).toBe(shouldRetry);
  });
});
