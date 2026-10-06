/**
 * `i18n/index` - the console's translation instance.
 *
 * ## Why this file is a rule, not a convenience
 *
 * `admin-console-screens.md` §4 rule 2: no user-facing string may live in a component. Arabic ships at
 * launch, so a string literal in a component is an untranslated string on day one - not a debt, a bug.
 * Centralising the catalogues is what makes `tests/i18n.test.ts` able to fail the build when a key exists in
 * `en.json` and not `ar.json`.
 *
 * ## `ar` is not `ar-EG` on purpose
 *
 * The locale is `ar` with `lng: "ar-EG"`. Egyptian Arabic and Modern Standard Arabic differ in more than
 * orthography, and `Intl` needs the region to place digits and separators correctly. antd, by contrast, keys
 * its own locale packs as `ar_EG`, which is why `antdLocaleKey` exists below as a separate lookup.
 *
 * ## Direction
 *
 * `rtl` is set from the locale, and `document.documentElement.dir` is kept in sync by `applyDocumentLocale`.
 * A console that renders Arabic left-to-right is worse than one that renders nothing: the operator reads
 * mirrored layouts as broken data rather than as a styling mistake.
 */

import i18n from "i18next";
import { initReactI18next } from "react-i18next";

import ar from "./ar.json";
import en from "./en.json";

/** A locale this console ships. */
export type Locale = "en" | "ar";

export const SUPPORTED_LOCALES: readonly Locale[] = ["en", "ar"];

/** The BCP-47 tag sent to `Intl` and to Supabase. */
const INTL_TAG: Readonly<Record<Locale, string>> = {
  en: "en-EG",
  ar: "ar-EG",
};

/** antd's own locale pack keys, which use underscores. Mapped separately from `INTL_TAG` on purpose. */
const ANTD_LOCALE_KEY: Readonly<Record<Locale, string>> = {
  en: "en_US",
  ar: "ar_EG",
};

/** The `direction` for a locale. Derived rather than stored so the two cannot disagree. */
export function directionFor(locale: Locale): "ltr" | "rtl" {
  return locale === "ar" ? "rtl" : "ltr";
}

export function intlTagFor(locale: Locale): string {
  return INTL_TAG[locale];
}

export function antdLocaleKeyFor(locale: Locale): string {
  return ANTD_LOCALE_KEY[locale];
}

/**
 * Reads the operator's language from the browser, defaulting to English.
 *
 * `navigator.language` is `ar-EG` in Egypt and `en-GB` in the UK, so the match is on the primary subtag
 * rather than on the whole tag. An exact match on `ar-EG` would miss `ar`, and the console would open in
 * English for an Arabic-speaking operator in every browser that reports a different region.
 */
export function detectLocale(navigatorLanguage: string | undefined): Locale {
  if (navigatorLanguage === undefined) {
    return "en";
  }
  const primary = navigatorLanguage.split("-")[0]?.toLowerCase();
  return primary === "ar" ? "ar" : "en";
}

/**
 * Keeps `<html lang>` and `<html dir>` in step with the locale.
 *
 * Screen readers announce the `lang` of the document. Without this, an Arabic console in an English browser
 * is read by an English voice, which is the same failure as rendering it left-to-right.
 */
export function applyDocumentLocale(locale: Locale, doc: Document): void {
  doc.documentElement.lang = INTL_TAG[locale];
  doc.documentElement.dir = directionFor(locale);
}

export const resources = {
  en: { translation: en },
  ar: { translation: ar },
} as const;

/**
 * `escapeValue: false`.
 *
 * The console interpolates values that contain `&`, `<` and `>` - an entity name, a free-text reason typed
 * by an operator - and i18next's default escaping would render `Kofta & Sons` as `Kofta &amp; Sons`.
 * React escapes on render, so escaping here as well would double-encode. The trade is that these strings are
 * never injected as raw HTML, which is true because every one of them goes through a JSX text node.
 */
void i18n.use(initReactI18next).init({
  resources,
  lng: "en",
  fallbackLng: "en",
  interpolation: { escapeValue: false },
  returnNull: false,
});

export default i18n;