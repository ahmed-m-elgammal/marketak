/**
 * Arabic plural rendering (DESIGN §13.5, §18 digits rule).
 *
 * Arabic has six CLDR categories; `Intl.PluralRules("ar")` is the authority,
 * not a hand-rolled `count === 1` check. Counts interpolate through shared
 * `formatCount`, so digits follow the locale system: Arabic-Indic in
 * telemetry prose per §18, Western digits where the monospace layout must
 * hold (§13.3).
 */
import { formatCount, type Language } from "@marketak/shared";

export type ArabicPluralCategory = "zero" | "one" | "two" | "few" | "many" | "other";

export function arabicPluralCategory(count: number): ArabicPluralCategory {
  return new Intl.PluralRules("ar").select(count);
}

/** The string-table key holding this count's form: `${base}.${category}`. */
export function pluralKey(base: string, count: number): string {
  return `${base}.${arabicPluralCategory(count)}`;
}

const COUNT_TOKEN = "{count}";

export function fillCount(template: string, count: number, lang: Language): string {
  return template.replace(COUNT_TOKEN, formatCount(count, lang));
}
