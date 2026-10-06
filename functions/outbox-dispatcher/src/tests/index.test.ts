/**
 * Tests for the HTTP entry point.
 *
 * These cover the surface an operator interacts with directly - the health check, the auth guard, the method
 * guard, the 404 - and, more importantly, that each failure is LOGGED. The reason this file exists: the
 * Worker returned clear messages to callers and recorded nothing at all, so a 401 or a 404 left no trace and
 * an error filter over the log stream always came back empty.
 */

import { afterEach, describe, expect, it, vi } from "vitest";

import worker from "../index.js";

/** The bindings shape the handlers read. Secrets are placeholders; nothing here reaches a network. */
function bindings(overrides: Record<string, string> = {}): Record<string, string> {
  return {
    SUPABASE_URL: "https://project.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
    FCM_SERVICE_ACCOUNT_JSON: JSON.stringify({
      project_id: "test-project",
      private_key: "test-private-key",
      client_email: "test@test-project.iam.gserviceaccount.com",
    }),
    DRAIN_TOKEN: "test-drain-token",
    ...overrides,
  };
}

const DRAIN = { kind: "drain" } as unknown as ScheduledController;

interface Captured {
  readonly level: "log" | "warn" | "error";
  readonly parsed: Record<string, unknown>;
}

function captureConsole(): Captured[] {
  const calls: Captured[] = [];
  for (const level of ["log", "warn", "error"] as const) {
    vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
      calls.push({ level, parsed: JSON.parse(String(args[0])) as Record<string, unknown> });
    });
  }
  return calls;
}

describe("GET /health", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("answers without a secret, so a deploy can be verified by anyone", async () => {
    const response = await worker.fetch(new Request("https://w/health"), {});

    expect(response.status).toBe(200);
    const body: Record<string, unknown> = await response.json();
    expect(body["ok"]).toBe(true);
    expect(body["service"]).toBe("outbox-dispatcher");
  });
});

describe("GET /drain", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("rejects with 405 and the method to use", async () => {
    captureConsole();

    const response = await worker.fetch(new Request("https://w/drain"), bindings());

    expect(response.status).toBe(405);
    const body: Record<string, unknown> = await response.json();
    expect(body["error"]).toBe("use POST /drain");
  });

  it("logs the rejection, which the previous version did not do", async () => {
    // The point of the test: a rejected method used to be invisible. The count is now non-zero.
    const calls = captureConsole();

    await worker.fetch(new Request("https://w/drain"), bindings());

    expect(calls.length).toBeGreaterThan(0);
    expect(calls[0]?.level).toBe("warn");
    expect(calls[0]?.parsed["http_status"]).toBe("405");
    expect(calls[0]?.parsed["path"]).toBe("https://w/drain");
  });

  it("carries the Cloudflare request id as the join key", async () => {
    // Without this, a Worker log line and a Cloudflare dashboard entry cannot be tied together.
    const calls = captureConsole();

    await worker.fetch(
      new Request("https://w/drain", { headers: { "cf-ray": "8abc1234def" } }),
      bindings(),
    );

    expect(calls[0]?.parsed["cf_ray"]).toBe("8abc1234def");
  });
});

describe("POST /drain auth", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("rejects a request with no token", async () => {
    const calls = captureConsole();

    const response = await worker.fetch(
      new Request("https://w/drain", { method: "POST" }),
      bindings(),
    );

    expect(response.status).toBe(401);
    const body: Record<string, unknown> = await response.json();
    expect(body["error"]).toBe("invalid or missing x-drain-token");
    expect(calls.some((call) => call.level === "warn")).toBe(true);
  });

  it("rejects a wrong token", async () => {
    const response = await worker.fetch(
      new Request("https://w/drain", {
        method: "POST",
        headers: { "x-drain-token": "wrong" },
      }),
      bindings(),
    );

    expect(response.status).toBe(401);
  });

  it("returns 403-free 401 so the response does not confirm the token exists", async () => {
    const response = await worker.fetch(
      new Request("https://w/drain", {
        method: "POST",
        headers: { "x-drain-token": "wrong" },
      }),
      bindings(),
    );

    // 401 for a missing token and 401 for a wrong token: an attacker cannot tell them apart.
    const missing = await worker.fetch(
      new Request("https://w/drain", { method: "POST" }),
      bindings(),
    );
    expect(response.status).toBe(missing.status);
  });

  it("reports 503 and says the route is disabled when DRAIN_TOKEN is unset", async () => {
    // Distinct from 401 on purpose: 401 means "prove yourself", 503 means "this door does not exist". The
    // message must reassure the operator that the CRON trigger still works, or they will disable the
    // schedule chasing a broken manual route.
    const calls = captureConsole();
    const env = bindings();
    delete env["DRAIN_TOKEN"];

    const response = await worker.fetch(
      new Request("https://w/drain", { method: "POST" }),
      env,
    );

    expect(response.status).toBe(503);
    const body: Record<string, unknown> = await response.json();
    expect(String(body["error"])).toContain("cron trigger still works");
    expect(calls[0]?.level).toBe("error");
  });
});

describe("unknown route", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("answers 404 and logs it", async () => {
    const calls = captureConsole();

    const response = await worker.fetch(new Request("https://w/nope"), bindings());

    expect(response.status).toBe(404);
    const body: Record<string, unknown> = await response.json();
    expect(body["error"]).toBe("not found");
    expect(calls.length).toBeGreaterThan(0);
  });
});

describe("scheduled trigger", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("logs a CONFIG_MISSING error when a secret is absent, naming the variable not the value", async () => {
    // A cron invocation's status code goes nowhere, so this log line is the ONLY evidence a misconfigured
    // deploy happened. Without it the drain is simply silent.
    const calls = captureConsole();
    const env = bindings();
    delete env["SUPABASE_SERVICE_ROLE_KEY"];

    await worker.scheduled(DRAIN, env);

    const line = calls.find((call) => call.level === "error");
    expect(line).toBeDefined();
    expect(line?.parsed["code"]).toBe("CONFIG_MISSING");
    expect(String(line?.parsed["message"])).toContain("SUPABASE_SERVICE_ROLE_KEY");
    // The reason this assertion is here: the log must not contain the other real-looking secrets.
    expect(String(line?.parsed["message"])).not.toContain("test-drain-token");
  });

  it("never reaches the network with a malformed service account, and says why", async () => {
    // `readEnv` rejects this before any HTTP call, which is why the handler can answer without a database.
    // Asserting the rejection is the point: a Worker that validated nothing would instead send a JWT signed
    // with "test-private-key" and report the result as an FCM failure, which is a much worse message.
    const calls = captureConsole();
    const env = bindings();
    env["FCM_SERVICE_ACCOUNT_JSON"] = JSON.stringify({ project_id: "p" });

    await worker.scheduled(DRAIN, env);

    expect(calls.some((call) => call.level === "error")).toBe(true);
    expect(calls.some((call) => String(call.parsed["code"]).startsWith("CONFIG"))).toBe(true);
  });
});