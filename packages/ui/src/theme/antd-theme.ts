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
import { FONT_FAMILY, MIN_CONTROL_HEIGHT, MIN_TOUCH_TARGET, layout, motion, radius, space, typeScale } from "./tokens.js";

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
      // Only `radius.md` is mapped. `borderRadiusLG` is set to the same value deliberately: antd's large
      // radius (8) exists for modals and drawers, and the brief's scale has three radii - control, badge,
      // pill. A modal at 8 and an input at 6 is a fourth radius nobody chose.
      borderRadius: radius.md,
      borderRadiusSM: radius.sm,
      borderRadiusLG: radius.md,
      borderRadiusXS: radius.sm,

      // --- type ---
      //
      // The font stack is `tokens.FONT_FAMILY` - IBM Plex Sans plus its Arabic sibling, self-hosted. Not a
      // stack assembled here, because a second definition of the family is a second place for the two to
      // disagree, and a console that renders Latin in one face and Arabic in another looks machine-translated.
      fontFamily: FONT_FAMILY,
      fontSize: typeScale.body.size,
      fontSizeLG: typeScale.pageTitle.size,
      fontSizeSM: typeScale.caption.size,
      fontSizeHeading1: typeScale.pageTitle.size,
      fontSizeHeading2: typeScale.heading.size,
      fontSizeHeading3: typeScale.heading.size,
      fontSizeHeading4: typeScale.heading.size,
      lineHeight: typeScale.body.lineHeight / typeScale.body.size,
      lineHeightLG: typeScale.pageTitle.lineHeight / typeScale.pageTitle.size,
      lineHeightSM: typeScale.caption.lineHeight / typeScale.caption.size,
      lineWidth: 1,
      fontWeightStrong: typeScale.bodyStrong.weight,

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
        // One horizontal rule under the header, no vertical dividers anywhere. A dense work table reads faster
        // with horizontal rhythm, and a vertical rule per column costs a decision on every row.
        headerSplitColor: border.subtle,
        headerSortActiveBg: surface.hover,
        headerSortHoverBg: surface.hover,
        bodySortBg: surface.raised,
        fixedHeaderSortActiveBg: surface.hover,
        headerBorderRadius: radius.none,
        borderColor: border.subtle,
        rowHoverBg: surface.hover,
        rowSelectedBg: brand.primarySubtle,
        cellFontSize: typeScale.body.size,
        cellPaddingBlock: 10,
        cellPaddingInline: space[4],
      },
      Button: {
        primaryShadow: "none",
        defaultShadow: "none",
        dangerShadow: "none",
        fontWeight: 400,
      },
      Menu: {
        itemBg: surface.chrome,
        itemColor: text.onDarkSecondary,
        itemHoverColor: text.onDark,
        itemSelectedBg: brand.primarySubtle,
        itemSelectedColor: text.primary,
        itemMarginInline: space[2],
        itemBorderRadius: radius.md,
        itemHeight: MIN_CONTROL_HEIGHT + 8,
        // The light tokens above would be overridden by the `dark*` set whenever `theme="dark"` is passed, so
        // the same values are declared twice rather than once. Declaring them once and relying on the caller
        // not to pass `theme="dark"` is how a sidebar silently reverts to antd's dark defaults.
        darkItemBg: surface.chrome,
        darkItemColor: text.onDarkSecondary,
        darkItemHoverBg: "#2A2725",
        darkItemSelectedBg: brand.primarySubtle,
      },
      Layout: {
        /*
         * One surface, full height.
         *
         * `siderBg` matches the page chrome so the sidebar is a single plane flush to the viewport edge rather
         * than a dark island floating beside a white list - the island is what makes an admin shell look like
         * a template. The separation between sidebar and content is a hairline, not a colour change.
         */
        siderBg: surface.chrome,
        headerBg: surface.raised,
        headerHeight: layout.header,
        headerPadding: `0 ${space[6]}px`,
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
        paddingLG: 24,
      },
      Statistic: {
        // 24 rather than the dashboard's old 32: this is a dense work tool and the figure has to fit beside a
        // label without the number dominating the row it sits in.
        titleFontSize: typeScale.label.size,
        contentFontSize: typeScale.pageTitle.size,
      },
      Card: {
        // A card here is a section, not a widget. Transparent header and antd's own body padding; the
        // separation a card would normally provide comes from a heading rule instead. No fill, no border -
        // that is what keeps a long detail page from reading as a stack of boxes.
        headerBg: "transparent",
        headerFontSize: typeScale.heading.size,
        headerHeight: 48,
        headerPadding: 0,
        /*
         * `bodyPadding` stays at antd's own default.
         *
         * The zeroing that was here removed the padding a card needs *around its content*, which on a section
         * containing a form makes every field sit flush against the section heading. The heading rule does the
         * separating; the body's padding does the rest.
         */
      },
      Alert: {
        withDescriptionPadding: "12px 16px",
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

/**
 * The `:root` block, so plain CSS in a component can reference a token.
 *
 * Colours come from `colors.toCssVariables()` and the spacing, radius, type and layout scales from
 * `tokens.ts`. Both are emitted here rather than hand-written into `global.css`, so there is exactly one
 * definition of each value in the repository: a hand-written `:root` block is a second copy of the palette
 * that a token change silently leaves behind.
 *
 * Type is emitted as size/weight/line-height *triples* rather than as ready-made CSS shorthands. A component
 * that needs only the size writes `var(--type-body-size)`, and one that needs the full definition writes the
 * three longhands - which keeps the vertical rhythm exact rather than depending on a browser's default
 * `line-height` when only a size is overridden.
 */
export function cssVariablesBlock(): string {
  const colours = toCssVariables();

  // `--space-N` follows the scale's numeric keys, so a component can reach any step the scale defines and a
  // new step appears here automatically.
  const spacingBlock = Object.entries(space)
    .map(([step, px]) => `  --space-${step}: ${px}px;`)
    .join("\n");

  const radiusBlock = Object.entries(radius)
    .map(([step, px]) => `  --radius-${step}: ${px}px;`)
    .join("\n");

  // Only the steps the console actually uses, so the block is not a wall of variables that nothing reads.
  // Typed explicitly because the array-of-pairs form infers `(string | TypeStep)[][]`, and `step.size` on a
  // `string` is the error this exists to prevent.
  const typeBlock = (
    [
      ["body", typeScale.body],
      ["body-strong", typeScale.bodyStrong],
      ["label", typeScale.label],
      ["small", typeScale.small],
      ["caption", typeScale.caption],
      ["header", typeScale.tableHeader],
      ["section", typeScale.heading],
      ["title", typeScale.pageTitle],
      ["display", typeScale.display],
    ] as const
  )
    .map(
      ([name, step]) =>
        `  --type-${name}-size: ${String(step.size)}px;\n  --type-${name}-weight: ${String(step.weight)};\n  --type-${name}-line: ${String(step.lineHeight)}px;`,
    )
    .join("\n");

  const layoutBlock = Object.entries(layout)
    .map(([key, px]) => `  --layout-${key}: ${px}px;`)
    .join("\n");

  return [
    ":root {",
    "  /* One type family, Latin and Arabic. The Arabic face is second on purpose: Latin reads first in the",
    "     English UI and the Arabic face takes over for Arabic codepoints. */",
    `  --font-family: ${FONT_FAMILY};`,
    `  --control-height: ${MIN_CONTROL_HEIGHT}px;`,
    `  --touch-target: ${MIN_TOUCH_TARGET}px;`,
    `  --motion-fast: ${motion.fast}ms;`,
    `  --motion-base: ${motion.base}ms;`,
    "  /* --- colours --- */",
    ...Object.entries(colours).map(([name, value]) => `  ${name}: ${value};`),
    "  /* --- spacing --- */",
    spacingBlock,
    "  /* --- radii --- */",
    radiusBlock,
    "  /* --- type --- */",
    typeBlock,
    "  /* --- layout --- */",
    layoutBlock,
    "}",
  ].join("\n");
}