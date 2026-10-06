# Admin console — screen architecture

Companion to `admin-dashboard-plan.md`. That file says **what** the phases deliver; this one says
**which screens exist, how they nest, and where each one lives in the tree**. No code yet.

Chosen UI kit: **Ant Design 5**. Rationale in §6.

---

## 1. Information architecture

Six top-level sections in the sidebar, in the order an operator actually works:

```
Dashboard ─┬─ Customers ─── list ──→ profile ─┬─ Overview / Orders / Addresses / Reviews
           │
           ├─ Merchants ─── list ──→ profile ─┬─ Overview / Catalog ─→ category ─→ item
           │                                   └─ Staff / Schedule / Wallet / Orders
           │
           ├─ Orders ───── list ──→ detail ──── timeline + sub-orders + money
           │
           ├─ Money ────── reconciliation / wallets / payouts / fees
           │
           ├─ Settings ─── cities / zones / vouchers / flags / audit
           │
           └─ Riders ───── list ──→ profile
```

**One drill-down rule, applied everywhere.** Every list row leads to exactly one profile, and every
profile has its tabs. No screen is reachable two different ways, because a support agent who bookmarks a
URL must get the same page next week.

**The nesting you described, stated precisely:**

```
Customers        → Customer profile        (everything about one person, tabbed)
Merchants        → Merchant list           (filterable grid)
                   Merchant profile        (name, phone, location + tabs)
                     └ Catalog             → Category → Item
Riders           → Rider list → Rider profile
Orders           → Order list  → Order detail
```

Catalog is a **drill-down inside the merchant**, not a separate top-level section. A menu item has no
meaning without knowing which merchant and which category it belongs to, so putting Catalog in the sidebar
would force the operator to hold that context in their head — which is the thing the design philosophy
below exists to prevent.

## 2. Screen inventory

**41 screens.** Every one is counted, including the ones that are one component.

| # | Screen | Route | Depth | Backend | Phase |
|---|---|---|---|---|---|
| 1 | Dashboard | `/` | 1 | `get_admin_metrics_v1` | A3 |
| 2 | Customers list | `/customers` | 1 | RLS read | A4 |
| 3 | Customer profile — Overview | `/customers/:id` | 2 | RLS read | A4 |
| 4 | Customer — Orders | tab | 3 | RLS read | A6 |
| 5 | Customer — Addresses | tab | 3 | RLS read | A4 |
| 6 | Customer — Reviews | tab | 3 | RLS read | A6 |
| 7 | Merchants list | `/merchants` | 1 | RLS read | A4 |
| 8 | Merchant profile — Overview | `/merchants/:id` | 2 | RLS read | A4 |
| 9 | Merchant — Catalog | tab | 3 | RLS read | A4 |
| 10 | Category detail | `/merchants/:id/catalog/:categoryId` | 4 | RLS read | A4 |
| 11 | Item detail | `/merchants/:id/catalog/:categoryId/items/:itemId` | 5 | RLS read | A4 |
| 12 | Merchant — Options & sizes | tab | 3 | RLS read | A4 |
| 13 | Merchant — Staff | tab | 3 | `admin_upsert_vendor_staff_v1` | A4 |
| 14 | Merchant — Schedule | tab | 3 | `admin_upsert_vendor_schedule_v1` | A4 |
| 15 | Merchant — Wallet | tab | 3 | `get_wallet_balance_v1` | A5 |
| 16 | Merchant — Orders | tab | 3 | RLS read | A6 |
| 17 | Orders list | `/orders` | 1 | RLS read | A6 |
| 18 | Order detail | `/orders/:id` | 2 | RLS read | A6 |
| 19 | Riders list | `/riders` | 1 | RLS read | A6 |
| 20 | Rider profile | `/riders/:id` | 2 | RLS read | A6 |
| 21 | Reconciliation | `/money/reconciliation` | 2 | `reconcile_day_v1` | A3 |
| 22 | Float variance history | `/money/float` | 2 | `get_platform_float_v1` | A3 |
| 23 | Wallets — frozen queue | `/money/wallets` | 2 | `list_frozen_v1` | A5 |
| 24 | Wallet detail | `/money/wallets/:ownerType/:ownerId` | 3 | `get_wallet_balance_v1` | A5 |
| 25 | Adjust wallet (modal) | — | — | `adjust_wallet_v1` | A5 |
| 26 | Payouts list | `/money/payouts` | 2 | `run_payout_v1` | A5 |
| 27 | Payout detail | `/money/payouts/:id` | 3 | `run_payout_v1` | A5 |
| 28 | Fee tiers | `/money/fees` | 2 | `get_fee_rules_v1`, `set_fee_tier_v1` | A5 |
| 29 | Commission rules | `/money/commissions` | 2 | `get_commission_v1`, `set_commission_rule_v1` | A5 |
| 30 | Cities | `/settings/cities` | 2 | `admin_upsert_city_v1` | A4 |
| 31 | Areas | `/settings/areas` | 2 | `admin_upsert_area_v1` | A4 |
| 32 | Vouchers | `/settings/vouchers` | 2 | `admin_upsert_voucher_v1` | A4 |
| 33 | Brands & cuisines | `/settings/taxonomy` | 2 | `admin_upsert_brand_v1`, `admin_upsert_cuisine_v1` | A4 |
| 34 | Feature flags | `/settings/flags` | 2 | `get_flags_v1` | A3 |
| 35 | Audit log | `/settings/audit` | 2 | RLS read on `audit_log` | **A1** |
| 36 | Language switcher | global | — | — | A2 |
| 37 | Forbidden (403) | `/403` | 1 | `user_roles` | A2 |
| 38 | Not found (404) | `*` | 1 | — | A2 |
| 39 | Sign in | `/sign-in` | 1 | Google OAuth | A2 |
| 40 | Notification templates | `/settings/templates` | 2 | RLS read | future |
| 41 | Rider pay rules | `/money/rider-pay` | 2 | RLS read | future |

