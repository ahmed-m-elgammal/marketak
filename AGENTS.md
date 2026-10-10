# Marketak — Delivery Platform

Delivery platform for one city at a time, lunch service first. Arabic and English.
Brand: **Marketak · ماركتك**

Rules only. Everything else lives in the two contract files below.

---

## READ THIS FIRST

There is a **live database** and a **documented contract for it**. There is **no application code yet**.
The database is real and applied; `apps/mobile/` is a stubbed tree.

### Reading order

| # | File | What it gives you |
|---|---|---|
| 1 | `AGENTS.md` | This file. The rules. |
| 2 | `specs-mobile/README.md` | **The database contract.** Tables, RLS, every RPC signature and error code, the quote object, index and trigger catalogue. Written from `pg_proc` / `pg_policies` / `pg_constraint` — not from a spec. |
| 3 | `apps/mobile/README.md` | **The mobile architecture contract.** The eight layers, the seven rules, the dependency-cruiser enforcement, the folder tree. |
| 4 | `CHANGELOG.md` | What was actually delivered, and the known gaps. |

`.specify/memory/constitution.md` still exists and holds the 33 non-negotiable rules on *what* the
system is. This file governs *how* work gets done; it does not restate them.

`specs/001-platform-foundation/decisions.md` still exists but is **no longer the source of truth** — the
ADRs were retired. `specs/001-platform-foundation/` retains only `decisions.md`,
`e2e-fixture.json` and `free-tier-plan.md`. Where an ADR and the live database disagree, **the database
is right**.

`architecture-spec-supabase-cloudflare-firebase.md` is the original v1 spec, superseded. It is kept only
for its free-tier arithmetic. Do not build from it.

### The five things that will break the build if you get them wrong

1. **A checkout is one `orders` row plus N `sub_orders` rows.** Never one order with a nullable
   `vendor_id`. This is the whole reason the schema exists.
2. **The platform holds no customer money.** No customer wallet, no top-up flow. The customer pays
   the rider directly. Do not "improve" this by adding a wallet.
3. **Never trust the client for money.** `place_order_v1` re-prices inside its transaction and aborts
   with `PRICE_CHANGED` if anything moved. Do not cache a price and charge it.
4. **All money constants are configuration.** Delivery base fee, per-vendor multiplier, free radius,
   per-km fee, vendor cap, rider pay, cash limit — all rows in `public.settings`. None of them may
   appear as a literal in app code or in a SQL function body.
5. **Google and Apple only.** No email, no password, no phone OTP. A user without
   `profile_completed_at` can browse but cannot order.

---

## Current state

- **Database: live and applied.** Project `erxxsebcqqcpkipzcdhg` (`marketak`, `eu-central-1`,
  Postgres 17.11). 62 tables and partitions + 1 view · 150 functions across `public` and `private` ·
  72 triggers · 115 RLS policies · 252 index entries in `pg_indexes` · 176 CHECK constraints ·
  107 foreign keys. RLS is on every table and partition.
- **Migration history has a hole.** Six migrations were applied to the live project and never
  committed: `038i_claim_currency`, `fix_handle_new_user_phone_column`, `stock_decrement`,
  `admin_upsert_rider_idempotent`, `dev_seed_second_run`, `dev_seed_vendor_areas`. They cannot be
  reconstructed honestly. `supabase/migrations/045_parity_with_live.sql` instead pins the current
  definition of the three functions they touched, so a fresh build matches production. **Do not write
  a fake `043_*.sql`** — that would put a decision in the record that nobody made.
- **Database size: 20 MB**, down from 81 MB. The 59 MB was `menu_items` **index** bloat from ~586k
  inserts and 67k rows later deleted; `VACUUM` reclaimed the heap but never the indexes. Mock data was
  wiped on 2026-10-10: 13 seeded accounts, 4 riders, 6 vendors, all menus, orders, carts and addresses.
  Config (`settings`, `cities`, `areas`, `delivery_zones`, `delivery_fee_tiers`,
  `notification_templates`, `commission_rules`, `rider_pay_rules`) was kept. One real auth user kept.
- **Mobile tree: foundation landed.** `app/_layout.tsx`, `src/theme/` (tokens, Tamagui config, fonts, design rules) and `src/services/` (Supabase client, typed RPC boundary) are real. `features/`, the route groups and the remaining `src/` slots are still `.gitkeep`-stubbed.
- **`npm run deps:check` is green.** It had never run: `enhancedResolveOptions` used `exports: true`,
  which is not a valid key in dependency-cruiser 18 — the config was rejected outright. Fixed to
  `exportsFields: ["exports"]`.
