/**
 * Bundled-font registry (DESIGN §3.2, loading contract in `design-rules.md`).
 *
 * Pure asset map — no `expo-font` import, so tests can assert the registry
 * without loading the native module. The hook that consumes it lives in
 * `useAppFonts.ts`; the registration names below are what `fontFamily`
 * styles reference, and a mismatch renders fallback type with no error.
 */
import ibmPlexSansArabic from "../../assets/fonts/IBMPlexSansArabic-Regular.ttf";
import ibmPlexSansArabicBold from "../../assets/fonts/IBMPlexSansArabic-Bold.ttf";
import jetBrainsMono from "../../assets/fonts/JetBrainsMono-Variable.ttf";
import materialSymbolsSharp400 from "../../assets/fonts/MaterialSymbolsSharp-400.ttf";
import materialSymbolsSharp400Filled from "../../assets/fonts/MaterialSymbolsSharp-400-Filled.ttf";
import materialSymbolsSharp600 from "../../assets/fonts/MaterialSymbolsSharp-600.ttf";
import materialSymbolsSharp600Filled from "../../assets/fonts/MaterialSymbolsSharp-600-Filled.ttf";
import spaceGrotesk from "../../assets/fonts/SpaceGrotesk-Variable.ttf";

/**
 * Registration name → bundled file. Keys must equal the family names in
 * `design-rules.md` exactly; values are bundler asset references (Metro
 * numbers on device, paths under other bundlers) — never fetched URLs.
 */
export const FONT_ASSETS = {
  SpaceGrotesk: spaceGrotesk,
  JetBrainsMono: jetBrainsMono,
  IBMPlexSansArabic: ibmPlexSansArabic,
  "IBMPlexSansArabic-Bold": ibmPlexSansArabicBold,
  "MaterialSymbolsSharp-400": materialSymbolsSharp400,
  "MaterialSymbolsSharp-400-Filled": materialSymbolsSharp400Filled,
  "MaterialSymbolsSharp-600": materialSymbolsSharp600,
  "MaterialSymbolsSharp-600-Filled": materialSymbolsSharp600Filled,
} as const;

export type FontRegistrationName = keyof typeof FONT_ASSETS;
