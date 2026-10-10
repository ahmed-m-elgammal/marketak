# Theme boundary rules (`src/theme/`)

One token source: `tokens.ts`, transcribed from the DESIGN.md frontmatter.
Everything else derives from it. A value is added here first; a call site
that invents a color, radius, spacing, duration or size is a defect.

## Who owns what

| Surface | Owns | Reads |
|---|---|---|
| `tokens.ts` | every value | DESIGN.md frontmatter only |
| `tamagui.config.ts` | kit components (theme, tokens, media) | `./tokens` (direct import — never duplicated) |
| `tailwind.config.js` | utilities (colors, spacing, fonts) | mirror of `./tokens` (JS cannot import TS; mirror by hand, both directions checked in review) |
| `global.css` | nothing (directives only) | compiled by `withNativeWind` |

Tamagui theme owns kit components; NativeWind utilities own layout and
custom composition. No value lives in both configs — a value in both is
the defect this file exists to prevent. `borderRadius` and `boxShadow`
Tailwind core plugins are off (`tailwind.config.js`): zero radius (§6)
and zero-blur hard shadows (§5) cannot be expressed as utilities.

## Build wiring

- Babel (`babel.config.js`): `babel-preset-expo` with
  `jsxImportSource: "nativewind"` first, then `nativewind/babel`
  (NativeWind v4 documented order). `react-native-worklets/plugin` stays
  **last** in `plugins`: the worklet transform must see the final AST.
- Metro (`metro.config.js`): default Expo config + the two documented
  resolver tweaks (`unstable_enablePackageExports`, `ttf`/`otf` asset
  exts), wrapped in `withNativeWind(config, { input:
  "./src/theme/global.css" })`.
- `tamagui.config.ts` lives in `src/theme/`, not the project root: a
  root-level `.ts` file belongs to no tsconfig `include`, no lint scope
  and no dependency-cruiser scope. It builds no default theme beyond
  `dark` — there is no light theme (§1).
- `app/_layout.tsx` imports `global.css` once and mounts
  `TamaguiProvider`. It holds no business logic; gates land in F-07.

## Fonts (expo-font)

| Family (registration name) | File | Status |
|---|---|---|
| `SpaceGrotesk` | `assets/fonts/SpaceGrotesk-Variable.ttf` (136676 B) | bundled |
| `JetBrainsMono` | `assets/fonts/JetBrainsMono-Variable.ttf` (187208 B) | bundled |
| `IBMPlexSansArabic` | `assets/fonts/IBMPlexSansArabic-Regular.ttf` (235924 B) + `IBMPlexSansArabic-Bold.ttf` (246992 B) | bundled |
| `MaterialSymbolsSharp` (400 customer / 600 courier × plain/Filled) | `assets/fonts/MaterialSymbolsSharp-400.ttf` (869656 B) + `MaterialSymbolsSharp-400-Filled.ttf` (1279796 B) + `MaterialSymbolsSharp-600.ttf` (872088 B) + `MaterialSymbolsSharp-600-Filled.ttf` (1283876 B), vendored from `@expo-google-fonts/material-symbols-sharp@0.4.61` | bundled |

Loading contract (implemented with the first screens in F-06, via
`expo-font` `useFonts` + `expo-splash-screen`): register each file under
exactly its name below — config and components reference these strings,
and a mismatch renders fallback type with no error.

| File | Family name |
|---|---|
| `SpaceGrotesk-Variable.ttf` | `SpaceGrotesk` (variable: 600/700 covered) |
| `JetBrainsMono-Variable.ttf` | `JetBrainsMono` (variable: 400/500/600/700 covered) |
| `IBMPlexSansArabic-Regular.ttf` | `IBMPlexSansArabic` |
| `IBMPlexSansArabic-Bold.ttf` | `IBMPlexSansArabic-Bold` |
| `MaterialSymbolsSharp-400.ttf` / `-400-Filled.ttf` | `MaterialSymbolsSharp-400` / `MaterialSymbolsSharp-400-Filled` |
| `MaterialSymbolsSharp-600.ttf` / `-600-Filled.ttf` | `MaterialSymbolsSharp-600` / `MaterialSymbolsSharp-600-Filled` |

Arabic strings render in `IBMPlexSansArabic(-Bold)`; digits stay
`JetBrainsMono` tabular (§13.5).

