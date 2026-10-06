# Architecture

**Read this first.** It answers "where does X live" without a search, and it exists because the previous
layout put tests next to the code they cover, which meant finding them was a grep.

---

## The three commands

```bash
npm run verify        # typecheck + lint + test + test-integrity. Run before every commit.
npm run worker:deploy # deploy the outbox-dispatcher to Cloudflare
npm run worker:dev    # local Worker, reads .dev.vars
```

There is no other entry point. If you need a fourth, it goes in `package.json` `scripts` and nowhere else.

---

## The tree

```
delivery app/
├─ packages/
│  └─ shared/                          # types, money, rendering. No Cloudflare, no React.
│     └─ src/
│        ├─ domain/                    # facts about the business. Imports nothing upward.
│        │  ├─ money/format-money.ts   # piastres -> a string a human reads
│        │  └─ notifications/
│        │     └─ claim-contract.ts    # what claim_events_v1 returns + the Worker-owned strings
│        ├─ application/
│        │  └─ render-notification.ts  # variables + template -> a sendable message
│        ├─ adapters/                  # reserved for future I/O
│        ├─ tests/                     # EVERY test in this package
│        │  ├─ format-money.test.ts
│        │  └─ ...
│        └─ index.ts                   # the public surface. Import from here, not from a deep path.
│
├─ functions/
│  └─ outbox-dispatcher/               # the Cloudflare Worker
│     ├─ wrangler.toml                 # cron trigger, vars, aliases. NEVER a secret.
│     └─ src/
│        ├─ index.ts                   # entry point: scheduled + fetch handlers
│        ├─ config/
│        │  └─ env.ts                  # reads and validates the four env values
│        ├─ database/
│        │  └─ supabase.ts             # the ONLY code that talks to Postgres. Three RPCs.
│        ├─ google/
│        │  └─ access-token.ts         # RS256 JWT + 55-minute cache
│        ├─ messaging/
│        │  └─ fcm-client.ts           # FCM HTTP v1. One request per device.
│        ├─ drain/
│        │  └─ drain-once.ts           # claim -> render -> send -> mark. The whole pipeline.
│        └─ tests/                     # EVERY test in this package
│           ├─ config-env.test.ts
│           ├─ access-token.test.ts
│           ├─ drain-once.test.ts
│           ├─ supabase.test.ts
│           └─ fakes.ts                # hand-written doubles. Not a mocking library, on purpose.
│
├─ supabase/migrations/                # numbered .sql, applied in order, NEVER edited after applying
├─ specs/001-platform-foundation/      # the specification. Decisions, contracts, data model, tasks.
├─ scripts/
│  └─ check-test-integrity.mjs         # refuses .skip, .only, tautologies, hollow suites
├─ eslint.config.js
├─ vitest.config.ts
├─ tsconfig.json
└─ package.json
```

---

## Where tests live

**`src/tests/`, one directory per package.** Not beside the source.

Filenames match the module they cover:

| Test file | Covers |
|---|---|
| `packages/shared/src/tests/format-money.test.ts` | `packages/shared/src/domain/money/format-money.ts` |
| `functions/outbox-dispatcher/src/tests/drain-once.test.ts` | `functions/outbox-dispatcher/src/drain/drain-once.ts` |
| `functions/outbox-dispatcher/src/tests/supabase.test.ts` | `functions/outbox-dispatcher/src/database/supabase.ts` |
| `functions/outbox-dispatcher/src/tests/access-token.test.ts` | `functions/outbox-dispatcher/src/google/access-token.ts` |

A test file ends in `.test.ts` and lives under a `tests/` directory. `vitest.config.ts` matches exactly that
glob, so a test written anywhere else does not run and does not fail either — which is why
`check-test-integrity.mjs` fails on a file with zero assertions.

`fakes.ts` lives in `tests/` too. It is not a test; it has no `it()` in it.

---

## Layering, and why it is one-way

```
adapters/      -> HTTP, PostgREST, anything outside the process
application/   -> use cases that coordinate the domain
domain/        -> facts about the business
tests/         -> imports everything
```

**Nothing in `domain/` may import from `application/` or `adapters/`.** That is what keeps money formatting
and the notification contract usable by the mobile app and the admin console, neither of which wants a
Cloudflare dependency. Every file's header states what it depends on and why.

