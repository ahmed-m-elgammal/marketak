# Marketak — Delivery Platform

Delivery platform for one city at a time, lunch service first. Arabic and English.
Brand: **Marketak · ماركتك**

---

## READ THIS FIRST

This repo contains a **complete database and a specification**. There is no application code yet.
`supabase/migrations/` exists and is applied; `apps/`, `functions/` and `package.json` do not.

If you were asked to build something, read the spec before writing a line of code.

### Reading order

| # | File | What it gives you | Read it when |
|---|---|---|---|
| 1 | `.specify/memory/constitution.md` | 33 non-negotiable rules | **Always. First. Never skip.** |
| 2 | `specs/001-platform-foundation/spec.md` | Business model, actors, order state machine, fee formula, revenue phasing, retention, risks | Planning or product questions |
| 3 | `specs/001-platform-foundation/decisions.md` | 16 ADRs — what was decided, what was rejected, why | Before changing anything structural |
| 4 | `specs/001-platform-foundation/data-model.md` | Full Postgres schema, DDL, RLS matrix, 22 migrations | Writing migrations or RPCs |
| 5 | `specs/001-platform-foundation/contracts.md` | Every RPC signature, error code, event type, push template | Writing an app or a Worker |
| 6 | `specs/001-platform-foundation/plan.md` | Architecture, order-placement sequence, payment-at-delivery flow, build order | Implementing anything |
| 7 | `specs/001-platform-foundation/free-tier-plan.md` | Byte budgets, egress budgets, the $25 upgrade trigger | Anything touching storage, images, polling |
| 8 | `specs/001-platform-foundation/tasks.md` | 139 ordered tasks in 8 phases | Picking up work |
| 9 | `specs/001-platform-foundation/open-questions.md` | Undecided items | Before assuming anything |
| 10 | `ENVIRONMENT.md` | Accounts, regions, CLI versions, MCP setup, known gotchas | Running a command |
| 11 | `FEATURES.md` | Every feature and its real state. All ⬜ | Before claiming anything works |
| 12 | `CHANGELOG.md` | What has actually been delivered, and the known gaps | Reporting status |
| 13 | `specs/001-platform-foundation/001-020-integrity-notes.md` | Live-database results of the adversarial suite: isolation probes, the policy texts they rest on, and the retractions | Before trusting any claim about RLS, or before "fixing" a probe that fails |

### Verification is not a test suite

There is no `npm test`. Every database claim in this repo was produced by **hand-run SQL against the
live project**, and the notes files record what was actually executed. Two consequences:

- A green probe is evidence about the **database contract**, not about shipped software. No app code
  exists.
- **A failing probe is usually a wrong expectation, not a bug.** In the 001–020 suite every failure was
  mine and the schema was right each time. Read `pg_policies` before changing anything.

### Do not read `architecture-spec-supabase-cloudflare-firebase.md`

That is the **original v1 architecture spec, now superseded.** It contradicts the current spec on
points 2, 3, 5 and 7 of `decisions.md`. It is kept only for its free-tier arithmetic, which the
current plan supersedes with better numbers. **Where they disagree, the current spec wins.**

### The five things that will break the build if you get them wrong

1. **A checkout is one `orders` row plus N `sub_orders` rows.** Never one order with a nullable
   `vendor_id`. This is the whole reason the schema exists.
2. **The platform holds no customer money.** No customer wallet, no top-up flow. The customer pays
   the rider directly. Do not "improve" this by adding a wallet.
3. **Never trust the client for money.** The SQLite cache and R2 snapshots are display-only.
   `place_order_v1` re-prices inside the transaction and aborts with `PRICE_CHANGED` if anything
   moved. Do not cache a price and charge it.
4. **All money constants are configuration.** Delivery base fee, per-vendor multiplier, free radius,
   per-km fee, vendor cap, rider pay, cash limit. None of them may appear as a literal in app code
   or in a SQL function body.
