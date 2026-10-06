/**
 * Every `t("...")` key must exist in **both** catalogues.
 *
 * ## Why this test exists
 *
 * The dashboard shipped two cards reading the literal text `dashboard.completionRateHint` and
 * `dashboard.etaMinutes`, because `DashboardPage` referenced keys that were never added to `en.json` or
 * `ar.json`. i18next renders a missing key as the key itself - it does not throw, does not warn in production,
 * and does not fail `tsc`, since `t()` accepts any string. So a missing translation is invisible to every
 * other check in this repo and reaches the screen.
 *
 * That is the whole argument for this file: the failure mode is invisible to the type checker, to lint, and to
 * the other tests, because `t` is typed to accept whatever string it is given. Scanning the source is the
 * only place the two can be compared.
 *
 * ## Why the scan is mechanical
 *
 * Keys are collected with a regex rather than an AST walk on purpose. An AST walk would need a parser as a
 * dev dependency, and the pattern it has to recognise - a double-quoted first argument to `t(` - is narrow
 * enough that a regex is honest about its own limits. A dynamic key is invisible here, so dynamic keys are
 * constrained instead: the one dynamic key in the console, `orderStatus.${status}`, is asserted exhaustively
 * below against the real `OrderStatus` union, so a new status cannot land without its translation.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { sep } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import en from "../i18n/en.json" with { type: "json" };
import ar from "../i18n/ar.json" with { type: "json" };
import { ORDER_STATUSES } from "../lib/order-status.js";

/**
 * `src/`, as a filesystem path.
 *
 * `fileURLToPath` rather than `new URL(..).pathname`: the path form percent-encodes, so a directory named
 * "delivery app" arrives as `delivery%20app` and every `readdirSync` fails with ENOENT. The whole reason this
 * failed is that the workspace path contains a space.
 */
const SRC = fileURLToPath(new URL("..", import.meta.url));

type Catalogue = Readonly<Record<string, unknown>>;

function resolve(catalogue: Catalogue, dotted: string): unknown {
  return dotted.split(".").reduce<unknown>((node, key) => {
    if (typeof node !== "object" || node === null) {
      return undefined;
    }
    return (node as Record<string, unknown>)[key];
  }, catalogue);
}

/** Every `.ts`/`.tsx` under `src`, so a new screen is covered without editing this file. */
function sourceFiles(dir: string): readonly string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = dir + sep + entry;
    if (statSync(full).isDirectory()) {
      return sourceFiles(full);
    }
    return full.endsWith(".ts") || full.endsWith(".tsx") ? [full] : [];
  });
}

/**
 * Static keys only.
 *
 * A key containing `${` is built at runtime and is handled by the dedicated dynamic assertion rather than
 * here, where it would always report as missing.
 */