- **`npm test` runs 63 tests in 7 files** (`packages/shared` money plus the
  `apps/mobile` services boundary suites). Six more test files
  exist under `functions/outbox-dispatcher/src/tests/` and **do not run** — the root
  `vitest.config.ts` includes only `packages/*` and `apps/*`.
- **Application code: foundation only.** No screens, no features. `apps/admin-web/`, `apps/vendor-web/` and
  `packages/ui/` do not exist.
- **Styling is settled: Tamagui (themed kit) + NativeWind (utility classes) + `expo-image` (food photography), fitted to `DESIGN.md`.** `src/theme/` holds the Tamagui theme + tailwind config from one token source; `src/ui/` wraps Tamagui, with telemetry-only components (slide rail, signature, square loader, scanner) hand-built per DESIGN §9. Expo SDK 57+ / RN 0.86 is the floor.
- **Do not report the database as verified by a test suite.** Hand-run SQL verification against the live project is real; that is not the same thing as `npm run verify`. (`CHANGELOG.md` was removed; the living record lives wherever `tasks.mf` §5 Q3 designates.)

---

## Engineering rules

Non-negotiable. These govern *how* work gets done.

### The three-phase workflow

No phase is skipped, and no phase is entered early.

```
1. PLAN & GROUNDING     Understand the task before writing code.
                        Load only the contract sections the task touches.
2. IMPLEMENTATION       Production-ready code, built in dependency order.
                        Matches the contract. No placeholders.
3. VERIFY & SYNC        Prove correctness, then leave zero documentation drift.
```

### Standing rules

| # | Rule | Meaning here |
|---|---|---|
| 1 | **ZERO RAW `any`** | `"strict": true`. Explicit DTOs and interfaces. Generated Supabase types are `any` at the edge — wrap them, do not cast through them |
| 2 | **ZERO INLINE STYLING** | No hardcoded colours or spacing in a component. All values come from the token module (`src/theme/`) |
| 3 | **ZERO PLACEHOLDER SHORTCUTS** | Real production code only. No mock fallbacks, no empty `TODO`, no commented-out code, no deleted failing tests |
| 4 | **NEVER WEAKEN TESTS** | No `.skip`, `.only`, `.xit`, no tautological assertions, no hollowed-out suites. A behaviour change ships with edge-case **and** failure-path tests |
| 5 | **DECOMPOSE & REUSE** | No screen over 300–400 lines. No duplicated logic. Business and state logic isolated from presentation. No speculative abstraction |
| 6 | **CONTRACT SYNCHRONIZATION** | A change to the database contract (`specs-mobile/README.md`) or the mobile architecture (`apps/mobile/README.md`) ships **in the same commit** as the code. Never "docs follow" |
| 7 | **LEAN DOCUMENTATION** | Dense and useful. No verbose prose, no speculative filler, no restating the obvious |
| 8 | **NO TRIVIAL COMMENTS** | Comment only complex algorithms, subtle business invariants, and edge cases that look wrong until you know why |
| 9 | **ZERO ASSUMPTIONS** | When a requirement is ambiguous, stop and ask a structured question with recommended options. Do not pick silently |
| 10 | **NO DEAD CODE** | Study the impact first, then leave nothing unused behind. Unused exports, obsolete imports and commented-out blocks are deleted, not commented |
| 11 | **REUSE BEFORE CREATE** | Do not create a new folder, module, type, helper or table until you have searched for something that already does the job. A second implementation of money formatting, a DTO shape, an RPC wrapper or a shared component is a defect, not a convenience |

### Rule 11 in practice

Duplication is the most expensive mistake in this repo and the least visible. Two money formatters
produce `29.50` on one screen and `٢٩٫٥٠` on another. Two DTOs for one RPC drift, and the drift is a
silent runtime `null`. Two Supabase clients means two token refreshers racing, and the loser's write
wins.

Before adding anything, run the search:

```bash
git grep -n "formatMoney\|Piastres" -- packages/shared/src   # helper exists?
git grep -n "place_order_v1" -- apps/mobile/src              # DTO exists?
git grep -rn "PriceText\|OrderCard" -- apps/mobile/src       # component exists?
```

