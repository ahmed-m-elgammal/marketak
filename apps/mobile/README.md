# apps/mobile — file architecture

One Expo app, two roles, 60 routes, 23 sheets, 19 client RPCs. **Nothing here is a god file, and that is enforced, not promised.**

**Styling is Uniwind + PanelUI** — see `decisions.md` **ADR 25**, which reverses open question 3.9.
`src/theme/` is `global.css` with Tailwind v4 `@theme{}` tokens. `src/components/ui/` is a **wrapper
layer**, not an implementation layer: the 34 Tier-0 primitives named in
`APP-SCREENS-AND-COMPONENTS.md` §6.1 stay as the naming contract and become thin files that compose
PanelUI with Marketak tokens.

> **Expo SDK 57+ / React Native 0.86 is the floor.** Required by PanelUI.
>
> **Subpath imports only.** `import { Button } from 'panelui-native/components/button'` — never
> `from 'panelui-native'`. Metro does not tree-shake the root, so the root form evaluates all 138
> components before the first screen paints and OOM-kills Android under memory pressure.

---

## The one rule everything else follows

> **`app/` decides *where you are*. `src/features/` decides *what happens*. `src/` decides *how it's drawn and fetched*.**
>
> A route file may render a screen. It may not fetch, map, or compute. A feature may not be imported by another feature. A screen may not be imported by anything except its own route file.

If you only remember one thing: **routes are addresses, features are brains, `src/` is the toolbox.**

---

## Layer map

| Layer | Owns | May import | Must never |
|---|---|---|---|
| `app/` | route addresses, navigators, layouts | `features/*` public surface, `components/*` | hook into `src/features/<x>/screens` by path, hold state, fetch |
| `src/features/<name>/` | one business slice end-to-end | own internals, `src/*` shared | import another feature directly |
| `src/components/` | shared UI only | `src/` shared | import `features/` |
| `src/lib/` | pure functions | nothing | import React or React Native |
| `src/services/` | every supabase / device / network touch | `src/lib/`, `src/types/` | import `features/` or `components/` |
| `src/stores/` | cross-screen state | `src/types/` | import `features/` |
| `src/theme/` | `@theme` tokens, typography, spacing, RTL | nothing | import anything |
| `src/types/` | DTOs mirroring the DB | nothing | import anything |

`src/lib/` importing nothing and `src/theme/` + `src/types/` importing nothing is what keeps the dependency graph a DAG. `.dependency-cruiser.cjs` enforces all of it in CI.

**`src/theme/design-rules.md` is the aesthetic contract.** Six rules set by the product owner — more
spacing, borders instead of shadows, a 60/30/10 palette, no decorative background shapes, two font
families max, less clutter and more clarity. They are enforced by `global.css` wherever they can be:
`--shadow-*` are set to `none`, the spacing scale is closed, the palette is closed, and there are no
gradient or shape tokens to reach for. **Read it before building any component.**

---

## Size limits — the anti-god-file contract

Hard caps. A file over its cap is a review failure, not a style opinion.

| Kind | Cap | Why |
|---|---:|---|
| Route file (`app/**`) | **20 lines** | it is an address, not a screen |
| Screen (`features/x/screens`) | **150 lines** | past 150 it is hiding a component |
| Component | **200 lines** | past 200 it is two components |
| Hook | **60 lines** | past 60 it is two hooks |
| Service module | **120 lines** | past 120 it is two modules |
| Mapper | **80 lines** | it is a pure shape translation |
| `index.ts` barrel | re-exports only, **no logic** | |

A screen that needs 400 lines does not get a 400-line screen. It gets a `components/` entry and a `hooks/` entry.

---

## `app/` — routes

Expo Router. Five route groups, one file per address:

```
app/
├── _layout.tsx              root providers + BootGate           (~40)
├── index.tsx                redirect by role                    (~10)
├── (auth)/                  7 routes — guest shell
├── (customer)/              37 routes
├── (driver)/                18 routes
└── (shared)/                5 routes — both roles
```

A route file looks like this and nothing more:

```tsx
// app/(customer)/orders/[orderId]/track.tsx
export { default } from '@/features/orders/screens/OrderTrackScreen';
```

That is the whole file. No `useQuery`, no `supabase`, no `StyleSheet.create`.

**Group choice is not cosmetic.** `(customer)` and `(driver)` unmount and remount on role switch — deliberately, because the two tab trees hold contradictory caches (customer cart vs active trip). Do not "optimise" this by keeping both mounted.

---

## `src/features/<name>/` — 15 vertical slices

Every slice has the same internal shape, so an agent landing in one can navigate all of them:

```
features/<name>/
├── screens/      1 file per screen, composition only, <=150 lines
├── components/   feature-local components, <=200 lines
├── sheets/       bottom sheets & modals owned by this feature
├── hooks/        1 concern per file, <=60 lines
├── api/          RPC + query calls, 1 file per RPC group
├── mappers/      DB row -> DTO, pure, no side effects
├── __tests__/    colocated
└── index.ts      THE ONLY PUBLIC SURFACE
```

<details>
<summary>The 15 slices, and what each owns</summary>

| Slice | Routes | Notes |
|---|---:|---|
| `auth` | 6 | splash, welcome, sign-in, callback, complete-profile, role switch |
| `discovery` | 5 | home, promo, search, cuisines, browse |
| `storefront` | 2 | vendor page, item detail |
| `cart` | 1 | cart + customization sheets |
| `checkout` | 6 | quote, address, review, price-changed, placed, voucher |
| `orders` | 9 | list, detail, track, timeline, cancel, review, receipt, changes, repeat |
| `account` | 5 | profile, addresses, favorites, settings |
| `notifications` | 2 | centre, push preferences |
| `platform` | 2 | support, about |
| `shell` | 0 | BootGate, tab bars, role switcher, banners |
| `driver-onboarding` | 1 | phone claim against `riders` |
| `driver-availability` | 4 | driver home, online/offline, shifts |
| `trips` | 7 | queue, detail, navigate, contact, cash, complete, failed |
| `driver-money` | 5 | earnings, ledger, cash float, payout list + detail |
| `driver-vehicle` | 1 | vehicle details |