Screens 40 and 41 are read-only and marked **future** because no `admin_upsert_*` RPC exists for them.
They are listed so the count is honest, not because phase A includes them.

### Modals, not screens

These are modal dialogs or drawers, deliberately **not** routes. Each is a short task that must lose
context if the operator wanders off mid-way:

Create merchant · Edit merchant · Soft-delete (with reason) · Restore · Create/edit category ·
Create/edit item · Create/edit option · Create/edit choice · Create/edit size · Add staff ·
Freeze wallet · Run payout · Create voucher · Adjust wallet.

**Delete always prompts for a reason.** `p_reason` is a required argument on all 16 delete RPCs, so the
field is required in the dialog, not just in the schema.

## 3. What each profile screen shows

### Customer profile — "everything I need to know about him"

Tabbed, because a single scroll of 40 fields is how operators miss the one that matters.

**Overview**
- Name, phone, email, avatar, preferred language, sign-up date, last seen
- Status badges: `is_active`, `profile_completed_at` (so: can they order?), `deleted_at`
- Lifetime value: order count, total spend, **currency stated explicitly**
- Wallet balance with **drift** beside it — the two disagreeing is the single most useful signal
- Auth providers (Google/Apple only — never show an email/password affordance)

**Orders** — every order, newest first, each expandable to its `sub_orders`. Filters by status and date.
**Addresses** — saved addresses with `is_default`, plus `delivery_instructions`.
**Reviews** — what they rated and said, per vendor and per rider.

### Merchant profile

**Overview** — exactly what you asked for, plus the fields an operator needs to act:

| Field | Source | Why it's on this screen |
|---|---|---|
| Name (en/ar), legal name, slug | `vendors` | identity |
| Phone, landline | `contact_phone`, `contact_landline` | how to reach them |
| Location | `latitude`, `longitude`, `geohash_prefix` | **rendered as a map link, never as raw decimal degrees** |
| Area, city | `area_id`, `city_id` | joined name, not the uuid |
| Vertical, brand | `vertical_type`, `brand_id` | classification |
| Open / busy / paused | `is_open`, `is_busy` | current state, one toggle |
| **Approved** | `is_approved` | the onboarding gate, and a distinct button |
| Prep time, min order, radius | `prep_time_minutes`, `minimum_order_value`, `delivery_radius_km` | what customers see |
| Rating | `rating_avg`, `rating_count` | quality |
| Cancelled / rejected count | from `sub_orders` | **the number operators watch** |

**Catalog** — categories for this merchant, with item counts. `+ Add category`.
**Category detail** — items in that category. `+ Add item`.
**Item detail** — name (en/ar), description, price or size-based pricing, availability, stock, prep time,
image, allergens, ingredients, nutrition, tags, spicy/vegetarian/featured/new flags.

Catalog is `vendors → categories → items` because that is the schema's shape exactly:
`menu_items.category_id → menu_categories.vendor_id`. No invention.

### Order detail

