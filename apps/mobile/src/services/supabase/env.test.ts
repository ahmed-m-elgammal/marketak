import { describe, expect, it } from "vitest";
import { readEnv } from "./env";

const URL = "https://example.supabase.co";
const PUBLISHABLE = "sb_publishable_testkey";

function unsignedJwt(role: string): string {
  const encode = (value: string): string =>
    btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
  return `${encode('{"alg":"none"}')}.${encode(JSON.stringify({ role }))}.sig`;
}

function source(overrides: Readonly<Record<string, string | undefined>>): Record<string, string | undefined> {
  return {
    EXPO_PUBLIC_SUPABASE_URL: URL,
    EXPO_PUBLIC_SUPABASE_ANON_KEY: PUBLISHABLE,
    ...overrides,
  };
}

describe("readEnv", () => {
  it("accepts https url with publishable key", () => {
    expect(readEnv(source({}))).toEqual({ url: URL, anonKey: PUBLISHABLE });
  });

  it("accepts a legacy anon JWT", () => {
    const env = readEnv(source({ EXPO_PUBLIC_SUPABASE_ANON_KEY: unsignedJwt("anon") }));
    expect(env.anonKey).toContain(".");
  });

  it("throws when the url is missing", () => {
    expect(() => readEnv(source({ EXPO_PUBLIC_SUPABASE_URL: undefined }))).toThrow(/SUPABASE_ENV_MISSING/);
  });

  it("throws when the key is missing", () => {
    expect(() => readEnv(source({ EXPO_PUBLIC_SUPABASE_ANON_KEY: "" }))).toThrow(/SUPABASE_ENV_MISSING/);
  });

  it("throws when the url is not a url", () => {
    expect(() => readEnv(source({ EXPO_PUBLIC_SUPABASE_URL: "not-a-url" }))).toThrow(/SUPABASE_ENV_INVALID/);
  });

  it("throws on http outside loopback", () => {
    expect(() => readEnv(source({ EXPO_PUBLIC_SUPABASE_URL: "http://example.com" }))).toThrow(/SUPABASE_ENV_INVALID/);
  });

  it("allows http on loopback for local development", () => {
    const env = readEnv(source({ EXPO_PUBLIC_SUPABASE_URL: "http://127.0.0.1:54321" }));
    expect(env.url).toBe("http://127.0.0.1:54321");
  });

  it("refuses a service-role JWT", () => {
    expect(() => readEnv(source({ EXPO_PUBLIC_SUPABASE_ANON_KEY: unsignedJwt("service_role") }))).toThrow(
      /SUPABASE_KEY_REFUSED/,
    );
  });

  it("refuses a JWT with any non-anon role", () => {
    expect(() => readEnv(source({ EXPO_PUBLIC_SUPABASE_ANON_KEY: unsignedJwt("authenticated") }))).toThrow(
      /SUPABASE_KEY_REFUSED/,
    );
  });

  it("refuses garbage that is neither publishable nor JWT", () => {
    expect(() => readEnv(source({ EXPO_PUBLIC_SUPABASE_ANON_KEY: "notakey" }))).toThrow(/SUPABASE_KEY_REFUSED/);
  });

  it("refuses a malformed JWT payload", () => {
    expect(() => readEnv(source({ EXPO_PUBLIC_SUPABASE_ANON_KEY: "a.b.c" }))).toThrow(/SUPABASE_KEY_REFUSED/);
  });
});