For the Worker the equivalent rule is: **only `database/supabase.ts` knows the RPC names.** `drain-once.ts`
talks to two interfaces, `NotificationSource` and `NotificationSender`, which is why `tests/fakes.ts` can
substitute doubles without a mocking library.

---

## Secrets

**Never in a file that is committed.** `wrangler.toml` has no secrets in it and must not acquire any.

| Name | Secret? | How to set |
|---|---|---|
| `SUPABASE_URL` | stored as a secret anyway | `wrangler secret put` |
| `SUPABASE_SERVICE_ROLE_KEY` | **yes** — `BYPASSRLS` on every table | `wrangler secret put` |
| `FCM_SERVICE_ACCOUNT_JSON` | **yes** — holds a private key | `wrangler secret put` |
| `DRAIN_TOKEN` | **yes** — guards the manual route | `wrangler secret put` |
| `DRY_RUN` | no | `[vars]` in `wrangler.toml`. `log` or `send`. Default `log`. |
| `BATCH_SIZE` | no | `[vars]`. 1–200, the RPC's own range. |

Check what is set without printing any of it:

```bash
npx wrangler secret list --config functions/outbox-dispatcher/wrangler.toml
```

Two local files hold secrets and are gitignored: `supabase_keys` and
`marketak-eg-firebase-adminsdk-fbsvc-c7293a9dfd.json`. Both are also in `eslint.config.js`'s `ignores`, so
the linter cannot put their contents in a cache or a log.

---

## The drain's contract with the database

Three RPCs, all `service_role`-only. `events` has one SELECT policy and no INSERT or UPDATE policy, so the
drain **cannot** write to `events` even with a service-role key — it must call the mark RPC. That is the
reason a client holding the publishable key cannot suppress notifications.

| RPC | Called from | Returns |
|---|---|---|
| `claim_events_v1(p_limit)` | `SupabaseClient.claimEvents` | collapsed rows, one per (recipient, template, order) |
| `mark_events_delivered_v1(p_ids, p_result)` | `SupabaseClient.markDelivered` | `(marked, still_open)` |
| `register_device_token_v1(...)` | the mobile app, not the Worker | `setof device_tokens` |

Templates and tokens are read through PostgREST with RLS bypassed, which is why `getTemplate` filters on
`notification_templates.deleted_at` (that column exists) and `getDeviceTokens` does **not** filter on
`device_tokens.deleted_at` (that column does not). Both halves are asserted in `tests/supabase.test.ts`,
because getting either wrong is a 400 that only a live drain would reveal.

---

## Things that will bite you

**A `plpgsql` body is not validated at `create function` time.** PostgreSQL defers every name and semantic
check to first execution, so `create function` with a wrong column, a wrong group-by ordinal or a wrong
aggregate succeeds. Four migrations in this repo shipped that way. Every migration that touches a function
now ends with a `perform * from fn(...)` call — the only assertion that catches it. Do not remove it.

**A fix and a probe never share a migration.** A failing probe rolls the fix back with it. That mistake
shipped `038b` and left the database with the broken function while the migration history claimed otherwise.

**`events.id` is a `bigint` and `JSON.parse` is lossy past 2^53.** Send ids as **strings** in a request body
(`p_ids`), and refuse an unrepresentable one on the way in. `JSON.stringify` throws on a BigInt outright,
which cost a full round trip on the first live drain.

**There is no `CURRENCY` constant.** It is per-order data from `orders.currency`, and the column is
overridable through `admin_upsert_city_v1`. constitution rule 4.

**`DRY_RUN` defaults to `log`.** A Worker deployed with a missing or misspelled flag must fail toward not
sending: an undelivered notification is retried, a wrongly-delivered one cannot be recalled.

---

## TypeScript is pinned below latest, deliberately

`typescript` is `~6.0.3` while `latest` is 7.x, because `typescript-eslint@8.71.1` declares
`peer typescript: ">=4.8.4 <6.1.0"`. Forcing past it produces a mismatched parser, which is how a lint rule
silently stops seeing a file — and the `no-explicit-any` rule is what constitution rule 1 rests on.

Bump both together when typescript-eslint widens its range. The reason is recorded in `package.json` under
`comments.typescriptPin`.