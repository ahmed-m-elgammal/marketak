/**
 * `theme/antd-theme` - the bridge from our tokens into Ant Design.
 *
 * ## Why this file exists
 *
 * Ant Design ships its own visual language and its own token object. `admin-console-screens.md` §4 rule 1
 * says `theme/` owns every colour, so the moment an antd component takes a default colour that is not in our
 * scale, that rule is silently broken. Ant Design's defaults are, for several tokens, **below WCAG AA** - its
 * default `colorError` measures 3.0:1 against white, which fails at body weight.
 *
 * The fix is structural rather than disciplinary: every token that can carry a colour is mapped here, from
 * our palette, and this is the only file that constructs an antd `ThemeConfig`. A component cannot reach
 * antd's defaults because there is no path from a component to one.
 *
 * ## Why antd 6 and not antd 5
 *
 * 6.6.5 is current. It requires React >= 18, supports React 19 without the `v5-patch-for-react-19`
 * shim, and keeps the same `ConfigProvider theme.token` mechanism this file depends on. Two v6 defaults were
 * changed and both are corrected here rather than left to surprise a screen later:
 *
 * - **CSS variables are enabled by default.** Tokens become CSS custom properties, so the emitted
 *   `:root` block in `css-variables.ts` is not decoration - it is how antd resolves them.
 * - **`Modal`/`Drawer` masks blur by default from 6.3.0.** Disabled here, because a blur behind a dialog is
 *   a motion effect this console does not need and it costs paint on a tablet.
 *
 * ## The seed-token strategy
 *
 * Only *seed* tokens are overridden. Everything else - the whole map and alias layers - is derived by
 * antd's algorithm from the seeds, which means hover, active and disabled states are generated rather than
 * hand-listed. Hand-listing them is how a palette ends up with two spellings of "the button hover colour",
 * one of which is wrong.
 */

import { theme as antdThemeApi, type ThemeConfig } from "antd";

import { brand, border, status, surface, text, toCssVariables } from "./colors.js";
import { motion, radius } from "./tokens.js";

/**
 * A `ThemeConfig` built entirely from our tokens.
 *
 * Exported as a function rather than a constant so the caller can pass a `direction` and get a fresh
 * object. antd documents that passing `undefined` to `theme` on a later render re-mounts the whole tree,
 * so this never returns `undefined` even when nothing overrides - it always hands antd an object.
 */
export function buildAntdTheme(locale?: string): ThemeConfig {
  return {
    // `cssVar` is on in antd 6 by default. Kept explicit with a stable KEY because the generated variable
    // names are prefixed with it, and a generated name means `getDesignToken` and our CSS can disagree
    // about the same token.
    cssVar: { key: "marketak", prefix: "mk" },
    hashed: false,

    token: {
      // --- brand ---
      colorPrimary: brand.primary,
      colorPrimaryHover: brand.primaryHover,
      colorPrimaryActive: brand.primaryHover,
      colorPrimaryBg: brand.primarySubtle,
      colorPrimaryBgHover: brand.primarySubtle,
      colorPrimaryText: brand.primaryText,
      colorPrimaryBorder: brand.primary,
      colorPrimaryBorderHover: brand.primaryHover,

      // --- success / warning / error / info ---
      // antd's own defaults are substituted, not inherited: `colorError` at #FF4D4F measures 3.0:1 on white
      // and fails AA at 14px.
      colorSuccess: status.success,
      colorSuccessBg: "#ECFDF3",
      colorSuccessBorder: status.success,
      colorWarning: status.warning,
      colorWarningBg: "#FFFAEB",
      colorWarningBorder: status.warning,
      colorError: status.danger,
      colorErrorBg: "#FEF3F2",
      colorErrorBorder: status.danger,
      colorErrorText: status.danger,
      colorInfo: status.info,
      colorInfoBg: "#EFF8FF",
      colorInfoBorder: status.info,

      // --- text ---
      colorText: text.primary,
      colorTextSecondary: text.secondary,
      colorTextTertiary: text.subtle,
      colorTextQuaternary: text.disabled,
      colorTextPlaceholder: text.disabled,
      colorTextDescription: text.subtle,
      colorTextHeading: text.primary,

      // --- surfaces ---
      colorBgBase: surface.base,
      colorBgContainer: surface.raised,
      colorBgElevated: surface.raised,
      colorBgLayout: surface.sunken,
      colorBgSpotlight: surface.chrome,
      colorBgMask: surface.scrim,

      // --- borders ---
      colorBorder: border.strong,
      colorBorderSecondary: border.subtle,
      colorSplit: border.subtle,
      colorFillSecondary: surface.sunken,
      colorFillTertiary: surface.hover,
      colorFillQuaternary: surface.hover,
      colorFillAlter: surface.sunken,

      // --- radii ---
      borderRadius: radius.md,
      borderRadiusSM: radius.sm,
      borderRadiusLG: radius.lg,
      borderRadiusXS: radius.sm,

      // --- type ---
      fontFamily:
        '-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans Arabic", "Noto Sans", Roboto, Helvetica, Arial, sans-serif',
      fontSize: 14,
      fontSizeLG: 16,
      fontSizeSM: 13,
      fontSizeHeading1: 28,
      fontSizeHeading2: 20,
      fontSizeHeading3: 16,
      fontSizeHeading4: 16,
      lineHeight: 1.5714285714285714,
      lineHeightLG: 1.5,
      lineHeightSM: 1.5384615384615385,
      lineWidth: 1,
      fontWeightStrong: 600,

      // --- motion ---
      motionDurationFast: String(motion.fast) + "ms",
      motionDurationMid: String(motion.base) + "ms",
      motionDurationSlow: String(motion.base) + "ms",
      motionEaseInOut: "cubic-bezier(0.645, 0.045, 0.355, 1)",
      motionEaseOut: "cubic-bezier(0.215, 0.61, 0.355, 1)",

      // --- wireframe ---
      wireframe: false,
      zIndexPopupBase: 1000,
    },

    components: {
      // A table row must be 48px, not antd's ~54 for `middle` on this token set or ~39 for `small`. The
      // override is per-component because the global `size` would also change every button and input.
      Table: {
        headerBg: surface.sunken,
        headerColor: text.secondary,
        headerSplitColor: border.subtle,
        rowHoverBg: surface.hover,
        cellPaddingBlock: 12,
        cellPaddingInline: 12,
        borderColor: border.subtle,
      },
      Button: {
        primaryShadow: "none",
        defaultShadow: "none",
        dangerShadow: "none",
        fontWeight: 400,
      },
      Menu: {
        itemBg: surface.chrome,
        subMenuItemBg: surface.chrome,
        itemColor: text.onDarkSecondary,
        itemSelectedBg: brand.primary,
        itemSelectedColor: text.onDark,
        itemHeight: 48,
      },
      Layout: {
        siderBg: surface.chrome,
        headerBg: surface.raised,
        bodyBg: surface.base,
      },
      Input: {
        activeBorderColor: border.focus,
        hoverBorderColor: border.strong,
        paddingBlock: 6,
      },
      Select: {
        optionSelectedBg: brand.primarySubtle,
      },
      Modal: {
        titleFontSize: 16,
      },
      Drawer: {
        paddingLG: 20,
      },
      Card: {
        headerBg: "transparent",
        headerFontSize: 16,
      },
      Statistic: {
        titleFontSize: 13,
        contentFontSize: 24,
      },
      Alert: {
        withDescriptionPadding: "16px 20px",
      },
    },

    // `locale` here is antd's own locale pack key (`en_US` / `ar_EG`), not an i18next locale. Omitted when
    // undefined rather than set to a literal, because passing a wrong key silently falls back to English.
    ...(locale === undefined ? {} : { locale }),
  };
}

