import { describe, expect, it } from "vitest";
import { QueryClient } from "@tanstack/react-query";
import type { RiderProfile } from "@marketak/shared";
import { sessionKey } from "../../../services/cache/query-keys";
import { switchActiveRole, toRoleState } from "./use-role";

const PROFILE = { rider_id: "r1" } as RiderProfile;

describe("toRoleState", () => {
  it("resolves signed-out, pending, customer-only and rider", () => {
    expect(toRoleState(null, undefined)).toBe("signed-out");
    expect(toRoleState(undefined, undefined)).toBe("signed-out");
    expect(toRoleState("u1", undefined)).toBe("pending");
    expect(toRoleState("u1", null)).toBe("customer-only");
    expect(toRoleState("u1", PROFILE)).toBe("rider");
  });
});

describe("switchActiveRole", () => {
  function seeded(): QueryClient {
    const queryClient = new QueryClient();
    queryClient.setQueryData(sessionKey(), { userId: "u1" });
    queryClient.setQueryData(["customer", "orders", "u1"], []);
    queryClient.setQueryData(["rider", "profile", "u1"], PROFILE);
    return queryClient;
  }

  it("clears the other namespace and keeps the session", () => {
    const queryClient = seeded();
    switchActiveRole(queryClient, "courier");
    expect(queryClient.getQueryData(["customer", "orders", "u1"])).toBeUndefined();
    expect(queryClient.getQueryData(["rider", "profile", "u1"])).toEqual(PROFILE);
    expect(queryClient.getQueryData(sessionKey())).toEqual({ userId: "u1" });
  });

  it("clears rider queries when switching back to customer", () => {
    const queryClient = seeded();
    switchActiveRole(queryClient, "customer");
    expect(queryClient.getQueryData(["rider", "profile", "u1"])).toBeUndefined();
    expect(queryClient.getQueryData(["customer", "orders", "u1"])).toEqual([]);
    expect(queryClient.getQueryData(sessionKey())).toEqual({ userId: "u1" });
  });
});
