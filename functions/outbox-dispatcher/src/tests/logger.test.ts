/**
 * Tests for the logger.
 *
 * The log layer is what an operator reads instead of a stack trace, so the things asserted here are the
 * things that decide whether a production failure is diagnosable at all: that errors reach `console.error`
 * (and therefore a `wrangler tail --status error` filter), that a code is present on every line, and that a
 * credential cannot leak through it.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ErrorCode, describeError, log, newRunId, redact } from "../config/logger.js";

/** Captures the level a line was written at, which is the property that makes it filterable. */
type Level = "log" | "warn" | "error";

interface Captured {
  readonly level: Level;
  readonly parsed: Record<string, unknown>;
}

function captureConsole(): { readonly calls: Captured[] } {
  const calls: Captured[] = [];
  for (const level of ["log", "warn", "error"] as const) {
    vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
      calls.push({
        level,
        parsed: JSON.parse(String(args[0])) as Record<string, unknown>,
      });
    });
  }
  return { calls };
}

describe("redact", () => {
  it("replaces a value that contains a private key marker rather than truncating it", () => {
    // Truncation would leave the head of the key readable, which is the part that is still a credential.
    const secret = `-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg\n-----END PRIVATE KEY-----`;
    expect(redact(`something failed: ${secret}`)).toBe(
      "[redacted: contained -----BEGIN]",
    );
  });

  it("redacts a Supabase publishable key", () => {
    expect(redact("token sb_secret_abcdef123456 rejected")).toBe(
      "[redacted: contained sb_secret_]",
    );
  });

  it("redacts a JWT", () => {
    expect(redact("auth header eyJhbGciOiJIUzI1NiJ9.abc.def was bad")).toBe(
      "[redacted: contained eyJhbGciOi]",
    );
  });

  it("leaves an ordinary message alone", () => {
    expect(redact("fcm 401: Unauthorized")).toBe("fcm 401: Unauthorized");
  });

  it("truncates and reports how much was dropped", () => {
    // `events.last_error` is a single text column an admin reads, so an unbounded error body would
    // accumulate there. The count is reported so the truncation is not mistaken for the whole message.
    const out = redact("x".repeat(500), 100);
    expect(out).toBe(`${"x".repeat(100)}…[truncated 400 chars]`);
  });
});

describe("describeError", () => {
  it("keeps the name and message of an Error", () => {
    expect(describeError(new TypeError("bad thing"))).toBe("TypeError: bad thing");
  });

  it("handles a thrown non-Error", () => {
    // Throwing a string is legal in JavaScript and happens in code that rethrows whatever it caught.
    expect(describeError("plain string")).toBe("plain string");
  });

  it("redacts a secret inside an Error message", () => {
    const error = new Error("supabase rejected -----BEGIN PRIVATE KEY-----abc");
    expect(describeError(error)).toBe("[redacted: contained -----BEGIN]");
  });
});

describe("newRunId", () => {
  it("returns a non-empty id", () => {
    expect(newRunId()).not.toBe("");
  });

  it("returns a different id on each call", () => {
    expect(newRunId()).not.toBe(newRunId());
  });
});

describe("log", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("writes an error-severity entry to console.error", () => {
    // This is the whole reason the module exists. The first version of the Worker used console.log for
    // everything, so `--status error` showed nothing and the failure had to be found in the database.
    const { calls } = captureConsole();
    log({
      severity: "error",
      code: ErrorCode.FCM_AUTH,
      message: "fcm auth 401",
      drain_run_id: "run_x",
    });
    expect(calls).toHaveLength(1);
    expect(calls[0]?.level).toBe("error");
    expect(calls[0]?.parsed["code"]).toBe("FCM_AUTH");
  });

  it("writes a warn-severity entry to console.warn", () => {
    const { calls } = captureConsole();
    log({
      severity: "warn",
      code: ErrorCode.NO_DEVICE_TOKEN,
      message: "no active device token",
    });
    expect(calls[0]?.level).toBe("warn");
  });

  it("writes an info-severity entry to console.log", () => {
    const { calls } = captureConsole();
    log({ severity: "info", code: ErrorCode.DELIVERED, message: "accepted by FCM" });
    expect(calls[0]?.level).toBe("log");
  });

  it("keeps every field queryable as a top-level scalar", () => {
    const { calls } = captureConsole();
    log({
      severity: "error",
      code: ErrorCode.RENDER_UNFILLED,
      message: "unfilled placeholder(s): vendor_name",
      drain_run_id: "run_y",
      template_key: "order.placed",
      order_id: "ord-1",
      event_count: 3,
    });
    expect(calls[0]?.parsed).toMatchObject({
      severity: "error",
      code: "RENDER_UNFILLED",
      drain_run_id: "run_y",
      template_key: "order.placed",
      order_id: "ord-1",
      event_count: 3,
    });
  });

  it("never lets a bigint through, because JSON.stringify throws on one", () => {
    // `JSON.stringify` is what threw on the first live drain. The drain keeps `bigint` internally for
    // precision, so a log line built from a report would hit the same wall.
    const { calls } = captureConsole();
    log({
      severity: "error",
      code: ErrorCode.DB_EVENT_ID_UNSAFE,
      message: "event id too large",
      event_count: 9007199254740993n,
    });
    expect(calls[0]?.parsed["event_count"]).toBe("9007199254740993");
  });

  it("redacts a secret that reaches the message field", () => {
    const { calls } = captureConsole();
    log({
      severity: "error",
      code: ErrorCode.GOOGLE_TOKEN_FAILED,
      message: "signing failed for -----BEGIN PRIVATE KEY-----abc",
    });
    expect(calls[0]?.parsed["message"]).toBe("[redacted: contained -----BEGIN]");
  });
});