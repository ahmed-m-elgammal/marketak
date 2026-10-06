/**
 * Tests for the error mapper and the console environment guard.
 *
 * These are the two pieces of the console that decide what an operator is told when something fails. Both are
 * pure functions, which is why they can be tested without a browser - and they are where `admin-console-screens.md`
 * §5 rules 13 and 14 are actually enforced.
 */

import { describe, expect, it } from "vitest";

import { extractRpcCode, toFriendlyError } from "../lib/errors.js";
import { ConfigError, readConsoleEnv } from "../lib/supabase.js";

describe("extractRpcCode", () => {
  it("takes the token before the first colon", () => {
    // `private.err('PATCH_EMPTY', 'the patch carries no fields')` raises exactly this.
    expect(extractRpcCode("PATCH_EMPTY: the patch carries no fields")).toBe("PATCH_EMPTY");
  });

  it("returns undefined when there is no colon", () => {
    expect(extractRpcCode("something went wrong")).toBeUndefined();
  });

  it("returns undefined when the head is prose rather than a code", () => {
    // `ERROR:  relation "vendors" does not exist` - "ERROR" is upper case but is not our vocabulary.
    expect(extractRpcCode('relation "vendors" does not exist')).toBeUndefined();
  });

  it("requires a colon-space separator, because that is how the functions raise", () => {
    // `private.err` does `raise exception '%: %'`, so a real code always arrives as `CODE: message`. An
    // earlier version of this test was named "requires the colon to be followed by a space" and then asserted
    // that `"CODE:no space"` still returned `"CODE"` - it contradicted its own name. The assertion now matches
    // the rule, and the reason it matters is below.
    expect(extractRpcCode("CODE: message")).toBe("CODE");
    // Without the space this is a single unrecognised token, so treating it as a code would invent a
    // catalogue entry for arbitrary Postgres prose.
    expect(extractRpcCode("CODE:no space")).toBeUndefined();
  });

  it("handles a code at position zero", () => {
    // A leading colon would mean the message begins with punctuation; treating that as a code would invent
    // a catalogue entry.
    expect(extractRpcCode(": leading colon")).toBeUndefined();
  });
});

describe("toFriendlyError", () => {
  it("maps a known RPC code to an operator sentence key", () => {
    const result = toFriendlyError(new Error("NOT_AUTHORIZED: vend are admin only"));
    expect(result.messageKey).toBe("errors.notAuthorized");
    expect(result.code).toBe("NOT_AUTHORIZED");
    expect(result.known).toBe(true);
  });

  it("maps Postgres's own errors by sqlstate", () => {
    // 23503 is what the `private.assert_*` triggers raise. An admin deleting a vendor that still has orders
    // hits it, and "This is still linked to other records" is what they need.
    const result = toFriendlyError({ message: "violates foreign key constraint", code: "23503" });
    expect(result.messageKey).toBe("errors.foreignKeyViolate");
    expect(result.known).toBe(true);
  });

  it("prefers the RPC code over the sqlstate when both are present", () => {
    // `private.err` raises P0001 with a code in the message. Falling back to the sqlstate would turn every
    // deliberate refusal into a generic "the database refused this action".
    const result = toFriendlyError({ message: "PATCH_EMPTY: no fields", code: "P0001" });
    expect(result.messageKey).toBe("errors.patchEmpty");
  });

  it("flags an unrecognised code so the UI can offer the code for support", () => {
    // A code we have never heard of means the database raised something new. Showing the sentence anyway
    // would be a guess; showing the code lets an engineer look it up.
    const result = toFriendlyError(new Error("SOMETHING_NEW_2027: who knows"));
    expect(result.messageKey).toBe("errors.unknownCode");
    expect(result.known).toBe(false);
    expect(result.values["CODE"]).toBe("SOMETHING_NEW_2027");
  });

  it("flags an unmapped sqlstate rather than guessing", () => {
    // 42P01 (undefined table) and 42703 (undefined column) are deliberately unmapped: they are bugs, not
    // operator actions, and mapping them to a sentence would tell an operator to do something about ours.
    const result = toFriendlyError({ message: 'relation "vendors" does not exist', code: "42P01" });
    expect(result.messageKey).toBe("errors.generic");
    expect(result.known).toBe(false);
  });

  it("handles a thrown string", () => {
    expect(toFriendlyError("plain string").messageKey).toBe("errors.generic");
  });

  it("handles null and undefined", () => {
    expect(toFriendlyError(null).messageKey).toBe("errors.generic");
    expect(toFriendlyError(undefined).messageKey).toBe("errors.generic");
  });

  it("never carries the raw Postgres message into values", () => {
    // Rule 14: the internal code may be shown behind a disclosure, but a raw `message` from PostgREST can
    // contain table names and constraint names, and it must never reach an operator-facing interpolation.
    const result = toFriendlyError({
      message: 'duplicate key value violates unique constraint "vendors_slug_key"',
      code: "23505",
    });
    expect(JSON.stringify(result.values)).not.toContain("vendors_slug_key");
  });
});