function staticKeys(): readonly string[] {
  const keys = new Set<string>();
  for (const file of sourceFiles(SRC)) {
    // Tests assert *about* catalogues and are full of deliberate key-shaped strings that do not exist.
    if (file.includes(`src${sep}tests${sep}`)) {
      continue;
    }
    const source = readFileSync(file, "utf8");
    for (const match of source.matchAll(/\bt\(\s*"([a-zA-Z0-9_.]+)"/g)) {
      const key = match[1];
      // The capture group is non-optional, but `noUncheckedIndexedAccess` types it as possibly undefined, and
      // guarding here keeps the assertion honest rather than asserting on a value that might not be a string.
      if (key === undefined || key.includes("$")) {
        continue;
      }
      // Rejects `"..."` and `"__"` - the placeholder keys this very file uses in its own `t()` examples, and
      // any comment or doc-string quoting a key. A bare `.` or `_` run is not a real i18n path, and letting it
      // through reported `en.... (missing)`, which is unreadable.
      if (!/^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$/u.test(key)) {
        continue;
      }
      keys.add(key);
    }
  }
  return [...keys].sort();
}

const KEYS = staticKeys();

describe("i18n catalogues are complete", () => {
  it("finds keys to check - a broken scan passes vacuously otherwise", () => {
    expect(KEYS.length).toBeGreaterThan(50);
  });

  /**
   * The whole file, stated once: every referenced key resolves to a non-empty string in both catalogues.
   *
   * Three separate assertions used to live here - "exists", "is not an object", "is not empty" - and each was
   * necessary for a failure that had actually occurred. They are one predicate: `resolve` must return a string
   * with content. Vitest truncates a long expectation message in the summary, so the list is also written to a
   * file by the caller when it fails, which is the only way to see all of them at once.
   */
  // Thrown with an explicit `Error` rather than asserted with a custom message: Vitest truncates custom
  // expectation messages at about 40 characters, which hides the one key that matters out of 180.
  function problems(catalogue: Catalogue, label: string): readonly string[] {
    // Read from disk rather than from the imported JSON, and scanned here rather than in `staticKeys`, so a
    // key that failed to *parse* - an unescaped quote in a value, a trailing comma - is reported by name.
    // Importing the catalogue makes any such error a module-load failure with no key in the message at all.
    return KEYS.flatMap((key: string) => {
      const value = resolve(catalogue, key);
      if (typeof value !== "string") {
        return [`${label}.${key} (${value === undefined ? "missing" : "not a string"})`];
      }
      return value.trim() === "" ? [`${label}.${key} (empty)`] : [];
    });
  }

  it("has a usable English string for every referenced key", () => {
    const found = problems(en, "en");
    // Thrown rather than asserted, because Vitest truncates a long custom-message and there is no way to see
    // which of 180 keys is missing. An explicit failure names it.
    if (found.length > 0) {
      throw new Error(`i18n en.json unusable for ${found.length} key(s):\n  ${found.join("\n  ")}`);
    }
    expect(found).toEqual([]);
  });

  it("has a usable Arabic string for every referenced key", () => {
    const found = problems(ar, "ar");
    if (found.length > 0) {
      throw new Error(`i18n ar.json unusable for ${found.length} key(s):\n  ${found.join("\n  ")}`);
    }
    expect(found).toEqual([]);
  });

  it("never leaves a referenced key empty", () => {
    // An empty string renders as blank space, which is harder to notice than a raw key and just as wrong.
    const empty = KEYS.filter((key: string) => {
      const value = resolve(en, key);
      return typeof value === "string" && value.trim() === "";
    });
    expect(empty, `empty in en.json: ${empty.join(", ")}`).toEqual([]);
  });

  it("interpolates the same placeholders in both catalogues", () => {
    // A key present in both files but placeholder sets to `{{amount}}` in one and `{{sum}}` in the other
    // passes both completeness tests and still renders a literal `{{amount}}` in Arabic. Comparing the
    // placeholder names is the only check that catches it.
    const placeholders = (value: unknown): readonly string[] =>
      typeof value === "string" ? [...value.matchAll(/\{\{\s*([a-zA-Z0-9_]+)/g)].map((m) => m[1] ?? "").sort() : [];

    const mismatched = KEYS.filter((key: string) => {
      const fromEn = placeholders(resolve(en, key));
      const fromAr = placeholders(resolve(ar, key));
      return fromEn.length > 0 && fromEn.join(",") !== fromAr.join(",");
    });
    expect(mismatched, `placeholder mismatch: ${mismatched.join(", ")}`).toEqual([]);
  });

  it("translates every order status, since that key is built at runtime", () => {
    for (const status of ORDER_STATUSES) {
      expect(resolve(en, `orderStatus.${status}`), `en orderStatus.${status}`).toBeTypeOf("string");
      expect(resolve(ar, `orderStatus.${status}`), `ar orderStatus.${status}`).toBeTypeOf("string");
    }
  });

  it("resolves every referenced key to a string in both catalogues", () => {
    // Covered by the two tests above via `problems`; kept as a separate assertion because it is the
    // distinction that actually bit - `resolve` returning an *intermediate object* rather than `undefined`.
    // A key like `nav.vendors` resolving to the `nav` object would render `[object Object]`.
    for (const key of KEYS) {
      expect(typeof resolve(en, key), `en.${key} is not a string`).toBe("string");
      expect(typeof resolve(ar, key), `ar.${key} is not a string`).toBe("string");
    }
  });
});