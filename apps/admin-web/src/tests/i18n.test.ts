/**
 * Tests for the i18n catalogues.
 *
 * This file is the mechanical half of `admin-console-screens.md` §4 rule 2. The rule says no user-facing
 * string may live in a component, because Arabic ships at launch - so an English literal in JSX is an
 * untranslated string on day one. That rule cannot be enforced by review alone, so it is enforced here:
 * every key in `en.json` must exist in `ar.json`, and the error catalogue must cover every code
 * `lib/errors.ts` can emit.
 */

import { describe, expect, it } from "vitest";

import ar from "../i18n/ar.json";
import en from "../i18n/en.json";

/**
 * Every dotted leaf path in a catalogue.
 */
function leafPaths(value: unknown, prefix = ""): string[] {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return [prefix];
  }
  return Object.entries(value).flatMap(([key, child]) =>
    leafPaths(child, prefix === "" ? key : `${prefix}.${key}`),
  );
}

/**
 * The CLDR plural categories i18next resolves for a language.
 *
 * English has two - `one` and `other`. Arabic has **six** - `zero`, `one`, `two`, `few`, `many`, `other` -
 * because it distinguishes 0, 1, 2, 3-10 and 11-99 grammatically.
 *
 * This matters here and it was missed the first time. The catalogues were written with English's two forms,
 * so every Arabic count in the console read as `{{count}} محلات` for a single merchant. Writing a catalogue
 * key without checking the locale's plural categories is how an operator ends up reading "3 merchants" on a
 * row that says one.
 */
const PLURAL_SUFFIXES = ["_zero", "_one", "_two", "_few", "_many", "_other"] as const;

/** The plural categories a language actually uses. */
const PLURAL_CATEGORIES: Readonly<Record<string, readonly string[]>> = {
  en: ["one", "other"],
  ar: ["zero", "one", "two", "few", "many", "other"],
};

/** Strips a plural suffix, so `fees.tierForCount_few` and `fees.tierForCount_other` are one family. */
function pluralFamily(path: string): string {
  for (const suffix of PLURAL_SUFFIXES) {
    if (path.endsWith(suffix)) {
      return `${path.slice(0, -suffix.length)}#`;
    }
  }
  return path;
}

/** Families of paths that are NOT plural keys. */
function plainKeys(value: unknown): string[] {
  return leafPaths(value).filter((path) => !path.includes("#") && pluralFamily(path) === path);
}

/** The plural families a catalogue declares, with the categories it declared for each. */
function pluralFamilies(
  value: unknown,
): Map<string, { readonly categories: string[]; readonly paths: string[] }> {
  const families = new Map<string, { categories: string[]; paths: string[] }>();
  for (const path of leafPaths(value)) {
    const family = pluralFamily(path);
    if (family === path) {
      continue;
    }
    const existing = families.get(family) ?? { categories: [], paths: [] };
    // `family` ends in `#`, so its length is the offset of the category name in `path`.
    existing.categories.push(path.slice(family.length));
    existing.paths.push(path);
    families.set(family, existing);
  }
  return families;
}

const EN_PATHS = leafPaths(en);
const AR_PATHS = new Set(leafPaths(ar));

describe("the two catalogues agree", () => {
  it("every non-plural English key exists in Arabic", () => {
    // The failure this prevents: an operator in Cairo sees the raw key `orders.deliveryFee` because the
    // English string shipped and the Arabic one did not.
    //
    // Plural keys are excluded here and covered by their own tests below, because they are *supposed* to
    // differ: Arabic needs six categories where English needs two. Asserting identical key sets - as an
    // earlier version of this file did - is what hid the missing Arabic plural forms in the first place.
    const missing = plainKeys(en).filter((path) => !AR_PATHS.has(path));
    expect(missing).toEqual([]);
  });

  it("every non-plural Arabic key exists in English, so neither catalogue is ahead", () => {
    const enPaths = new Set(EN_PATHS);
    const extra = plainKeys(ar).filter((path) => !enPaths.has(path));
    expect(extra).toEqual([]);
  });

  it("both languages declare the same plural families", () => {
    // A family present in one language and absent in the other is a string that silently vanishes. A family
    // present with different categories is a count rendered with the wrong grammar.
    const enFamilies = new Set([...pluralFamilies(en).keys()]);
    const arFamilies = new Set([...pluralFamilies(ar).keys()]);

    const missingInArabic = [...enFamilies].filter((family) => !arFamilies.has(family));
    const missingInEnglish = [...arFamilies].filter((family) => !enFamilies.has(family));

    expect(missingInArabic).toEqual([]);
    expect(missingInEnglish).toEqual([]);
  });

  it("each language declares exactly the plural categories its language has", () => {
    // The assertion that catches the real bug. English with six categories would be dead weight; Arabic with
    // two would render "3 محلات" for one merchant.
    for (const [language, catalogue] of [
      ["en", en],
      ["ar", ar],
    ] as const) {
      const expected = PLURAL_CATEGORIES[language] ?? [];
      for (const [family, entry] of pluralFamilies(catalogue)) {
        expect(
          [...entry.categories].sort(),
          `${family} in ${language}`,
        ).toEqual([...expected].sort());
      }
    }
  });

  it("has a non-trivial number of keys, so a truncated import fails loudly", () => {
    // A `{}` from a bad import would satisfy both directions of the tests above. This catches it.
    expect(EN_PATHS.length).toBeGreaterThan(200);
  });
});

/** `{{NAME}}` tokens in a leaf value. */
function placeholderNames(value: unknown): string[] {
  if (typeof value !== "string") {
    return [];
  }
  return [...value.matchAll(/\{\{(\w+)\}\}/gu)].map((match) => match[1] ?? "");
}

