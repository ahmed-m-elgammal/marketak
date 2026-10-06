# Admin console — end-to-end plan

`apps/admin-web`. Static Cloudflare Pages, reads and writes through RPCs under RLS. No Worker.

**Screens, routes, file architecture and Ant Design integration: `admin-console-screens.md`.** That file
owns the 41-screen inventory and the directory tree; this one owns phases, tasks and exit criteria.

Everything in the "verified" column below was read from the **live** project on 2026-10-06, not from
`tasks.md`, which lags the schema. Where the two disagree, this file is right and the task list needs
updating.

---

## 1. What already exists (verified live)

| Surface | Count | Notes |
|---|---|---|
| `admin_*` RPCs | **48** | 16 `upsert`, 16 `delete`, 16 `restore`. All `security definer`, all call `private.is_admin()` |
| Admin reads | `get_admin_metrics_v1`, `reconcile_day_v1`, `get_platform_float_v1`, `get_fee_rules_v1`, `get_commission_v1`, `set_fee_tier_v1`, `set_commission_rule_v1`, `get_flags_v1`, `list_frozen_v1`, `get_wallet_balance_v1`, `adjust_wallet_v1`, `freeze_wallet_v1`, `run_payout_v1` | every one grants `authenticated=true`, `anon=false` |
| Admin RLS read policies | 12 tables | `vendors`, `orders`, `sub_orders`, `users`, `riders`, `wallets`, `payouts`, `platform_float`, `audit_log`, `user_roles`, `settings` |
| Role source | `user_roles.role = 'admin'`, `revoked_at is null`, read through `private.is_admin()` | 1 admin exists |
| Live data | 3 users, 2 vendors, 1 order, 13 settings, 1 city (`LIV`, Africa/Cairo, **not** `is_primary`) | |

**Grants are correct and complete for an authenticated admin.** No RPC grants `anon`. The read path needs
no Worker, no service-role key, and no edge proxy.

## 2. The blocking defect: nothing writes `audit_log`

This is the one thing that must be fixed before the console exposes any write action.

`audit_log` exists and is finished: 2 relations (parent + a monthly partition), 4 indexes, 3 policies,
`bigserial` PK, `before`/`after` jsonb, `actor_user_id references users(id) on delete set null`,
admin-only read. `data-model.md` §2018 documents it as the record that "must outlive the thing it
describes".

**Zero functions anywhere in the database insert into it.** Verified:

- 0 of 48 `admin_*` functions mention `audit_log`
- 0 functions database-wide match `insert into ... audit_log`
- 0 triggers on `vendors`, `cities`, `wallets`, `user_roles`, `vouchers` other than `set_updated_at` and
  `private.assert_wallet_owner`
- `audit_log` contains 0 rows

What the admin writes go to `events` instead. `admin_upsert_vendor_v1` emits
`('vendor.updated', 'vendor', v_id, jsonb_build_object('actor', v_user, 'fields', ...))` — the actor is
recorded, and the **field names are recorded, but not the values**. `before`/`after` are unpopulated
because nothing captures them.

So today an admin can change a vendor's price and the database can show *that* it changed and *who*, but
not *from what to what*. `data-model.md:2052` calls self-contained rows the whole point.

Consequence for the plan: **the console's audit screen is unshippable until this is fixed**, and building
write screens first would ship an admin panel whose history an operator cannot trust. A1 below fixes it.

## 3. Phases

Ordered by dependency, not by size. Each phase has one exit criterion that is verifiable.

### A0 — Scaffold and design tokens

No admin UI work starts without this, because `AGENTS.md` rule 2 bans inline colour and spacing and
requires `src/theme/`. Scaffolding afterwards means ripping out a stylesheet.

- [ ] **A0.1** `apps/admin-web`: Vite + React + TypeScript + **Ant Design 5**, `"strict": true`, added as
      a workspace. See `admin-console-screens.md` §6 for the kit decision and its one real cost
- [ ] **A0.2** `packages/ui` tokens: colour, spacing, type scale, radii, elevation. CSS custom properties.
      `admin-console-screens.md` §4 fixes the tree: `src/theme/` owns every colour and
      `theme/antd-theme.ts` maps those tokens into antd's `ConfigProvider`, so antd never introduces an
      untracked colour
- [ ] **A0.3** Money formatting. `packages/shared/src/domain/money/format-money.ts` exists for the mobile
  app — the console must consume it, not write a second formatter. **All amounts are integer minor units**
  (paise). Never a float, never a bare number with a currency symbol. Basis points render as a
      multiplier (`12500` → `1.25×`), never as `12500`
- [ ] **A0.4** RTL. Arabic and English both ship. Logical properties (`margin-inline-start`) not physical
- [ ] **A0.5** Supabase client: `createClient` with the **publishable** anon key only. No service-role key
      in a browser, ever
- [ ] **A0.6** `src/i18n/` with `en.json` and `ar.json`. **No user-facing string may live in a component**
      — that is what makes the Arabic translation real rather than aspirational. RPC error codes map to
      message keys via `lib/errors.ts`; `PRICE_CHANGED` and friends never reach the screen
