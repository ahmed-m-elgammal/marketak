/**
 * src/theme/tokens.ts - the TypeScript mirror of `src/global.css`.
 *
 * ## Why this file exists when global.css already holds the tokens
 *
 * `@theme` in `global.css` is the source of truth for every *class* utility, and it is the form that
 * satisfies constitution rule 2. But a handful of native APIs take a raw string rather than a class
 * name - `expo-system-ui`'s `setBackgroundColorAsync`, a `StatusBar` background, an
 * `expo-image` `placeholder` blurhash, a chart series that must read a colour out as a value. Those
 * need the value, not the utility.
 *
 * So: **class utilities read `global.css`; native APIs read this file.** Both are transcribed from
 * `imgs/design.md` §2 and `src/theme/design-rules.md`, and they must agree.
 *
 * ## The drift this can cause, and why it is worth the risk
 *
 * Two files holding the same numbers will eventually disagree. A test that parses `@theme` and
 * asserts equality with this object is the correct fix and is deliberately NOT written yet - the app
 * has one screen, so it would be a test of a constant against itself. It becomes worth writing the
 * moment a second native API needs a value here.
 *
 * Names are prefixed `color`/`spacing`/`radius` rather than reusing Tailwind's, so an import is
 * unambiguous about which module it came from.
 */

/** Brand - the 10%. The only saturated colour on screen, so a CTA is the only thing that pops. */
export const color = {
  /* 60% - canvas. The surface everything sits on. */
  cream: "#F8F5EE",

  /* 30% - content. Cards, sheets, inputs, and the ink on them. */
  surface: "#FFFFFF",
  surfaceSubtle: "#F4F2EC",
  ink: "#17211E",
  inkSecondary: "#66716C",
  inkTertiary: "#89928D",
  line: "#E2E5E0",
  lineStrong: "#B8C2BB",

  /* 10% - action. */
  brand: "#123F35",
  brandPressed: "#0D3029",
  brandSoft: "#E5EEE9",

  /* Status - the only exemption from the 10%. Meaning, never decoration. */
  success: "#24734E",
  warning: "#946116",
  danger: "#B42318",
  info: "#245C87",

  /* Modal and sheet backdrop. */
  scrim: "#17211E80",
} as const;

/** 4-point grid. The complete set - there is no 5, 7, 9 or 11 to reach for. */
export const spacing = {
  "1": 4,
  "2": 8,
  "3": 12,
  "4": 16,
  "5": 20,
  "6": 24,
  "8": 32,
  "10": 40,
  "12": 48,
  "16": 64,
} as const;

/** Radius expresses hierarchy, so containers do not all round the same way. */
export const radius = {
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  pill: 999,
} as const;

/** Type scale. Eight sizes; weights limited to regular, medium, semibold, bold. */
export const text = {
  display: 32,
  h1: 28,
  h2: 22,
  h3: 18,
  body: 16,
  bodyMedium: 16,
  bodySmall: 14,
  label: 13,
  caption: 12,
  button: 16,
  price: 18,
  priceSmall: 14,
} as const;

/** Two families, and two is the ceiling. See design-rules.md §5. */
export const font = {
  /** Latin and numerals. */
  sans: "Inter",
  /** Arabic. Kept separate only because the two scripts need different metrics. */
  arabic: "Cairo",
} as const;
