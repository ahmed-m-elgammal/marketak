/**
 * Font boot hook, consumed once by the composition root (`app/_layout.tsx`).
 *
 * Thin by design: `expo-font` `useFonts` does the work, this module only
 * pins the asset map. Untested at unit level — loading real TTFs is a
 * device concern, and the registry it draws from is asserted in
 * `fonts.test.ts`.
 */
import { useFonts } from "expo-font";
import { FONT_ASSETS } from "./fonts";

export function useAppFonts(): readonly [boolean, Error | null] {
  return useFonts(FONT_ASSETS);
}
