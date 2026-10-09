---
version: '2.0'
name: Telemetry Dispatch Terminal
description: Brutalist dark-terminal design system for the courier, customer and merchant apps. Native Android and iOS; phones, tablets and iPad.
platforms:
  - ios
  - android
form-factors:
  - phone
  - tablet
  - ipad
theme: dark-only
units: 'px = 1 dp (Android) = 1 pt (iOS)'
colors:
  # ---- Brand core (canonical) ----
  cobalt-electric: '#1D4ED8'
  cobalt-high-beam: '#3B82F6'
  cobalt-recessed: '#172554'
  telemetry-cyan: '#00F0FF'
  dispatch-amber: '#F59E0B'
  alert-crimson: '#EF4444'
  success-radar: '#10B981'
  vertical-food: '#F97316'
  vertical-grocery: '#84CC16'
  vertical-pharmacy: '#06B6D4'
  vertical-parcel: '#94A3B8'
  white: '#FFFFFF'
  # ---- Surfaces ----
  void-base: '#020408'
  surface-raster-0: '#080C14'
  surface-raster-1: '#0F172A'
  surface-raster-2: '#1E293B'
  row-alt: '#0B0F19'
  # ---- Text ----
  text-primary: '#DFE2F1'
  text-muted: '#94A3B8'
  text-placeholder: '#7C8AA0'
  text-disabled: '#64748B'
  # ---- Lines and overlays ----
  wire-border-dim: 'rgba(255, 255, 255, 0.08)'
  wire-border-mid: 'rgba(255, 255, 255, 0.16)'
  wire-border-control: 'rgba(255, 255, 255, 0.40)'
  wire-border-active: '#3B82F6'
  focus-ring: '#3B82F6'
  scrim: 'rgba(2, 4, 8, 0.72)'
  # ---- 12% status tints (badge fills) ----
  tint-success: 'rgba(16, 185, 129, 0.12)'
  tint-pharmacy: 'rgba(6, 182, 212, 0.12)'
  tint-food: 'rgba(249, 115, 22, 0.12)'
  tint-grocery: 'rgba(132, 204, 22, 0.12)'
  tint-parcel: 'rgba(148, 163, 184, 0.12)'
  tint-amber: 'rgba(245, 158, 11, 0.12)'
  tint-crimson: 'rgba(239, 68, 68, 0.12)'
  # ---- Material 3 role mapping (derived from the brand core; for tooling that expects M3 roles) ----
  primary: '#1D4ED8'
  on-primary: '#FFFFFF'
  primary-container: '#172554'
  on-primary-container: '#B7C4FF'
  inverse-primary: '#B7C4FF'
  secondary: '#00F0FF'
  on-secondary: '#020408'
  secondary-container: '#004F54'
  on-secondary-container: '#7DF4FF'
  tertiary: '#F59E0B'
  on-tertiary: '#2A1700'
  tertiary-container: '#653E00'
  on-tertiary-container: '#FFDDB8'
  error: '#EF4444'
  on-error: '#020408'
  error-container: '#93000A'
  on-error-container: '#FFDAD6'
  background: '#080C14'
  on-background: '#DFE2F1'
  surface: '#080C14'
  surface-dim: '#020408'
  surface-bright: '#1E293B'
  surface-container-lowest: '#020408'
  surface-container-low: '#080C14'
  surface-container: '#0F172A'
  surface-container-high: '#1E293B'
  surface-container-highest: '#1E293B'
  surface-variant: '#1E293B'
  surface-tint: '#3B82F6'
  on-surface: '#DFE2F1'
  on-surface-variant: '#94A3B8'
  inverse-surface: '#DFE2F1'
  inverse-on-surface: '#080C14'
  outline: '#6B6D72'
  outline-variant: '#30333A'
typography:
  # Line heights are snapped to the 4px grid. Apply tabular numerals (tnum) to every token.
  display-lg:
    fontFamily: Space Grotesk
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 52px
    letterSpacing: -0.03em
  display-lg-mobile:
    fontFamily: Space Grotesk
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 36px
    letterSpacing: -0.02em
  headline-xl:
    fontFamily: Space Grotesk
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 36px
    letterSpacing: -0.02em
  headline-xl-mobile:
    fontFamily: Space Grotesk
    fontSize: 22px
    fontWeight: '700'
    lineHeight: 28px
    letterSpacing: -0.01em
  headline-md:
    fontFamily: Space Grotesk
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
    letterSpacing: -0.01em
  title-lg:
    fontFamily: Space Grotesk
    fontSize: 18px
    fontWeight: '600'
    lineHeight: 24px
    letterSpacing: 0em
  title-md:
    fontFamily: Space Grotesk
    fontSize: 16px
    fontWeight: '600'
    lineHeight: 24px
    letterSpacing: 0em
  code-lg:
    fontFamily: JetBrains Mono
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 36px
    letterSpacing: 0em
  body-lg:
    fontFamily: JetBrains Mono
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
    letterSpacing: -0.01em
  body-md:
    fontFamily: JetBrains Mono
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
    letterSpacing: 0em
  body-sm:
    fontFamily: JetBrains Mono
    fontSize: 12px
    fontWeight: '400'
    lineHeight: 16px
    letterSpacing: 0.01em
  label-lg:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.04em
  label-md:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '500'
    lineHeight: 16px
    letterSpacing: 0.06em
  label-caps:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '700'
    lineHeight: 16px
    letterSpacing: 0.12em
rounded:
  none: 0px
  DEFAULT: 0px
  sm: 0px
  md: 0px
  lg: 0px
  xl: 0px
  full: 0px
spacing:
  space-xs: 4px
  space-sm: 8px
  space-md: 16px
  space-lg: 24px
  space-xl: 32px
  space-2xl: 40px
  space-3xl: 48px
  margin-compact: 16px
  margin-medium: 24px
  margin-expanded: 24px
  margin-large: 32px
  gutter-compact: 12px
  gutter-medium: 16px
  gutter-expanded: 16px
  gutter-large: 24px
layout:
  size-classes:
    compact:
      min-width: 0
      max-width: 599
      columns: 4
      margin: '{spacing.margin-compact}'
      gutter: '{spacing.gutter-compact}'
    medium:
      min-width: 600
      max-width: 839
      columns: 8
      margin: '{spacing.margin-medium}'
      gutter: '{spacing.gutter-medium}'
    expanded:
      min-width: 840
      max-width: 1199
      columns: 12
      margin: '{spacing.margin-expanded}'
      gutter: '{spacing.gutter-expanded}'
    large:
      min-width: 1200
      columns: 12
      margin: '{spacing.margin-large}'
      gutter: '{spacing.gutter-large}'
  height-classes:
    compact-height: 'window height < 480'
    regular-height: 'window height >= 480'
  rail-width: 80px
  deck-width: 380px
  inspector-width: 320px
  canvas-min-width: 360px
  content-max-width: 640px
  dialog-max-width: 480px
  action-max-width: 480px
  topbar-height: 56px
  tabbar-height: 56px
  banner-height: 48px
  sheet-peek-height: 120px
  sheet-default-ratio: 0.45
  map-min-visible-ratio: 0.20
touch:
  target-primary: 56px
  target-secondary: 48px
  target-min: 48px
  hit-gap-min: 8px
border:
  hairline: 1px
  emphasis: 2px
  focus: 2px
  route: 4px
elevation:
  hard-shadow-offset: 4px
  hard-shadow-blur: 0px
  hard-shadow-color-default: '{colors.cobalt-electric}'
  hard-shadow-color-critical: '{colors.alert-crimson}'
  chamfer-sm: 8px
  chamfer-md: 12px
