/**
 * `@marketak/ui` - the design tokens, and nothing else.
 *
 * ## Scope, deliberately narrow
 *
 * This package exports tokens. It does not export React components, and it must not grow to. The reason is
 * the layering in `AGENTS.md`: `packages/ui` is shared between the React Native mobile app and this
 * admin console, and those two runtimes have nothing in common beyond a palette. A component here would be
 * unusable by the app, and its presence would suggest a shared component library exists when it does not.
 *
 * `antd-theme.ts` is the one file that imports a UI kit, and it exists to map tokens *into* the kit rather
 * than to distribute the kit. It is the single point where a console-only dependency enters a package the
 * mobile app also loads. That is a cost paid once, deliberately, instead of at forty call sites.
 *
 * ## Consumers
 *
 * | Package | Uses |
 * |---|---|
 * | `apps/admin-web` | `theme/antd-theme.ts` via `ConfigProvider`, plus the scales directly |
 * | `apps/mobile` | the scales and `colors.ts` only. It cannot import `antd-theme.ts` |
 */

export {
  ALL_COLORS,
  alias,
  brand,
  border,
  chart,
  focusRing,
  status,
  statusWash,
  surface,
  text,
  toCssVariables,
} from "./theme/colors.js";

export {
  breakpoint,
  controlSize,
  MIN_TOUCH_TARGET,
  motion,
  radius,
  space,
  typeScale,
  type Breakpoint,
  type ControlSize,
  type MotionStep,
  type RadiusStep,
  type SpaceStep,
  type TypeScaleStep,
} from "./theme/tokens.js";

export { buildAntdConfig, buildAntdTheme, cssVariablesBlock } from "./theme/antd-theme.js";