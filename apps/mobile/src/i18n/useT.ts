/**
 * String lookup hook (mobile README §1, L5 one home).
 *
 * Takes the language as an argument — `domain/` and feature state never
 * import `i18n/`, so the resolved language travels down from the composition
 * root rather than being read from a module singleton. Lookup falls back
 * requested → Arabic (primary) → the key itself, so a missing translation
 * renders a greppable key, never `undefined` and never an empty control.
 */
import { useMemo } from "react";
import type { Language } from "@marketak/shared";
import ar from "./ar.json";
import en from "./en.json";

const TABLES: Readonly<Record<Language, Readonly<Record<string, string>>>> = { ar, en } as const;

export interface Translator {
  readonly t: (key: string) => string;
  readonly lang: Language;
  readonly isRTL: boolean;
}

/** Pure lookup: requested → Arabic (primary) → the key itself. */
export function translate(lang: Language, key: string): string {
  const table: Readonly<Record<string, string>> = TABLES[lang];
  return table[key] ?? TABLES.ar[key] ?? key;
}

export function useT(lang: Language): Translator {
  return useMemo<Translator>(() => {
    const t = (key: string): string => translate(lang, key);
    return { t, lang, isRTL: lang === "ar" };
  }, [lang]);
}
