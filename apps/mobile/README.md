# apps/mobile — architecture map

**Read this file first. It is the map. Everything else is enforced by tooling, not convention.**

One Expo app, two roles (customer and rider), one Supabase project. No god files.

> **The three sentences that explain everything below**
> `app/` decides **where you are**. `src/core/` decides **what the app can reach**. `src/features/` decides **what happens in one business area**.

---

## 1. The shape

```
apps/mobile/
├── app/                          ROUTES. One file = one address.
│   ├── _layout.tsx               root providers, splash hold
│   └── index.tsx                 entry redirect
│
├── src/
│   ├── core/                     CROSS-CUTTING. Everything not owned by one feature.
│   │   ├── config/env.ts         EXPO_PUBLIC_* config, validated at boot
│   │   ├── theme/                global.css (@theme tokens), tokens.ts, design-rules.md
│   │   ├── error/                AppError — PG error code -> typed failure
│   │   ├── network/              THE ONLY NETWORK BOUNDARY
│   │   │   ├── supabase-client.ts   the single Supabase client
│   │   │   └── rpc/                 DTOs, call.ts, typed wrappers
│   │   ├── storage/              device + cache storage (created on first use)
│   │   ├── device/               push, location, calls (created on first use)
│   │   ├── utils/                pure helpers (created on first use)
│   │   └── di/                   composition root (created on first use)
│   │
│   ├── features/<name>/          ONE BUSINESS SLICE. Vertical, self-contained.
│   │   ├── index.ts              THE ONLY PUBLIC SURFACE (barrel)
│   │   ├── screens/              a screen — composition only, <=150 lines
│   │   ├── widgets/              slice-local components, <=200 lines
│   │   ├── hooks/                one concern per file, <=60 lines
│   │   ├── mappers/              DB shape -> view shape. Created only if one is needed.
│   │   └── api/                  slice-specific RPC grouping, if core/rpc is not enough
│   │
│   ├── components/               SHARED UI, two tiers
│   │   ├── ui/                   Tier 0: thin wrappers over PanelUI + tokens
│   │   └── domain/               Tier 1: used by TWO or more features. Never preemptively.
│   │
│   └── lib/                      pure maths: geo, bidi, schedule. Zero react.
│
└── .dependency-cruiser.cjs       the boundaries above, made executable
```

**Why `core/` and not `services/`:** the Talabat-style `lib/core/` grouping is genuinely better
than a flat `services/`, `lib/`, `config/`, `theme/`. Cross-cutting concerns get one home
instead of four top-level folders. What is **not** copied is their per-feature
`bloc/` + `event/` + `state/` trio, because React already is the state layer and a
`feature_event.ts` would duplicate `useState`. Nor `domain/entities/ + repositories/ + usecases/`,
which for this app would be three files forwarding to Postgres RPCs.

---

## 2. Which stubs exist, and why

Stub folders hold a `.gitkeep` until the file that needs them is written. They are listed here so
you can see the plan without opening the tree.

| Stub | Slices | Justification |
|---|---|---|
| `features/<slice>/` | 14 slices | Each maps to a numbered section of `APP-SCREENS-AND-COMPONENTS.md` |
| `features/<slice>/screens/` | 14 slices | Every slice has at least one route in the spec |
| `features/<slice>/widgets/` | 14 slices | Every slice has components (spec §6.2–6.3) |
| `features/<slice>/hooks/` | 14 slices | 35 hooks are enumerated in spec §9 |
| `components/ui/` + 8 categories | — | 34 Tier-0 primitives are enumerated in spec §6.1 |
| `components/domain/` + 4 categories | — | 55 Tier-1 domain components in spec §6.2–6.3 |
| `core/storage/ device/ utils/ di/` | — | 22 services enumerated in spec §9 |

**Deliberately NOT stubbed:**

| Not created | Why |
|---|---|
| `features/*/mappers/` | Every RPC already returns a typed DTO from `core/network/rpc/dto.ts`. There is no raw row left to map. Create one only when a real mapping appears. |
| `features/*/sheets/` | Bottom sheets are screen-level, not slice-level. They live in `widgets/`. |
| `features/*/domain/` | Business logic is in Postgres. A `domain/` here would forward, not decide. |
| `features/*/api/` | `core/network/rpc/api.ts` already owns the RPC wrappers. |
| `stores/` | No zustand installed, no cross-screen state that needs it yet. |

