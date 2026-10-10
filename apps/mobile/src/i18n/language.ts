/**
 * Language resolution and RTL policy (DESIGN §13.5, specs-mobile §18).
 *
 * The account default is Arabic (live `users.preferred_language` default
 * `'ar'`, CHECK `ar|en`), so an unrecognized device locale resolves to
 * Arabic, never to the device language. Direction comes from RN core, not a
 * kit: `allowRTL` stays on, and `forceRTL` runs only when the manager
 * disagrees with the app language. The manager is injected — `I18nManager`
 * at boot, a fake in tests — because this layer imports no native modules.
 */
import { PRIMARY_LANGUAGE, type Language } from "@marketak/shared";

export function resolveLanguage(tags: readonly string[] | null | undefined): Language {
  if (tags === null || tags === undefined) return PRIMARY_LANGUAGE;
  for (const tag of tags) {
    const base = tag.split("-")[0]?.toLowerCase();
    if (base === "ar") return "ar";
    if (base === "en") return "en";
  }
  return PRIMARY_LANGUAGE;
}

export interface RtlManager {
  readonly isRTL: boolean;
  allowRTL(value: boolean): void;
  forceRTL(value: boolean): void;
}

export function applyRtlPolicy(lang: Language, manager: RtlManager): void {
  manager.allowRTL(true);
  const rtl = lang === "ar";
  if (manager.isRTL !== rtl) manager.forceRTL(rtl);
}