motion:
  duration-instant: 0ms
  duration-fast: 100ms
  duration-base: 160ms
  duration-slow: 240ms
  duration-pulse: 1200ms
  easing-linear: linear
  easing-standard: 'cubic-bezier(0.2, 0, 0, 1)'
z-index:
  map: 0
  sheet: 10
  navigation: 20
  banner: 30
  toast: 40
  modal: 50
  system-alert: 60
icon:
  family: Material Symbols Sharp
  size-sm: 20px
  size-md: 24px
  size-lg: 32px
  weight-courier: 600
  weight-customer: 400
  grade: 0
  fill-default: 0
  fill-active: 1
components:
  button-primary:
    backgroundColor: '{colors.cobalt-electric}'
    textColor: '{colors.on-primary}'
    typography: '{typography.title-md}'
    rounded: '{rounded.none}'
    height: 56px
    padding: 16px
  button-primary-pressed:
    backgroundColor: '{colors.white}'
    textColor: '{colors.cobalt-electric}'
  button-secondary:
    backgroundColor: '{colors.surface-raster-1}'
    textColor: '{colors.text-muted}'
    typography: '{typography.title-md}'
    rounded: '{rounded.none}'
    height: 56px
    padding: 16px
  button-danger:
    backgroundColor: '{colors.alert-crimson}'
    textColor: '{colors.on-error}'
    typography: '{typography.title-md}'
    rounded: '{rounded.none}'
    height: 56px
    padding: 16px
  slide-rail:
    backgroundColor: '{colors.surface-raster-0}'
    rounded: '{rounded.none}'
    height: 56px
    padding: 4px
  slide-rail-handle:
    backgroundColor: '{colors.cobalt-electric}'
    textColor: '{colors.on-primary}'
    size: 48px
  input:
    backgroundColor: '{colors.surface-raster-0}'
    textColor: '{colors.text-primary}'
    typography: '{typography.body-lg}'
    rounded: '{rounded.none}'
    height: 56px
    padding: 16px
  checkbox:
    backgroundColor: '{colors.surface-raster-0}'
    rounded: '{rounded.none}'
    size: 20px
  chip:
    typography: '{typography.label-caps}'
    rounded: '{rounded.none}'
    padding: 8px
  list-row:
    backgroundColor: '{colors.surface-raster-0}'
    textColor: '{colors.text-primary}'
    typography: '{typography.body-md}'
    height: 56px
    padding: 16px
  card-hud:
    backgroundColor: '{colors.surface-raster-0}'
    textColor: '{colors.text-primary}'
    typography: '{typography.body-md}'
    rounded: '{rounded.none}'
    padding: 16px
  card-hud-header:
    backgroundColor: '{colors.surface-raster-1}'
    typography: '{typography.label-lg}'
    height: 32px
  bottom-sheet:
    backgroundColor: '{colors.surface-raster-1}'
    rounded: '{rounded.none}'
    padding: 16px
  dialog:
    backgroundColor: '{colors.surface-raster-2}'
    textColor: '{colors.text-primary}'
    rounded: '{rounded.none}'
    padding: 24px
  tab-bar:
    backgroundColor: '{colors.surface-raster-1}'
    height: 56px
  toast:
    backgroundColor: '{colors.surface-raster-1}'
    textColor: '{colors.text-primary}'
    typography: '{typography.body-md}'
    height: 48px
    padding: 16px
---

## 0. How an AI agent must use this file

This file is the contract for every screen in the courier, customer and merchant apps. Read this section first.

1. **Precedence.** YAML frontmatter tokens are canonical. Prose explains how to use them. If prose and frontmatter disagree, the frontmatter wins. If both are silent, pick the most restrictive option (higher contrast, larger target, fewer colors) and state the assumption in your summary. Never silently invent a value.
2. **Tokens only.** Feature code must reference tokens (`colors.cobalt-high-beam`, `spacing.space-md`), never raw hex or numbers. Never invent a color, radius, shadow, font size, duration or spacing value. If a design needs one, stop and ask.
3. **Respond to the window, not the device.** iPad Split View, Stage Manager, Android multi-window, foldables and rotation all change the window size at runtime. Choose layout from the measured window width and height (section 4), never from "is this a tablet".
4. **Know the role.** Every screen belongs to one role. Roles change density and target size, not the visual language.

| Role | Primary devices | Density | Min target | Notes |
|---|---|---|---|---|
| Courier terminal | Phone; in-cab tablet | Highest | 56 primary, 48 secondary | Used while moving. Safety rules in section 14 apply. |
| Customer live view | Phone; iPad | Medium | 48 | Reassurance and clarity over density. |
| Merchant console | Tablet and iPad (counter); phone for alerts | High | 48 (56 for accept/ready actions) | Dual-pane by default on expanded windows. |

5. **Theme file first.** When generating UI code for a stack, first create or extend the theme layer that maps these tokens (colors, type, spacing, shapes, motion), then build screens from it. Section 15 lists the platform-specific overrides needed to defeat framework defaults.
6. **Finish with the checklist** in section 17 and report which items you could not verify.

## 1. Brand & Style

This design system is an unyielding, mission-critical heads-up telemetry dispatch console. It serves two operational domains: high-velocity courier execution (car, two-wheeler and on-foot) and dense customer tracking across multi-merchant verticals (food, grocery, pharmacy cold-chain and express parcel).

- **Brutalist telemetry architecture.** Zero ornamentation, zero softening, zero roundedness. Industrial avionics terminal: right-angle compartments, near-black raster surfaces, hairline borders, concentrated bursts of electric cobalt.
- **Glanceability under velocity.** Designed for solar glare on handlebars, dark cabin mounts, vibrating cradles and arm's-length reads.
- **Dark only.** There is no light theme. Outdoor legibility comes from contrast, size and spacing, not from a theme switch. Do not generate a light variant.
- **Courier terminal:** hierarchical, monospaced data matrices, physical-scale targets (48 to 56), kinetic gestures for irreversible actions.
- **Customer live view:** precise route telemetry, merchant state, cold-chain badges and itemized manifests with clinical accuracy.
- **Merchant console:** queue-first, dual-pane, scannable at counter distance.
- **Multi-merchant stratification.** Four vertical channels, each with a color, a glyph and a text label (section 2).

Product name, logo and app icon are not defined here (see section 18).

## 2. Colors

### 2.1 Roles

The brand core is anchored by cobalt `#1D4ED8`. The M3 role block in the frontmatter is derived from the brand core and exists only for tooling; always reason from the brand tokens.

| Role | Token | Use |
|---|---|---|
| Primary | `cobalt-electric` `#1D4ED8` | Fills for master command buttons, handles, checked boxes. White text only. |
| Primary line | `cobalt-high-beam` `#3B82F6` | Every line, ring, border, icon, link and active route on a dark surface. |
| Secondary | `telemetry-cyan` `#00F0FF` | Live data only: GPS pings, pickup codes, ETA tickers, telemetry numerals. |
| Tertiary | `dispatch-amber` `#F59E0B` | Expiry windows, temperature-decay timers, order modifications, priority queues. |
| Success | `success-radar` `#10B981` | Completed handoff, verified scan, courier online. |
| Critical | `alert-crimson` `#EF4444` | Emergency, failed cold-chain seal, blocking requirements (signature, ID check), vehicle stoppage. |

### 2.2 Vertical channels

| Vertical | Token | Identity glyph | Condition glyphs |
|---|---|---|---|
| Food and restaurant | `vertical-food` `#F97316` | `restaurant` | `local_fire_department` (hot-holding) |
| Grocery and produce | `vertical-grocery` `#84CC16` | `local_grocery_store` | substitution alert uses `swap_horiz` |
| Pharmacy and cold-chain | `vertical-pharmacy` `#06B6D4` | `prescriptions` | `ac_unit` (cold-chain) |
| Parcel and P2P | `vertical-parcel` `#94A3B8` | `package_2` | `lock` (lockbox) |

