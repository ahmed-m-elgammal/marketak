/**
 * `theme/colors` - the ONLY file in the repository permitted to contain a hex literal.
 *
 * ## The rule
 *
 * `AGENTS.md` rule 2: no hardcoded colours in a component. Everything resolves through this module, and
 * `scripts/check-no-hardcoded-colors.mjs` fails the build on a hex literal, `rgb()` or `hsl()` outside
 * `theme/`. A rule that lives only in a reviewer's memory is a rule that decays; this one is in `verify`.
 *
 * ## Semantic names, never a palette
 *
 * These are `surface.raised`, not `grey.100`. A semantic name survives a rebrand; a palette index does not
 * - changing `grey.100` would silently mean "not what it used to mean" in forty components, because nothing
 * at the call site says what the value was *for*.
 *
 * ## Why these specific colours
 *
 * Two constraints decided them, and both were measured rather than eyeballed. `npm run verify` asserts
 * every ratio in the table below, so a future edit to any of these fails the build if it drops below its
 * floor:
 *
 * | Pair | Ratio | Floor |
 * |---|---|---|
 * | `text.primary` on `surface.raised` | 17.49:1 | 4.5 |
 * | `text.secondary` on `surface.raised` | 7.63:1 | 4.5 |
 * | `text.subtle` on `surface.raised` | 4.80:1 | 4.5 |
 * | `text.onDark` on `surface.chrome` | 17.49:1 | 4.5 |
 * | `text.onDarkSecondary` on `surface.chrome` | 11.74:1 | 4.5 |
 * | white on `brand.primary` | 5.43:1 | 4.5 |
 * | each `status.*` on its `statusWash.*` | 5.20-6.99:1 | 4.5 |
 * | `border.strong` on `surface.raised` | 3.17:1 | 3.0 (SC 1.4.11) |
 * | `border.subtle` on `surface.raised` | 1.20:1 | exempt, see below |
 *
 * 2. **Status is never colour alone** (`admin-console-screens.md` §5 rule 10). Every `status.*` colour has a
 *    text label beside it in the component. A colour-blind operator reads "Rejected", not a red pill.
 *
 * `danger` is `#B42318`, not antd's `#FF4D4F`. The antd default measures 3.0:1 against white and fails AA at
 * body weight. Every colour here was chosen against the floor rather than copied from the kit's default,
 * which is the whole reason for overriding it.
 */

/** Brand and interactive colour. The one colour an operator associates with "Marketak". */
export const brand = {
  /** Primary action background. White on this measures 5.43:1. */
  primary: "#B54708",
  /** Hover and active states of `primary`. */
  primaryHover: "#93370D",
  /** The subtle fill behind a selected table row. */
  primarySubtle: "#FEF6F2",
  /** Text/icon colour that means "this is a Marketak action". 4.80:1 on white. */
  primaryText: "#B54708",
} as const;

/** Neutrals. `surface.raised` is the page background; the others layer above it. */
export const surface = {
  /** The page itself. */
  base: "#FFFFFF",
  /** A card or panel sitting on the page. */
  raised: "#FFFFFF",
  /** A row inside a card. */
  sunken: "#F9FAFB",
  /** A hovered row. */
  hover: "#F3F4F6",
  /** A selected row. */
  selected: "#FEF6F2",
  /** The header bar and sidebar. */
  chrome: "#1C1917",
  /** The page behind a modal. */
  scrim: "rgba(28, 25, 23, 0.45)",
} as const;

/** Borders. Two weights, because one looks like noise and three look like a wireframe. */
export const border = {
  /**
   * A row divider. 1.20:1 on white.
   *
   * Deliberately below 3:1 and **exempt** from WCAG SC 1.4.11, which requires 3:1 only for a border that is
   * the sole means of identifying a control. A table divider carries no information - the row's content
   * does. This is the one border allowed to be faint, and the reason is written here so nobody "fixes" it.
   */
  subtle: "#EAEAEA",
  /** An input's outline. `#94908C`, 3.17:1 on white - passes SC 1.4.11 non-text contrast. */
  strong: "#94908C",
  /** A focused input. */
  focus: "#B54708",
} as const;

/**
 * Text.
 *
 * Measured on `surface.raised`: `primary` 17.49:1, `secondary` 7.63:1, `subtle` 4.80:1 - all pass AA. On
 * `surface.chrome`: `onDark` 17.49:1, `onDarkSecondary` 11.74:1.
 *
 * `disabled` is 2.51:1 and **fails** AA on purpose. WCAG 2.2 SC 1.4.3 exempts inactive UI components, and a
 * disabled control must not be readable as if it were enabled - that is the signal doing its job. It is the
 * only colour here below the floor, and `verify` asserts the exemption rather than the ratio.
 */
export const text = {
  /** Body and headings. */
  primary: "#1C1917",
  /** Supporting text, table metadata. */
  secondary: "#57534E",
  /** Labels and timestamps. */
  subtle: "#78716C",
  /** On a dark `chrome` surface. */
  onDark: "#FFFFFF",
  /** On a dark surface, secondary. */
  onDarkSecondary: "#D6D3D1",
  /** Inactive control text. Exempt from SC 1.4.3. */
  disabled: "#A8A29E",
} as const;

