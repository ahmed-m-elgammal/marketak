import { describe, expect, it, vi } from "vitest";
import { QueryClient } from "@tanstack/react-query";
import { gateState, signOutEverywhere } from "./use-session";
import { sessionKey } from "../../../services/cache/query-keys";

describe("gateState", () => {
  it("distinguishes pending, signed-out and authorized", () => {
    expect(gateState(undefined)).toBe("pending");
    expect(gateState(null)).toBe("signed-out");
    expect(gateState({ userId: "u1" })).toBe("authorized");
  });
});

describe("signOutEverywhere", () => {
  it("signs out, then clears the cache and resets UI", async () => {
    const queryClient = new QueryClient();
    queryClient.setQueryData(sessionKey(), { userId: "u1" });
    const order: string[] = [];
    const reset = vi.fn(() => {
      order.push("reset");
    });
    await signOutEverywhere(
      queryClient,
      () => {
        order.push("signOut");
        return Promise.resolve();
      },
      reset,
    );
    expect(order).toEqual(["signOut", "reset"]);
    expect(queryClient.getQueryData(sessionKey())).toBeUndefined();
    expect(reset).toHaveBeenCalledTimes(1);
  });

  it("keeps cache and UI untouched when the server sign-out fails", async () => {
    const queryClient = new QueryClient();
    queryClient.setQueryData(sessionKey(), { userId: "u1" });
    const reset = vi.fn();
    await expect(
      signOutEverywhere(queryClient, () => Promise.reject(new Error("offline")), reset),
    ).rejects.toThrow("offline");
    expect(queryClient.getQueryData(sessionKey())).toEqual({ userId: "u1" });
    expect(reset).not.toHaveBeenCalled();
  });
});