A vertical glyph always inherits its vertical color.

### 2.3 Resolving look-alike colors

These pairs are close in hue and are easy to confuse in glare. The rules below keep them apart.

- **Vertical color is identity. State color is condition.** A state color (crimson, amber, success) always overrides the vertical color on the badge that reports the condition. The order header keeps the vertical identity glyph.
- **Prescription signature required** is a blocking condition: crimson with the `draw` glyph. **Pharmacy cold-chain intact** is an integrity flag: pharmacy cyan with `ac_unit`. A failed cold-chain seal is crimson.
- **Telemetry cyan vs pharmacy cyan.** `telemetry-cyan` is only for live numerals, pings and codes, never for fills, badges or category labels. `vertical-pharmacy` is only for the pharmacy vertical and always paired with `prescriptions` or `ac_unit`.
- **Time-critical amber vs food orange.** Time-critical badges always carry the `timer` glyph and a countdown. Food badges always carry `restaurant` or `local_fire_department`. Never place the two side by side without their glyphs.
- **Color is never the only signal.** Every colored state also has a glyph and a text label.

### 2.4 Surface hierarchy (single mapping)

| Token | Hex | Use |
|---|---|---|
| `void-base` | `#020408` | Map base, scanner viewfinder, ambient gutters. Level 0. |
| `surface-raster-0` | `#080C14` | Screen foundation, Level 1 plates, input beds, list rows. |
| `row-alt` | `#0B0F19` | Alternating list rows only. |
| `surface-raster-1` | `#0F172A` | Level 2: sheets, decks, action bars, navigation, card headers, toasts. |
| `surface-raster-2` | `#1E293B` | Level 3: dialogs and alerts. Pressed and selected rows. |

Inputs always use `surface-raster-0` (a recessed bed) regardless of the surface they sit on.

### 2.5 Contrast rules (measured)

Measured against WCAG 2.x. Body text needs 4.5:1; large text and non-text UI need 3:1.

| Pair | Ratio | Rule |
|---|---|---|
| `cobalt-electric` on `surface-raster-0` | 2.92 | Fails 3:1. Never use cobalt as text, border, icon, ring or line on a dark surface. Fill with white text only (6.70). |
| `cobalt-high-beam` on raster-0 / 1 / 2 | 5.32 / 4.85 / 3.98 | Use for all lines, rings, borders, icons, links, active routes. Text on raster-2 is not allowed (3.98). |
| White on `cobalt-high-beam` fill | 3.68 | Never put text on a high-beam fill. |
| White on `alert-crimson` fill | 3.76 | Never. Text on a crimson fill is `void-base` (5.45). |
| `alert-crimson` text on raster-0 / 1 / 2 | 5.20 / 4.74 / 3.89 | Crimson text allowed on raster-0 and raster-1 only. On raster-2 use `text-primary` text with a crimson glyph. |
| Crimson badge text on 12% tint over raster-0 / 1 | 4.72 / 4.28 | Tinted crimson badges only on raster-0. On raster-1 and above use the solid variant (section 9.3). |
| `text-primary` / `text-muted` on raster-0 | 15.18 / 7.63 | Primary and secondary text. |
| `text-placeholder` on raster-0 | 5.59 | Placeholder text on input beds only. |
| `text-disabled` on raster-0 | 4.11 | Disabled only (exempt from contrast rules, so a "why disabled" caption is required). |
| `telemetry-cyan` on raster-0 | 13.89 | Telemetry text. |
| Vertical and state colors on raster-0 | 6.98 to 9.91 | All pass 4.5 as text. |
| Border `wire-border-control` (0.40) on raster-0 / 1 / 2 | 3.78 / 3.81 / 3.62 | All interactive control boundaries use this token. |
| Border `wire-border-mid` (0.16) and `dim` (0.08) | 1.55 / 1.19 | Decorative dividers only. Never the sole boundary of an input, checkbox or other control. |

## 3. Typography

**Space Grotesk** carries display, headline and title tokens and high-impact numerals. **JetBrains Mono** carries all tabular data, manifests, status labels, order codes and telemetry.

### 3.1 Rules

- **Tabular numerals everywhere.** Order numbers, coordinates, currency, weights and timers use tabular figures so live updates never jitter. JetBrains Mono is inherently fixed-width; for Space Grotesk numerals enable the `tnum` feature. Numeric values update by instant swap, never by count-up animation.
- **Minimum sizes.** Courier terminal: nothing below 11px (`label-md`, `label-caps`); critical states (stale GPS, cold-chain breach, blocking requirements) use `label-lg` (13px) or larger. Customer and merchant surfaces: nothing below 11px.
- **Small labels** (11px) use `label-caps` or `label-md`, uppercase, tracked `0.06em` to `0.12em`. Uppercase comes from the text transform, not from typed capitals, so translations stay editable.
- **Tier by size class.** Compact windows (under 600) use the `-mobile` display and headline tokens. Medium and larger windows use `display-lg` and `headline-xl`. Body, label and title tokens do not change between classes.
- **In-cab tablets** (medium and larger windows in the courier terminal): body text steps up one token (`body-md` to `body-lg`) for arm's-length reading. Labels keep their tokens.
- **Truncation.** Order IDs, pickup codes, coordinates and amounts are never truncated: they wrap or the container grows. Street addresses wrap to 2 lines in rows and 3 lines in decks and sheets, then end with an ellipsis. Merchant names end with an ellipsis after 1 line in rows.
- **OS text scaling.** Support up to 150% font scale. `label-*` tokens cap at 130%. Rows and buttons use `min-height` (never fixed height) so they grow with text. When text grows past the container, the layout reflows to a single column and the slide rail and buttons keep their 56px minimum.
- **Line height** for non-Latin scripts rounds up to the next multiple of 4px.

### 3.2 Fonts and fallbacks

Bundle fonts in the app binary (never load at runtime): Space Grotesk 600 and 700; JetBrains Mono 400, 500, 600 and 700. Fallback stacks: Space Grotesk falls back to the system sans (SF Pro on iOS, Roboto on Android); JetBrains Mono falls back to the system monospace (SF Mono / Menlo on iOS, Roboto Mono / `monospace` on Android). Neither font covers non-Latin scripts; see section 13.

## 4. Layout & Spacing

Everything is on a 4px grid. Exceptions: 1px and 2px strokes, and font sizes.

### 4.1 Size classes (measure the window)

| Class | Window width | Columns | Margin | Gutter | Typical windows |
|---|---|---|---|---|---|
| `compact` | 0 to 599 | 4 | 16 | 12 | Phones in portrait; iPad Split View narrow pane; folded foldables |
| `medium` | 600 to 839 | 8 | 24 | 16 | Large phones in landscape; tablets in portrait; iPad half-screen |
| `expanded` | 840 to 1199 | 12 | 24 | 16 | Tablets and iPad in landscape; in-cab tablets; phones in landscape on large devices |
| `large` | 1200 and up | 12 | 32 | 24 | iPad Pro landscape; Stage Manager and multi-window large windows |

Height class: `compact-height` is window height under 480 (phones in landscape). Everything else is `regular-height`.

Compute the class from the live window size every time the window changes:

```
widthClass(w) = w < 600 ? compact : w < 840 ? medium : w < 1200 ? expanded : large
heightClass(h) = h < 480 ? compact-height : regular-height
```

Use `MediaQuery.sizeOf` / `LayoutBuilder` (Flutter), `useWindowDimensions` (React Native), measured geometry (SwiftUI; do not trust `horizontalSizeClass` alone because it reports `regular` for iPad Split View panes that are visually narrow), or `currentWindowAdaptiveInfo().windowSizeClass` (Compose; its 600 and 840 thresholds match this table).