- [ ] **A0.7** Route-level code splitting. Ant Design is large and the bundle must be measured, not assumed
- [ ] **A0.8** `npm run typecheck`, `lint`, `test` wired into `verify` for the new package

**Exit:** a page renders with tokens, no inline styles, and `verify` is green.

### A1 — Audit trail (database, must precede every write screen)

- [ ] **A1.1** Migration `039_admin_audit`: a `private.write_audit(p_action, p_entity_type, p_entity_id,
      p_before, p_after)` helper that snapshots `row_to_json` before and after
- [ ] **A1.2** Call it from all 48 `admin_*` RPCs, plus `adjust_wallet_v1`, `freeze_wallet_v1`,
      `run_payout_v1`, `set_fee_tier_v1`, `set_commission_rule_v1`
- [ ] **A1.3** `reconcile_day_v1` writes its `variance_explanation` to `audit_log` too — it is a
      justification for money, which is the highest-value audit row in the system
- [ ] **A1.4** **Keep** the existing `events` rows. They drive push routing; `audit_log` is the compliance
      record. Two logs, different jobs
- [ ] **A1.5** Migration already exists locally as `038i` but was **never written to disk** — write the
      file so a fresh `supabase db reset` reproduces `currency` in the claim
- [ ] **A1.6** Adversarial probes: non-admin cannot write an audit row; `before`/`after` differ on update;
      deleting a user nulls `actor_user_id` and **keeps the row**; a failing RPC leaves no partial audit row

**Exit:** an admin edits a vendor price, and `audit_log` holds the old and new values with the actor id.

### A2 — Auth and shell

- [ ] **A2.1** Google sign-in only. No email, no password, no OTP (constitution)
- [ ] **A2.2** Role gate: read `user_roles` for `auth.uid()`. Not admin → a real 403 page, not a blank
      screen and not a redirect loop
- [ ] **A2.3** Route guard on every route, not just the root
- [ ] **A2.4** Shell: sidebar, header, language switch (ar/en), sign-out
- [ ] **A2.5** Loading, empty, and error states on the shell itself — rule A4 requires all three designed,
      not just the happy path

**Exit:** an admin signs in with Google and lands on a populated shell; a signed-in non-admin gets 403.

### A3 — Read-only dashboard

Highest value per screen, and it needs no writes at all — pure RLS reads.

- [ ] **A3.1** `get_admin_metrics_v1(p_date)` → the funnel, orders, revenue, cancellation, ETA accuracy,
      vendor and rider blocks. One RPC, one screen
- [ ] **A3.2** **Surface `float_variance` and never filter it to zero.** The function's own comment cites
      constitution I.10 for this. A dashboard that greys out an unexplained variance destroys the signal
- [ ] **A3.3** `reconcile_day_v1(p_date, p_explanation)` + `get_platform_float_v1(p_from, p_to)` —
      the T4.13 reconciliation view
- [ ] **A3.4** Date picker in **city timezone** (`Africa/Cairo`), never the browser's. The RPC derives its
      window from `cities.timezone`; a browser in UTC silently shows the wrong day
- [ ] **A3.5** Flags: `get_flags_v1` — the T6.2 surface

**Exit:** an operator opens the console, sees today's numbers, and they match `reconcile_day_v1` for the
same date.

### A4 — Catalog and vendor CRUD

The widest surface — 57 of the 67 admin RPCs live here.

- [ ] **A4.1** Vendor list with server-side filter and pagination. PostgREST `select` with `count=exact`,
      not a client-side slice of a full table
- [ ] **A4.2** Vendor form → `admin_upsert_vendor_v1(p_patch, p_id)`. Note the patch is
      **whitelisted server-side**: an unknown key raises `UNKNOWN_KEY`. The form must not send
      `deleted_at`, `menu_version`, or the `*_normalized` columns
- [ ] **A4.3** Soft delete and restore: `admin_delete_vendor_v1(p_id, p_reason)` and
      `admin_restore_vendor_v1`. **`p_reason` is mandatory** — make the field required in the UI, not just
      in the schema
- [ ] **A4.4** Cities, areas, brands, cuisines, vouchers — same triple each
- [ ] **A4.5** Staff: `admin_upsert_vendor_staff_v1`. `vendor_staff.can_edit_menu` and `can_manage_orders`
      are separate booleans — render them as two independent toggles, not a role dropdown
- [ ] **A4.6** Menus: categories, items, options, choices, sizes. Admin **read** needs no RPC — `menu_items`,
      `menu_categories`, `item_options`, `option_choices` and `menu_item_sizes` all carry admin read RLS
      (verified live), so this screen reads directly. Admin **write** goes through the six existing
      `admin_upsert_menu_*` / `admin_delete_menu_*` RPCs. **T1.2/T1.3 are not a blocker for this screen** —
      they are for the *vendor-facing* menu editor, and the earlier draft of this plan said otherwise
- [ ] **A4.7** Confirmation dialog on every delete, quoting the reason that will be recorded. The reason is
      a required argument on all 16 delete RPCs, so the dialog must make it required — see
      `admin-console-screens.md` §2, "Modals, not screens"

