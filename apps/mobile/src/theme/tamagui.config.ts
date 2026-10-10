/**
 * Tamagui configuration.
 *
 * Built from `./tokens` (the canonical source), NOT from
 * `@tamagui/config-default`: the default config carries web palettes and
 * fonts this dark-only native app must never render. What is defined here:
 *
 * - `tokens`: color/space/size/radius/zIndex, every value from `./tokens`.
 *   `size` mirrors the 4px grid (§4: everything is on a 4px grid).
 * - `themes.dark`: the only theme. Framework slots (`background`,
 *   `color`, `borderColor`…) filled from raster tiers; there is no light
 *   theme to switch to, so components may also read `./tokens` directly.
 * - `media`: DESIGN §4.1 window-width classes, transcribed as max/min
 *   widths. Layout reads the live window; these keys name the classes.
 * - `shorthands`: the stock Tamagui set, unmodified.
 *
 * Deliberately absent: `animations` (motion values live in `./tokens`; the
 * driver wires up with the first animated component).
 *
 * Location note: this file lives in `src/theme/` rather than the project
 * root so `tsc`, ESLint and dependency-cruiser all see it — a root-level
 * `.ts` file belongs to no tsconfig `include` and to no lint scope.
 */
import { createFont, createTamagui } from "tamagui";
import { shorthands } from "@tamagui/shorthands";
import { borders, colors, fonts, layout, motion, radius, spacing, typography, zIndex } from "./tokens";

/**
 * Token tracking is em; Tamagui/RN `letterSpacing` is px. The conversion is
 * tracking × slot px — derived, not invented. Native-only: `react-native-web`
 * was refused, so no web em path exists to keep in sync.
 */
function trackingPx(tracking: string, px: number): number {
  return Number.parseFloat(tracking) * px;
}

/**
 * The three type voices, derived slot-by-slot from `./tokens` — a value is
 * never written here directly, so the Tamagui font scale cannot drift from
 * the canonical scale. `arabic` reuses the body slots in
 * `IBMPlexSansArabic`; only Regular 400 and Bold 700 ship (§3.2), so the
 * 500/600 slots collapse to the nearest shipped weight.
 */
const heading = createFont({
  family: fonts.display,
  size: {
    displayLg: typography.displayLg.fontSize,
    displayLgMobile: typography.displayLgMobile.fontSize,
    headlineXl: typography.headlineXl.fontSize,
    headlineXlMobile: typography.headlineXlMobile.fontSize,
    headlineMd: typography.headlineMd.fontSize,
    titleLg: typography.titleLg.fontSize,
    titleMd: typography.titleMd.fontSize,
  },
  lineHeight: {
    displayLg: typography.displayLg.lineHeight,
    displayLgMobile: typography.displayLgMobile.lineHeight,
    headlineXl: typography.headlineXl.lineHeight,
    headlineXlMobile: typography.headlineXlMobile.lineHeight,
    headlineMd: typography.headlineMd.lineHeight,
    titleLg: typography.titleLg.lineHeight,
    titleMd: typography.titleMd.lineHeight,
  },
  weight: {
    displayLg: typography.displayLg.fontWeight,
    displayLgMobile: typography.displayLgMobile.fontWeight,
    headlineXl: typography.headlineXl.fontWeight,
    headlineXlMobile: typography.headlineXlMobile.fontWeight,
    headlineMd: typography.headlineMd.fontWeight,
    titleLg: typography.titleLg.fontWeight,
    titleMd: typography.titleMd.fontWeight,
  },
  letterSpacing: {
    displayLg: trackingPx(typography.displayLg.letterSpacing, typography.displayLg.fontSize),
    displayLgMobile: trackingPx(typography.displayLgMobile.letterSpacing, typography.displayLgMobile.fontSize),
    headlineXl: trackingPx(typography.headlineXl.letterSpacing, typography.headlineXl.fontSize),
    headlineXlMobile: trackingPx(typography.headlineXlMobile.letterSpacing, typography.headlineXlMobile.fontSize),
    headlineMd: trackingPx(typography.headlineMd.letterSpacing, typography.headlineMd.fontSize),
    titleLg: trackingPx(typography.titleLg.letterSpacing, typography.titleLg.fontSize),
    titleMd: trackingPx(typography.titleMd.letterSpacing, typography.titleMd.fontSize),
  },
});