5. **Google and Apple only.** No email, no password, no phone OTP. A user without
   `profile_completed_at` can browse but cannot order.

### Current state

- **Specification: complete but unreviewed by a human.** All ADRs are `proposed`, not `accepted`.
  Nothing here is approved until you have read it.
- Infrastructure: Supabase / Cloudflare / Firebase accounts created and MCP servers connected.
- **Database: migrations `001`–`014a` written and applied** to the live project. 62 tables and
  partitions, 229 indexes, 0 unindexed foreign keys, RLS on every table and partition.
  See `CHANGELOG.md` for the per-migration record.
- **Application code: none.** No `apps/`, no `package.json`. `functions/` and `apps/` are still to
  be scaffolded (tasks.md T0.1).
- **`npm run typecheck`, `npm run lint`, `npm test` and `npm run verify` do not exist**, so no
  engineering checklist below can be signed off. Creating them is task **T0.1c**.
- **Database behaviour has been verified by direct SQL against the live project.** The SQL
  verification in `CHANGELOG.md` is real — every claim there was executed. That is *not* a substitute
  for `npm run verify`, which does not exist yet and covers application code that does not exist
  yet. Do not report the database as verified by a test suite.
- **All features are ⬜.** See `FEATURES.md`.

---

## Engineering rules

Non-negotiable. These sit alongside `constitution.md`, which governs *what* the system is; these
govern *how* work gets done here.

### The three-phase workflow

**No phase is skipped, and no phase is entered early.**

```
1. PLAN & GROUNDING     Understand the task before writing code.
                         Load only the 1–2 spec files the task touches.
                         Name the ADRs and invariants at risk.
2. IMPLEMENTATION        Production-ready code, built in dependency order.
                         Matches the spec. No placeholders.
3. VERIFY & SYNC         Prove correctness, then leave zero documentation drift.
```

### Standing rules

| # | Rule | Meaning here |
|---|---|---|
| 1 | **ZERO RAW `any`** | `"strict": true`. Explicit DTOs and interfaces. Exception: generated Supabase types are `any` at the edge — wrap them, do not cast through them |
| 2 | **ZERO INLINE STYLING** | No hardcoded colors or spacing in a component. All values come from the token module (`src/theme/`). See the open question on NativeWind vs StyleSheet |
| 3 | **ZERO PLACEHOLDER SHORTCUTS** | Real production code only. No mock fallbacks, no empty `TODO`, no commented-out code, no deleted failing tests |
| 4 | **NEVER WEAKEN TESTS** | No `.skip`, `.only`, `.xit`, no tautological assertions, no hollowed-out suites. A behaviour change ships with edge-case **and** failure-path tests |
| 5 | **DECOMPOSE & REUSE** | No screen over 300–400 lines. No duplicated logic. Business and state logic isolated from presentation. No speculative abstraction |
| 6 | **ADR SYNCHRONIZATION** | A change to a dependency, state machine, storage model or ingress requires a new or amended entry in `decisions.md` **in the same commit** |
| 7 | **LEAN DOCUMENTATION** | Dense and useful. No verbose prose, no speculative filler, no restating the obvious |
| 8 | **NO TRIVIAL COMMENTS** | Comment only complex algorithms, subtle business invariants, and edge cases that look wrong until you know why |
| 9 | **ZERO ASSUMPTIONS** | When a requirement is ambiguous, stop and ask a structured question with recommended options. Do not pick silently |
| 10 | **NO DEAD CODE** | Any change: study the impact first, then leave nothing unused behind. Unused exports, obsolete imports and commented-out blocks are deleted, not commented |

### Checklist A — adding a feature or sub-feature

