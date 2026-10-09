# Design rules — apps/mobile

Six rules, set by the product owner. They are the aesthetic contract for every screen built here.
They are **enforced by the token module** (`src/global.css`) wherever enforcement is possible, so a
violation is a build-time surprise rather than a design-review argument.

> **The point of all six: feel less cluttered, more clear.**

---

## 1. Spacing — more than you think

Between-elements spacing is what stops a screen feeling cluttered. More spacing buys readability,
touch targets and visual balance.

**But too much reads as empty and disconnected.** The scale below is a 4-point grid; the judgement is
which rung to reach for.

| Situation | Rung |
|---|---|
| Between related controls (label → input) | `space-2` / `space-3` |
| Inside a card, padding | `space-4` / `space-5` |
| Between cards in a list | `space-4` / `space-6` |
| Between major sections | `space-8` / `space-10` |
| Screen horizontal padding | `space-5` / `space-6` |

**Enforced:** the scale is `--spacing-*` in `global.css`. Unreachable-for-spacing values do not exist,
so there is no `p-7` to reach for.

## 2. Borders, not shadows

A shadow is hard to get right — too strong looks artificial, too soft loses all impact. A subtle
border gives the same separation and always looks clean.

**Enforced, and this is the hard one: `--shadow-*` are set to `none` in `global.css`.** The `shadow`,
`shadow-sm`, `shadow-md`, `shadow-lg`, `shadow-xl` and `shadow-2xl` utilities produce **nothing**.
Depth comes from `border` + `bg-surface`, or from `--radius`, never from elevation. If a screen
genuinely needs elevation — a toast above a scrim, a floating action button over content — it uses
`overlay.scrim` and a border, and it says why in a comment.

## 3. Palette — 60 / 30 / 10

Too many colours make a UI chaotic and hard to navigate. Three, in the classic ratio:

| Share | Role | Token |
|---:|---|---|
| **60%** | canvas — the surface everything sits on | `bg-cream` |
| **30%** | content — cards, sheets, inputs, and the ink on them | `bg-surface`, `text-ink`, `text-ink-secondary`, `text-ink-tertiary`, `border-line` |
| **10%** | action — the one colour that should draw the eye | `bg-brand`, `bg-brand-pressed`, `bg-brand-soft` |

Contrast is spent deliberately: a CTA pops against cream because brand green is the only saturated
value on screen, and the rest of the UI stays quiet. **Every screen should read as 60% cream, 30%
white-and-ink, 10% brand.**

**The one legitimate exception is status**, and it is not decoration: `success`, `warning`, `danger`
and `info` communicate meaning and are never used as ornament. They are exempt from the 10% — a red
error text is information, not brand.

**Enforced:** the palette is closed. There is no free-form colour — `global.css` defines exactly
these, and `scripts/check-no-hardcoded-colors.mjs` fails the build on a hex literal outside
`packages/ui/src/theme/colors.ts` and this file.

## 4. No decorative shapes in the background

A blob, a curve, a scattered dot grid: they seem like a good idea and they usually clutter the UI and
pull attention off the content. If a shape has no purpose it is visual noise.

**Concretely:** no background shapes, no decorative curves, no dot grids, no glassmorphism, no
arbitrary gradients — unless the shape *is* the content (a map, a chart, a product photo, an
illustration that carries meaning). Brand green fills a CTA; it does not get a swoosh behind it.

**Enforced:** there is no `bg-gradient-*` or decorative-shape token in the palette, and `blob`,
`swoosh`, `decoration` and `dot-grid` are not components anyone may add. This is the rule most likely
to be broken by a well-meaning addition, so it is the one to argue against loudly.

## 5. Two fonts, weights used sparingly

Not every heading needs a different weight. Two families maximum, and weight does the work that a
third family would.

| Family | Used for | Token |
|---|---|---|
| Latin sans | everything English, and numerals | `font-sans` |
| Arabic | Arabic copy | `font-arabic` |

Two families is the *ceiling*, justified by one thing only: Arabic and Latin need different metrics,
and `imgs/design.md` §3 records that aligning them by visual baseline is not safe with one family. If
a single family covers both, drop to one.

Weights: `regular` for body, `medium` for emphasis, `semibold` for headings and buttons, `bold` for
prices and the display size. **No other weights exist in the scale** — there is no `font-thin` or
`font-black` to reach for, and a heading does not get a new weight just because it is a heading.

**Enforced:** the type scale in `global.css` carries only these, and `text-display` through
`text-caption` are the complete set of sizes.

## 6. The result

Less clutter, more clarity. When two rules conflict, the tie-breaker is this one.

---

## How these are checked

| Rule | Enforced by |
|---|---|
| 2, shadows | `--shadow-*: none` — the utility does nothing |
| 3, palette | closed token set + `scripts/check-no-hardcoded-colors.mjs` in `npm run verify` |
| 3, fonts | `--font-sans`, `--font-arabic` only |
| 5, sizes/weights | closed type scale in `global.css` |
| 1, 4, 6 | judgement — design review |

Rules 1, 4 and 6 are the ones a linter cannot catch. They are the ones to review by hand.