### 4.2 Spacing scale and where it applies

| Token | Value | Use |
|---|---|---|
| `space-xs` | 4 | Hairline gaps, badge interior padding |
| `space-sm` | 8 | Icon-to-label gap, dense row spacing, minimum gap between adjacent tap targets |
| `space-md` | 16 | Standard cell padding, card interior, gap between cards |
| `space-lg` | 24 | Gap between modules, dialog padding |
| `space-xl` | 32 | Gap between primary sections |
| `space-2xl` / `space-3xl` | 40 / 48 | Large touch footprints, empty-state offsets |

Responsive values: screen edge margin and column gutter come from the size class table. Card padding stays `space-md` in every class. Gap between modules is `space-lg` in compact and medium, `space-xl` in expanded and large.

Do not scale touch targets or typography with the window. Wider windows get more panes and more columns, not bigger controls.

### 4.3 Touch targets

| Element | Minimum |
|---|---|
| Courier primary actions, status switches, map controls, slide rail | 56 high, 56 hit area |
| Courier secondary list items, customer and merchant controls, navigation items | 48 |
| Visual elements smaller than 48 (checkbox 20, chips 24, route nodes) | Interactive ones extend their hit area to 48 x 48 with padding; hit areas of neighbors must not overlap (keep 8 between visual edges, minimum) |

Targets stay at 56 and 48 on tablets. A primary action is never wider than 480 (`layout.action-max-width`) and sits inside the deck or sheet, within thumb reach.

### 4.4 Safe areas and system bars

- Draw edge to edge. Backgrounds extend under status bar, notches, display cutouts, gesture bars and navigation bars; content respects the insets.
- Pinned bottom actions use bottom padding of `max(inset-bottom, 16px) + 8px` so they clear the home indicator and Android gesture area.
- In landscape, respect left and right insets (notch or camera cutout) on top of the size class margin.
- Foldables: never place text, the primary action or the slide rail across the hinge. In tabletop or book posture, the dual-pane split aligns to the fold.

### 4.5 Pane architecture by size class

```
COMPACT / MEDIUM (regular height)        EXPANDED / LARGE
+------------------------------+         +----+-----------+-------------------------+----------+
| top bar 56                   |         |rail|  DECK     |  CANVAS (fluid, 12 col) |INSPECTOR |
+------------------------------+         | 80 |  380      |  map / cluster / sensors|  320     |
| MAP  (55%)                   |         |    |  queue    |                         | (large   |
|                              |         |    |  manifest |                         |  only)   |
+==============================+         |    |  chat     |                         |          |
| SHEET (45%)  [peek|45%|full] |         |    |  [action] |                         |          |
|  [ pinned action 56 ]        |         +----+-----------+-------------------------+----------+
+------------------------------+
| tab bar 56 + inset (customer/merchant) 
```

| Concern | compact | medium | expanded | large |
|---|---|---|---|---|
| Main layout | Single pane. Map top 55%, sheet bottom 45% | Same as compact, content max 640 and centered | Dual-pane: deck 380 fixed + canvas fluid | Dual-pane + optional inspector 320 on the trailing side |
| Navigation | Bottom tab bar (customer, merchant). None during an active courier job | Navigation rail 80 (customer, merchant). None during an active courier job | Rail 80 + deck. None during an active courier job | Same as expanded |
| Sheet / deck | Bottom sheet with 3 snaps | Bottom sheet, content max 640 | Deck replaces the sheet. Bottom sheets only for secondary pickers | Same |
| Pinned primary action | Full width of the sheet | Full width up to 480, centered | Bottom of the deck, deck width | Same |
| Dialog | Width = window - 2 x margin | 480 centered | 480 centered | 480 centered |
| Catalog grid | 2 columns, cards at least 160 wide | Auto-fit, cards at least 160 wide | Auto-fit in canvas | Auto-fit in canvas |
| Forms | 1 column | 1 column, max 640, centered | 1 or 2 columns in canvas (label and input side by side) | Same |
| Type tier | `-mobile` display and headline | Full tier | Full tier | Full tier |

Rules that make the table work:

- **Compact-height with width at least 600** (phone landscape): use side by side. Map takes the fluid side, the deck or sheet content sits on the leading side with width `min(380, floor(0.5 x window width / 4) x 4)`. Drop the top bar title; keep the 56 high action bar. No navigation rail.
- **Window resize or rotation must not lose state.** Preserve sheet snap, scroll, selection and in-progress forms across class changes. Android: handle config changes without recreating the activity (`screenSize|smallestScreenSize|screenLayout|orientation`), `resizeableActivity=true`. iOS: support all iPad orientations and multitasking; do not set `UIRequiresFullScreen`.
- **Bottom sheet snaps:** `peek` (height 120: 32 header + 56 action + 32 padding, plus bottom inset), `default` (45% of window height; the map keeps at least 55%), `full` (window height minus top bar and top inset). The map is never covered below 20% of height. No overshoot, no spring.
- **Keyboard:** when the IME opens, the sheet snaps to `full` and the pinned action rises above the keyboard. Respect IME insets.
- **Deck and canvas.** The deck is a single column with `space-md` padding and `space-lg` between modules. The 12-column grid applies to the canvas only. Minimum canvas width is 360; if the window is too narrow for rail + deck + 360, drop the rail first (use a top-bar menu), then fall back to medium layout.
- **Content max width.** Reading and form content never stretches past 640 on wide panes. Dashboards and maps are fluid.

## 5. Elevation & Depth

No blurred or ambient shadows. Depth comes from tonal raster tiers, wire borders, and a hard-offset shadow.

| Level | Role | Fill | Border | Shadow | Examples |
|---|---|---|---|---|---|
| 0 | Map base, sensor void | `void-base` | none | none | Map, scanner viewfinder |
| 1 | Structural plates | `surface-raster-0` | 1px `wire-border-dim` | none | Order summaries, product grids, merchant panels, data tables |
| 2 | Control heads, decks, bottom decks | `surface-raster-1` | 1px `wire-border-mid` | none | Sheets, deck, action bars, navigation, toasts, card headers |
| 3 | Phosphor alert / high-beam | `surface-raster-2` | 1px `cobalt-high-beam` (critical: `alert-crimson`) | `4px 4px 0 0` in `hard-shadow-color-default` (critical: `-critical`) | Dialogs, incoming dispatch alert, emergency verification |

- **No glow with blur.** The v1 "glow" and "phosphor halo" wording means a zero-blur ring: a solid square outline offset outward (for example `0 0 0 4px rgba(59,130,246,0.35)`). Blur radius is always 0.
- **Hard shadow placement** is bottom and trailing (bottom-right in LTR, bottom-left in RTL). Do not put chamfers on that corner.
- **Z-order** (low to high): map 0, sheet 10, navigation 20, banner 30, toast 40, modal 50, system alert 60.

## 6. Shapes

**Zero roundedness.** `rounded.*` is 0 for every key. Override framework defaults (section 15): every container, button, input, chip, card, sheet, progress indicator, switch, avatar, map marker, touch ripple, focus ring and pressed highlight is a right-angled rectangle. This applies to container geometry; glyph interiors (the circle inside an icon) are allowed.

### 6.1 Chamfers

Use a 45-degree chamfer only to differentiate nested modules. Allowed on HUD cards, Level 3 dialogs and radio selectors. Never on buttons, inputs, chips or anything else that is a tap target.

- Size: `chamfer-sm` (8) on cards and dialogs, 4 on radios.
- Position: top trailing corner (top-right in LTR, top-left in RTL).
- The border must follow the diagonal. Path for width `w`, height `h`, chamfer `c` (LTR):