/**
 * The `ConfigProvider` props that are NOT theme tokens.
 *
 * antd 6 moved these out of `theme.components` and onto `ConfigProvider` itself, and the compiler enforces
 * the move - `Modal.mask` and `Tag.styles` are rejected inside `components`. That is a useful kind of strict:
 * the two are genuinely different mechanisms. `components.Modal.titleFontSize` is a design token derived from
 * the palette; `modal.mask.blur` is a runtime rendering behaviour with no palette meaning.
 *
 * Returned separately so the caller has one object to spread and cannot half-apply it.
 */
export interface AntdConfig {
  readonly theme: ThemeConfig;
  readonly direction: "ltr" | "rtl";
  /** antd's own locale pack key, `en_US` or `ar_EG`. Undefined leaves antd on its default. */
  readonly locale?: string;
  readonly modal: { readonly mask: { readonly blur: boolean } };
  readonly drawer: { readonly mask: { readonly blur: boolean } };
  readonly tag: { readonly styles: { readonly root: { readonly marginInlineEnd: number } } };
}

/**
 * The full `ConfigProvider` configuration.
 *
 * `algorithm` is set explicitly rather than omitted. antd documents that omitting it changes derived tokens
 * in v6, and the symptom - hover and active states that do not derive from the seed colour - is invisible in
 * a screenshot until somebody clicks a button.
 */
export function buildAntdConfig(locale?: string): AntdConfig {
  const theme = buildAntdTheme(locale);
  return {
    theme: { ...theme, algorithm: antdThemeApi.defaultAlgorithm },
    // Replaced by the real direction once the locale is wired in A2. Arabic is a launch language, so RTL is
    // the default from the first commit rather than a retrofit.
    direction: locale !== undefined && locale.startsWith("ar") ? "rtl" : "ltr",
    ...(locale === undefined ? {} : { locale }),
    // antd 6.3.0 enabled mask blur by default. Off: it is an effect this console does not need, and it costs
    // a paint on a tablet.
    modal: { mask: { blur: false } },
    drawer: { mask: { blur: false } },
    // antd v6 removed the trailing `margin-inline-end` on the last Tag in a row. This console uses Tags in
    // dense status columns and relied on that margin for spacing, so it is reinstated explicitly rather than
    // left to look like a layout bug.
    tag: { styles: { root: { marginInlineEnd: 8 } } },
  };
}

/** The `:root` block, so plain CSS in a component can reference a token. */
export function cssVariablesBlock(): string {
  const entries = Object.entries(toCssVariables());
  const lines = entries.map(([name, value]) => `  ${name}: ${value};`);
  return [":root {", ...lines, "}"].join("\n");
}