</details>

### The barrel is the boundary

`features/orders/index.ts` re-exports. Nothing else is importable from outside:

```ts
// features/orders/index.ts
export { OrderListScreen } from './screens/OrderListScreen';
export { useOrders } from './hooks/useOrders';
export type { OrderDTO, OrderStatus } from './types';
```

`import { OrderListScreen } from '@/features/orders'` — correct.
`import { OrderListScreen } from '@/features/orders/screens/OrderListScreen'` — blocked by dependency-cruiser.

Routes may reach **into** a feature's public surface. Features may never reach into another feature at all. Shared behaviour goes to `src/` first, or a third feature, never a cross-import.

---

## `src/` shared layers

```
src/
├── components/
│   ├── ui/          Tier 0 primitives — WRAPPERS over PanelUI, ~5-15 lines each
│   │   ├── text/ buttons/ inputs/ overlays/ feedback/ layout/ media/ charts/
│   └── domain/      cross-feature domain parts, used by >= 2 features
│       ├── vendor/ money/ order/ rider/
├── hooks/           shared hooks only — a hook used by one feature lives in that feature
├── lib/             pure functions, ZERO react / react-native imports
│   ├── money/       piastres <-> EGP, bps, rounding, diff arithmetic
│   ├── format/      numbers, dates, ETA, distance
│   ├── bidi/        mixed ar/en runs, LTR-locked numerals
│   ├── geo/         geohash encode/decode, area resolve, haversine
│   ├── time/        quote TTL, schedule windows, holiday merge
│   └── validation/  voucher, phone, checkout input
├── services/        the ONLY layer that touches supabase, R2, device APIs
│   ├── supabase/    client, auth, session
│   ├── rpc/         19 client-callable RPCs, 1 file per RPC group
│   ├── storage/     R2 signer round trip (proof, signature, avatar)
│   ├── device/      push, location, calls
│   └── errors/      PG code -> copy -> CTA map
├── stores/          9 zustand slices
├── theme/           global.css (@theme), typography, spacing, RTL direction
├── types/           17 modules mirroring schema/*.sql
├── config/          env, constants, flag defaults
└── test/            utils, fixtures, builders
```

**`src/lib/` imports nothing.** That is what makes money arithmetic, geohash and schedule maths unit-testable without a renderer. If a function in `lib/` needs `View`, it is in the wrong file.

**`src/components/ui/` is a wrapper layer.** A Tier-0 file composes PanelUI and applies Marketak tokens; it does not implement. That is what keeps 34 primitives maintainable by one person, and it is why the §6.1 names can stay stable while the underlying library is swapped.

**`src/services/` is the only network boundary.** No feature calls `supabase` directly; every feature calls a `services/rpc/*` function. That is how a missing RPC becomes a type error instead of a runtime blank screen — which matters here, because the screen audit found **eight table groups with no write RPC at all**.

---

## What "no god files" buys you, concretely

| Symptom of a god file | What the structure does instead |
|---|---|
| A 900-line `OrderDetailScreen` | `orders/screens/` holds the shell; `orders/components/` holds the vendor cards, rails and lines; `orders/hooks/` holds `useOrderDetail`, `useCancelOrder`, `useReview` |
| One `utils.ts` everyone appends to | `lib/` is split by concern and imports nothing |
| `api.ts` with 40 supabase calls | `services/rpc/` one module per RPC group, typed against `types/rpc` |
| Every screen re-implementing the money format | one `lib/money` + one `PriceText` in `components/ui/text` |
| Feature A reaching into Feature B | barrel boundary, enforced in CI |
| A component that is "sort of shared" | it lives in its feature until a *second* feature needs it, then it moves to `components/domain/` — never before |

---

## Conventions an agent must follow

1. **Named exports only.** No default exports except route files.
2. **Import order is enforced:** react → react-native → panelui → `@/components` → `@/features` → `@/lib` → relative.
3. **No `any`.** Generated Supabase types are wrapped at the `services/` edge into hand-written DTOs; nothing downstream sees the raw row.
4. **PanelUI imports use subpaths only.** `panelui-native/components/button`, never the root. Lint-enforced — see the header.
5. **A component file is a composition.** If a `ui/` file exceeds ~15 lines it is implementing instead of wrapping, and belongs in `domain/` or the feature.
6. **Colocate the test.** `features/x/hooks/useQuote.test.ts` sits next to `useQuote.ts`.
7. **A new feature gets all seven folders**, even the empty ones. An empty folder is a slot waiting for its file; a missing one is where the next god file gets born.
8. **Route files never exceed 20 lines.** If it does, the screen is doing navigation's job.

---

## Verification

These do not exist yet — they are repo task **T0.1c**. Until they do, the architecture above is a convention, not a guarantee.

```
npm run typecheck     # blocks: raw any, boundary violations
npm run lint          # blocks: import order, inline styling
npm run test          # blocks: behaviour regressions
npm run verify        # all of the above + dependency-cruiser
```

`.dependency-cruiser.cjs` already encodes the layer rules above. Run `npx depcruise src app --config .dependency-cruiser.cjs` once T0.1 scaffolds `package.json`.
