import { describe, expect, it } from "vitest";

import { ConfigError, readEnv } from "../config/env.js";

/**
 * The real service account from `marketak-eg`, with the private key replaced by a syntactically valid but
 * obviously fake key. A real private key must never reach a test file, which means it reaches git.
 *
 * The PEM body is well-formed base64 so the "looks like a PEM" check passes; the content is irrelevant
 * because these tests never sign.
 */
const FAKE_SERVICE_ACCOUNT = JSON.stringify({
  type: "service_account",
  project_id: "marketak-eg",
  client_email: "firebase-adminsdk-fbsvc@marketak-eg.iam.gserviceaccount.com",
  private_key: [
    "-----BEGIN PRIVATE KEY-----",
    "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDummyKeyForTestsOnly",
    "-----END PRIVATE KEY-----",
  ].join("\n"),
});

function rawEnv(overrides: Record<string, string | undefined> = {}): Record<string, string | undefined> {
  return {
    SUPABASE_URL: "https://erxxsebcqqcpkipzcdhg.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "sb_secret_dummy_for_tests",
    FCM_SERVICE_ACCOUNT_JSON: FAKE_SERVICE_ACCOUNT,
    ...overrides,
  };
}

describe("readEnv", () => {
  it("returns a typed Env from the three required secrets", () => {
    const env = readEnv(rawEnv());

    expect(env.supabaseUrl).toBe("https://erxxsebcqqcpkipzcdhg.supabase.co");
    expect(env.fcm.projectId).toBe("marketak-eg");
    expect(env.fcm.clientEmail).toContain("marketak-eg");
  });

  it("defaults DRY_RUN to log, not send", () => {
    // A Worker deployed with a missing or misspelled flag must fail toward NOT sending. An undelivered
    // notification is retried on the next tick; a wrongly-delivered one reaches a customer and cannot be
    // recalled.
    expect(readEnv(rawEnv()).dryRun).toBe("log");
  });

  it("defaults BATCH_SIZE to 50, matching the plan", () => {
    expect(readEnv(rawEnv()).batchSize).toBe(50);
  });

  it("accepts send mode explicitly", () => {
    expect(readEnv(rawEnv({ DRY_RUN: "send" })).dryRun).toBe("send");
  });

  it("refuses a misspelled DRY_RUN instead of defaulting", () => {
    // The dangerous failure is a typo'd flag silently behaving as the default. In `send` mode a typo that
    // fell back to `log` would quietly stop all notifications; being strict makes it a startup error.
    expect(() => readEnv(rawEnv({ DRY_RUN: "true" }))).toThrow(ConfigError);
  });

  it("names every missing secret at once", () => {
    // One message listing all three, rather than failing on the first and needing three deploy cycles to
    // discover there were three.
    let message = "";
    try {
      readEnv({});
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    }

    expect(message).toContain("SUPABASE_URL");
    expect(message).toContain("SUPABASE_SERVICE_ROLE_KEY");
    expect(message).toContain("FCM_SERVICE_ACCOUNT_JSON");
  });

  it("treats an empty string as absent", () => {
    // Wrangler writes an empty value for a variable set to "". It must not be treated as present, or the
    // failure surfaces at the first fetch instead of at startup.
    expect(() => readEnv(rawEnv({ SUPABASE_SERVICE_ROLE_KEY: "" }))).toThrow(/SUPABASE_SERVICE_ROLE_KEY/u);
  });

  it("never puts a secret value in the error message", () => {
    // An error message is the most likely place for a service-role key to reach a log, a dashboard, and
    // eventually a screenshot. The message names the variable and nothing else.
    const secret = "sb_secret_this_must_never_appear_in_a_log";
    let message = "";
    try {
      readEnv(rawEnv({ FCM_SERVICE_ACCOUNT_JSON: "not-json", SUPABASE_SERVICE_ROLE_KEY: secret }));
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    }

    expect(message).not.toContain(secret);
  });

  it("refuses a plaintext Supabase URL", () => {
    // A plaintext URL would put the service-role key on the wire in the clear.
    expect(() => readEnv(rawEnv({ SUPABASE_URL: "http://example.supabase.co" }))).toThrow(/https/u);
  });

  it("refuses service-account JSON that is not valid JSON", () => {
    expect(() => readEnv(rawEnv({ FCM_SERVICE_ACCOUNT_JSON: "{nope" }))).toThrow(/not valid JSON/u);
  });

  it("names the missing fields of a service-account JSON", () => {
    let message = "";
    try {
      readEnv(rawEnv({ FCM_SERVICE_ACCOUNT_JSON: JSON.stringify({ project_id: "x" }) }));
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    }

    expect(message).toContain("client_email");
    expect(message).toContain("private_key");
    expect(message).not.toContain("private_key\":");
  });

  it("refuses a private_key that is not a PEM", () => {
    // WebCrypto's PKCS#8 import gives an opaque error for a value that is not a key. Catching it here
    // turns a 40-request-later failure into a startup error.
    const bad = JSON.stringify({
      project_id: "marketak-eg",
      client_email: "a@b.com",
      private_key: "definitely-not-a-key",
    });
    expect(() => readEnv(rawEnv({ FCM_SERVICE_ACCOUNT_JSON: bad }))).toThrow(/PEM/u);
  });

  it("refuses a BATCH_SIZE outside the RPC's own range", () => {
    // The RPC clamps to 200 and floors at 1. A config that appears honoured but is not is worse than one
    // that refuses.
    expect(() => readEnv(rawEnv({ BATCH_SIZE: "0" }))).toThrow(ConfigError);
    expect(() => readEnv(rawEnv({ BATCH_SIZE: "201" }))).toThrow(ConfigError);
    expect(() => readEnv(rawEnv({ BATCH_SIZE: "50.5" }))).toThrow(ConfigError);
    expect(() => readEnv(rawEnv({ BATCH_SIZE: "lots" }))).toThrow(ConfigError);
  });

  it("accepts the RPC's own limits", () => {
    expect(readEnv(rawEnv({ BATCH_SIZE: "1" })).batchSize).toBe(1);
    expect(readEnv(rawEnv({ BATCH_SIZE: "200" })).batchSize).toBe(200);
  });
});