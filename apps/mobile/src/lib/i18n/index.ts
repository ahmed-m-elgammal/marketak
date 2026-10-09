/** Locale and direction. Arabic-first: users.preferred_language defaults to `ar`. */

import { getLocales } from "expo-localization";
import { t, type Language, type MessageKey } from "@/lib/i18n/copy";

export type { Language, MessageKey };

/** Arabic is RTL; English is LTR. Drives writing direction and row order. */
export function isRtl(language: Language): boolean {
  return language === "ar";
}

/**
 * Device locale, defaulting to Arabic. Not users.preferred_language: ProfileStatus does not carry
 * it yet — the RPC returns the gate booleans only.
 */
export function deviceLanguage(): Language {
  return getLocales()[0]?.languageCode === "en" ? "en" : "ar";
}

/** One call per screen, so no screen hardcodes a language. */
export function useCopy(): (key: MessageKey) => string {
  const language = deviceLanguage();
  return (key: MessageKey) => t(language, key);
}

/** Writing direction for the current locale, as `Text` and `View` expect. */
export function writingDirection(): "rtl" | "ltr" {
  return isRtl(deviceLanguage()) ? "rtl" : "ltr";
}