```
M0,0 H(w-c) L w,c V h H0 Z
```

### 6.2 Tabs

Index-tab protrusions are allowed on HUD cards: a rectangular tab 8 high, same fill as the card header, aligned to the leading edge. No curves.

## 7. Iconography

- **Family:** Material Symbols **Sharp** (square terminals, fits zero roundedness). Do not use the Rounded variant. Outlined is allowed only if a glyph is missing in Sharp. Do not substitute legacy Material Icons.
- **Axes:** `wght` 600 in the courier terminal, 400 for customer and merchant. `GRAD` 0. `FILL` 0 by default, 1 for the active or selected state. Optical size matches the pixel size (20 or 24; 32 for empty states).
- **Sizes:** 20 and 24 by default; 32 for empty-state glyphs only. Every tappable icon sits in a 48 x 48 hit area.
- **Delivery:** ship the variable font or generated per-glyph assets in the app. Do not load icons from the network.
- **Glyph set** (courier): `navigation`, `two_wheeler`, `local_shipping`, `barcode_scanner`, `check_box`, `emergency`, `pin_drop`, `keyboard_double_arrow_right`, `sensors`, `timer`, `draw`, `badge`, `photo_camera`, `flashlight_on`, `wifi_off`, `gps_off`, `battery_alert`, `call`, `chat`. Customer and merchant: `storefront`, `shopping_bag`, `prescriptions`, `package_2`, `schedule`, `restaurant`, `local_grocery_store`, `add`, `remove`, `close`, `arrow_drop_down`.
- **Vertical coding:** icons for a vertical use its color token (section 2.2).
- **RTL:** mirror directional glyphs (arrows, `keyboard_double_arrow_right`, chevrons). Do not mirror `navigation` (map heading), clocks, checks, barcodes or media controls.

## 8. Motion

Motion is mechanical and instant. No springs, bounce, overshoot or easing flourishes.

| Token | Value | Use |
|---|---|---|
| `duration-instant` | 0ms | Focus border change, state color swaps |
| `duration-fast` | 100ms | Press state, minimum visible time for a press flash |
| `duration-base` | 160ms | Sheet snap, panel changes, slide-rail snap back, square-loader step |
| `duration-slow` | 240ms | Dialog and full-screen entry |
| `duration-pulse` | 1200ms | Live location and current-stop pulse |

Easing: `linear` for telemetry and loaders, `cubic-bezier(0.2, 0, 0, 1)` for sheets and dialogs.

- **Pulse.** The current-stop square and live courier marker pulse a hollow square ring outward from 0 to 12px offset over 1200ms, linear, from 0.6 opacity to 0. Zero blur. Reduced motion: replace the animation with a static 4px ring at 0.35 opacity.
- **Reduced motion** (OS setting): remove pulses, scanner sweep and skeleton sweep; replace slides and fades with instant swaps; keep state changes visible through color and glyph.
- **No auto-moving carousels.** No parallax.

## 9. Components

Every interactive component implements all of: default, pressed, focus-visible, disabled, loading (if it triggers async work), error (if it takes input) and selected (if it can be chosen). Defaults for all components:

- **Pressed:** feedback begins at 0ms and stays visible for at least 100ms (`duration-fast`) so a quick tap still flashes. Press feedback is a rectangle, never a circular ripple.
- **Focus-visible** (external keyboard, switch control, d-pad, VoiceOver and TalkBack focus): `2px solid focus-ring` outline with a 2px offset. Never remove it.
- **Hover** applies only to pointer devices (iPad trackpad, Android mouse). Touch has no hover state.
- **Disabled:** fill `surface-raster-1`, text `text-disabled`, border `wire-border-dim`. Any disabled primary action shows a one-line caption explaining what enables it (for example `ARRIVE AT DROP-OFF TO ENABLE`).
- **Loading:** freeze the control width, replace the label with the square loader (9.9), ignore taps, announce busy to assistive tech.
- **Selected:** 4px `cobalt-high-beam` bar on the leading edge plus `surface-raster-2` fill.

### 9.1 Buttons

- **Primary telemetry action** (Accept Dispatch, Confirm Handoff): height 56, fill `cobalt-electric`, text `on-primary` in `title-md` uppercase with `0.04em` tracking, `1px solid cobalt-high-beam`, radius 0. **Pressed:** fill `white`, text `cobalt-electric` (6.70:1). **Hover** (pointer only): fill `cobalt-high-beam`, text `void-base` (5.58:1). Max width 480.
- **Secondary / abort:** height 56, fill `surface-raster-1`, `1px solid wire-border-mid`, text `text-muted` (6.96:1). **Pressed:** fill `surface-raster-2`, border `1px solid white`. **Hover:** border `1px solid white`.
- **Danger** (Refuse Handoff, Cancel Order): fill `alert-crimson`, text `on-error` (`void-base`, 5.45:1). **Pressed:** fill `void-base`, text and `1px` border `alert-crimson`.
- **Emergency control:** 56 x 56 minimum, `alert-crimson` fill with `emergency` glyph, activated by press-and-hold for 2 seconds with a linear fill progress. Keep at least 16 away from any primary action.

### 9.2 Slide-to-complete rail (courier irreversible actions)

- **Track:** height 56, fill `surface-raster-0`, `1px solid wire-border-mid`, 4px inner padding. Width = container width. **Handle:** 48 x 48 square, fill `cobalt-electric`, `keyboard_double_arrow_right` glyph (mirrored in RTL, travel direction mirrors too).
- **Progress fill:** area behind the handle fills with `cobalt-recessed`; label ("SLIDE TO CONFIRM DELIVERY") sits in the unfilled area in `label-lg`.
- **Commit:** release at 90% of travel or more and after a drag of at least 250ms. Otherwise snap back over 160ms, linear. No spring.
- **Haptics:** selection tick at drag start, success confirm on commit.
- **Pocket-trigger safety:** the rail ignores touches that start on the track but not on the handle.
- **Gesture conflicts:** on iOS disable the interactive back-swipe on screens that host a rail; on Android register the rail frame as a system gesture exclusion rect. Keep at least 16 between the screen edge and the handle.
- **Accessibility alternative:** when a screen reader or switch control is active, expose the rail as a single button with an `activate` action labeled "Confirm delivery", followed by a confirm dialog. The visual rail remains.
- **Preconditions:** see section 14 (stopped and inside the drop-off geofence).

### 9.3 Chips and status badges

Structure: radius 0, padding `4px 8px`, `label-caps`, 1px border in the text color, leading 20px glyph, text label always present. Visual height is 24; if tappable, extend the hit area to 48.

| Badge | Fill | Text and border | Glyph |
|---|---|---|---|
| Courier online | `tint-success` | `success-radar` | `sensors` |
| Pharmacy cold-chain | `tint-pharmacy` | `vertical-pharmacy` | `ac_unit` |
| Food thermal lock | `tint-food` | `vertical-food` | `local_fire_department` |
| Grocery substitution | `tint-grocery` | `vertical-grocery` | `swap_horiz` |
| Parcel lockbox | `tint-parcel` | `vertical-parcel` | `lock` |
| Time critical | `tint-amber` | `dispatch-amber` | `timer` |
| Blocking requirement (signature, ID, seal failed) | `tint-crimson` on raster-0 only | `alert-crimson` | `draw`, `badge` or `ac_unit` |

- **Solid variant** (required on raster-1 and above for crimson; required over photos and map): fill the badge with the state color and use `void-base` text and glyph.
- **Badges over imagery** use a solid `surface-raster-0` fill, not a tint.

### 9.4 Lists and manifests

