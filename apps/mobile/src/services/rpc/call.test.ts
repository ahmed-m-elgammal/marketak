import { describe, expect, it } from "vitest";
import { z } from "zod";
import { AppError } from "@marketak/shared";
import { callRpc, decodeWith, readMismatch, type RpcDeps } from "./call";
import type { RpcCall } from "../supabase/client";

type Canned =
  | { readonly kind: "resolve"; readonly data: unknown; readonly error: { message: string } | null }
  | { readonly kind: "reject"; readonly thrown: unknown };

interface Seen {
  method: string;
  args: Record<string, unknown>;
  signal?: AbortSignal;
  single: boolean;
}

function cannedCall(canned: Canned, seen: Seen): RpcCall {
  const call: RpcCall = {
    abortSignal(signal: AbortSignal): RpcCall {
      seen.signal = signal;
      return call;
    },
    single(): RpcCall {
      seen.single = true;
      return call;
    },
    execute(): Promise<{ data: unknown; error: { message: string } | null }> {
      if (canned.kind === "reject") throw canned.thrown;
      return Promise.resolve({ data: canned.data, error: canned.error });
    },
  };
  return call;
}

function depsFor(
  rpcName: "quote_order_v1" | "place_order_v1" | "get_flags_v1" | "upsert_cart_item_v1",
  canned: Canned,
): { deps: RpcDeps; seen: Seen } {
  const seen: Seen = { method: "", args: {}, single: false };
  const deps: RpcDeps = {
    call: (m, a) => {
      seen.method = m;
      seen.args = a;
      return cannedCall(canned, seen);
    },
  };
  return { deps, seen };
}

const rowSchema = z.looseObject({ id: z.string().uuid() });
const ID = "123e4567-e89b-12d3-a456-426614174000";

describe("callRpc", () => {
  it("resolves, validates and returns the typed row", async () => {
    const { deps, seen } = depsFor("quote_order_v1", { kind: "resolve", data: { id: ID }, error: null });
    const row = await callRpc("quote_order_v1", { p_cart_id: ID }, rowSchema, deps);
    expect(row).toEqual({ id: ID });
    expect(seen.method).toBe("quote_order_v1");
    expect(seen.args).toEqual({ p_cart_id: ID });
    expect(seen.single).toBe(false);
  });

  it("requests object mode for single-row RPCs", async () => {
    const { deps, seen } = depsFor("place_order_v1", { kind: "resolve", data: { id: ID }, error: null });
    await callRpc("place_order_v1", {}, rowSchema, { ...deps, single: true });
    expect(seen.single).toBe(true);
  });

  it("maps a business failure to AppError with code and server copy", async () => {
    const { deps } = depsFor("quote_order_v1", {
      kind: "resolve",
      data: null,
      error: { message: "PRICE_CHANGED: تغير السعر" },
    });
    const failure = await callRpc("quote_order_v1", {}, rowSchema, deps).then(
      () => null,
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(AppError);
    if (failure instanceof AppError) {
      expect(failure.code).toBe("PRICE_CHANGED");
      expect(failure.serverMessage).toBe("تغير السعر");
      expect(failure.kind).toBe("conflict");
      expect(failure.retryable).toBe(true);
    }
  });

  it("maps sign-in failures without looping the caller", async () => {
    const { deps } = depsFor("get_flags_v1", {
      kind: "resolve",
      data: null,
      error: { message: "NOT_AUTHORIZED: not yours" },
    });
    const failure = await callRpc("get_flags_v1", {}, rowSchema, deps).then(
      () => null,
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(AppError);
    if (failure instanceof AppError) {
      expect(failure.requiresSignIn).toBe(true);
    }
  });

  it("maps transport rejection distinctly: null code, empty message, TypeError cause", async () => {
    const { deps } = depsFor("upsert_cart_item_v1", { kind: "reject", thrown: new TypeError("fetch failed") });
    const failure = await callRpc("upsert_cart_item_v1", {}, rowSchema, deps).then(
      () => null,
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(AppError);
    if (failure instanceof AppError) {
      expect(failure.code).toBeNull();
      expect(failure.serverMessage).toBe("");
      expect(failure.cause).toBeInstanceOf(TypeError);
    }
  });

  it("maps a resolved abort to an empty, non-retryable failure — never rendered, never retried", async () => {
    const raw = { message: "AbortError: The user aborted a request." };
    const { deps } = depsFor("quote_order_v1", { kind: "resolve", data: null, error: raw });
    const failure = await callRpc("quote_order_v1", {}, rowSchema, deps).then(
      () => null,
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(AppError);
    if (failure instanceof AppError) {
      expect(failure.code).toBeNull();
      expect(failure.serverMessage).toBe("");
      expect(failure.cause).toBe(raw);
      expect(failure.cause instanceof TypeError).toBe(false);
    }
  });

  it("forwards an abort signal to the transport", async () => {
    const controller = new AbortController();
    const { deps, seen } = depsFor("place_order_v1", { kind: "resolve", data: { id: ID }, error: null });
    await callRpc("place_order_v1", {}, rowSchema, { ...deps, signal: controller.signal });
    expect(seen.signal).toBe(controller.signal);
  });

  it("records the first mismatch per RPC and keeps it on later drift", async () => {
    const name = "upsert_cart_item_v1";
    const { deps } = depsFor(name, { kind: "resolve", data: { wrong: 1 }, error: null });
    await expect(callRpc(name, {}, rowSchema, deps)).rejects.toBeInstanceOf(AppError);
    const first = readMismatch(name);
    expect(typeof first).toBe("string");
    await expect(callRpc(name, {}, rowSchema, deps)).rejects.toBeInstanceOf(AppError);
    expect(readMismatch(name)).toBe(first);
  });
});

describe("decodeWith", () => {
  it("passes unknown keys through instead of crashing on server additions", () => {
    const row = decodeWith("probe.pass", rowSchema, { id: ID, future_column: "new" });
    expect(row).toEqual({ id: ID, future_column: "new" });
  });
});