| You want to add | Search first | If it exists |
|---|---|---|
| money / date / rate formatting | `@marketak/shared` — `formatMoney`, `formatCount`, `formatRateBps`, `formatWhen`, `formatRelativeInZone` | **Never** add `lib/money`. Import from `@marketak/shared` |
| a DB column shape | `apps/mobile/src/services/rpc/dto/`, then `pg_proc` | Extend the existing DTO. One shape per RPC, one place |
| an RPC call | `apps/mobile/src/services/rpc/index.ts` | Add a wrapper there. Never `supabase.rpc()` elsewhere |
| a screen or component | `apps/mobile/src/ui/`, then Tamagui | Theme via Tamagui tokens + NativeWind utilities; rebuild only what no kit provides (rail, signature, loader, scanner per DESIGN §9) |
| a folder | the tree in `apps/mobile/README.md` | The map is authoritative. A new folder needs a reason in the commit message |
| a config value | `apps/mobile/src/config/env.ts` | Add the variable there, validated at boot |

**Two rules about folders, easy to get wrong in both directions:**

1. **A folder is created by the file that needs it.** Do not pre-create `screens/ model/ widgets/`
   for a slice that does not exist yet.
2. **A planned slot may exist and be committed** holding a `.gitkeep` — that is what the 57 stubbed
   folders in `apps/mobile` are. `.gitkeep` is exempt from the `no-orphans` depcruise rule for that
   reason. **Delete the `.gitkeep` the moment the first real file lands** — a `.gitkeep` sitting next
   to source is the placeholder the rule exists to catch.

The architecture lives in `apps/mobile/README.md` and in `.dependency-cruiser.cjs`, not in a tree of
empty directories. If the map and the tree disagree, the map is right until proven otherwise and the
tree is the bug.

---

### Checklist A — adding a feature or sub-feature

| # | Step | Done when |
|---|---|---|
| A1 | **Grounding.** Load only the contract sections the task touches | Named the sections at risk |
| A2 | **Invariant check.** Verify against the five break-the-build rules, the RLS matrix and the status vocabularies | No rule is violated. If one must be broken, that is a contract change, not a comment |
| A3 | **Backend.** Strictly typed DTOs, validated at the boundary (Zod on the app side; `search_path`-pinned, `security definer` Postgres RPC on the server). Any multi-statement mutation is **one ACID transaction** | One `events` row written in the same transaction as the state change |
| A4 | **UI.** Design tokens only, responsive, explicit loading and error states | No inline colour or spacing. Empty, loading and failure states all designed, not just the happy path |
| A5 | **Automated verification.** `npm run typecheck`, `npm run lint`, `npm test`, `npm run deps:check` | All green, no regression. **Never edit the test to make it pass** |
| A6 | **Living docs sync.** `CHANGELOG.md` records the deliverable | Zero drift. If the behaviour changed, the contract changed too |

### Checklist B — fixing a bug

| # | Step | Done when |
|---|---|---|
| B1 | **Root cause.** Reproduce with an automated test **before** touching code | The test fails for the right reason |
| B2 | **Contract check.** Confirm intended behaviour in the contract files; verify no invariant is violated | You know whether this is a code bug or a contract bug |
| B3 | **Surgical fix.** Targeted change, no broad rewrite | The diff is the smallest one that fixes the cause |
| B4 | **Adherence.** Zero raw `any`, zero inline styles, zero trivial comments | Lint and typecheck agree |
| B5 | **Regression.** Full suite green | Including the new test, which now passes for the right reason |
| B6 | **Living docs sync.** `CHANGELOG.md` under `### Fixed` | Zero drift |
| B7 | **Commit protocol** | See below |

### Checklist C — refactoring or modernisation

| # | Step | Done when |
|---|---|---|
| C1 | **Architectural alignment.** Aligns with `apps/mobile/README.md` and preserves established patterns | No pattern invented for one call site |
| C2 | **Interface preservation.** Public signatures, RPC contracts, component props unchanged | A caller cannot tell it was refactored |
| C3 | **Token extraction.** Hardcoded values replaced with design tokens | Grep for the old literal returns nothing |
| C4 | **Dead code cleanup.** Unused methods, obsolete imports, commented-out code — deleted completely | Not commented out. Deleted |
| C5 | **Static analysis.** `npm run typecheck` exits 0, `npm run lint` reports 0 issues, `npm test` passes, `npm run deps:check` clean | Coverage floors hold |
| C6 | **Living docs sync.** `CHANGELOG.md` under `### Changed` | Zero drift |
| C7 | **Commit protocol** | See below |

---

### Commit protocol

1. `npm run verify` green — typecheck, lint, test, test-integrity, secrets, hardcoded-colours,
   policies, status-types.
