import { describe, expect, it } from "vitest";
import { FONT_ASSETS, type FontRegistrationName } from "./fonts";

const EXPECTED: readonly FontRegistrationName[] = [
  "SpaceGrotesk",
  "JetBrainsMono",
  "IBMPlexSansArabic",
  "IBMPlexSansArabic-Bold",
  "MaterialSymbolsSharp-400",
  "MaterialSymbolsSharp-400-Filled",
  "MaterialSymbolsSharp-600",
  "MaterialSymbolsSharp-600-Filled",
];

describe("font registry", () => {
  it("registers exactly the loading-contract families (design-rules.md)", () => {
    expect(Object.keys(FONT_ASSETS).sort()).toEqual([...EXPECTED].sort());
  });

  it("resolves every family to a bundled asset reference, never a URL", () => {
    for (const asset of Object.values(FONT_ASSETS)) {
      expect(asset).toBeDefined();
      expect(String(asset).startsWith("http")).toBe(false);
    }
  });
});