If a stub survives with no file and no scheduled work in `tasks.md`, it is deleted. That is
AGENTS.md rule 11.

---

## 3. How to find things

| I need to… | Look in | Never |
|---|---|---|
| Add a screen | `features/<name>/screens/` | add logic to `app/*.tsx` |
| Change what an RPC sends/receives | `core/network/rpc/dto.ts` | re-declare the shape in a feature |
| Add an RPC call | `core/network/rpc/api.ts` | call `supabase.rpc()` anywhere else |
| Understand a DB failure | `core/error/app-error.ts` → `BEHAVIOUR_CODES` | write a new copy of the code |
| Format money, dates, rates | `@marketak/shared` | create `lib/money/` — it would duplicate tested helpers |
| Add a colour / spacing | `core/theme/global.css` | write a literal in a component |
| Add a shared button | `components/ui/` | rebuild one PanelUI already provides |
| Add env config | `core/config/env.ts` | read `process.env` anywhere else |

**Money lives in `@marketak/shared`.** `formatMoney`, `formatCount`, `formatRateBps`, `formatWhen`
already exist and are tested. Two money formatters is how one screen shows `29.50` and another
shows `٢٩٫٥٠`.

---

## 4. Import direction — enforced, not promised

```
app/        -> features/* (barrel only), components/*
features/x/ -> its own internals, src/* shared.   NEVER features/y.
components/ -> src/* shared.                       NEVER features/.
core/       -> theme, config, shared.             NEVER features/ or components/.
lib/        -> nothing.                            NEVER react, react-native, expo.
theme/      -> nothing.
```

`.dependency-cruiser.cjs` fails the build on all of it:

```bash
npx depcruise src app --config .dependency-cruiser.cjs
```

| Rule | Fails when |
|---|---|
| `no-circular` | anything imports itself back |
| `no-cross-slice-<name>` | a feature reaches into a *different* feature's internals — one rule generated per slice, so a new slice is covered automatically |
| `no-deep-feature-import-from-outside` | a route or a service imports `features/x/screens` by path instead of the barrel |
| `lib-is-pure` | `lib/` imports react / react-native / expo |
| `theme-is-a-leaf` | `theme/` imports anything from `src/` |
| `no-supabase-outside-services` | anything outside `core/network/` imports `@supabase/supabase-js` — this is what guarantees **one** auth subscription |
| `shared-never-imports-features` | `components/ lib/ theme/` depends on a feature |
| `no-orphans` | a file nothing imports (dead code, repo rule 10) |

---

## 5. Size limits

| Kind | Cap |
|---|---:|
| Route file `app/**` | **20 lines** |
| Screen | **150 lines** |
| Widget / component | **200 lines** |
| Hook | **60 lines** |
| Core module | **120 lines** |
| `index.ts` barrel | re-exports only, zero logic |

---

## 6. Conventions

1. **Named exports only.** Default exports are for route files.
2. **No `any`.** Supabase's generated types are wrapped at the `core/network/` edge into
   hand-written DTOs. Nothing downstream sees a raw row.
3. **PanelUI subpath imports only:** `panelui-native/components/button`. Never the root — Metro
   does not tree-shake it, and the root form evaluates all 138 components before first paint,
   which OOM-kills Android under memory pressure.
4. **`components/ui/` wraps, it does not implement.** Over ~15 lines means it belongs in
   `domain/` or the feature.
5. **Colocate the test:** `features/x/hooks/useQuote.test.ts` beside `useQuote.ts`.
6. **Money is `Piastres` (integer) from `@marketak/shared`,** never a float.
7. **The client is never trusted with money.** `upsertCartItem` sends intent (item id, options,
   quantity) and the server returns the price. Never cache a price and send it.

---

## 7. Before you commit

```bash
npm run typecheck
npm run lint
npm test
npx depcruise src app --config .dependency-cruiser.cjs
```

---

## 8. Current state

| | |
|---|---|
| Routes | 2 (`_layout`, `index` — splash shell) |
| Features | 1 with code (`auth` — Google/Apple, session, profile gate) |
| Core | `config`, `theme`, `error`, `network` |
| Screens | none yet. Built one at a time, deliberately. |

Read `core/theme/design-rules.md` before building any component. Six rules set by the product
owner: more spacing, borders instead of shadows, 60/30/10 palette, no decorative background
shapes, two font families max, less clutter.