/**
 * Tests for the formatters and the route table.
 *
 * The formatter tests exist because the two mistakes they guard against are the ones an operator acts on:
 * rendering `multiplier_bps` raw (12,500× instead of 1.25×) and formatting a date in the browser's timezone
 * rather than the city's, which shows a different day than the number beside it.
 */

import { describe, expect, it } from "vitest";

import {
  formatRateBps,
  formatRelativeInZone,
  formatWhen,
  multiplierFromBps,
} from "@marketak/shared";

import { formatAmount, formatMultiplier, toMapHref, toTelHref } from "../i18n/format.js";
import { detectLocale, directionFor, intlTagFor } from "../i18n/index.js";
import {
  PUBLIC_PATHS,
  SCREENS,
  SECTIONS,
  builtScreens,
  isPublicPath,
  sidebarScreens,
} from "../app/routes.js";

/**
 * Rates, multipliers and timestamps are formatted by `packages/shared`, not here.
 *
 * A0.3 requires the console to consume that formatting rather than reimplement it. The functions under test
 * are the shared ones; the console's own contribution is the `{en, ar}` to BCP-47 mapping in `intlTagFor`,
 * which is what the wrappers below exercise.
 */
const EN = intlTagFor("en");

describe("multipliers", () => {
  it("turns basis points into a factor", () => {
    // `set_fee_tier_v1` takes multiplier_bps. 12500 bps is a 1.25x multiplier.
    expect(multiplierFromBps(12_500)).toBe(1.25);
    expect(multiplierFromBps(10_000)).toBe(1);
  });

  it("renders a factor, never the raw basis points", () => {
    // The mistake this prevents: an operator reads `12500` and applies a 12,500x delivery fee.
    const rendered = formatMultiplier(12_500);
    expect(rendered).toBe("1.25x");
    expect(rendered).not.toContain("12500");
  });

  it("returns undefined for a non-finite input rather than printing NaNx", () => {
    // A formatter that can print `NaN` will eventually do so on a screen, and `NaNx` is worse than `NaN`.
    expect(formatRateBps(Number.NaN, EN)).toBeUndefined();
    expect(formatRateBps(Number.POSITIVE_INFINITY, EN)).toBeUndefined();
    expect(formatMultiplier(Number.NaN)).toBeUndefined();
  });
});

describe("rates", () => {
  it("renders basis points as a percentage", () => {
    // `completion_rate_bps = 8425` is 84.25%, and every rate in get_admin_metrics_v1 arrives this way.
    const rendered = formatRateBps(8_425, EN);
    expect(rendered).toContain("84");
    expect(rendered).toContain("%");
    expect(rendered).not.toContain("8425");
  });
});

describe("money", () => {
  it("formats piastres with the currency attached", () => {
    // Never a bare number with a symbol guessed at the call site: constitution 7 makes currency
    // configuration, and `formatMoney` deliberately has no default.
    const rendered = formatAmount(33_000, "EGP");
    expect(rendered).toBeDefined();
    expect(rendered).toContain("EGP");
  });

  it("returns undefined for a non-integer amount", () => {
    // The schema stores money as integers. A float reaching here means something upstream divided it, and
    // printing the float would show a figure the database never held.
    expect(formatAmount(330.5, "EGP")).toBeUndefined();
    // `bpchar` PADS, so a city row can arrive as "EGP " and another as "EGP".
    expect(formatAmount(33_000, "EGP ")).toBeUndefined();
    expect(formatAmount(33_000, "egp")).toBeUndefined();
  });

  it("differs between locales, because Arabic numerals are not the same characters", () => {
    expect(formatAmount(33_000, "EGP", "en")).not.toBe(formatAmount(33_000, "EGP", "ar"));
  });
});

describe("times", () => {
  const instant = "2026-10-06T14:32:00.000Z";

  it("formats in the city's timezone, not the browser's", () => {
    // Egypt REINTRODUCED daylight saving in 2023, so Africa/Cairo is UTC+3 on 6 October 2026, not UTC+2.
    // An earlier version of this test asserted "16:32" and its comment repeated the mistake - the same
    // unverified assumption written twice, which is how it survived.
    //
    // Two things are asserted, and the split matters:
    // - `cairo !== utc` is the real invariant: the hour came from `timeZone`, not from the runner.
    // - the literal is checked with `en-GB`, which uses a 24-hour clock. `en-EG` - the console's English tag -
    //   renders 17:32 as "5:32 PM", so asserting "17:32" against it is asserting a clock format, not a
    //   timezone.
    const cairo = formatWhen(instant, "Africa/Cairo", EN);
    const utc = formatWhen(instant, "UTC", EN);
    expect(cairo).toBeDefined();
    expect(utc).toBeDefined();
    expect(cairo).not.toBe(utc);

    expect(formatWhen(instant, "Africa/Cairo", "en-GB")).toContain("17:32");
  });

  it("uses a relative form inside 24 hours and an absolute one outside", () => {
    // "23 hours ago" is unhelpful on a support ticket; an absolute time is what gets copied into one.
    const now = new Date("2026-10-06T20:00:00.000Z");
    expect(formatRelativeInZone(instant, EN, now)).toBeDefined();

    const yesterday = "2026-10-05T08:00:00.000Z";
    expect(formatRelativeInZone(yesterday, EN, now)).toBeUndefined();
    expect(formatWhen(yesterday, "Africa/Cairo", EN, now)).toContain("Oct");
  });

  it("returns undefined for an unparseable instant", () => {
    expect(formatWhen("not a date", "Africa/Cairo", EN)).toBeUndefined();
  });

  it("returns undefined for a future instant, which means clock skew", () => {
    // A delivered order cannot be "in 3 minutes". Rendering it as relative time hides a real discrepancy.
    const now = new Date("2026-10-06T12:00:00.000Z");
    expect(formatRelativeInZone("2026-10-06T12:03:00.000Z", EN, now)).toBeUndefined();
  });
});

