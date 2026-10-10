/**
 * Arabic label treatment (DESIGN §13.5).
 *
 * Small labels are uppercase-with-tracking in Latin (§3.1, via transform so
 * translations stay editable). Scripts with no case or joining letters take
 * no uppercase transform and zero tracking. Screens spread this onto label
 * text; English keeps the token tracking by leaving it `undefined`.
 */
import type { Language } from "@marketak/shared";

export interface LabelTreatment {
  readonly textTransform: "none" | "uppercase";
  readonly letterSpacing: 0 | undefined;
}

export function labelTreatment(lang: Language): LabelTreatment {
  if (lang === "ar") return { textTransform: "none", letterSpacing: 0 };
  return { textTransform: "uppercase", letterSpacing: undefined };
}
