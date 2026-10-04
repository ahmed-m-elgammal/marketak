# Changelog

All notable changes to Marketak. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is not yet meaningful — there
is no released version, and the schema is still pre-review.

## [Unreleased]

Nothing shipped. This project is specification-only.

### Added

- **Platform specification** for a one-city, lunch-first delivery platform on Supabase +
  Cloudflare + Firebase. Eight documents: constitution, spec, decisions, data-model, contracts,
  plan, free-tier-plan, tasks, open-questions.
- **Multi-vendor checkout model.** One `orders` row plus N `sub_orders`. Order items belong to a
  sub-order, never to an order. This is the requirement the whole schema is shaped around.
- **Configurable delivery fee.** `base × multiplier(vendor_count)` plus a distance component.
  Tiers seed at ×1.00 / ×1.10 / ×1.20 for 1 / 2 / 3 vendors, stored in basis points. Maximum
  vendors per cart is 3, from `settings`. No fee constant appears in code or in a function body.
- **Phased revenue model.** Launch revenue is a cut of the delivery fee taken from the rider.
  Vendor commission on items and a customer service fee exist as inactive rows, activated by an
  `update` around month 3–4. `effective_from` prevents retroactive application.
- **No customer wallet.** The customer pays the rider directly in cash or by Vodafone Cash /
  Instapay. Wallets exist for vendors and riders only. Chosen for money integrity: it removes the
  entire top-up fraud surface and all customer float.
- **Two-phase checkout.** `quote_order_v1` reprices and returns a 5-minute fingerprint;
  `place_order_v1` reprices inside the transaction and aborts with `PRICE_CHANGED` plus an
  itemised diff. The offline cache is display-only and can never produce a wrong charge.
- **Append-only ledger** with Postgres rules forbidding `UPDATE` and `DELETE`. Corrections are
  reversing entries. Money is integer piastres.
- **Free-tier longevity plan.** Byte-level model of every cap, three retention scenarios, a ranked
  list of 14 levers, and a named upgrade trigger: Postgres over 350 MB, or cumulative orders over
  ~40,000, or the first real cash in the system.
- **Agent skills** — 16 Cloudflare, 13 Firebase, 2 Supabase. Relevance recorded in
  `ENVIRONMENT.md` §5.
- **MCP servers** — Cloudflare (API, docs, bindings, builds, observability), Supabase, Firebase.
  All connected and authenticated.

### Infrastructure

- **Supabase project `marketak`** created — ref `erxxsebcqqcpkipzcdhg`, region `eu-central-1`
  (Frankfurt), Postgres 17.11, free plan, `ACTIVE_HEALTHY`. Extensions verified available
  including `pg_tap`, so the RLS policy tests are runnable rather than theoretical.
- **Firebase project `marketak-eg`** created (number `283007295790`) and set active. `marketak`
  was already taken as a global Firebase project id.
- **Firebase apps registered** for Android and iOS under bundle/package `com.jaylak.mobile`.
- **R2 enabled.** Buckets `marketak-public` and `marketak-private` created in `EEUR`.

### Database

Migrations 001–004 written **and applied** to the live project. 20 tables, 58 indexes.

- `001_extensions` — `pgcrypto`, `pg_trgm`, `btree_gist`, `unaccent`, `pg_partman`. PostGIS is
  available and deliberately **not** installed: area matching is geohash-prefix plus a haversine
  distance, so nothing in the schema depends on a spatial extension.
- `002_geo_and_config` — `cities`, `areas`, `delivery_zones`, `delivery_fee_tiers`, `settings`
- `002s_seed_fee_tiers` — the ×1.00 / ×1.10 / ×1.20 vendor-count tiers, as data, in a separate file
- `003_identity` — `users`, `user_roles`, `user_auth_providers`, `addresses`, `device_tokens`,
  `feature_flags`, plus the `on_auth_user_created` trigger
- `004_vendors` — `brands`, `vendors`, `vendor_areas`, `vendor_schedules`, `vendor_holidays`,
  `cuisines`, `vendor_cuisines`, `vendor_staff`, `vendor_earnings_daily`

Verified against the live database rather than assumed: **0 unindexed foreign keys**, every
`security definer` function pinned to `search_path = ''`, and the profile gate proven across six
cases — the trigger fires on sign-in, grants the base `customer` role, leaves the profile
incomplete, rejects a completion with no phone, accepts a valid one, and rejects a duplicate phone.

**Defect found by applying rather than reading:** `users.id uuid primary key default
auth.users(id)` is illegal — Postgres rejects a column reference in a `DEFAULT` expression
(`ERROR 0A000`). `data-model.md` carried the same bug and was corrected in the same change, so the
spec and the database do not disagree.

### Changed

- **Nothing shipped, so nothing changed.** This section is where refactors and specification
  revisions land. It is empty by design, not by omission.

### Fixed

- **No fixes yet.** This is where bug fixes land, per Checklist B step 6.

### Security

- Purged an Apple App Store Connect private key (`*.p8`) and an iOS distribution certificate
  (`*.cer`) from git history after they were committed by a `git add -A`. `.gitignore` extended
  to cover `*.p8 *.cer *.p12 *.pfx *.jks *.mobileprovision` and the `appstore/` directory.
  `git add -A` is now forbidden by the commit protocol in `AGENTS.md`.
- The App Store Connect key should still be revoked and regenerated. It was never pushed to a
  remote, but an App Store Connect key can read sales data and manage builds, and it does not
  expire on its own.

### Deprecated

- `architecture-spec-supabase-cloudflare-firebase.md` — the original v1 architecture spec.
  Superseded. Marked with a contradiction table so it is not implemented from by mistake. Retained
  only as a historical artifact.

## Known gaps

Recorded in `open-questions.md` §6. The significant ones:

- No migration `.sql` files exist. The DDL is fenced blocks inside `data-model.md`.
- No application code. No `apps/`. No `package.json`.
- `npm run typecheck`, `npm run lint`, `npm test`, `npm run verify` do not exist, so **no
  engineering checklist can currently be signed off.** See `AGENTS.md` §Verification commands.
- `scripts/check-test-integrity.mjs` does not exist, so rule 4 is unenforced.
- The spec has never been reviewed by a human. Every number in it is a proposal.