describe("links an operator can actually use", () => {
  it("builds a tel: href, converting Arabic-Indic digits", () => {
    // An Egyptian keyboard produces ٠١٢٣, and `tel:` with those fails silently on iOS. "The call button
    // does nothing" is a bug nobody can reproduce from a screenshot.
    expect(toTelHref("٠١٠٠٠٠٠٠٠٠٠")).toBe("tel:01000000000");
    expect(toTelHref("+20 100 000 0000")).toBe("tel:+201000000000");
  });

  it("refuses a tel: href for something too short to be a number", () => {
    expect(toTelHref("")).toBeUndefined();
    expect(toTelHref("123")).toBeUndefined();
  });

  it("builds a map href from coordinates", () => {
    // Rule 7: `30.0444, 31.2357` is not information a person can use.
    expect(toMapHref(30.0444, 31.2357)).toContain("30.0444");
    expect(toMapHref(null, 31.2357)).toBeUndefined();
    expect(toMapHref(Number.NaN, 31.2357)).toBeUndefined();
  });
});

describe("locale detection", () => {
  it("matches on the primary subtag, not the whole tag", () => {
    // An exact match on `ar-EG` would miss `ar` and open an Arabic console in English for an operator in
    // every browser that reports a different region.
    expect(detectLocale("ar-EG")).toBe("ar");
    expect(detectLocale("ar")).toBe("ar");
    expect(detectLocale("ar-SA")).toBe("ar");
  });

  it("defaults to English for an unknown or absent language", () => {
    expect(detectLocale("en-GB")).toBe("en");
    expect(detectLocale("fr-FR")).toBe("en");
    expect(detectLocale(undefined)).toBe("en");
  });

  it("derives direction from the locale rather than storing it", () => {
    // Two sources of truth for the same fact would eventually disagree, and a console rendering Arabic
    // left-to-right reads as corrupt data rather than as a styling fault.
    expect(directionFor("ar")).toBe("rtl");
    expect(directionFor("en")).toBe("ltr");
  });
});

describe("the screen table", () => {
  it("has a unique path for every screen", () => {
    // A duplicate path silently shadows a screen, and the shadowed one becomes unreachable with no error.
    const paths = SCREENS.map((screen) => screen.path);
    expect(new Set(paths).size).toBe(paths.length);
  });

  it("has a unique key for every screen", () => {
    const keys = SCREENS.map((screen) => screen.key);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("assigns every screen to a declared section", () => {
    for (const screen of SCREENS) {
      expect(SECTIONS).toContain(screen.section);
    }
  });

  it("gives every screen a phase, so an unbuilt row states when it stops being empty", () => {
    for (const screen of SCREENS) {
      expect(screen.phase, `${screen.key} has no phase`).toMatch(/^A\d/u);
    }
  });

  it("gives an element to a built screen and to an unbuilt one nothing", () => {
    // The invariant that replaced the old "every screen has an element". That assertion encoded the stub-page
    // decision - six modules whose whole body was "not built" - which `AGENTS.md` rule 3 forbids. Now the
    // asymmetry IS the rule: a screen is either implemented and routed, or absent and 404s.
    for (const screen of SCREENS) {
      if (screen.element === undefined) {
        continue;
      }
      expect(screen.phase, `${screen.key} is built but has no phase`).toMatch(/^A\d/u);
    }
    expect(builtScreens().length).toBeGreaterThan(0);
    expect(builtScreens().length).toBeLessThan(SCREENS.length);
  });

  it("lists only built screens in the sidebar", () => {
    // Detail pages have no sidebar entry; a list has one. And an unbuilt screen has nothing to navigate to,
    // so listing it would send an operator to a 404 from the sidebar itself.
    const sidebarKeys = sidebarScreens().map((screen) => screen.key);
    expect(sidebarKeys).toContain("dashboard");
    expect(sidebarKeys).not.toContain("merchants");
    for (const screen of sidebarScreens()) {
      expect(screen.element, `${screen.key} is in the sidebar but unbuilt`).toBeDefined();
    }
  });

  it("marks the sign-in and 403 paths public, and nothing else", () => {
    // `/403` is public because a signed-in non-admin who follows a deep link must get an explanation rather
    // than a redirect loop back to sign-in they cannot satisfy.
    expect(isPublicPath("/403")).toBe(true);
    expect(isPublicPath("/sign-in")).toBe(true);
    expect(isPublicPath("/merchants")).toBe(false);
    expect(PUBLIC_PATHS).toHaveLength(2);
  });

  it("covers every sidebar screen of every section", () => {
    for (const section of SECTIONS) {
      expect(
        SCREENS.some((screen) => screen.section === section),
        `section ${section} has no screen`,
      ).toBe(true);
    }
  });
});