**Sharp set, resolved:** no installable channel carries the Material Symbols
Sharp *variable* TTF (verified absent from the `google/fonts` raw paths
probed, the `material-symbols` release paths probed, the `material-symbols`
npm package and Fontsource — both woff2-only, unusable for native
bundling). Resolved instead through `@expo-google-fonts/material-symbols-sharp`
(static per-weight TTFs, exact for the two weights × two fills the design
uses). Do NOT substitute legacy Material Icons (§7 forbids it). Icon axes
at use: 400 customer / 600 courier, plain vs Filled file, opsz 20/24 (32
empty states).

## RTL posture (no kit)

Direction comes from RN core (`I18nManager` + start/end logical props),
not a component library. Glyph mirroring rules (§7) and bidi isolates
(§13.5) are implemented at the component layer in F-06, honoring the
ESLint `no-restricted-syntax` ban on `left`/`right`/`marginLeft` and
friends (architecture rule 8, enforced).

## RN platform overrides (DESIGN §15, applied)

Framework defaults fight the system; the theme layer defeats them before
screens exist. "At use" means the wrapper or screen applying the rule.

| Concern | Rule in this tree |
|---|---|
| Zero radius | No `borderRadius` anywhere. `tokens.radius` is all 0 (asserted in `theme.test.ts`); `tamagui.config.ts` derives its radius scale from `radius.none`, so the kit cannot round either. |
| Chamfer (§6.1) | `react-native-svg` path or mask at use; never on tap targets. |
| Hard shadow (§5) | iOS: `shadowRadius: 0, shadowOffset: {width: 4, height: 4}, shadowOpacity: 1`. Android: sibling rectangle offset by 4 behind the surface (elevation cannot tint). Bottom-trailing placement; mirrors in RTL. |
| Press feedback (§9) | Rectangular state fill at use. No ripple, no iOS highlight. |
| Banned kit | No `ActivityIndicator` (square loader instead), no native `Switch` (custom instead), no native pickers (OS prompts and share sheets are the only native dialogs). |
| Tabular numerals (§3.1) | `fontVariant: ['tabular-nums']` on every numeric `Text`, plus instant swap (no count-up). Digits stay JetBrains Mono; Arabic strings render in `IBMPlexSansArabic(-Bold)`. |
| Edge to edge | Root draws under bars; content respects insets. Pinned bottom actions: `max(inset-bottom, 16) + 8` padding. |
| Back gestures | iOS interactive pop off on rail screens; Android gesture exclusion rects for the rail; predictive back elsewhere. |
| Haptics | `selection` ticks, `confirm` success, `reject` errors. Never the only feedback. |
| Fonts and icons | Bundled (`fonts.ts` + `useAppFonts`, root-gated). Never fetched at runtime. |
| Window changes (§4.1) | Layout reads the live window (`xs/sm/md/lg` media keys); state survives resize and rotation. |
| Dispatch channels | F-08: time-sensitive iOS / full-screen-intent Android; pharmacy payloads sealed (§14). |

## Import style (Metro can only resolve one)

Relative imports in `apps/mobile` are **extensionless** (`./parse`, never
`./parse.js`): Metro appends extensions, never strips them, so a `.js`
suffix resolves nowhere at bundle time while passing typecheck, lint and
unit tests silently. Keep `.json`/`.ttf`/`.css` suffixes — those resolve
natively. `packages/shared` keeps NodeNext `.js` suffixes in source (its
`dist` emit requires them) and the app consumes the package entry
(`dist`), never source: the mobile tsconfig carries no
`@marketak/shared` path mapping, because something in the Metro chain
honours it and bundles source. `dist` freshness comes from the root
`tsc --build`; a mobile-only typecheck after a shared change can report
phantom missing members until the root build reruns.

## Pre-ship procedure (DESIGN §17, per screen)

Run for every screen; report unverified items instead of skipping them.

1. Tokens: `git grep -n "#[0-9a-fA-F]\{6\}\|rgba(" -- <screen>` returns nothing outside `theme/`.
2. Radius: no `borderRadius` in the screen or its wrappers.
3. Layout at 360, 600, 840, 1200 wide and 375, 900 high; resize and rotation keep sheet snap, scroll, selection, drafts.
4. Contrast spot-check against §2.5 (no cobalt on dark, no text on high-beam fill, crimson text only on raster-0/1).
5. States: default, pressed, focus-visible, disabled with reason caption, loading, error, selected.
6. Tabular numerals, instant swap; Sharp icons, 400 customer / 600 courier, fill for active.
7. Reduced motion, 150% text scale, screen-reader names matching visible text.
8. Slide rail (if any): button alternative + gesture-conflict handling.
9. RTL: mirroring, isolates on IDs/codes/coords/amounts, Arabic labels untransformed with 0 tracking.
10. Courier moving-state and pharmacy sealed-copy rules where applicable.
11. Anything not verified is listed in the summary.
