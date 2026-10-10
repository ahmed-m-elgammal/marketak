# apps/mobile — the layer and size contract

One React Native / Expo binary serving **two roles**, customer and rider, role-switched from the same
build. This file is the architecture contract: what goes where, what may import what, and where the
boundaries are enforced. It is written for an agent building the app.

Read it with `specs-mobile/README.md`, which is the **database** contract. Where the two meet — RPC
names, DTO shapes, status strings, error codes — the database file wins and this file tells you where
that code lives.

---

## 1. The tree

```
apps/mobile/
├── app/                                    L0  composition root (Expo Router)
│   ├── (auth)/                              welcome · sign-in · complete-profile
│   ├── (customer)/                          home · vendor · cart · checkout · orders
│   ├── (rider)/                             offers · trip · earnings · profile
│   ├── +not-found.tsx
│   └── _layout.tsx                          consumes useSession/useRole; mounts providers only
│
└── src/
    ├── features/                            L1 role zones · L2 shared
    │   ├── customer/
    │   │   ├── discovery/       screens/ widgets/ model/
    │   │   ├── cart/            screens/ widgets/ model/
    │   │   ├── checkout/        screens/ widgets/ model/
    │   │   ├── orders/          screens/ widgets/ model/
    │   │   ├── address/         screens/ widgets/ model/
    │   │   └── account/         screens/ model/
    │   ├── rider/
    │   │   ├── offers/          screens/ widgets/ model/
    │   │   ├── trip/            screens/ widgets/ model/
    │   │   ├── money/           screens/ model/
    │   │   └── profile/         screens/ model/
    │   └── shared/                          imports NEITHER role zone
    │       ├── auth/            use-session.ts  use-role.ts  provider.tsx
    │       └── device/          permissions.ts  notification-prompt.tsx
    │
    ├── services/                            L3 the only Supabase layer
    │   ├── supabase/           client.ts  env.ts
    │   ├── auth/               session.ts            server state, NOT in state/
    │   ├── rpc/
    │   │   ├── index.ts        the barrel — the only importable entry
    │   │   ├── call.ts          fetch + error parse + ZOD validation
    │   │   ├── reads.ts         supabase.from() — the only direct table reads
    │   │   ├── dto/             cart orders rider discovery profile admin push
    │   │   └── schemas/         cart orders rider discovery quote       zod
    │   │       cart.ts  orders.ts  rider.ts  discovery.ts  profile.ts  admin.ts  push.ts
    │   ├── errors/             parse.ts  behaviour.ts  toBehaviour()  overrides.ts
    │   ├── cache/              queryClient.ts  query-keys.ts
    │   ├── push/               fcm.ts  register.ts  routing.ts
    │   └── analytics/          provider.ts
    │
    ├── ui/                                  L4 presentational
    │   ├── buttons/  text/  inputs/  overlays/  charts/  media/
    │   └── feedback/            error-screen  empty-state  loading
    │
    ├── theme/                               L5
    │   └── tokens.ts  global.css  design-rules.md
    │
    ├── i18n/                                L5 one home, RTL
    │   └── index.ts  useT.ts  ar.json  en.json  pickLang.ts
    │
    ├── domain/                              L6 leaf — imports nothing internal
    │   ├── orders/status.ts     five string unions ONLY
    │   ├── money.ts             re-export @marketak/shared
    │   ├── time/index.ts        re-export formatWhen, formatRelativeInZone
    │   └── geo/  measure/
    │
    ├── state/                               L7 leaf — UI only, no session
    │   └── ui.ts               sheet open, selected tab, form drafts
    │
    └── lib/  config/env.ts                  L7
```

**Inside a feature, the same three slots — when they exist:**

```
features/customer/cart/
├── screens/    CartScreen.tsx      route content: composes widgets + one hook
├── widgets/    CartLine.tsx        presentational, props in
└── model/      use-cart.ts          queries, mutations, local state
```

There is no `api/` folder — it is folded into `model/`. There is no feature `index.ts` anywhere; the one
barrel in the app is `services/rpc/index.ts`.

### Why `.gitkeep` and not empty `.ts` files

Every folder above currently holds only `.gitkeep`. An empty `cart.ts` that nothing imports trips the
`no-orphans` rule in `.dependency-cruiser.cjs` on the first `npm run deps:check`. `.gitkeep` is the
exemption the rule already grants. **Delete a `.gitkeep` the moment you create the first real file in
that folder** — a `.gitkeep` sitting next to source is the placeholder the rule is there to catch.

---

## 2. The layer order

A layer imports only layers **strictly below** it. Layer 0 is the composition root and is the single
exception: it imports anything, because it mounts the provider stack.

