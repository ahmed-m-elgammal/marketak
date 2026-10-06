/**
 * `i18n/use-locale` - reading the active locale outside of a translation lookup.
 *
 * ## Why this exists
 *
 * `formatAmount` needs a `Locale` to pick an `Intl` tag, and `t()` already resolves inside React. Anything
 * that calls a formatter - a table cell, a `Money` component, a chart axis - needs the locale as a *value*.
 *
 * The obvious implementation is a second i18next instance or a React context, and both are wrong here: the
 * locale is already state inside i18next, so duplicating it into a context would create two sources that can
 * disagree. This reads i18next's own state and subscribes to its change event, so there is nothing to keep in
 * sync.
 */

import { useEffect, useState } from "react";

import i18n, { SUPPORTED_LOCALES, type Locale } from "./index.js";

/**
 * The active locale, narrowed to one this console ships.
 *
 * Narrowed rather than cast: `i18n.language` is `string` and can be `"en-GB"` or `"ar"`, and the narrowing
 * is what turns a possible typo in a formatter call into a compile error.
 */
export function useLocale(): Locale {
  const [locale, setLocale] = useState<Locale>(() => current());

  useEffect(() => {
    const onChanged = (next: string): void => {
      setLocale(narrow(next));
    };
    i18n.on("languageChanged", onChanged);
    return () => {
      i18n.off("languageChanged", onChanged);
    };
  }, []);

  return locale;
}

function current(): Locale {
  return narrow(i18n.language);
}

function narrow(language: string): Locale {
  const primary = language.split("-")[0]?.toLowerCase() ?? "en";
  return SUPPORTED_LOCALES.find((locale) => locale === primary) ?? "en";
}