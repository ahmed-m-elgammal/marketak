import { describe, expect, it } from "vitest";
import { UI_INVENTORY } from "./inventory";

const SECTIONS = ["9.1", "9.2", "9.3", "9.4", "9.5", "9.6", "9.7", "9.8", "9.9", "9.10", "9.11", "9.12"] as const;

/** Wrappers no kit provides (DESIGN §§9.2/9.9/9.10 + the §15 bans). */
const CUSTOM_BUILT = [
  "emergency-control",
  "slide-rail",
  "radio",
  "switch",
  "square-loader",
  "scanner-overlay",
  "signature-pad",
  "proof-photo",
  "route-stepper",
] as const;

describe("wrapper inventory", () => {
  it("names every wrapper once", () => {
    const names = UI_INVENTORY.map((entry) => entry.wrapper);
    expect(new Set(names).size).toBe(names.length);
  });

  it("covers every DESIGN §9 subsection", () => {
    const covered = new Set(UI_INVENTORY.map((entry) => entry.designRef));
    for (const section of SECTIONS) {
      expect(covered.has(section)).toBe(true);
    }
  });

  it("marks exactly the no-kit set custom-built", () => {
    const custom = UI_INVENTORY.filter((entry) => entry.source.kind === "custom").map(
      (entry) => entry.wrapper,
    );
    expect([...custom].sort()).toEqual([...CUSTOM_BUILT].sort());
  });

  it("backs menu and avatar photography with expo-image", () => {
    const backed = UI_INVENTORY.filter((entry) => entry.source.kind === "expo-image").map(
      (entry) => entry.wrapper,
    );
    expect(backed).toContain("photo-image");
    expect(backed).toContain("avatar-image");
  });

  it("names the kit component behind every tamagui entry", () => {
    for (const entry of UI_INVENTORY) {
      if (entry.source.kind === "tamagui") {
        expect(entry.source.component.length).toBeGreaterThan(0);
      }
    }
  });
});
