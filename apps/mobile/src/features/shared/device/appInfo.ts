/**
 * Device facts for registration (F-08). Thin by design: three native reads,
 * no branches worth testing. Untested at unit level — `expo-constants`,
 * `expo-localization` and `Platform` need the device, and every decision
 * built on these values is asserted where it is made.
 */
import Constants from "expo-constants";
import * as Localization from "expo-localization";
import { resolveLanguage } from "../../../i18n/index";
import type { Language } from "@marketak/shared";

/** The device's real language (device_tokens.language is per registration). */
export function deviceLanguage(): Language {
  return resolveLanguage(Localization.getLocales().map((locale) => locale.languageTag));
}

/** The running build's version, or null when the manifest carries none. */
export function appVersion(): string | null {
  const version = Constants.expoConfig?.version;
  return typeof version === "string" && version !== "" ? version : null;
}