Header (number, status, currency) · timeline from `order_status_history` and `events` ·
`sub_orders` as a table, one row per merchant, each showing its share and settlement status ·
the money block (subtotal, fee, multiplier, service fee, discount, tip, total) · payment state ·
delivery location.

## 4. File architecture

```
apps/admin-web/
├─ src/
│  ├─ app/                      # shell only: providers, router, layout, guards, routes table
│  │  ├─ routes.tsx             # the screen table. A screen with no element is NOT built and 404s.
│  │  ├─ providers.tsx          # ConfigProvider (antd theme + locale), QueryClient, CSS variables
│  │  ├─ AppShell.tsx           # sidebar, header, breadcrumbs
│  │  ├─ App.tsx                # the router and the two guards
│  │  └─ styles/global.css      # the ONLY stylesheet. var(--…) references, never a literal.
│  ├─ i18n/
│  │  ├─ index.ts               # instance, Locale type, antd locale mapping, document direction
│  │  ├─ en.json  ar.json       # every user-facing string. Rule: no string in a component.
│  │  ├─ format.ts              # console-only formatters: locale mapping, tel:, map:
│  │  └─ use-locale.ts          # reads the active locale outside a translation lookup
│  ├─ lib/
│  │  ├─ supabase.ts            # readConsoleEnv - refuses a service-role key
│  │  ├─ supabase-client.ts     # the one lazy client instance
│  │  ├─ errors.ts              # RPC error code -> i18n key. Never a raw Postgres string.
│  │  ├─ use-admin-role.ts      # is this operator an admin? reads user_roles
│  │  └─ queries/               # one module per RPC or table read. No fetch in components.
│  ├─ features/<section>/       # one directory per sidebar section
│  ├─ components/               # shared, feature-agnostic
│  │  ├─ PageSkeleton.tsx  StateBlock.tsx  Money.tsx  StatusTag.tsx  LocaleSwitch.tsx
│  └─ main.tsx
packages/ui/
└─ src/theme/
   ├─ tokens.ts                 # spacing, type, radius, motion, breakpoints. No colour.
   ├─ colors.ts                 # THE ONLY FILE with a hex literal.
   ├─ antd-theme.ts             # maps tokens into antd's ConfigProvider
   └─ tests/tokens.test.ts      # asserts every contrast ratio against its WCAG floor
```

**Why tokens live in `packages/ui` and not `apps/admin-web/src/theme/`**

An earlier draft of this document put `theme/` inside the console. It was built in `packages/ui` instead, and
this section was wrong rather than the code. The mobile app needs the same spacing scale and the same palette,
and a token module that only the console can import is a second palette waiting to diverge. `packages/ui`
exports **tokens only** — no components — and `antd` is an *optional* peer dependency, so a React Native
bundle can read `space.4` without installing a desktop UI kit. Only `antd-theme.ts` knows the kit exists.

**Six rules this tree enforces**

1. **One file owns colour.** `packages/ui/src/theme/colors.ts` is the only file permitted a hex literal, and
   `scripts/check-no-hardcoded-colors.mjs` fails `npm run verify` on one anywhere else. The guard was
   verified by planting a probe, not by reading it.
2. **`global.css` may reference a token, never define one.** Stricter than the rule on TSX, because a
   stylesheet is where a hardcoded hex survives longest.
3. **`i18n/` owns every string.** No English or Arabic literal in a component. This is what makes the Arabic
   translation real rather than aspirational.
4. **`lib/queries/` owns every network call.** No `supabase.from(...)` inside a component.
5. **`components/` is feature-agnostic.** Anything that knows about vendors belongs in `features/`.
6. **An unbuilt screen does not exist as a module.** The route table carries its path and phase; it has no
   `element`, is absent from the sidebar, and 404s. `AGENTS.md` rule 3 forbids a file whose only content is an
   admission that it is empty.

### `ActionMenu` — your "clear admin action" requirement

One component, used in every list and every profile header, so the same verb always looks the same:

| Action | RPC | Presentation |
|---|---|---|
| Edit | `admin_upsert_*_v1` | opens a form drawer |
| Delete | `admin_delete_*_v1` | **red**, requires a typed reason, names what will be soft-deleted |
| Restore | `admin_restore_*_v1` | only when `deleted_at` is set — never shown otherwise |
| Approve / unapprove | `admin_upsert_vendor_v1` | separate button, not buried in a form |
| Open / pause | `admin_upsert_vendor_v1` | a switch, because it is the most frequent action |

Per-row actions sit in a `⋯` menu. **Destructive actions are never the icon alone** — each has a text
label, because a row of identical `⋯` icons is guesswork and guesswork is what the philosophy below
forbids.

