import { describe, expect, it } from "vitest";
import { colors, radius, spacing, touch } from "./tokens";

/**
 * Locks DESIGN §6 (zero radius), §4 (4px grid, targets) and the §2.5
 * contrast rules that can be computed: prohibitions are asserted as
 * failures (< threshold) so the rule, not just the passing pairs, is
 * pinned. Thresholds follow §2.5 (4.5:1 text, 3:1 non-text UI).
 */

function parseChannels(value: string): readonly [number, number, number, number] {
  const hex = /^#([0-9a-fA-F]{6})$/.exec(value);
  if (hex?.[1] !== undefined) {
    const n = Number.parseInt(hex[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255, 1];
  }
  const rgba = /^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([\d.]+)\s*\)$/.exec(value);
  if (rgba?.[1] !== undefined && rgba[2] !== undefined && rgba[3] !== undefined && rgba[4] !== undefined) {
    return [Number(rgba[1]), Number(rgba[2]), Number(rgba[3]), Number(rgba[4])];
  }
  throw new Error(`Unparseable token value: ${value}`);
}

function compositeOver(fg: string, bg: string): readonly [number, number, number] {
  const [r, g, b, a] = parseChannels(fg);
  const [br, bgc, bb] = parseChannels(bg);
  return [r * a + br * (1 - a), g * a + bgc * (1 - a), b * a + bb * (1 - a)];
}

function luminance(rgb: readonly [number, number, number]): number {
  const [r, g, b] = rgb.map((v) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * (r ?? 0) + 0.7152 * (g ?? 0) + 0.0722 * (b ?? 0);
}

function ratio(fg: string, bg: string): number {
  const l1 = luminance(compositeOver(fg, bg));
  const l2 = luminance(compositeOver(bg, bg));
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}

const RASTER_0 = colors["surface-raster-0"];
const RASTER_1 = colors["surface-raster-1"];
const RASTER_2 = colors["surface-raster-2"];

describe("zero radius", () => {
  it("sets every radius token to 0 (§6)", () => {
    for (const value of Object.values(radius)) {
      expect(value).toBe(0);
    }
  });
});

describe("grid and targets", () => {
  it("keeps spacing on the 4px grid (§4)", () => {
    for (const value of Object.values(spacing)) {
      expect(value % 4).toBe(0);
    }
  });

  it("keeps touch targets at 56/48 minimum (§4.3)", () => {
    expect(touch.targetPrimary).toBe(56);
    expect(touch.targetSecondary).toBe(48);
    expect(touch.targetMin).toBe(48);
  });
});

describe("contrast rules (§2.5)", () => {
  it("forbids cobalt-electric as text, border or line on dark", () => {
    expect(ratio(colors["cobalt-electric"], RASTER_0)).toBeLessThan(3);
  });

  it("uses high-beam for lines and rings on raster-0/1, never text on raster-2", () => {
    expect(ratio(colors["cobalt-high-beam"], RASTER_0)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(colors["cobalt-high-beam"], RASTER_1)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(colors["cobalt-high-beam"], RASTER_2)).toBeLessThan(4.5);
  });

  it("puts void-base text on electric and crimson fills, never white on either", () => {
    expect(ratio(colors.white, colors["cobalt-electric"])).toBeGreaterThanOrEqual(3);
    expect(ratio(colors["void-base"], colors["alert-crimson"])).toBeGreaterThanOrEqual(3);
    expect(ratio(colors.white, colors["alert-crimson"])).toBeLessThan(4.5);
    expect(ratio(colors.white, colors["cobalt-high-beam"])).toBeLessThan(4.5);
  });

  it("allows crimson text on raster-0/1 only", () => {
    expect(ratio(colors["alert-crimson"], RASTER_0)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(colors["alert-crimson"], RASTER_1)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(colors["alert-crimson"], RASTER_2)).toBeLessThan(4.5);
  });

  it("keeps body text pairs at 4.5:1", () => {
    expect(ratio(colors["text-primary"], RASTER_0)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(colors["text-muted"], RASTER_0)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(colors["text-placeholder"], RASTER_0)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(colors["telemetry-cyan"], RASTER_0)).toBeGreaterThanOrEqual(4.5);
  });

  it("keeps control borders at 3:1 on every raster", () => {
    for (const bg of [RASTER_0, RASTER_1, RASTER_2] as const) {
      expect(ratio(colors["wire-border-control"], bg)).toBeGreaterThanOrEqual(3);
    }
  });

  it("keeps vertical and state colors legible as text on raster-0", () => {
    for (const token of [
      "vertical-food",
      "vertical-grocery",
      "vertical-pharmacy",
      "vertical-parcel",
      "dispatch-amber",
      "success-radar",
    ] as const) {
      expect(ratio(colors[token], RASTER_0)).toBeGreaterThanOrEqual(4.5);
    }
  });
});
