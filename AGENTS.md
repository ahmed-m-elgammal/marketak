# Markatek — Delivery Platform

Delivery platform for one city at a time, lunch service first. Arabic and English.
Brand: **Markatek · ماركتك**

---

## READ THIS FIRST

This repo currently contains **specification only**. There is no application code yet.
No `apps/`, no `supabase/migrations/`, no `wrangler.toml`, no `package.json`.

If you were asked to build something, read the spec before writing a line of code.

### Reading order

| # | File | What it gives you | Read it when |
|---|---|---|---|
| 1 | `.specify/memory/constitution.md` | 33 non-negotiable rules | **Always. First. Never skip.** |
| 2 | `specs/001-platform-foundation/spec.md` | Business model, actors, order state machine, fee formula, revenue phasing, retention, risks | Planning or product questions |
| 3 | `specs/001-platform-foundation/decisions.md` | 15 ADRs — what was decided, what was rejected, why | Before changing anything structural |
| 4 | `specs/001-platform-foundation/data-model.md` | Full Postgres schema, DDL, RLS matrix, 22 migrations | Writing migrations or RPCs |
| 5 | `specs/001-platform-foundation/contracts.md` | Every RPC signature, error code, event type, push template | Writing an app or a Worker |
| 6 | `specs/001-platform-foundation/plan.md` | Architecture, order-placement sequence, payment-at-delivery flow, build order | Implementing anything |
| 7 | `specs/001-platform-foundation/free-tier-plan.md` | Byte budgets, egress budgets, the $25 upgrade trigger | Anything touching storage, images, polling |
| 8 | `specs/001-platform-foundation/tasks.md` | 132 ordered tasks in 8 phases | Picking up work |
| 9 | `specs/001-platform-foundation/open-questions.md` | Undecided items | Before assuming anything |
| 10 | `ENVIRONMENT.md` | Accounts, regions, CLI versions, MCP setup, known gotchas | Running a command |

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

- Specification: complete, unreviewed by a human.
- Infrastructure: Supabase / Cloudflare / Firebase accounts created and MCP servers connected.
- **Supabase project: not yet created.** See `open-questions.md` §1.
- Application code: none.
- Migrations: none written. The DDL exists as fenced SQL blocks inside `data-model.md`, ordered by
  `data-model.md` §14. Extracting them into `supabase/migrations/*.sql` is task **T0.1a**.

### Working agreements

- Money as **integer piastres**. Percentages and multipliers as **basis points**. No floats.
- Postgres RPC for all business logic. No Edge Functions in v1 (the free quota is reserved for a
  future payment gateway).
- Every state change writes its `events` row in the same transaction.
- `ledger_entries` is append-only, enforced by database rules.
- Migrations are forward-only and additive. RPC names are versioned `_v1`.
- Secrets go in Worker secrets or Supabase secrets. Never in an app, never in git.

### When you are asked to do something not covered here

Say so. Do not invent a table, a fee rule or a payment path. `open-questions.md` exists so that
unresolved decisions stay visible instead of becoming silent assumptions — the previous draft of
this spec had forty invented tables that nobody had approved.