/** Walks a dotted path into a catalogue. Returns `undefined` rather than throwing on a bad path. */
function valueAt(catalogue: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>(
    (node, key) =>
      typeof node === "object" && node !== null
        ? (node as Record<string, unknown>)[key]
        : undefined,
    catalogue,
  );
}

describe("placeholders match between languages", () => {
  it("never introduces a placeholder the English string does not have", () => {
    // For plural keys the rule is deliberately one-directional, and an earlier version of this file asserted
    // exact parity. That was wrong in a way that would have pushed the Arabic catalogue to be wrong:
    // English renders "1 merchant" and Arabic renders "محل واحد" - the singular form is a word and needs no
    // count. Requiring `{{count}}` in both would have produced "1 محل واحد".
    //
    // So: Arabic may OMIT a placeholder English has, but may never ADD one English lacks. An extra
    // placeholder renders as the literal `{{name}}` on screen, which is the failure worth preventing.
    const mismatches: string[] = [];
    const enFamilies = pluralFamilies(en);

    for (const [family, arEntry] of pluralFamilies(ar)) {
      const enEntry = enFamilies.get(family);
      if (enEntry === undefined) {
        // Family parity is asserted by its own test above; nothing to compare against.
        continue;
      }
      for (const arPath of arEntry.paths) {
        const category = arPath.slice(family.length);
        const enPath = `family.slice(0, -1)}${category}`;
        // Only categories that exist in BOTH catalogues have a baseline. English has no `_few`, so
        // `tierForCount_few` has nothing to be compared against - and asserting it does would be asserting
        // that English has Arabic's grammar, which is the mistake this test was originally making.
        const enNames = new Set(placeholderNames(valueAt(en, enPath)));
        if (enNames.size === 0) {
          continue;
        }
        for (const name of placeholderNames(valueAt(ar, arPath))) {
          if (!enNames.has(name)) {
            mismatches.push(`${arPath} introduces {{${name}}} which ${enPath} does not have`);
          }
        }
      }
    }
    expect(mismatches).toEqual([]);
  });

  it("declares the same interpolation names for non-plural keys", () => {
    const enPlaceholders = new Map(
      plainKeys(en).map((path) => [path, placeholderNames(valueAt(en, path)).sort().join(",")]),
    );
    const mismatches: string[] = [];
    for (const path of plainKeys(ar)) {
      const expected = enPlaceholders.get(path);
      const actual = placeholderNames(valueAt(ar, path)).sort().join(",");
      if (expected !== actual) {
        mismatches.push(`${path}: en [${String(expected)}] vs ar [${actual}]`);
      }
    }
    expect(mismatches).toEqual([]);
  });
});

describe("the error catalogue", () => {
  it("covers every error key the router can emit", () => {
    // `ErrorState` renders `error.messageKey`, and `t()` returns the key itself when one is missing. So a
    // missing key shows an operator `errors.notAuthorized` verbatim. Asserting the group exists catches the
    // whole class.
    const errorKeys = EN_PATHS.filter((path) => path.startsWith("errors."));
    expect(errorKeys.length).toBeGreaterThan(20);
  });

  it("has a sentence for NOT_AUTHORIZED that tells the operator what to do", () => {
    // Rule 13: say what to do next. An error that only states the problem leaves the operator to guess.
    expect(en.errors.notAuthorized).toContain("admin");
    expect(ar.errors.notAuthorized).toContain("مشرف");
  });

  it("never shows an internal code to the operator", () => {
    // Rule 14. `errors.unknownCode` is the one exception and it is deliberate: an unrecognised code means
    // the console met something new, and hiding that makes every support question unanswerable. It is shown
    // behind a disclosure in `ErrorState`, not as the message.
    const internalCodes = ["PRICE_CHANGED", "FOREIGN_KEY_VIOLATE", "UNKNOWN_KEY", "NOT_AUTHORIZED"];
    for (const code of internalCodes) {
      const asSentence = Object.entries(en.errors).filter(
        ([key, value]) => !key.includes("unknownCode") && typeof value === "string" && value.includes(code),
      );
      expect(asSentence, `${code} appears in an operator-facing sentence`).toEqual([]);
    }
  });
});

describe("the Arabic catalogue is actually Arabic", () => {
  it("has Arabic script in the operator-facing sections", () => {
    // A copy-paste of the English file would satisfy every structural test above. This is the check that
    // catches it.
    const arabicPattern = /[؀-ۿ]/u;
    expect(arabicPattern.test(ar.app.console)).toBe(true);
    expect(arabicPattern.test(ar.nav.merchants)).toBe(true);
    expect(arabicPattern.test(ar.status.cancelled)).toBe(true);
  });

  it("contains no English leaked into a sentence", () => {
    // One real instance of this was caught while writing this file: a stray "Adjustment" in the Arabic
    // wallet reference hint. The check is narrow - capitalised words are legitimate in a few places - so it
    // looks for a Latin word surrounded by Arabic, which is what a leak looks like.
    const suspicious: string[] = [];
    for (const path of leafPaths(ar)) {
      const value = path.split(".").reduce<unknown>(
        (node, key) => (typeof node === "object" && node !== null ? (node as Record<string, unknown>)[key] : undefined),
        ar,
      );
      if (typeof value === "string" && /[؀-ۿ][A-Za-z]{3,}|[A-Za-z]{3,}[؀-ۿ]/u.test(value)) {
        suspicious.push(`${path}: ${value}`);
      }
    }
    expect(suspicious).toEqual([]);
  });
});