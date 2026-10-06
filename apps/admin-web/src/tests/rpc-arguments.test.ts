/**
 * `tests/rpc-arguments` - every RPC is called with explicit named arguments.
 *
 * ## The bug this exists to prevent
 *
 * `reconcile_day_v1(date, text)` has a default on both parameters, so the natural call is
 * `rpc("reconcile_day_v1")` with no body. It fails with `PGRST202`, and the error describes something that is
 * not wrong:
 *
 * > Searched for the function `public.reconcile_day_v1` without parameters or with a single unnamed
 * > json/jsonb parameter, but no matches were found in the schema cache.
 *
 * PostgREST resolves a bodiless `POST /rpc/f` against **zero-argument** functions only. A defaulted parameter is
 * not treated as optional at the routing layer, so a function with two defaulted arguments is unreachable by
 * name alone. Both `reconcile_day_v1` and `get_platform_float_v1` have this shape.
 *
 * ## Why only a test catches it
 *
 * The function exists, `authenticated` holds EXECUTE, and the signature resolves in `pg_proc`. The type checker
 * sees `any`. Nothing in the app fails until a browser loads the screen, and the failure arrives as an opaque
 * schema-cache complaint that invites the reader to go looking for a missing function or a stale cache. Two
 * wrong theories were chased before the actual rule was found.
 *
 * So the invariant is asserted against the **source**, mechanically: any `rpcRows("fn")` with no second
 * argument must name a function that genuinely takes no arguments. `get_flags_v1` is the only one that does.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

/** Signatures read from `pg_proc` on the live project. Kept as data so the rule below is checkable. */
const SIGNATURES: Readonly<Record<string, readonly string[]>> = {
  reconcile_day_v1: ["p_date", "p_explanation"],
  get_platform_float_v1: ["p_from", "p_to"],
  get_flags_v1: ["p_app_role", "p_app_version"],
  get_admin_metrics_v1: ["p_date"],
};

const QUERIES_DIR = fileURLToPath(new URL("../lib/queries/", import.meta.url));

function queryFiles(dir: string): readonly string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = dir + "/" + entry;
    if (statSync(full).isDirectory()) {
      return queryFiles(full);
    }
    return full.endsWith(".ts") ? [full] : [];
  });
}

interface Call {
  readonly file: string;
  readonly fn: string;
  readonly line: number;
  readonly hasArgs: boolean;
}

/** Every `rpcRows("name", ...)` call, with whether it passed a second argument. */
function calls(): readonly Call[] {
  const found: Call[] = [];
  for (const file of queryFiles(QUERIES_DIR)) {
    const source = readFileSync(file, "utf8").split(/\r?\n/);
    source.forEach((text, index) => {
      const match = /rpcRows\(\s*"([a-z_0-9]+)"\s*(,)?/.exec(text);
      if (match === null || match[1] === undefined) {
        return;
      }
      found.push({
        file: file.split("/").pop() ?? file,
        fn: match[1],
        line: index + 1,
        hasArgs: match[2] !== undefined,
      });
    });
  }
  return found;
}

describe("RPC calls are addressable by PostgREST", () => {
  it("finds calls to check - a broken scan must not pass vacuously", () => {
    expect(calls().length).toBeGreaterThan(3);
  });

  it("calls only functions that exist", () => {
    // A typo'd function name is a 404 at runtime with no compile-time signal.
    for (const call of calls()) {
      expect(Object.keys(SIGNATURES), `${call.file}:${call.line} calls unknown ${call.fn}`).toContain(
        call.fn,
      );
    }
  });

  it("passes named arguments to every function that declares any", () => {
    for (const call of calls()) {
      // `get_flags_v1` takes two *nullable* parameters - the app is asking "every flag visible to this caller",
      // not one filtered by role - and PostgREST does route a bodiless call to it, verified live against the
      // running project. So the rule is about *declared arity*, not about whether an argument would be useful.
      if (call.fn === "get_flags_v1") {
        continue;
      }
      const parameters = SIGNATURES[call.fn] ?? [];
      expect(parameters.length, `${call.fn} unexpectedly takes no parameters`).toBeGreaterThan(0);
      expect(
        call.hasArgs,
        `${call.file}:${call.line} calls ${call.fn}(${parameters.join(", ")}) with no arguments. ` +
          `PostgREST resolves a bodiless POST /rpc/f against zero-argument functions only, so this returns ` +
          `PGRST202 "no matches were found in the schema cache" even though the function exists. ` +
          `Send every parameter explicitly, using null for the ones meant to take their default.`,
      ).toBe(true);
    }
  });

  it("sends p_date for a read of reconcile_day_v1, which has no default for it", () => {
    // `pg_get_function_arguments` renders the signature as
    // `p_date date, p_explanation text DEFAULT NULL::text`, so the DEFAULT reads as though it covers both
    // parameters. It covers only `p_explanation`; the body rejects a null date with `DATE_REQUIRED`. Verified
    // by reading `prosrc`, because the signature alone says the opposite.
    const source = readFileSync(QUERIES_DIR + "finance.ts", "utf8");
    expect(
      source,
      "getReconciliation must send a real date. The RPC has no default for p_date and raises DATE_REQUIRED " +
        "on null, so relying on a default here fails every read.",
    ).toContain('"reconcile_day_v1", { p_date: date, p_explanation: null }');
  });

  

  it("names every parameter a call sends, with nothing spelled wrong", () => {
    // A misspelled argument name is a different failure - PGRST202 again - with an even less helpful message,
    // because PostgREST cannot tell "you misspelled it" from "that function does not exist".
    for (const file of queryFiles(QUERIES_DIR)) {
      const source = readFileSync(file, "utf8");
      for (const match of source.matchAll(/rpcRows\(\s*"([a-z_0-9]+)"\s*,\s*\{([^}]*)\}/gu)) {
        const fn = match[1];
        if (fn === undefined) {
          continue;
        }
        const body = match[2] ?? "";
        const allowed = SIGNATURES[fn] ?? [];
        for (const key of body.matchAll(/([a-z_0-9]+)\s*:/gu)) {
          const name = key[1];
          if (name === undefined) {
            continue;
          }
          expect(
            allowed,
            `${file.split("/").pop()} sends ${name} to ${fn}, which declares ${allowed.join(", ")}`,
          ).toContain(name);
        }
      }
    }
  });
});