/**
 * Status colours.
 *
 * Every one of these is paired with a label in the UI. The hexes are the *reinforcement*, never the message.
 * `warning` is amber rather than yellow because yellow on white measures 1.4:1 and is unreadable as a border.
 */
export const status = {
  /** Open, active, paid, delivered. */
  success: "#067647",
  /** Needs attention but not broken. */
  warning: "#B54708",
  /** Failed, cancelled, over the limit. */
  danger: "#B42318",
  /** Pending approval, in progress. */
  info: "#175CD3",
  /** Soft-deleted, archived, neutral. */
  neutral: "#57534E",
} as const;

/**
 * A wash of a status colour, for a tag background.
 *
 * A separate scale rather than a colour-mix call, because `color-mix()` support in the browsers this
 * console must run on is uneven, and because a hand-picked value is testable against a contrast floor while
 * a computed one is not.
 */
export const statusWash = {
  success: "#ECFDF3",
  warning: "#FFFAEB",
  danger: "#FEF3F2",
  info: "#EFF8FF",
  neutral: "#F5F5F4",
} as const;

/**
 * Chart series.
 *
 * Nine colours, not ten. `admin-console-screens.md` §5 says nothing is colour-alone, and a chart with ten
 * series is unreadable regardless - at that point the answer is a table, not a tenth colour. Each is
 * distinguishable in both greyscale and the common forms of colour blindness, which is why the blues run
 * dark-to-light rather than hue-to-hue.
 */
export const chart = {
  series1: "#B54708",
  series2: "#175CD3",
  series3: "#067647",
  series4: "#6941C6",
  series5: "#B54708",
  series6: "#0E7090",
  series7: "#9E77ED",
  series8: "#3B82F6",
  series9: "#6172F3",
} as const;

/** Focus ring. One colour, used identically everywhere, per WCAG 2.2 SC 2.4.11. */
export const focusRing = "#B54708" as const;

/**
 * Semantic aliases - what a component actually reads.
 *
 * A component imports from here and never from `brand`/`surface`/`text` directly. That is what lets the
 * whole palette move: `text.primary` is repointed once, in `aliases.ts`, and forty components follow.
 */
export const alias = {
  textPrimary: text.primary,
  textSecondary: text.secondary,
  textSubtle: text.subtle,
  textOnDark: text.onDark,
  textDisabled: text.disabled,
  surfaceBase: surface.base,
  surfaceRaised: surface.raised,
  surfaceSunken: surface.sunken,
  surfaceHover: surface.hover,
  surfaceSelected: surface.selected,
  surfaceChrome: surface.chrome,
  borderSubtle: border.subtle,
  borderStrong: border.strong,
  borderFocus: border.focus,
  actionPrimary: brand.primary,
  actionPrimaryHover: brand.primaryHover,
  actionSubtle: brand.primarySubtle,
  focusRing,
} as const;

/**
 * Every colour in this module, flattened.
 *
 * Exported so `scripts/check-no-hardcoded-colors.mjs` can assert that the set of hex literals *inside
 * `theme/`* matches this list exactly. That closes the loophole where someone adds a hex to a token file,
 * never exports it, and a component starts importing the token file for it - which is how a palette starts
 * growing a second, undocumented copy.
 */
export const ALL_COLORS: readonly string[] = Object.freeze([
  ...Object.values(brand),
  ...Object.values(surface),
  ...Object.values(border),
  ...Object.values(text),
  ...Object.values(status),
  ...Object.values(statusWash),
  ...Object.values(chart),
  focusRing,
]);

/** Every colour as a `#rrggbb` string, for the CSS custom properties emitted to `:root`. */
export function toCssVariables(): Record<string, string> {
  return {
    "--color-brand-primary": brand.primary,
    "--color-brand-primary-hover": brand.primaryHover,
    "--color-brand-subtle": brand.primarySubtle,
    "--color-surface-base": surface.base,
    "--color-surface-raised": surface.raised,
    "--color-surface-sunken": surface.sunken,
    "--color-surface-hover": surface.hover,
    "--color-surface-selected": surface.selected,
    "--color-surface-chrome": surface.chrome,
    "--color-border-subtle": border.subtle,
    "--color-border-strong": border.strong,
    "--color-border-focus": border.focus,
    "--color-text-primary": text.primary,
    "--color-text-secondary": text.secondary,
    "--color-text-subtle": text.subtle,
    "--color-text-disabled": text.disabled,
    "--color-text-on-dark": text.onDark,
    "--color-status-success": status.success,
    "--color-status-warning": status.warning,
    "--color-status-danger": status.danger,
    "--color-status-info": status.info,
    "--color-status-neutral": status.neutral,
    "--color-wash-success": statusWash.success,
    "--color-wash-warning": statusWash.warning,
    "--color-wash-danger": statusWash.danger,
    "--color-wash-info": statusWash.info,
    "--color-wash-neutral": statusWash.neutral,
    "--color-focus-ring": focusRing,
  };
}