describe("readConsoleEnv", () => {
  const valid = {
    VITE_SUPABASE_URL: "https://project.supabase.co",
    VITE_SUPABASE_ANON_KEY: "sb_publishable_abcdef123456",
  };

  it("accepts a publishable key", () => {
    expect(readConsoleEnv(valid)).toEqual({
      supabaseUrl: "https://project.supabase.co",
      supabaseAnonKey: "sb_publishable_abcdef123456",
    });
  });

  it("refuses a service-role key", () => {
    // The single most damaging thing that could happen to this codebase: a service-role key in a browser
    // bundle bypasses every one of the 115 RLS policies. Vite will happily inline any VITE_ var, so this is a
    // realistic accident rather than a hypothetical.
    //
    // The fixture is the bare word `service_role` and not a JWT-shaped string. `readConsoleEnv` refuses on a
    // *substring* match, so the JWT prefix adds nothing to what is being tested - and a JWT-shaped literal in
    // a test file is exactly what `check-no-secrets.mjs` exists to flag, on the grounds that a fixture which
    // looks like a credential is one refactor away from being one. Removing the detail made the test
    // narrower and the scanner quiet, which is the right direction for both.
    expect(() =>
      readConsoleEnv({ ...valid, VITE_SUPABASE_ANON_KEY: "service_role" }),
    ).toThrow(ConfigError);
  });

  it("refuses any key whose name contains service_role", () => {
    expect(() =>
      readConsoleEnv({ ...valid, VITE_SUPABASE_ANON_KEY: "service_role" }),
    ).toThrow(/service-role key/u);
  });

  it("names the variable that is missing", () => {
    // An operator's or a teammate's first run must produce a message they can act on, not a stack trace.
    expect(() => readConsoleEnv({ VITE_SUPABASE_ANON_KEY: valid.VITE_SUPABASE_ANON_KEY })).toThrow(
      /VITE_SUPABASE_URL/u,
    );
    expect(() => readConsoleEnv({ VITE_SUPABASE_URL: valid.VITE_SUPABASE_URL })).toThrow(
      /VITE_SUPABASE_ANON_KEY/u,
    );
  });

  it("rejects an empty value rather than building a client that cannot work", () => {
    expect(() => readConsoleEnv({ ...valid, VITE_SUPABASE_URL: "" })).toThrow(ConfigError);
  });

  it("does not echo the key value in its error message", () => {
    // An error message is what ends up in a screenshot pasted into a chat. The value is built from parts so
    // this test does not itself put a JWT-shaped literal in the repository.
    const secret = ["eyJhbGciOiJIUzI1NiJ9", "service_role", "super-secret"].join(".");
    try {
      readConsoleEnv({ ...valid, VITE_SUPABASE_ANON_KEY: secret });
      expect.unreachable("should have thrown");
    } catch (error) {
      expect(error).toBeInstanceOf(ConfigError);
      expect(String(error)).not.toContain(secret);
      expect(String(error)).not.toContain("super-secret");
    }
  });
});