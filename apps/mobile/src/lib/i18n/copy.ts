/**
 * Reads a message from ar.json / en.json.
 *
 * en.json is the type source, so a key added to Arabic but not English is a compile error.
 */

import ar from "@/lib/i18n/ar.json";
import en from "@/lib/i18n/en.json";

export type Language = "ar" | "en";

export type MessageKey = keyof typeof en;

const CATALOGUE: Readonly<Record<Language, Readonly<Record<MessageKey, string>>>> = { ar, en };

export function t(language: Language, key: MessageKey): string {
  return CATALOGUE[language][key] ?? en[key] ?? key;
}