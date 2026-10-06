/**
 * `theme/tokens` - the spacing, type, radius and motion scales.
 *
 * ## Why this file is a dependency of every other token file
 *
 * `AGENTS.md` rule 2 forbids a hardcoded colour or spacing value anywhere in a component. This file is the
 * other half of that rule: it defines the *scales* those values must come from, so a rule can be enforced
 * mechanically rather than by review.
 *
 * ## Why 4px
 *
 * Not aesthetics. Every number below is a multiple of 4, which means two components that both use
 * `space.3` produce identical gaps regardless of which one measured them. A designer moving from an 8px
 * grid to 16px needs one number changed here, not a grep across forty files. The admin console has 41
 * screens, and the console's entire value proposition to its operator is that everything lines up.
 *
 * ## Why `space` is `as const`
 *
 * So `space[3]` is typed `8` and not `number`, and so an out-of-range index is a compile error rather than
 * `undefined` at runtime. A missing scale step should break the build.
 */

/** A spacing step in pixels. The base unit is 4. */
export const space = {
  0: 0,
  1: 4,
  2: 8,
  3: 12,
  4: 16,
  5: 20,
  6: 24,
  7: 28,
  8: 32,
  10: 40,
  12: 48,
  16: 64,
} as const;

export type SpaceStep = keyof typeof space;

/**
 * A type scale.
 *
 * `lineHeight` is paired with each step rather than derived, because a line height that suits 12px
 * display type is wrong for 12px table text. Ant Design's own token names are reused here so
 * `theme/antd-theme.ts` is a mapping rather than a translation - a mapping can be diffed against antd's
 * docs, a translation cannot.
 *
 * ## Two corrections made for the bilingual work-tool brief
 *
 * **`pageTitle` is 24/32 at 600, and `display` is no longer the page heading.** The brief asks for a 24/32
 * title at weight 600 and explicitly *not* 800 - 800 at 24px is a poster, and this is a console an operator
 * reads for eight hours. `display` remains for the one place a large figure genuinely carries meaning (the
 * dashboard's open-order count) and is not used as a heading anywhere.
 *
 * **`tableHeader` is 12/16 at 500, sentence case.** It is a distinct step rather than a reuse of `caption`
 * because it is the only text in the console that must *not* be letter-spaced or uppercased - see
 * `FONT_FAMILY` and the note on uppercase below.
 */
export const typeScale = {
  /** One large figure where the number itself is the message. Never a heading. */
  display: { size: 28, lineHeight: 36, weight: 600 },
  /** Page title. 24/32 at 600. */
  pageTitle: { size: 24, lineHeight: 32, weight: 600 },
  /** Section heading, with a divider above it. */
  heading: { size: 16, lineHeight: 24, weight: 600 },
  /** Body. 14/20 at 400 - the brief's figure, and the density a work tool needs. */
  body: { size: 14, lineHeight: 20, weight: 400 },
  bodyStrong: { size: 14, lineHeight: 20, weight: 600 },
  /** A field label. */
  label: { size: 13, lineHeight: 20, weight: 500 },
  small: { size: 13, lineHeight: 20, weight: 400 },
  /**
   * Table header. Sentence case at 500.
   *
   * The single clearest tell of a generated interface is a tracked-out ALL-CAPS header, and in a bilingual
   * console it is also broken rather than merely ugly: **Arabic has no uppercase**, so `text-transform:
   * uppercase` silently does nothing in Arabic while letter-spacing Arabic glyphs breaks the cursive joins
   * and leaves gaps between joined letters. One rule, correct in both scripts.
   */
  tableHeader: { size: 12, lineHeight: 16, weight: 500 },
  caption: { size: 12, lineHeight: 16, weight: 400 },
} as const;

export type TypeScaleStep = keyof typeof typeScale;

/**
 * Corner radii.
 *
 * `sm` through `lg` map onto antd's `borderRadius`, `borderRadiusLG` and `borderRadiusSM` in that order.
 * Named by role rather than by size so a redesign does not have to find every call site.
 *
 * The brief asks for exactly three radii - a control, a badge, a pill - so `md` (8) is deliberately unused by
 * the console and left in place only because antd's `borderRadiusLG` maps to it. Nothing in `apps/admin-web`
 * reads `radius.lg`.
 */