- **Dispatch order rows:** min-height 56, alternating `surface-raster-0` and `row-alt`, `1px solid wire-border-dim` separators. Customer and merchant secondary lists: min-height 48.
- **Manifest row:** monospaced count at the leading edge (`02x`), item title in `body-md` in the center, vertical validation icon at the trailing edge in a 48 x 48 hit area (for example `barcode_scanner` for parcel pickup).
- **Pressed row:** fill `surface-raster-2`.
- **Pharmacy rows** never show item names to couriers (section 14).

### 9.5 Checkbox, radio, switch

- **Checkbox:** 20 x 20 square, hit area 48 x 48. Unchecked: fill `surface-raster-0`, `1px solid wire-border-control`. Checked: fill `cobalt-electric`, `1px solid cobalt-high-beam`, `check` glyph in white.
- **Radio:** 20 x 20 square with a 4px chamfer on the top trailing corner (distinguishes it from a checkbox). Selected: 12 x 12 `cobalt-electric` square centered, border `cobalt-high-beam`.
- **Switch** (status toggles, such as Go Online): 56 x 32 rectangular track and a 24 x 24 square thumb; hit area at least 56 high. On: track `cobalt-electric`, thumb `white`, label `ON`. Off: track `surface-raster-0` with `wire-border-control`, thumb `text-muted`, label `OFF`. State text is always visible beside the switch.

### 9.6 Inputs, scanner fields, OTP

- **Container:** bed `surface-raster-0`, `1px solid wire-border-control`, radius 0. Height 56 in the courier terminal, 48 elsewhere. Value text `body-lg` (56) or `body-md` (48). Placeholder `text-placeholder`.
- **Label** above in `label-md` uppercase `text-muted`, 8 gap. **Helper** below in `body-sm` `text-muted`.
- **Focus:** border becomes `1px solid cobalt-high-beam` plus `inset 0 0 0 1px cobalt-high-beam` (a 2px total border without layout shift), instant.
- **Error:** border `1px solid alert-crimson` plus a message row with the `error` glyph and `body-sm` text. Crimson text only on raster-0 or raster-1; on raster-2 use `text-primary` text with a crimson glyph.
- **Scanner field:** integrated 48 x 48 trailing button with `barcode_scanner`. A manual-entry path always exists.
- **OTP / pickup code:** 4 to 6 boxes, each 56 x 56, 8 gap, `code-lg` text. Active box shows the focus style. Pickup codes shown to the user render in `telemetry-cyan`. Enable one-time-code autofill (iOS `.oneTimeCode`, Android SMS retriever).

### 9.7 Cards and HUD modules

- **HUD card:** header bar 32 high on `surface-raster-1` holding order number (`#ORD-9024`) and the vertical badge; body on `surface-raster-0` with 16 padding showing destination, clearance time and recipient notes in `body-md`; footer pins a 56 action button or the slide rail. Top trailing chamfer 8.
- **Product/menu card:** photo at the top (4:3 for menu, 1:1 for grocery), `1px solid wire-border-dim`, no radius, no filters. Name in `title-md`, price in `body-md` (monospaced, tabular), quantity stepper at the bottom. Missing photo: `surface-raster-1` block with an `image` glyph.
- **Quantity stepper:** `[-] 02 [+]`; each button 48 x 48 square, count in `body-lg`. Long-press repeats.
- **Avatar:** square, 48 (or 32 in dense rows), `1px solid wire-border-mid`; fallback is initials in `label-lg`.

### 9.8 Navigation

- **Top bar:** 56 high, `surface-raster-0`, bottom `1px wire-border-dim`, title in `title-lg`, leading action in a 48 hit area. Respects the top inset.
- **Tab bar** (compact, customer and merchant): 56 high plus bottom inset, `surface-raster-1`, 3 to 5 items each at least 48 wide. Item: 24 glyph (FILL 1 when active) above a `label-md` label. Active: `cobalt-high-beam` glyph, `text-primary` label, 2px `cobalt-high-beam` top bar. Inactive: `text-muted`.
- **Navigation rail** (medium and larger): 80 wide, items 56 high, same active treatment on the leading edge.
- **Courier active job:** navigation is hidden; the screen is the job.

### 9.9 Sheets, dialogs, toasts, banners, loaders

- **Bottom sheet:** Level 2, 16 padding, drag handle 32 x 4 square centered 8 from the top in a 48 high hit area, snaps per section 4.5, no scrim (the map stays interactive).
- **Dialog:** Level 3, width per section 4.5, 24 padding, title `title-lg`, body `body-md`. Scrim `scrim`. Actions stack vertically on compact (primary first), side by side on medium and larger (primary on the trailing side). Critical dialogs have no outside-tap dismiss.
- **Toast:** Level 2, min-height 48, appears above the pinned action bar or tab bar, 4 seconds (6 with an action), one at a time. Never covers a primary action. No toast that needs interaction while a courier is moving.
- **Banner:** 48 high, full width, directly below the top bar, glyph + label + timestamp, not dismissible while the condition persists (section 11).
- **Square loader** (the only indeterminate indicator): three 8 x 8 squares, 4 gap, lighting in sequence every 160ms in `cobalt-high-beam`. Reduced motion: static `LOADING` text. Never use `CircularProgressIndicator`, `UIActivityIndicatorView` or any round spinner.
- **Determinate progress / ETA bar:** a segmented bar 8 high, segments separated by 4. Filled `cobalt-high-beam`, current segment pulses, remaining `surface-raster-2`.
- **Skeleton:** `surface-raster-1` rectangles with `1px wire-border-dim`; an optional 1px scanline sweep at 1200ms linear (static under reduced motion).
- **Empty state:** 32 glyph, `title-md` heading stating what is empty, `body-md` `text-muted` line with the next step, and one action button.

### 9.10 Scanner, signature, proof of delivery

- **Scanner overlay:** full-bleed camera over `void-base`; reticle is four corner brackets (24 arm length, 2px `cobalt-high-beam`, square ends); a 1px `telemetry-cyan` scan line sweeps (static center line under reduced motion). Success turns brackets `success-radar`, plays a confirm haptic and shows `check`. Always show a 56 torch toggle (`flashlight_on`) and a manual entry field. Denied camera permission shows an empty state with a settings action.
- **Signature capture:** canvas `surface-raster-0`, `1px wire-border-control`, min-height 160, baseline dash, strokes 2px `white`. Export on a white background with black ink for the record. Actions: `CLEAR` (secondary) and `CONFIRM` (primary, disabled until a minimum stroke length is reached).
- **Proof-of-delivery photo:** viewfinder as the scanner; shutter is a 64 x 64 square with a 2px white border and a 48 white inner square; `RETAKE` and `USE PHOTO` after capture. Timestamp and coordinates stored as metadata and shown in `label-md`.

### 9.11 Messaging and incoming dispatch

- **Message block** (customer and courier chat): rectangular blocks, max 80% of the pane width. Incoming: `surface-raster-1`, `1px wire-border-dim`, leading side. Outgoing: `surface-raster-2`, 4px `cobalt-high-beam` bar on the leading edge, trailing side. Timestamp in `label-md` `text-muted`. Courier compose uses preset quick replies in 56 high chips; free typing is disabled while moving.
- **Incoming dispatch alert** (courier): Level 3 full-screen takeover on compact, centered 480 dialog on medium and larger. Shows vertical badge, pickup and drop-off distance, payout, and a segmented `dispatch-amber` countdown. Two stacked 56 high actions: `ACCEPT` (primary) and `DECLINE` (secondary). Sound plus haptic. Expiry auto-declines and records it. Must surface in the background (iOS time-sensitive notification, Android full-screen intent). Default window: 30 seconds (see section 18).

### 9.12 Route stepper