2. Stage deliberately. `git add -A` is **forbidden** in this repo; it once committed an Apple
   App Store Connect private key from an `appstore/` directory. Stage named paths.
3. Never commit a secret. `*.p8 *.pem *.key *.cer *.p12 *.mobileprovision .env*` are ignored, and
   the ignore list is not proof — check `git status` before committing.
4. One concern per commit.
5. Message states **why**, not just what.
6. If a contract file changed, it is in the same commit as the code. Never "docs follow".

### Verification commands

These exist and run. A red one blocks the checklist named.

| Command | Blocks |
|---|---|
| `npm run typecheck` | A5, B4, C5 |
| `npm run lint` | A5, B4, C5 |
| `npm test` | A5, B5, C5 |
| `npm run deps:check` (from `apps/mobile`) | A5, C5 — the architecture gate |
| `npm run verify` | Commit protocol step 1 |
| `node scripts/check-test-integrity.mjs` | Rule 4 |

`npm run verify` requires `SUPABASE_DB_URL` in `.env`. `scripts/check-policies.mjs` exits **2** when it
cannot reach the database, which means "unchecked", never "clean" — and `verify` runs it.

### Stack substitutions

This project deliberately does not use the tools a generic checklist would name.

| Generic | This repo uses | Why |
|---|---|---|
| `class-validator` | **Zod** at the app boundary | No server framework — the server is Postgres. Zod is already a dependency |
| Prisma / Drizzle types | `generate_typescript_types` via Supabase MCP, wrapped in hand-written DTOs | No ORM. Business logic is RPC |
| ACID in a service layer | ACID **inside the Postgres function** | There is no service layer. The transaction *is* the function |
| Tailwind / NativeWind | **Tamagui + NativeWind + `expo-image`** | Utility-first styling, themed kit, cached imagery. One token source feeds both configs (boundary in `tasks.mf` F-01/F-06); compiler + versions align-gated |

---

## Repository layout

| Path | Holds |
|---|---|
| `apps/mobile/` | The one React Native app — customer + rider, role-switched. `README.md` is the architecture contract |
| `packages/shared/` | Shared types, error codes, money helpers. The only place a formatter or DTO shape is defined once |
| `functions/outbox-dispatcher/` | The Cloudflare Worker that drains the `events` outbox to FCM/APNs |
| `supabase/migrations/` | Numbered `.sql`. `045_parity_with_live.sql` pins the functions the six uncommitted migrations touched |
| `supabase/functions/` | Edge Functions. **Reserved for a future payment gateway** — not used in v1 |
| `scripts/` | `check-test-integrity.mjs`, `check-policies.mjs`, `check-no-secrets.mjs`, `check-status-types.mjs`, `check-no-hardcoded-colors.mjs` |
| `specs-mobile/` | The database contract |
| `.agents/skills/` | Project-local agent skills. Loaded via `skills.paths` in `opencode.json` — opencode does not auto-scan this directory |

`apps/admin-web/`, `apps/vendor-web/` and `packages/ui/` do not exist yet.

### Skills

Loading a 20 KB skill costs context. Load only what the task touches.

| Skill | Load when |
|---|---|
| `supabase-postgres-best-practices` | Any SQL, migration, RLS policy or index |
| `backend-patterns` | Writing RPCs, transactions, idempotency |
| `react-native-patterns` | Building the mobile app |
| `react-testing` | Writing component tests |
| `accessibility` | Any UI work — A4 requires it |
| `design-system` | Token extraction. Its CSS/Tailwind sections do not apply to React Native |
| `git-workflow`, `github-ops` | Committing, branching, opening PRs |
| `benchmark` | Before claiming a latency target is met |

**Do not load:** `firebase-auth-basics`, `firebase-firestore`, `firebase-data-connect`,
`firestore-rules-creation`, `firebase-security-rules-auditor`, `firebase-hosting-basics`,
`firebase-app-hosting-basics`, `firebase-remote-config-basics`, `firebase-ai-logic-basics`,
`extension-to-functions-codebase`, `nextjs-on-cloudflare`, `sandbox-*`, `basin`, `k2`,
`cloudflare-one*`, `turnstile-spin`, `cloudflare-email-service`. None are used in v1.
`firebase-auth-basics` in particular teaches the identity system the constitution forbids.

---

## When you are asked to do something not covered here

Say so. Do not invent a table, a fee rule or a payment path. The two contract files exist so that
unresolved decisions stay visible instead of becoming silent assumptions.