const body = createFont({
  family: fonts.body,
  size: {
    codeLg: typography.codeLg.fontSize,
    bodyLg: typography.bodyLg.fontSize,
    bodyMd: typography.bodyMd.fontSize,
    bodySm: typography.bodySm.fontSize,
    labelLg: typography.labelLg.fontSize,
    labelMd: typography.labelMd.fontSize,
    labelCaps: typography.labelCaps.fontSize,
  },
  lineHeight: {
    codeLg: typography.codeLg.lineHeight,
    bodyLg: typography.bodyLg.lineHeight,
    bodyMd: typography.bodyMd.lineHeight,
    bodySm: typography.bodySm.lineHeight,
    labelLg: typography.labelLg.lineHeight,
    labelMd: typography.labelMd.lineHeight,
    labelCaps: typography.labelCaps.lineHeight,
  },
  weight: {
    codeLg: typography.codeLg.fontWeight,
    bodyLg: typography.bodyLg.fontWeight,
    bodyMd: typography.bodyMd.fontWeight,
    bodySm: typography.bodySm.fontWeight,
    labelLg: typography.labelLg.fontWeight,
    labelMd: typography.labelMd.fontWeight,
    labelCaps: typography.labelCaps.fontWeight,
  },
  letterSpacing: {
    codeLg: trackingPx(typography.codeLg.letterSpacing, typography.codeLg.fontSize),
    bodyLg: trackingPx(typography.bodyLg.letterSpacing, typography.bodyLg.fontSize),
    bodyMd: trackingPx(typography.bodyMd.letterSpacing, typography.bodyMd.fontSize),
    bodySm: trackingPx(typography.bodySm.letterSpacing, typography.bodySm.fontSize),
    labelLg: trackingPx(typography.labelLg.letterSpacing, typography.labelLg.fontSize),
    labelMd: trackingPx(typography.labelMd.letterSpacing, typography.labelMd.fontSize),
    labelCaps: trackingPx(typography.labelCaps.letterSpacing, typography.labelCaps.fontSize),
  },
});

const arabic = createFont({
  // Only Regular 400 and Bold 700 ship (§3.2, `fonts.ts`); the two literals
  // below are the shipped files, not invented weights. Tracking is 0 on
  // every slot (§13.5 — scripts that join letters take no tracking).
  family: fonts.arabic,
  size: {
    codeLg: typography.codeLg.fontSize,
    bodyLg: typography.bodyLg.fontSize,
    bodyMd: typography.bodyMd.fontSize,
    bodySm: typography.bodySm.fontSize,
    labelLg: typography.labelLg.fontSize,
    labelMd: typography.labelMd.fontSize,
    labelCaps: typography.labelCaps.fontSize,
  },
  lineHeight: {
    codeLg: typography.codeLg.lineHeight,
    bodyLg: typography.bodyLg.lineHeight,
    bodyMd: typography.bodyMd.lineHeight,
    bodySm: typography.bodySm.lineHeight,
    labelLg: typography.labelLg.lineHeight,
    labelMd: typography.labelMd.lineHeight,
    labelCaps: typography.labelCaps.lineHeight,
  },
  weight: {
    codeLg: "700",
    bodyLg: "400",
    bodyMd: "400",
    bodySm: "400",
    labelLg: "700",
    labelMd: "400",
    labelCaps: "700",
  },
  letterSpacing: {
    codeLg: 0,
    bodyLg: 0,
    bodyMd: 0,
    bodySm: 0,
    labelLg: 0,
    labelMd: 0,
    labelCaps: 0,
  },
});

export const config = createTamagui({
  fonts: { heading, body, arabic },
  tokens: {
    color: { ...colors },
    // Tamagui sizes up/down from a `true` default at RUNTIME (a typecheck
    // cannot catch its absence — this exact crash reached a live boot
    // before any gate did). `true` is the default size, not a new value:
    // md (16), matching size.true.
    space: { ...spacing, true: spacing.md },
    size: {
      0: 0,
      1: 4,
      2: 8,
      3: 12,
      4: 16,
      true: 16,
      5: 20,
      6: 24,
      7: 32,
      8: 40,
      9: 48,
      10: 56,
    },
    radius: {
      0: radius.none,
      1: radius.none,
      2: radius.none,
      3: radius.none,
      4: radius.none,
      true: radius.none,
    },
    // Tamagui requires zIndex keys to overlap the size scale (same
    // runtime validation as above — read from its bundle, not guessed).
    // Slots follow the §5 level order low→high with token values;
    // components keep the named tokens (`zIndex.modal`), the kit uses
    // these slots internally.
    zIndex: {
      0: zIndex.map,
      1: zIndex.sheet,
      2: zIndex.navigation,
      3: zIndex.banner,
      4: zIndex.toast,
      5: zIndex.modal,
      6: zIndex.systemAlert,
    },
  },
  themes: {
    dark: {
      background: colors["surface-raster-0"],
      backgroundHover: colors["surface-raster-1"],
      backgroundFocus: colors["surface-raster-1"],
      backgroundPress: colors["surface-raster-2"],
      borderColor: colors["wire-border-mid"],
      color: colors["text-primary"],
      placeholderColor: colors["text-placeholder"],
      shadowColor: colors["cobalt-electric"],
    },
  },
  media: {
    xs: { maxWidth: 599 },
    sm: { minWidth: 600, maxWidth: 839 },
    md: { minWidth: 840, maxWidth: 1199 },
    lg: { minWidth: 1200 },
  },
  shorthands,
  settings: {
    fastSchemeChange: false,
  },
});

export type AppConfig = typeof config;

declare module "tamagui" {
  // eslint-disable-next-line @typescript-eslint/no-empty-object-type
  interface TamaguiCustomConfig extends AppConfig {}
}

export default config;

/** Re-exported so the motion tokens stay reachable without a second source. */
export { borders, layout, motion };