| # | Layer | May import | Must never import |
|---|---|---|---|
| **0** | `app/` | **everything** — composition root | — |
| **1** | `src/features/<role>/` | 2, 3, 4, 5, 6, 7 | — |
| **2** | `src/features/shared/` | 3, 4, 5, 6, 7 | **1** — never a role zone |
| **3** | `src/services/` | 5, 6, 7 | **1, 2, 4** — never a feature, never UI |
| **4** | `src/ui/` | 5, 6, 7 | 1, 2, 3 |
| **5** | `src/theme/` `src/i18n/` | 6, 7 | 1, 2, 3, 4 |
| **6** | `src/domain/` | 7 | everything above |
| **7** | `src/state/` `src/lib/` `src/config/` | 5, 6 | 1, 2, 3, 4 |

`features/shared` sits **above** `services`, not below it: it is a consumer of the data layer, not a
leaf. The only zone that imports from neither role is `features/shared`.

---

## 3. The seven rules

**R1 — One direction.** Layer N imports only layers > N. Layer 0 may import any. Nothing points up.

**R2 — No cross-role import, ever.** `customer/**` must never import `rider/**` and vice versa. They
meet in `app/` (routes), in `domain/` (vocabulary) and in `services/` (data). No exceptions.

**R3 — Only `model/` is public.** Within one role, `feature-a` may import `feature-b/model`. Never
`feature-b/screens`, `feature-b/widgets`, or a barrel. Across roles: nothing.

**R4 — `services/` is the only Supabase layer.** `rpc()`, `from()`, `storage`, `functions`,
`channel()` — all of it. No feature ever imports the client.

**R5 — Server data is cache, not store.** TanStack Query owns everything the server returns. `state/`
holds UI flags only: sheet open, selected tab, form drafts. A store holding `orders` is a second source
of truth that drifts, and it is banned twice — by the path rule on `state/` and by
`no-restricted-imports` on `services/rpc/dto/*`.

**R6 — Slots appear when a file needs them.** No folder exists until something in it. The tree in §1 is
the *target* shape, not a list of folders to fill.

---

## 4. What is enforced, and by what

`.dependency-cruiser.cjs` is the mechanical contract. `npm run deps:check` from `apps/mobile`.

| Rule in the config | Enforces |
|---|---|
| `no-customer-to-rider` / `no-rider-to-customer` | R2 |
| `shared-imports-neither-zone` | R2, `features/shared` |
| `no-supabase-outside-the-client` | R4 — `services/` is the only Supabase layer; features/routes never import it (direct-only: reachability through the barrel is the sanctioned chain, not a bypass) |
| `rpc-entry-is-the-barrel-only` | R4 — the barrel is the only entry; deep imports (`call.ts`, `schemas/`) bypass review |
| `only-model-is-public` | R3 — uses back-references, see below |
| `no-circular` | cycles from cross-feature `model/` imports |
| `no-second-money-module` | money formats only from `@marketak/shared` |
| `no-second-error-parser` | one error layer, `services/errors` |
| `no-orphans` | R6 + dead code; `.gitkeep` and `app/` are exempt |
| `no-server-tables-in-a-store` | R5 |

### Back-references are real, and `only-model-is-public` depends on them

Verified against `dependency-cruiser@18.5.0` in this repo: `src/validate/matchers.mjs` calls
`replaceGroupPlaceholders(pRule.to.path, pGroups)`, so capture groups from `from.path` are substituted
into `to.path` **before** the regex compiles. `$1` is the first capture group.

```js
{
  name: "only-model-is-public",
  severity: "error",
  // $1 = role, $2 = this feature's own name
  from: { path: "src/features/(customer|rider)/([^/]+)/" },
  to:   { path: "src/features/$1/(?:(?!$2/)[^/]+)/(screens|widgets|ui|index)" },
}
```

`checkout/screens/X.tsx` importing `cart/widgets/CartLine` → `$2 = checkout`, the lookahead `(?!
checkout/)` lets `cart` through, `/(widgets)` matches → **violation**.
`cart/screens/CartScreen.tsx` importing `cart/widgets/CartLine` → `$2 = cart`, the lookahead `(?!
cart/)` rejects `cart` → **no match, allowed**.

### The rule set is not trusted until it has been seen to fail

Add these six fixtures and run `npm run deps:check`. Each must produce **exactly one** named violation.

| # | Fixture | Expect |
|---|---|---|
| 1 | `rider/trip/model/x.ts` → `../../../customer/cart/screens/CartScreen` | `no-rider-to-customer` |
| 2 | `customer/checkout/model/x.ts` → `../../cart/widgets/CartBar` | `only-model-is-public` |
| 3 | `customer/checkout/model/a.ts` → `../../cart/model/b.ts` → back to `../../checkout/model/a.ts` | `no-circular` |
| 4 | `customer/orders/screens/O.tsx` → `../../../../services/rpc/call.ts` (deep) | `rpc-entry-is-the-barrel-only` |
| 5 | `customer/cart/model/x.ts` → `../../../../lib/money.ts` | `no-second-money-module` |
| 6 | `shared/auth/x.ts` → `../../customer/checkout/model/x.ts` | `shared-imports-neither-zone` |