**Exit:** an admin creates a vendor, edits it, soft-deletes it, restores it, and each step has an
`audit_log` row.

### A5 — Money: wallets, payouts, fees

Highest risk. Every screen here moves or explains real money, and a wrong number is a real loss.

- [ ] **A5.1** `get_wallet_balance_v1` — note it returns `balance`, `ledger_balance`, **`drift`**, and
      `recent_entries`. Show drift as its own column. A wallet whose balance disagrees with its ledger is
      the single most useful thing this console can surface
- [ ] **A5.2** `adjust_wallet_v1(p_owner_type, p_owner_id, p_amount, p_reason, p_reference,
      p_idempotency_key)` — reason mandatory, idempotency key generated client-side per attempt so a
      double-click cannot double-adjust
- [ ] **A5.3** `freeze_wallet_v1` / `list_frozen_v1` — a frozen queue with the reason inline
- [ ] **A5.4** `run_payout_v1(p_payout_type, p_account_id, p_period_start, p_period_end, p_action, ...)`.
      It returns `already_applied`, so the UI must handle the idempotent replay path, not just the happy one
- [ ] **A5.5** Fee tiers: `get_fee_rules_v1(p_zone_id)` + `set_fee_tier_v1`. **Show the multiplier as
      basis points and as a percentage side by side** — `multiplier_bps = 12500` is a 1.25× multiplier and
      reading it as 12500× would be catastrophic. `assert_fee_tiers_monotonic` exists; the UI should warn
      before it fires
- [ ] **A5.6** Commission rules: `get_commission_v1` / `set_commission_rule_v1`, showing
      `is_effective_now` separately from `is_active`
- [ ] **A5.7** Every money screen states its **currency** explicitly. The schema carries per-row `currency`
      defaulting to EGP, and `cities.currency` can differ. Never assume EGP
- [ ] **A5.8** No client-side money arithmetic. Totals come from the RPC. This is constitution 7 and 9
      restated for the console

**Exit:** an admin adjusts a wallet with a reason, and `audit_log` plus `ledger_entries` both show it.

### A6 — Orders and operations

- [ ] **A6.1** Order list and detail. `orders` RLS already grants admins full read
- [ ] **A6.2** Show `orders` and `sub_orders` as a hierarchy. A checkout is one `orders` row plus N
      `sub_orders` rows — never one order with a nullable `vendor_id`. Showing them flattened invents a
      data model the database deliberately does not have
- [ ] **A6.3** Status timeline from `events`
- [ ] **A6.4** Void a mis-placed order. `cancel_order_v1` is the only supported path — the console must not
      write `orders.status` directly
- [ ] **A6.5** Rider roster and verification state

**Exit:** an operator traces one real order from placement to delivery through the UI alone.

### A7 — Hardening and launch

- [ ] **A7.1** Confirm `publishable` anon key only in the bundle. Grep the built output for
      `service_role` and fail the build if found
- [ ] **A7.2** Accessibility pass against Checklist A4: keyboard navigation, focus visible, labels on
      every input, contrast ≥ 4.5:1, tables with real `<th>` and scope
- [ ] **A7.3** Cross-check every screen against the **live** RLS policies. A query that works for an admin
      can still be silently filtered by a partition policy — `notifications` and `audit_log` do not inherit
      from their parent
- [ ] **A7.4** `SPEC.md` §7 empty/loading/failure states designed for every screen
- [ ] **A7.5** Deploy to Cloudflare Pages; confirm `verify` green in CI

**Exit:** a non-admin cannot read a single admin byte from the browser console, proven by inspecting the
network tab.

---

## 4. Dependencies outside this plan

| Blocked on | Blocks |
|---|---|
| T1.2/T1.3 menu RPCs (0 exist) | **nothing in the console.** Admin menu read works today via RLS. They block the *vendor* web editor |
| T1.4 `upload-signer` | any image upload — vendor logos, menu photos (screens 9–11) |
| T1.5 on-device resize | R2 byte budget; a console task, not an app one |
| T-1.16 domain | `admin.` hostname, so no cookie-bound custom domain |

## 5. Open questions

These change the shape of the work. Per `AGENTS.md` rule 9 I have not guessed.

1. **Audit granularity.** Should a 24-field vendor patch write one row per admin action, or one row per
   changed field? Per-field is greppable and honest; per-action matches what an operator reads. This
   changes A1.2's shape.
2. **`p_reason` on delete.** The RPCs require it. Free text, or a reason vocabulary? A vocabulary makes
   the audit queryable; free text makes it honest.
3. **Vendor approval.** `is_approved` is a boolean on `vendors`. T6.5 describes apply → approve → schedule →
   menu. Should approval record *who* approved and *when*? Today it records neither, and `vendors` has no
   `approved_at` column — that is a schema question, not a UI one.
4. **Multi-city.** `cities.is_primary` drives the timezone every metrics function uses, and the live city
   `LIV` is **not** primary. Which is it meant to be? Until answered, A3.4 has no unambiguous "today".
5. **Can an admin impersonate support?** Most delivery platforms let support see a customer view. The
   schema has no impersonation concept and adding one is a security feature, not a UI feature.