## 5. Design philosophy, as rules

Your two principles, made checkable:

**"Don't make the admin think."**

1. Destructive actions require a reason and name their consequence in plain words.
2. Nothing destructive is behind an icon with no label.
3. Filters persist in the URL, so a shared link reproduces the exact view.
4. Pagination is server-side with a real total. "Showing 1–50 of ?" is never acceptable.
5. Every screen shows loading, empty, and failure states. Empty says *why* it's empty and what to do.
6. Money always carries its currency, and rates never appear as raw basis points.
7. Location renders as a map link. `30.0444, 31.2357` is not information a person can use.
8. After a save, stay on the page and confirm inline. Never bounce to a list.

**"Don't sound like the database."**

9. Column headers are nouns a merchant owner would use: not `vendor_id`, not `is_approved`, but
   **Approval status**.
10. Status is a word plus colour, never a colour alone. Colour-only status fails colour-blind operators.
11. Timestamps are relative where recent ("2 hours ago") and absolute where exact ("6 Oct 2026, 14:32").
12. Times are rendered in the **city's** timezone, and the screen says which one.
13. Errors say what to do next: "This vendor has open orders — close them first", not
    `foreign_key_violation`.
14. `PRICE_CHANGED`, `NOT_AUTHORIZED` and friends are internal codes. They never reach the screen.
15. Refusals read as the database already speaks: "vendor rejected this order", not "sub_order.status =
    rejected".

## 6. Ant Design 5

**Why it fits**

- 41 screens of tables, forms, drawers and dialogs is exactly antd's strength. Building that from scratch
  would be weeks of work that adds nothing to the product.
- Its `Form` + `Drawer` + `Modal` trio covers every modal in §2 without a custom component.
- **antd 6, not 5.** 6.6.5 is current. It requires React ≥ 18, supports React 19 without the
  `@ant-design/v5-patch-for-react-19` shim, and keeps the same `ConfigProvider theme.token` mechanism this
  design depends on. Three v6 defaults are corrected in `providers.tsx` rather than left to surprise a
  screen later:
  - **CSS variables are on by default**, with a stable `key`, so the generated variable names do not change
    per build.
  - **`Modal`/`Drawer` masks blur by default from 6.3.0.** Disabled — it costs a paint on a tablet and this
    console does not need it.
  - **`Tag` lost its trailing `margin-inline-end`.** Reinstated via `ConfigProvider`, because dense status
    columns relied on it and its absence reads as a layout bug.
- `ar_EG` and `en_US` locale packs both ship, so Arabic is not a hand-built locale.

**The tension, stated honestly.** Ant Design ships its own visual language and its own token object. Your
rule "no hardcoded colors" is at risk the moment a component takes a default colour that is not in our
tokens. The fix is in `theme/antd-theme.ts`: a single function that maps our tokens onto antd's token object,
so **every** antd colour resolves through our scale. `ConfigProvider` is mounted once in `providers.tsx` and
nothing else touches antd theming. This is not theoretical — antd's default `colorError` measures **3.0:1**
against white and fails AA at body weight, which is why every status colour here was chosen against a
measured floor instead of copied from the kit.

Two more:

- **Bundle.** Ant Design's full bundle is ~430 KB gzipped. Named imports plus one chunk per route keeps it
  down; React is split separately so a token tweak does not invalidate the framework cache. Worth measuring,
  not assuming.
- **`Form` validation vs RPC validation.** The RPCs validate server-side with a whitelist (`UNKNOWN_KEY` for
  a field antd thinks is fine). Client validation is for the operator's benefit; the server remains the
  authority. Never mirror server rules by hand — they drift.

**Alternative, if you'd rather own the pixels:** build on a headless kit (Radix or React Aria) plus
`packages/ui` tokens. Better RTL and accessibility posture, no default look to fight. Roughly 3× the
work for the same 41 screens. Worth it only if the default antd look is unacceptable to you.

## 7. Spacing and layout

A 4px base scale: `space.1 = 4` … `space.8 = 32`. Every margin and padding resolves to it. Layout rules:

- Page gutter `space.6` (24px); card padding `space.5` (20px); table cell padding `space.3` (12px)
- **Consistent density across all screens.** A gap between two tables means the same thing everywhere.
- Row height 48px minimum, comfortably above the 44px touch-target floor in `AGENTS.md` X.7
- Forms are one column below 768px, two above. Never two columns on mobile
- Proportional digits for money — `font-variant-numeric: tabular-nums` — so columns of amounts align