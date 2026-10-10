/**
 * Language-object picker (specs-mobile §§8b/11, mobile README §9).
 *
 * Notification `title`/`body`, promo slots and vendor names arrive as
 * `{ar, en}` jsonb objects, never strings. This is the one place a language
 * key is chosen — `domain/` never imports `i18n/`, so the language travels
 * as an argument.
 *
 * Fallback order: requested → primary (`ar`, the live `users` default) →
 * the other language → `""`. An explicitly empty string counts as missing:
 * a translation that renders nothing is not a translation.
 */
import { PRIMARY_LANGUAGE, type Language } from "@marketak/shared";

export interface LangString {
  readonly ar?: string;
  readonly en?: string;
}

export function pickLang(value: string | LangString | null | undefined, lang: Language): string {
  if (typeof value === "string") return value;
  if (value === null || value === undefined) return "";
  const wanted = value[lang];
  if (wanted !== undefined && wanted !== "") return wanted;
  const primary = value[PRIMARY_LANGUAGE];
  if (primary !== undefined && primary !== "") return primary;
  const other = value[lang === "ar" ? "en" : "ar"];
  if (other !== undefined) return other;
  return "";
}
