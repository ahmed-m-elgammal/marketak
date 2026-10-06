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
 */
export const typeScale = {
  display: { size: 28, lineHeight: 36, weight: 600 },
  title: { size: 20, lineHeight: 28, weight: 600 },
  heading: { size: 16, lineHeight: 24, weight: 600 },
  body: { size: 14, lineHeight: 22, weight: 400 },
  bodyStrong: { size: 14, lineHeight: 22, weight: 600 },
  small: { size: 13, lineHeight: 20, weight: 400 },
  caption: { size: 12, lineHeight: 18, weight: 400 },
} as const;

export type TypeScaleStep = keyof typeof typeScale;

/**
 * Corner radii.
 *
 * `sm` through `lg` map onto antd's `borderRadius`, `borderRadiusLG` and `borderRadiusSM` in that order.
 * Named by role rather than by size so a redesign does not have to find every call site.
 */
export const radius = {
  none: 0,
  sm: 4,
  md: 6,
  lg: 8,
  pill: 9999,
} as const;

export type RadiusStep = keyof typeof radius;

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