- **Lines:** 2px solid `cobalt-electric` for completed legs; dashed `wire-border-mid` with 4px dash and 4px gap for upcoming legs. Lines are decorative; the node shapes carry the meaning.
- **Nodes:** completed 12 x 12 solid `cobalt-electric` square; upcoming 12 x 12 hollow square with a 2px `wire-border-control` border; current stop 16 x 16 solid `cobalt-high-beam` square with the pulse ring (section 8).
- Nodes are not tappable; the stop row beside them is (48 high minimum).

## 10. Map

Provider is not fixed (section 18). Whatever the provider, the style must be expressible as vector style JSON. If a provider cannot meet this spec, flag it instead of approximating.

| Layer | Spec |
|---|---|
| Land | `void-base` |
| Water | `surface-raster-0` |
| Buildings | `surface-raster-1`, no extrusion |
| Minor roads | 1px `wire-border-dim` |
| Major roads | 1px `wire-border-mid` |
| Labels | `label-md` in `text-muted`, 1px `void-base` halo (a stroke, not a blur). Hide POIs and transit unless a screen needs them |
| Active route | 4px `cobalt-high-beam` with a 1px `void-base` casing |
| Completed route | 4px `cobalt-electric` |
| Upcoming route | 2px dashed (8 on, 8 off) `rgba(255,255,255,0.40)` |
| Pickup / drop-off markers | 32 x 32 squares with 2px border and 20 glyph in the vertical color (pickup: vertical identity glyph; drop-off: `pin_drop`); hit area 48 |
| Courier position | `navigation` glyph 24 in `telemetry-cyan`, rotated to heading, with the pulse ring |
| Map controls (recenter, zoom, layers) | 56 x 56 squares at Level 2, trailing edge, 16 from the margin, stacked with 8 gap |

Every map screen has a text alternative: a list-view toggle or the manifest in the deck. The map is never the only way to get information.

## 11. System states and live telemetry

Courier-critical states are banners (9.9) with a glyph, label and age, in this priority order. Only the highest-priority one shows; others collapse into a counter.

| State | Trigger (defaults) | Banner |
|---|---|---|
| Offline | no network | `wifi_off`, crimson. Queue writes locally and show `QUEUED`. |
| GPS lost | no fix for 30s | `gps_off`, crimson. `GPS SIGNAL LOST. LAST FIX 00:42 AGO.` |
| Stale telemetry | no update for 10s | `sensors`, amber with age counter |
| Low battery | below 15% (amber), below 5% (crimson) | `battery_alert` |
| Cold-chain breach | sensor out of range or stale | crimson, with required action steps; handoff blocked |

Customer and merchant views of stale data show the age in `label-md` (for example `UPDATED 00:18 AGO`) and never present stale ETA as live. Telemetry values show `--` with a stale glyph while unknown, never `0`.

## 12. Accessibility

- **Contrast:** follow section 2.5. Text 4.5:1, non-text UI 3:1.
- **Color independence:** every vertical, state and badge has a glyph and a text label.
- **Targets:** section 4.3.
- **Screen readers (VoiceOver, TalkBack):** every control has an accessible name that matches its visible text (Voice Control users speak the visible label). Reading order equals visual order. Live ETAs are `polite` and throttled (announce at most every 30 seconds or on a change of one minute or more). Dispatch offers, emergency and cold-chain breaches are `assertive`.
- **Gestures:** every drag, long-press or swipe has a tap alternative (slide rail, sheet snaps, emergency hold).
- **Text scaling:** section 3.1.
- **Reduced motion:** section 8.
- **Haptics and sound** are never the only feedback.
- **Focus order and focus visibility** are required for external keyboards on iPad and Android tablets.

## 13. Content, localization and RTL

### 13.1 Voice

Terse, imperative, factual. Uppercase is a style applied to labels and buttons only; body, errors and helper text are sentence case. No exclamation marks, no emoji, no jokes, no "Oops". State what happened and what to do next.

- Good: `GPS signal lost. Last fix 00:42 ago.` / `Seal broken. Do not hand over. Contact support.` / `Arrive at drop-off to enable.`
- Bad: `Oops! Something went wrong.` / `We couldn't connect :(`

### 13.2 Glossary (use consistently in UI strings)

- **Courier:** the person delivering (the term "driver" is not used in UI strings).
- **Customer:** the person receiving. **Merchant:** the business fulfilling.
- **Dispatch:** an offer sent to a courier. **Order:** the customer's purchase. **Pickup / drop-off:** the two stops. **Handoff:** the act of transferring the order. **Vertical:** food, grocery, pharmacy or parcel.

### 13.3 Formats

- **Time and dates:** follow the device locale. Countdowns under one hour use `MM:SS`; clock times use the locale's 12 or 24 hour format. Arrival shows clock time, remaining shows countdown.
- **Distance and units:** metric or imperial by locale or merchant setting. Show a consistent unit per screen.
- **Currency:** the merchant's currency, symbol per locale, fixed decimals, tabular numerals, aligned on the trailing edge in tables.
- **Digits:** telemetry values, codes, order IDs, coordinates and amounts always use Western Arabic digits (0 to 9) so the monospace layout holds. Digits in body prose follow the locale (see section 18).
- **Coordinates:** `lat, lng` with 5 decimals.

### 13.4 Imagery

Food and product photos are natural, unfiltered, rectangular, with `1px wire-border-dim`. Aspect ratios: 4:3 for menu, 1:1 for grocery. Parcel uses no photo (glyph and dimensions). No illustrations or mascots; empty states use a glyph and text.

### 13.5 RTL and non-Latin scripts

- Use logical start and end properties, never left and right. In RTL the rail, the deck, back arrows, the slide rail travel direction, the hard shadow and the chamfer corner all mirror (section 7 lists the glyphs that mirror and those that do not).
- Order IDs, pickup codes, coordinates and amounts embedded in RTL text are wrapped in a left-to-right isolate (U+2066 to U+2069, or the platform bidi API) so they never reorder.
- Set `letterSpacing` to 0 and skip the uppercase transform for scripts that have no case or join letters (Arabic and similar). Bundle or reference a fallback font for each shipped script; Space Grotesk and JetBrains Mono do not cover them. Keep tabular alignment by rendering digits in JetBrains Mono.

## 14. Domain safety and privacy

- **Moving lockout (courier).** When speed is above 8 km/h (5 mph) the app is in "moving" state: disable keyboards, free-text chat, notes, form entry and multi-step flows; allow navigation, accept and decline, hands-free calls and one-tap quick replies. Design each moving screen for glances of 2 seconds or less, no more than 12 seconds of total eyes-off-road for any task. Show only ETA, next instruction or address, and one action.
- **Handoff preconditions.** The slide rail enables only when the courier is within the drop-off geofence (default 150m) and has been below 8 km/h for 3 seconds, or has tapped `I AM ON FOOT`. Show the unmet condition in the disabled caption.
- **Pharmacy.** Never show drug names, prescription contents or patient details in push notifications, lock screens, widgets, app switcher snapshots or couriers' manifests. Use `Pharmacy order update` and `SEALED PACKAGE · RX`. Mark screens that contain protected data as secure (Android `FLAG_SECURE`; blur in the iOS app switcher). Handoff requires the signature and, where required, ID verification (`badge`), shown as blocking crimson requirements. A courier can refuse the handoff with a logged reason.
- **Cold-chain.** A failed seal or out-of-range sensor is crimson, blocks handoff, and shows the required steps.
- **Emergency control** is present on every active-job screen (section 9.1).
- **Location and camera:** request permission in context, explain why in one line, and provide a manual path (typed code, manual entry) when denied.

## 15. Platform implementation notes (Android and iOS)

Defaults of each framework fight this system. Override them in the theme layer before building screens.

