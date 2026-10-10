import { afterEach, describe, expect, it, vi } from "vitest";
import { createSupabaseClient, getSupabaseClient } from "./client";

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("createSupabaseClient", () => {
  it("builds a client exposing rpc and from", () => {
    const client = createSupabaseClient({
      url: "https://example.supabase.co",
      anonKey: "sb_publishable_testkey",
    });
    expect(typeof client.rpc).toBe("function");
    expect(typeof client.from).toBe("function");
  });
});

describe("getSupabaseClient", () => {
  it("throws when the environment is not configured", () => {
    vi.stubEnv("EXPO_PUBLIC_SUPABASE_URL", "");
    vi.stubEnv("EXPO_PUBLIC_SUPABASE_ANON_KEY", "");
    expect(() => getSupabaseClient()).toThrow(/SUPABASE_ENV_MISSING/);
  });

  it("memoizes one instance per process", () => {
    vi.stubEnv("EXPO_PUBLIC_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("EXPO_PUBLIC_SUPABASE_ANON_KEY", "sb_publishable_testkey");
    expect(getSupabaseClient()).toBe(getSupabaseClient());
  });
});