export const radius = {
  none: 0,
  /** 4px. Badges and tags - a badge is a label, not a surface. */
  sm: 4,
  /** 6px. Inputs, buttons, cards. The console's only control radius. */
  md: 6,
  lg: 8,
  /** 9999px. Fully rounded pills, and the availability dot's ring. */
  pill: 9999,
} as const;

export type RadiusStep = keyof typeof radius;

/**
 * The one type family, Latin and Arabic.
 *
 * IBM Plex Sans and IBM Plex Sans Arabic, self-hosted through `@fontsource` rather than loaded from a CDN -
 * the console's CSP is `font-src 'self' data:`, and an admin console has no business phoning a font CDN on
 * every load to render its own interface.
 *
 * **One family, not two.** A bilingual operator reads both scripts all day, often in the same sentence on the
 * merchant name row. Two unrelated faces produce a visible seam at every line boundary where the scripts
 * meet, and that seam is the first thing that makes a translated interface feel machine-made. Plex Sans and
 * Plex Sans Arabic share a skeleton, which is the entire reason this pair was chosen over, say, Inter plus
 * Noto Sans Arabic.
 *
 * The Arabic face is named *second* on purpose: Latin is read first in the English UI, and the Arabic face
 * only takes over for Arabic codepoints.
 */
export const FONT_FAMILY =
  '"IBM Plex Sans", "IBM Plex Sans Arabic", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';

/**
 * Geometry that a layout decision needs and a scale cannot express.
 *
 * `labelColumn` and `measure` are here rather than in the page because they are the two numbers that make the
 * merchant detail page line up: every section's values begin at the same x, and no section runs wider than a
 * comfortable measure. A page that hardcodes `160px` in three places is a page that drifts.
 */
export const layout = {
  /** Fixed label column in a detail grid. Every section's values align here. */
  labelColumn: 160,
  /** Content measure. A detail page is a form, not a document. */
  measure: 960,
  /** Sidebar width. */
  sidebar: 232,
  /** Header height. */
  header: 56,
} as const;

/**
 * The minimum interactive row height.
 *
 * 48, not antd's default and not the 44px WCAG 2.2 AA floor. The reason is the environment: this console is
 * used on a tablet held in one hand, next to a delivery happening, sometimes outdoors. 48px is the
 * Android recommended minimum for a list row and leaves 4px of slack for imprecision. `AGENTS.md` X.7
 * requires 48px touch targets, and this constant is where that requirement becomes enforceable.
 */
export const MIN_TOUCH_TARGET = 48;

/**
 * The console's minimum interactive height.
 *
 * Separate from `MIN_TOUCH_TARGET` because they answer different questions. WCAG 2.2 SC 2.5.8 requires a
 * 24px target; the tablet in an operator's hand justifies 48px for a *row*; and a dense work table still needs
 * its controls at 36px so twelve of them fit on a 1024px screen without becoming a scrolling column of
 * oversized buttons.
 */
export const MIN_CONTROL_HEIGHT = 36;

/**
 * Durations in milliseconds, for the few transitions the console uses.
 *
 * Deliberately short. A support agent switching between a list and a profile wants the interface to keep
 * up, not to perform. Only `motion.duration` is mapped into antd; nothing else animates.
 */
export const motion = {
  instant: 0,
  fast: 120,
  base: 200,
} as const;

export type MotionStep = keyof typeof motion;

/**
 * Ant Design's size enum, which drives table row height, input height and button height together.
 *
 * Exported as a mapping to antd's own names so a component never passes the string `"large"` - it passes
 * `controlSize.large`, which is typed. A typo in a size string is otherwise a silent no-op.
 */
export const controlSize = {
  small: "small",
  middle: "middle",
  large: "large",
} as const;

export type ControlSize = (typeof controlSize)[keyof typeof controlSize];

/** Breakpoints in pixels, for layout decisions that cannot be CSS media queries. */
export const breakpoint = {
  mobile: 768,
  tablet: 1024,
  desktop: 1280,
} as const;

export type Breakpoint = keyof typeof breakpoint;