| # | Step | Done when |
|---|---|---|
| A1 | **Grounding.** Load only the required 1–2 spec files | Named the sections and the ADRs at risk |
| A2 | **Invariant check.** Verify against `constitution.md`, ADRs, state machines, business rules | No rule is violated. If one must be broken, that is an ADR amendment, not a comment |
| A3 | **Backend.** Strictly typed DTOs, validated at the boundary (Zod on the app side; `search_path`-pinned, `security definer` Postgres RPC on the server). Any multi-statement mutation is **one ACID transaction**. Standard response envelope | One `events` row written in the same transaction as the state change |
| A4 | **UI.** Design tokens only, responsive, explicit loading and error states | No inline color or spacing. Empty, loading and failure states all designed, not just the happy path |
| A5 | **Automated verification.** `npm run typecheck`, `npm run lint`, `npm test` | All green, no regression. **Never edit the test to make it pass** |
| A6 | **Living docs sync.** Add a line to `FEATURES.md`, record the deliverable in `CHANGELOG.md` | Zero drift. If the behaviour changed, the spec changed too |

### Checklist B — fixing a bug

| # | Step | Done when |
|---|---|---|
| B1 | **Root cause.** Reproduce with an automated test **before** touching code | The test fails for the right reason |
| B2 | **Spec check.** Confirm intended behaviour in `spec.md` / `tasks.md`; verify no invariant is violated | You know whether this is a code bug or a spec bug. If the spec is wrong, that is an ADR amendment |
| B3 | **Surgical fix.** Targeted change, no broad rewrite | The diff is the smallest one that fixes the cause |
| B4 | **Adherence.** Zero raw `any`, zero inline styles, zero trivial comments | Lint and typecheck agree |
| B5 | **Regression.** Full suite green | Including the new test, which now passes for the right reason |
| B6 | **Living docs sync.** `CHANGELOG.md` under `### Fixed`; `FEATURES.md` if behaviour changed | Zero drift |
| B7 | **Commit protocol** | See below |

### Checklist C — refactoring or modernisation

| # | Step | Done when |
|---|---|---|
| C1 | **Architectural alignment.** Aligns with the ADRs and preserves established patterns | No pattern invented for one call site |
| C2 | **Interface preservation.** Public signatures, RPC contracts, component props unchanged | A caller cannot tell it was refactored |
| C3 | **Token extraction.** Hardcoded values replaced with design tokens | Grep for the old literal returns nothing |
| C4 | **Dead code cleanup.** Unused methods, obsolete imports, commented-out code — deleted completely | Not commented out. Deleted |
| C5 | **Static analysis.** `npm run typecheck` exits 0, `npm run lint` reports 0 issues, `npm test` passes 100% | Coverage floors hold |
| C6 | **Living docs sync.** `CHANGELOG.md` under `### Changed` | Zero drift |
| C7 | **Commit protocol** | See below |

### Commit protocol

1. `npm run verify` green — typecheck, lint, test, test-integrity.
2. Stage deliberately. `git add -A` is **forbidden** in this repo; it once committed an Apple
   App Store Connect private key from an `appstore/` directory. Stage named paths.
3. Never commit a secret. `*.p8 *.pem *.key *.cer *.p12 *.mobileprovision .env*` are ignored, and
   the ignore list is not proof — check `git status` before committing.
4. One concern per commit.
5. Message states **why**, not just what.
6. If an ADR or spec changed, it is in the same commit as the code. Never "docs follow".

### Verification commands

These **do not exist yet.** They are Phase 0 tasks (T0.1c). Until they exist, no checklist can be
signed off, and an agent must say so rather than claiming verification passed.

| Command | Blocks |
|---|---|
| `npm run typecheck` | A5, B4, C5 |
| `npm run lint` | A5, B4, C5 |
| `npm test` | A5, B5, C5 |
| `npm run verify` | Commit protocol step 1 |
| `node scripts/check-test-integrity.mjs` | Rule 4 |

### Stack substitutions

Your source checklist named tools this project does not use. Mapped deliberately:

| You wrote | This repo uses | Why |
|---|---|---|
| `class-validator` | **Zod** at the app boundary | `class-validator` is a NestJS decorator library. No server framework here — the server is Postgres |
| Prisma types | **`generate_typescript_types`** from Supabase MCP, wrapped in hand-written DTO interfaces | No ORM. Business logic is RPC |
| ACID in a service layer | ACID inside the **Postgres function** | There is no service layer. The transaction *is* the function |
| Tailwind / NativeWind / `AppColors` | **`StyleSheet` + a `src/theme/` token module** | Settled in open questions 3.9. No Tailwind, no Babel step. The token module is what satisfies rule 2 |
| `BRD` / `TID` | **`spec.md`** / **`tasks.md`** | Same job, existing files |
| `npm run …` | Same, but not yet created | T0.1c |

---

## Repository layout

| Path | Holds |
|---|---|
| `apps/mobile/` | The one React Native app — customer + rider, role-switched |
| `apps/admin-web/` | Admin dashboard, Cloudflare Pages, static |
| `apps/vendor-web/` | Vendor dashboard, Cloudflare Pages, static |
| `packages/shared/` | Shared types, error codes, money helpers. The only place a DTO is defined once |
| `packages/ui/` | Design tokens and shared components |
| `supabase/migrations/` | Numbered `.sql`, ordered by `data-model.md` §15.2 |
| `supabase/functions/` | Edge Functions. **Reserved for a future payment gateway** — not used in v1 |
| `functions/` | Cloudflare Workers: outbox dispatcher, upload signer, snapshot builder, file access, export jobs |
| `scripts/` | `check-test-integrity.mjs`, `check-policies.mjs`, other CI guards |
| `.agents/skills/` | Project-local agent skills. **Loaded via `skills.paths` in `opencode.json`** — opencode does not auto-scan this directory |

None of these exist yet except `.agents/skills/`, `opencode.json`, `supabase/migrations/` and
`specs/`. `tasks.md` T0.1 scaffolds the rest.

### Which skills to load, and when

Loading a 20 KB skill costs context. Load only what the task touches — this is rule A1 applied to
skills rather than to spec files.

| Skill | Load when |
|---|---|
| `supabase-postgres-best-practices` | Writing any SQL, migration, RLS policy or index. **Read before T0.1a** |
| `database-migrations` | T0.1a and every migration after. Its Prisma/Drizzle/Django/Go sections do not apply here |
| `architecture-decision-records` | Before changing a dependency, state machine, storage model or ingress |
| `backend-patterns` | Writing RPCs, transactions, idempotency |
| `react-native-patterns` | Building the mobile app |
| `react-testing` | Writing component tests |
| `accessibility` | Any UI work. Checklist A4 requires it |
| `design-system` | Token extraction and the 10-dimension visual audit. Its CSS/Tailwind sections do **not** apply to React Native |
| `git-workflow`, `github-ops` | Committing, branching, opening PRs |
| `benchmark` | Before claiming a latency target is met |
| `dashboard-builder` | The admin console, later |

**Do not load:** `firebase-auth-basics`, `firebase-firestore`, `firebase-data-connect`,
`firestore-rules-creation`, `firebase-security-rules-auditor`, `firebase-hosting-basics`,
`firebase-app-hosting-basics`, `firebase-remote-config-basics`, `firebase-ai-logic-basics`,
`extension-to-functions-codebase`, `nextjs-on-cloudflare`, `sandbox-*`, `basin`, `k2`,
`cloudflare-one*`, `turnstile-spin`, `cloudflare-email-service`. All are excluded by ADR and
constitution. `firebase-auth-basics` in particular teaches the identity system the constitution
forbids.

---

## When you are asked to do something not covered here

Say so. Do not invent a table, a fee rule or a payment path. `open-questions.md` exists so that
unresolved decisions stay visible instead of becoming silent assumptions — the previous draft of
this spec had forty invented tables that nobody had approved.