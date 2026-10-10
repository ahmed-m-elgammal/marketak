/**
 * Design tokens, transcribed from the DESIGN.md frontmatter (canonical).
 *
 * Precedence: frontmatter wins over prose; this module wins over every other
 * styling surface. `tailwind.config.js` mirrors the subset utilities need and
 * `tamagui.config.ts` consumes this module directly - a value is added here
 * first (procedure in `design-rules.md`), never invented at a call site.
 * Nothing here is a literal: every number below is a frontmatter value.
 */

export const colors = {
  "cobalt-electric": "#1D4ED8",
  "cobalt-high-beam": "#3B82F6",
  "cobalt-recessed": "#172554",
  "telemetry-cyan": "#00F0FF",
  "dispatch-amber": "#F59E0B",
  "alert-crimson": "#EF4444",
  "success-radar": "#10B981",
  "vertical-food": "#F97316",
  "vertical-grocery": "#84CC16",
  "vertical-pharmacy": "#06B6D4",
  "vertical-parcel": "#94A3B8",
  white: "#FFFFFF",
  "void-base": "#020408",
  "surface-raster-0": "#080C14",
  "surface-raster-1": "#0F172A",
  "surface-raster-2": "#1E293B",
  "row-alt": "#0B0F19",
  "text-primary": "#DFE2F1",
  "text-muted": "#94A3B8",
  "text-placeholder": "#7C8AA0",
  "text-disabled": "#64748B",
  "wire-border-dim": "rgba(255, 255, 255, 0.08)",
  "wire-border-mid": "rgba(255, 255, 255, 0.16)",
  "wire-border-control": "rgba(255, 255, 255, 0.40)",
  "wire-border-active": "#3B82F6",
  "focus-ring": "#3B82F6",
  scrim: "rgba(2, 4, 8, 0.72)",
  "tint-success": "rgba(16, 185, 129, 0.12)",
  "tint-pharmacy": "rgba(6, 182, 212, 0.12)",
  "tint-food": "rgba(249, 115, 22, 0.12)",
  "tint-grocery": "rgba(132, 204, 22, 0.12)",
  "tint-parcel": "rgba(148, 163, 184, 0.12)",
  "tint-amber": "rgba(245, 158, 11, 0.12)",
  "tint-crimson": "rgba(239, 68, 68, 0.12)",
} as const;
export type ColorToken = keyof typeof colors;

/** 4px grid scale (`space-*`). */
export const spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 32,
  "2xl": 40,
  "3xl": 48,
} as const;

/** Zero roundedness: every key is 0, by contract (§6). */
export const radius = {
  none: 0,
  sm: 0,
  md: 0,
  lg: 0,
  xl: 0,
  full: 0,
} as const;

/** Type scale: family, px size, weight, px line height, tracking. */
export const typography = {
  displayLg: {
    fontFamily: "SpaceGrotesk",
    fontSize: 48,
    fontWeight: "700",
    lineHeight: 52,
    letterSpacing: "-0.03em",
  },
  displayLgMobile: {
    fontFamily: "SpaceGrotesk",
    fontSize: 32,
    fontWeight: "700",
    lineHeight: 36,
    letterSpacing: "-0.02em",
  },
  headlineXl: {
    fontFamily: "SpaceGrotesk",
    fontSize: 28,
    fontWeight: "700",
    lineHeight: 36,
    letterSpacing: "-0.02em",
  },
  headlineXlMobile: {
    fontFamily: "SpaceGrotesk",
    fontSize: 22,
    fontWeight: "700",
    lineHeight: 28,
    letterSpacing: "-0.01em",
  },
  headlineMd: {
    fontFamily: "SpaceGrotesk",
    fontSize: 20,
    fontWeight: "600",
    lineHeight: 28,
    letterSpacing: "-0.01em",
  },
  titleLg: {
    fontFamily: "SpaceGrotesk",
    fontSize: 18,
    fontWeight: "600",
    lineHeight: 24,
    letterSpacing: "0em",
  },
  titleMd: {
    fontFamily: "SpaceGrotesk",
    fontSize: 16,
    fontWeight: "600",
    lineHeight: 24,
    letterSpacing: "0em",
  },
  codeLg: {
    fontFamily: "JetBrainsMono",
    fontSize: 28,
    fontWeight: "700",
    lineHeight: 36,
    letterSpacing: "0em",
  },
  bodyLg: {
    fontFamily: "JetBrainsMono",
    fontSize: 16,
    fontWeight: "400",
    lineHeight: 24,
    letterSpacing: "-0.01em",
  },
  bodyMd: {
    fontFamily: "JetBrainsMono",
    fontSize: 14,
    fontWeight: "400",
    lineHeight: 20,
    letterSpacing: "0em",
  },
  bodySm: {
    fontFamily: "JetBrainsMono",
    fontSize: 12,
    fontWeight: "400",
    lineHeight: 16,
    letterSpacing: "0.01em",
  },
  labelLg: {
    fontFamily: "JetBrainsMono",
    fontSize: 13,
    fontWeight: "600",
    lineHeight: 16,
    letterSpacing: "0.04em",
  },
  labelMd: {
    fontFamily: "JetBrainsMono",
    fontSize: 11,
    fontWeight: "500",
    lineHeight: 16,
    letterSpacing: "0.06em",
  },
  labelCaps: {
    fontFamily: "JetBrainsMono",
    fontSize: 11,
    fontWeight: "700",
    lineHeight: 16,
    letterSpacing: "0.12em",
  },
} as const;
export type TypographyToken = keyof typeof typography;

/** Motion durations (ms) and easings. */
export const motion = {
  durationInstant: 0,
  durationFast: 100,
  durationBase: 160,
  durationSlow: 240,
  durationPulse: 1200,
  easingLinear: "linear",
  easingStandard: "cubic-bezier(0.2, 0, 0, 1)",
} as const;

/** Z-order, low to high. */
export const zIndex = {
  map: 0,
  sheet: 10,
  navigation: 20,
  banner: 30,
  toast: 40,
  modal: 50,
  systemAlert: 60,
} as const;

/** Touch targets and gaps (px). */
export const touch = {
  targetPrimary: 56,
  targetSecondary: 48,
  targetMin: 48,
  hitGapMin: 8,
} as const;

/** Pane and chrome dimensions (px). */
export const layout = {
  railWidth: 80,
  deckWidth: 380,
  inspectorWidth: 320,
  canvasMinWidth: 360,
  contentMaxWidth: 640,
  dialogMaxWidth: 480,
  actionMaxWidth: 480,
  topbarHeight: 56,
  tabbarHeight: 56,
  bannerHeight: 48,
  sheetPeekHeight: 120,
} as const;

/** Stroke widths (px). */
export const borders = {
  hairline: 1,
  emphasis: 2,
  focus: 2,
  route: 4,
} as const;

/** Icon sizes (px) and weights per role. */
export const icons = {
  sizeSm: 20,
  sizeMd: 24,
  sizeLg: 32,
  weightCourier: 600,
  weightCustomer: 400,
} as const;

/**
 * Font families. Names must match the `expo-font` registration names in the
 * loading contract (`design-rules.md`): the config below references these
 * strings, and a mismatch renders fallback type with no error.
 */
export const fonts = {
  display: "SpaceGrotesk",
  body: "JetBrainsMono",
  arabic: "IBMPlexSansArabic",
  icons: "MaterialSymbolsSharp",
} as const;