Commit the config and the fixtures together. A rule nobody has watched fail is not a rule.

---

## 5. The cart → checkout → orders chain

This is the dependency the whole design has to survive. Nothing in it is a cross-feature import except
one, and that one is a `model/` import.

| Edge | How | Verdict |
|---|---|---|
| `checkout` reads the live cart | `import { useCart } from '../cart/model'` | ✅ R3 |
| `checkout` quotes and places | `services/rpc/index.ts` → `orders.ts` | ✅ R4 |
| `orders` needs the id `checkout` produced | route **param** + a query key, never an import | ✅ |
| both need the status vocabulary | `domain/orders/status.ts` | ✅ L6 |
| both need the RPC DTO | `services/rpc/dto/orders.ts` | ✅ L3 |

`checkout` never imports `orders`. `orders` never imports `checkout`. **Features compose in `app/` and
share vocabulary in `domain/` + `services/`.**

---

## 6. Roles, session, and the RLS union

### Where the session lives

`services/auth/session.ts` — a TanStack Query (`['session']`), because a session **is** server state.
Not `state/session.ts`; a session in `state/` would violate R5.

### Where `useRole` gets its answer

One source, and the README gives no other:

```ts
// features/shared/auth/use-role.ts
const { data: rider } = useQuery({ queryKey: ['rider','profile',userId],
                                   queryFn:  () => rpc.rider.profile(),
                                   retry: false })
// NOT_A_RIDER  → customer only
// a row        → rider
```

`get_my_rider_profile_v1` is the only rider read in the schema (§7 of the database README), and
`NOT_A_RIDER` means "you are not a rider" — so it doubles as the role probe. There is **no
self-registration**: a rider who was never onboarded by `admin_upsert_rider_v1` is permanently
customer-only, and the rider tab must say "contact support", not "apply".

`app/_layout.tsx` **consumes** `useSession()` / `useRole()`. It does not compute them, and it holds no
business logic — that would put a gate in the one file that cannot be unit-tested.

### Query keys carry the user id — always

```ts
['customer','orders',userId,{ filters }]
['rider','offers',userId,{ lat, lng }]
['customer','addresses',userId]
```

A key without `userId` leaks the previous account's rows after a sign-out and sign-in on the same
device. A keyed cache is not a security boundary.

- **Role switch** → `queryClient.removeQueries()` — scoped, keeps the session.
- **Sign-out** → `queryClient.clear()` **and** reset `state/ui.ts`. Clear on sign-out; do not clear on
  role switch, because the session is a query and `removeQueries` can be scoped to it.

### The union trap

`orders_read` (§12 of the database README) resolves through `private.visible_order_ids(uid)`, which is
the union of **customer-owned ∪ vendor-staffed ∪ rider-assigned**. A user holding two roles sees
everything mixed in one `select`.

- **Customer history must filter `user_id = auth.uid()`** — in `services/rpc/reads.ts`, in the `where`,
  not in a `.filter()` on the client. Client-side filtering after the rows have arrived is a leak.
- **Rider screens must read through `delivery_assignments.rider_id`**, never a bare `select from orders`.
- The same applies to `order_items`, `sub_orders` and `order_status_history`, which resolve through
  `owned_or_assigned_order_ids` and widen further to vendor-staffed rows.

Get this wrong and a customer sees the orders they are only delivering, on their own history screen.

---

## 7. Errors — a global handler, and per-call overrides

`services/errors/behaviour.ts` maps a code to a default behaviour:

| Code | Default |
|---|---|
| `NOT_AUTHORIZED` | `sign-in` |
| `INVALID_*`, `*_INVALID`, `SIZE_*`, `OPTION_*` | `invalid-input` |
| `PRICE_CHANGED`, `QUOTE_EXPIRED`, `IDEMPOTENCY_KEY_TAKEN`, `INVALID_TRANSITION` | `conflict` |
| everything else | `business` |

**The global handler acts on authentication and nothing else.** `conflict` is not global, because
silence is correct for a retried read and wrong for a price.

Per-call overrides live in `services/errors/overrides.ts`, applied at the boundary:

| Call | Code | Default | What actually happens |
|---|---|---|---|
| `place_order_v1` | `PRICE_CHANGED` | `conflict` | **Re-quote, show the new total, wait for consent.** Never re-place silently. |
| `quote_order_v1` | any rejection (`rejections[]` data — `OUT_OF_STOCK` and `VOUCHER_*` are rejection codes, never raised) | `business` | **Re-quote and let the shopper choose.** Never drop a line for them. |
| `cancel_order_v1` | `NOT_AUTHORIZED` | `sign-in` | "not your order" — the session is fine, the row is not. |
| `claim_order_v1` | `NOT_AUTHORIZED` | `sign-in` | "cannot claim as another rider". |

`toBehaviour(code)` returns a **default**; the caller decides. A single global handler that silently
retries checkout is how a shopper is charged a price they never agreed to.

---

## 8. Zod at the boundary

`services/rpc/call.ts` validates every response. There are no Postgres enums — every status is `text` +
CHECK, so a wrong string fails at runtime — and several RPCs return raw `jsonb`. A DTO is a
compile-time claim; only a schema is a runtime one.

**Generate, don't invent.**

- RPCs documented in `specs-mobile/README.md` §15 → schemas written from
  `pg_get_function_result(oid)`, which is the documented contract.
- RPCs never executed against the live database (the README names `get_vendor_feed_v1`,
  `cancel_order_v1`, `search_catalog_v1`) → **`z.unknown()`** with a TODO, until someone has actually
  called them. A guess here is worse than an `unknown`.

**Three rules for every schema:**

1. **Money fails closed.** `fee`, `subtotal`, `total`, `discount`, `rider_pay_*`, `currency` are
   `z.number().int().nonnegative()`. A parse failure **throws** and never renders `0`.
2. **Unknown keys pass.** `.passthrough()` everywhere, so a server-side field addition does not crash
   the client. A new field is fine; a new *shape* for a known field is not.
3. **Failures surface.** `call.ts` records the first mismatch per RPC so they are fixed in one pass,
   not one crash at a time.

`zod` is already a dependency. `QuoteResult`'s `fee_breakdown`, `per_vendor`, `limits`, `rejections`
and `warnings` are typed `unknown` **on purpose** in `specs-mobile/README.md` §15 — decode them once,
here, at the boundary. Do not loosen them to `any` and do not decode them twice.

---

## 9. Naming — the things that got renamed

| Do not | Do | Why |
|---|---|---|
| feature `api/` | feature `model/` | `api/` collided with `services/rpc/api.ts`. One word, one meaning. |
| `services/rpc/api.ts` | per-domain files + `index.ts` | 40+ RPCs in one file is a god file. |
| `state/session.ts` | `services/auth/session.ts` | A session is server state (R5). |
| `features/shared/feedback/` | `ui/feedback/` | Pure presentation belongs in `ui/`. |
| `features/shared/address/` | `features/customer/address/` | Riders read `address_snapshot` off the order. Only customers write an address. |
| `domain/time/format-when.ts` | `domain/time/index.ts` re-export | Two time formatters is how screens disagree. Same for money. |
| `domain/i18n/pickLang` | `src/i18n/pickLang.ts` | One home. `pickLang(value, lang)` takes the language as an argument, so `domain/` never imports `i18n/`. |
| `state/orders.ts` | TanStack Query | R5. |

`features/shared/` holds exactly two things: **auth** and **device**. If a third appears, it is either
role-specific (move it into the role) or presentation (move it into `ui/`).

This is a **role-sliced, feature-based, eight-layer** architecture. It is not Feature-Sliced Design —
FSD treats `widgets` as a layer, and `widgets` here is a folder inside a feature. Reading FSD docs will
give conflicting advice; this file is the authority.

---

## 10. Commands

| Command | What it is |
|---|---|
| `npm run deps:check` | dependency-cruiser against `.dependency-cruiser.cjs` — the architecture gate |
| `npm run typecheck` | `tsc --noEmit` — emits nothing, declarations live in `packages/shared` |
| `npm test` | vitest |
| `npm run align` | `expo install --check` — catches a hand-bumped Expo package |
| `npm run verify` (root) | everything, including `check:status-types` |

`npm run verify` needs `SUPABASE_DB_URL` in `.env`, because `check-policies.mjs` exits **2** — meaning
"unchecked", never "clean" — when it cannot reach the database.

---

## 11. Before the first real commit

The tree is stubbed with `.gitkeep`. In order:

1. Write the six fixtures in §4 and run `npm run deps:check`. Watch each one fail for the right reason.
2. Create `services/supabase/client.ts` and delete the `services/supabase/.gitkeep`.
3. Create `services/rpc/index.ts`, `call.ts`, and `dto/orders.ts`. Delete those `.gitkeep`s.
4. Build one vertical slice end to end — `customer/discovery` → `cart` → `checkout` → `orders` —
   before adding the rider slice. The slice proves the layers hold; six empty features prove nothing.

Every `.gitkeep` you leave behind after its first real file is a placeholder, and `no-orphans` is the
rule that is supposed to catch it.