| Concern | Rule |
|---|---|
| Units | `px` in this file = dp (Android) = pt (iOS). |
| Zero radius | Flutter: `BorderRadius.zero` in every component theme; RN: no `borderRadius`; Compose: `MaterialTheme.shapes` all `RectangleShape`; SwiftUI: use `Rectangle()` and `.clipShape(Rectangle())`. Never use `RoundedRectangle`, `.cornerRadius`, `Capsule` or `Circle`. |
| Chamfer | Flutter: `BeveledRectangleBorder` with a per-corner value; Compose and SwiftUI: a custom `Shape` using the path in 6.1; RN: `react-native-svg` path or mask. |
| Hard shadow | Flutter `BoxShadow(blurRadius: 0, offset: Offset(4,4))`; SwiftUI `.shadow(color:, radius: 0, x: 4, y: 4)`; iOS RN `shadowRadius: 0, shadowOffset: {width: 4, height: 4}, shadowOpacity: 1`; Android RN and Compose: draw a sibling rectangle offset by 4 behind the surface (elevation cannot tint hard shadows). |
| Press feedback | Replace Material ripple and iOS highlight with the rectangular press state (section 9). Flutter `NoSplash.splashFactory`; Compose a custom `Indication` that fills the bounds; do not use unbounded ripples. |
| Progress and switches | Ban `CircularProgressIndicator`, `UIActivityIndicatorView`, native `Switch`, native `Slider` thumbs and native date or time pickers; use the custom square components. OS permission prompts and share sheets are the only native dialogs. |
| Tabular numerals | Flutter `FontFeature.tabularFigures()`; SwiftUI `.monospacedDigit()`; RN `fontVariant: ['tabular-nums']`; Compose `fontFeatureSettings = "tnum"`. |
| System bars | Edge to edge. Light status bar icons on dark. Transparent or `surface-raster-0` navigation bar. Android 15 enforces edge to edge; always apply insets. |
| Window changes | Layout reads the live window size (4.1). Preserve state across resize, rotation and multitasking. |
| Keyboard | Use IME insets; sheet snaps to `full` (4.5). |
| Back gestures | Disable iOS interactive pop on screens with a slide rail; set Android gesture exclusion rects for the rail. Support Android predictive back elsewhere. |
| Haptics | `selection` for ticks, `confirm` for success, `reject` for errors (iOS `UIImpactFeedbackGenerator` and `UINotificationFeedbackGenerator`; Android `HapticFeedbackConstants`). |
| Fonts and icons | Bundle in the app. Do not fetch at runtime. |
| Notifications | Dispatch uses time-sensitive (iOS) and full-screen intent (Android) channels. Pharmacy payloads follow section 14. |
| Foldables | Honor the fold posture and hinge (4.4). |

Reusable snippets (language neutral):

```
focus ring:      outline 2px solid {colors.focus-ring}; offset 2px; blur 0
hard shadow:     offset (4,4); blur 0; color {elevation.hard-shadow-color-default}
pulse ring:      ring from 0 to 12px offset; 1200ms linear; opacity 0.6 -> 0; no blur
bottom action:   padding-bottom = max(inset-bottom, 16) + 8
```

## 16. Do and Don't

**Do**
- Use `cobalt-high-beam` for every line, ring, border, icon and route on a dark surface.
- Use `void-base` text on crimson, amber and cyan fills; white text only on `cobalt-electric`.
- Pair every color with a glyph and a label.
- Choose layout from the live window size; keep 56 and 48 targets on every device.
- Use tabular numerals; swap values instantly.
- Keep an escape for every gesture and every map screen.

**Don't**
- Don't use any radius, circle, pill, round spinner, circular ripple, avatar circle or Rounded icon variant.
- Don't use blurred shadows or glows; don't use gradients.
- Don't use cobalt `#1D4ED8` as text, border, icon or line on a dark surface.
- Don't put text on a high-beam fill, or white text on a crimson fill.
- Don't use `wire-border-mid` or `-dim` as the only boundary of a control.
- Don't create a light theme, a new color, a new font size or an off-grid spacing value.
- Don't shrink touch targets on tablets; don't make buttons full-width across a wide canvas.
- Don't animate numbers, spring, bounce or overshoot.
- Don't show pharmacy item names outside authenticated, secure screens.
- Don't rely on hover or color alone.

## 17. Pre-ship checklist (run before reporting a screen as done)

- [ ] All colors, sizes, spacing and durations come from tokens; no raw hex.
- [ ] Zero radius everywhere, including ripples, spinners, switches, avatars and focus rings.
- [ ] Layout verified at widths 360, 600, 840 and 1200, and heights 375 and 900; resize and rotation preserve state.
- [ ] Margins and gutters match the size class; touch targets are 56 or 48 minimum with non-overlapping hit areas.
- [ ] Text 4.5:1 and non-text UI 3:1 (section 2.5); no cobalt on dark; no text on high-beam fill.
- [ ] Every state has color, glyph and text; every vertical badge has glyph and label.
- [ ] All states implemented: default, pressed, focus-visible, disabled (with reason), loading, error, selected.
- [ ] Monospaced tabular numerals; no count-up animations.
- [ ] Icons: Sharp variant, correct weight, correct fill.
- [ ] Reduced motion, 150% text scale and screen reader labels checked.
- [ ] Slide rail has its accessible alternative and gesture-conflict handling.
- [ ] RTL checked (mirroring, isolates, tracking).
- [ ] Courier moving-state restrictions and pharmacy privacy rules applied.
- [ ] Anything not verified is listed in the summary.

## 18. Open decisions (assume these defaults, flag them in your summary)

| Decision | Default to assume |
|---|---|
| Framework | Stack-neutral rules in section 15. Ask which stack before generating theme code. |
| Product name, logo, app icon | Not defined. Use a text wordmark in Space Grotesk 700 uppercase, tracking `0.04em`. Provide a full-bleed square icon (`cobalt-electric` with a `void-base` glyph); the OS applies its own mask. |
| Map provider | Any provider that supports vector style JSON. |
| Dispatch offer window | 30 seconds. |
| Moving threshold, geofence radius | 8 km/h, 150m. |
| Digits in customer prose for RTL locales | Western digits in telemetry; locale digits in prose. |
| Optional "glare boost" mode (stronger borders and muted text) | Not implemented. |
| Emergency control behavior (what it calls or notifies) | Not defined; UI only. |

## 19. Changes from v1

| Area | v1 | v2 |
|---|---|---|
| M3 color roles | Pastel palette contradicting the brand core | Remapped to brand core; unused `*-fixed` roles removed |
| `surface` / `background` | `#0F131D` | `#080C14` (`surface-raster-0`) |
| `wire-border-active` | `#1D4ED8` | `#3B82F6` (contrast) |
| Control borders | 0.16 and 0.30 white | `wire-border-control` 0.40 (3:1 or better) |
| Rounded | prose only | `rounded.*` tokens all 0, with override rules |
| Icons | Outlined and Rounded | Sharp |
| Press state | "inverted or `#3B82F6`" | inverted white and cobalt; hover is high-beam with `void-base` text |
| Spacing keys | `gutter-tablet`, `gutter-desktop`, `margin-tablet`, `margin-desktop` | `gutter-{compact,medium,expanded,large}`, `margin-{compact,medium,expanded,large}`. `tablet` maps to `medium` and `expanded`; `desktop` maps to `large` |
| Type | `label-caps` 10/12; some line heights off-grid | `label-caps` 11/16; line heights on the 4px grid (`headline-xl` 36, `headline-md` 28, `title-md` 24, `label-md` 16) |
| Off-grid sizes | 10px nodes and radio inset | 12px nodes, 12px radio inset, 16px current node |
| New | none | `components` block, motion, z-index, size classes, states, platform rules, safety rules, checklist |
