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
│  ├─ app/                      # shell only: providers, router, layout, guards
│  │  ├─ router.tsx
│  │  ├─ routes.ts              # the 41 routes, one entry each
│  │  ├─ providers.tsx          # ConfigProvider (antd theme + locale), AuthProvider, QueryClient
│  │  └─ layout/                # AppShell, Sidebar, Header, Breadcrumbs
│  ├─ theme/                    # RULE 2 LIVES HERE. No colour literal outside this directory.
│  │  ├─ tokens.ts              # spacing scale, radii, type scale, z-index
│  │  ├─ colors.ts              # semantic only: text.primary, surface.raised. No raw hex elsewhere
│  │  ├─ antd-theme.ts          # maps tokens → antd ConfigProvider token object
│  │  └─ index.ts
│  ├─ i18n/
│  │  ├─ index.ts               # instance, LocaleProvider
│  │  ├─ en.json  ar.json       # every user-facing string. Rule: no string in a component.
│  │  └─ format.ts              # money, dates, relative time — delegates to packages/shared
│  ├─ lib/
│  │  ├─ supabase.ts            # createClient, anon key only
│  │  ├─ queries/               # one hook per RPC or table read. No fetch in components.
│  │  │  ├─ metrics.ts  customers.ts  merchants.ts  orders.ts
│  │  │  ├─ catalog.ts  money.ts  settings.ts  audit.ts
│  │  ├─ errors.ts              # RPC error code → message key. Never a raw Postgres string.
│  │  └─ permissions.ts         # canEdit(), canDelete() from user_roles
│  ├─ features/                 # one directory per section, mirroring the sidebar
│  │  ├─ dashboard/
│  │  │  ├─ DashboardPage.tsx    # < 300 lines
│  │  │  ├─ MetricCard.tsx  FunnelChart.tsx  EtaAccuracy.tsx  VarianceAlert.tsx
│  │  ├─ customers/
│  │  │  ├─ CustomerListPage.tsx  CustomerProfilePage.tsx
│  │  │  ├─ tabs/  OverviewTab.tsx  OrdersTab.tsx  AddressesTab.tsx  ReviewsTab.tsx
│  │  │  └─ components/  CustomerForm.tsx  OrderHistoryTable.tsx
│  │  ├─ merchants/
│  │  │  ├─ MerchantListPage.tsx  MerchantProfilePage.tsx
│  │  │  ├─ tabs/  OverviewTab.tsx  CatalogTab.tsx  StaffTab.tsx
│  │  │  │        ScheduleTab.tsx  WalletTab.tsx  OrdersTab.tsx
│  │  │  ├─ catalog/  CategoryPage.tsx  ItemPage.tsx  CategoryForm.tsx  ItemForm.tsx
│  │  │  └─ components/  VendorForm.tsx  StaffTable.tsx  ScheduleEditor.tsx  LocationCell.tsx
│  │  ├─ orders/     OrderListPage.tsx  OrderDetailPage.tsx  Timeline.tsx  SubOrdersTable.tsx
│  │  ├─ riders/     RiderListPage.tsx  RiderProfilePage.tsx
│  │  ├─ money/      ReconciliationPage.tsx  WalletsPage.tsx  WalletDetailPage.tsx
│  │  │             PayoutsPage.tsx  FeeTiersPage.tsx  CommissionsPage.tsx
│  │  ├─ settings/   CitiesPage.tsx  AreasPage.tsx  VouchersPage.tsx  FlagsPage.tsx  AuditPage.tsx
│  │  └─ auth/       SignInPage.tsx  ForbiddenPage.tsx  NotFoundPage.tsx
│  ├─ components/               # shared, feature-agnostic
│  │  ├─ DataTable.tsx          # server-side sort/filter/paginate, count=exact
│  │  ├─ PageHeader.tsx  EmptyState.tsx  LoadingState.tsx  ErrorState.tsx
│  │  ├─ ConfirmWithReason.tsx  StatusTag.tsx  Money.tsx  PhoneLink.tsx  LocationLink.tsx
│  │  └─ ActionMenu.tsx         # the per-row admin actions. See below.
│  └─ main.tsx
└─ package.json
```

**Five rules this tree enforces**

1. **`theme/` owns every colour.** A hex literal anywhere else is a lint error. `antd-theme.ts` maps our
   tokens *into* antd, so antd never introduces an untracked colour.
2. **`i18n/` owns every string.** No English or Arabic literal in a component. This is what makes the ar
   translation real rather than aspirational.
3. **`lib/queries/` owns every network call.** No `supabase.from(...)` inside a component, so no component
   can invent its own filter and quietly bypass RLS intent.
4. **`components/` is feature-agnostic.** Anything that knows about vendors belongs in `features/`.
5. **One file, one screen or one component.** `AGENTS.md` rule 5 caps a screen at 300–400 lines; the
   heaviest here is `MerchantProfilePage.tsx` at ~120 because the content lives in tabs.

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
- Built-in RTL support via `ConfigProvider direction="rtl"` — required, since Arabic ships.
- Locale packs exist for ar and en.

**The tension, stated honestly.** Ant Design ships its own visual language and its own theme file. Your
rule "no hardcoded colors" is at risk the moment a component takes a default colour that is not in our
tokens. The fix is in `theme/antd-theme.ts`: a single function that maps our tokens onto antd's token
object, so **every** antd colour resolves through our scale. `ConfigProvider` is mounted once in
`providers.tsx` and nothing else touches antd theming.

Two more:

- **Bundle.** Ant Design is large. Route-level code splitting plus `import { Table } from 'antd'`-style
  named imports keeps the initial payload sane. Worth measuring, not assuming.
- **`Form` validation vs RPC validation.** The RPCs validate server-side with a whitelist
  (`UNKNOWN_KEY` for a field antd thinks is fine). Client validation is for the operator's benefit; the
  server remains the authority. Never mirror server rules by hand — they drift.

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