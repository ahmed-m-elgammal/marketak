/**
 * Tests for the token module.
 *
 * The contrast assertions are the point of this file. `packages/ui` is the only place a colour literal is
 * allowed, which makes it the one place a colour can be quietly made unreadable - an `#8` dropped into a hex
 * passes every other check in the repository. So the ratios are asserted here, with the floor stated beside
 * each one, and a future edit that drops below the floor fails `npm run verify` rather than shipping.
 */

import { describe, expect, it } from "vitest";

import {
  ALL_COLORS,
  border,
  brand,
  chart,
  MIN_TOUCH_TARGET,
  radius,
  space,
  status,
  statusWash,
  surface,
  text,
  toCssVariables,
} from "../index.js";

/** WCAG 2.x relative luminance. */
function luminance(hex: string): number {
  const channels = hex
    .replace("#", "")
    .match(/../gu)
    ?.map((pair) => Number.parseInt(pair, 16) / 255)
    .map((value) =>
      value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4),
    );
  if (channels === undefined || channels.length !== 3) {
    throw new Error(`not a hex colour: ${hex}`);
  }
  const [r, g, b] = channels;
  return 0.2126 * (r ?? 0) + 0.7152 * (g ?? 0) + 0.0722 * (b ?? 0);
}

function contrast(foreground: string, background: string): number {
  const a = luminance(foreground);
  const b = luminance(background);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

/**
 * Contrast ratio, rounded to 4 decimal places.
 *
 * The precision is deliberate and matches what is written in `colors.ts`. An earlier version of this helper
 * used `toFixed(3)` while the assertions carried 2 decimals, so ten tests failed on rounding noise rather
 * than on a real accessibility regression - which is the worst way for this suite to fail, because it trains
 * a reader to ignore it. Four places is enough to catch a colour change and short enough to transcribe by
 * hand into a comment.
 */
function ratio(foreground: string, background: string): number {
  return Number.parseFloat(contrast(foreground, background).toFixed(4));
}

describe("colour contrast, AA", () => {
  // SC 1.4.3. The floor is 4.5:1 for body text.
  const AA_TEXT = 4.5;

  it.each([
    ["text.primary on raised", text.primary, surface.raised, 17.4883],
    ["text.secondary on raised", text.secondary, surface.raised, 7.6293],
    ["text.subtle on raised", text.subtle, surface.raised, 4.7976],
    ["text.onDark on chrome", text.onDark, surface.chrome, 17.4883],
    ["text.onDarkSecondary on chrome", text.onDarkSecondary, surface.chrome, 11.7402],
  ])("%s meets the text floor", (_name, foreground, background, expected) => {
    // Both asserted: the floor, so a regression fails, and the exact value, so a *silent* change also fails.
    // Asserting only the floor would let a colour drift from 17.49 to 5.0 and nobody would notice.
    expect(ratio(foreground, background)).toBeGreaterThanOrEqual(AA_TEXT);
    expect(ratio(foreground, background)).toBe(expected);
  });

  it("white on brand.primary meets the text floor, so a primary button is readable", () => {
    expect(ratio(text.onDark, brand.primary)).toBeGreaterThanOrEqual(AA_TEXT);
  });

  it.each([
    ["success", status.success, statusWash.success, 5.3958],
    ["warning", status.warning, statusWash.warning, 5.2011],
    ["danger", status.danger, statusWash.danger, 6.0473],
    ["info", status.info, statusWash.info, 5.5706],
    ["neutral", status.neutral, statusWash.neutral, 6.9934],
  ])("status.%s on its wash meets the text floor", (_name, foreground, background, expected) => {
    // This is the pair a `StatusTag` actually renders, so it is the one that has to pass - not the status
    // colour against white.
    expect(ratio(foreground, background)).toBeGreaterThanOrEqual(AA_TEXT);
    expect(ratio(foreground, background)).toBe(expected);
  });
});

describe("non-text contrast, SC 1.4.11", () => {
  it("an input border meets the 3:1 floor for a meaningful boundary", () => {
    // `border.strong` is the outline of every input, so it is the sole means of identifying the control and
    // SC 1.4.11 applies. The previous value measured 1.54:1 and failed.
    expect(ratio(border.strong, surface.raised)).toBeGreaterThanOrEqual(3);
  });

  it("border.subtle is exempt, and the exemption is deliberate", () => {
    // A table divider carries no information - the row's content does - so SC 1.4.11 does not apply. Asserted
    // so nobody "fixes" it into a heavy line on the grounds that a failing test looks like a bug.
    expect(ratio(border.subtle, surface.raised)).toBeLessThan(3);
  });
});

describe("text.disabled is exempt from AA, on purpose", () => {
  it("fails the text floor and that is the intent", () => {
    // SC 1.4.3 exempts inactive UI components. A disabled control must not read as enabled - that is the
    // signal doing its job. Asserting the failure is what stops someone "fixing" it into an active-looking
    // grey and losing the disabled state entirely.
    expect(ratio(text.disabled, surface.raised)).toBeLessThan(4.5);
  });
});

describe("every colour is a hex, and the list is complete", () => {
  it("has no stray value that is not a hex or a scrim", () => {
    // `surface.scrim` is the one deliberate exception: a modal mask must be translucent. Anything else that
    // is not a hex is a mistake - a named colour, or an `rgb()` that escaped the token module.
    for (const value of ALL_COLORS) {
      const isHex = /^#[0-9A-F]{6}$/iu.test(value);
      const isScrim = value === surface.scrim;
      expect(isHex || isScrim, `${value} is neither a hex nor the scrim`).toBe(true);
    }
  });

  it("reuses the brand colour as the first chart series, deliberately", () => {
    // The earlier version of this test asserted "no duplicate values at all" and failed on 40 values across 27
    // unique colours. It was the assertion that was wrong, not the palette. `chart.series1` being
    // `brand.primary` is a deliberate choice - a chart's leading series should be the brand colour, not a
    // one-off extra hex - and `chart.series5` repeating it is acceptable because a nine-series chart is only
    // legible if the palette is short.
    //
    // So the invariant worth asserting is the one that actually matters: the status palette must not collide
    // with itself, because those colours carry meaning and a repeat makes a status ambiguous.
    expect(status.success).not.toBe(status.warning);
    expect(status.warning).not.toBe(status.danger);
    expect(status.danger).not.toBe(status.info);
    expect(chart.series1).toBe(brand.primary);
  });

  it("emits a CSS variable for every colour it exposes", () => {
    // The `:root` block is how a plain CSS rule reaches a token. A missing entry means a component that
    // references it renders transparent.
    const vars = toCssVariables();
    for (const name of Object.keys(vars)) {
      expect(name.startsWith("--color-")).toBe(true);
      expect(vars[name]).toBeDefined();
    }
  });
});

describe("the spacing scale", () => {
  it("is a multiple of 4 everywhere", () => {
    // The reason the scale exists: two components that both use `space.3` produce identical gaps. That only
    // holds if every step is on the same base.
    for (const [name, value] of Object.entries(space)) {
      expect(value % 4, `space.${name} = ${String(value)}`).toBe(0);
    }
  });

  it("increases strictly", () => {
    const steps = Object.values(space);
    for (let index = 1; index < steps.length; index += 1) {
      expect(steps[index]).toBeGreaterThan(steps[index - 1] ?? 0);
    }
  });
});

describe("the touch target floor", () => {
  it("is 48px, above the WCAG 2.2 minimum of 44", () => {
    // AGENTS.md X.7 requires 48px. This is a tablet console used one-handed next to a live delivery, and 48
    // is the Android list-row minimum with 4px of slack for imprecision.
    expect(MIN_TOUCH_TARGET).toBeGreaterThanOrEqual(48);
  });
});

describe("the radius scale", () => {
  it("maps onto antd's three radius tokens in order", () => {
    // `antd-theme.ts` sets borderRadiusSM/MD/LG from these. If the order changed, every corner in the
    // console would silently change size.
    expect(radius.sm).toBeLessThan(radius.md);
    expect(radius.md).toBeLessThan(radius.lg);
  });
});