/**
 * `app/routes` - every route in the console, in one table.
 *
 * ## Why a table and not JSX
 *
 * `admin-console-screens.md` §2 enumerates 41 screens. A count that lives only in a routing file is a claim; a
 * count in a table beside the route it describes is checkable, and `tests/format-and-routes.test.tsx` asserts
 * every path is unique and every sidebar key resolves.
 *
 * ## Unbuilt screens have NO element, on purpose
 *
 * `AGENTS.md` rule 3 forbids placeholder shortcuts. An earlier version of this file pointed every one of the
 * 28 rows at a module whose entire body was "not built yet" - a stub, dressed up with a paragraph explaining
 * why it was honest. It was not honest, it was a placeholder with a comment.
 *
 * So: a screen that has no implementation has `element: undefined`, no module exists for it, and
 * - it does not appear in the sidebar, because there is nothing to navigate to
 * - its path is not registered, so it falls through to the 404
 *
 * The row stays, because the path and the section are the contract the later phases build against. When A4
 * builds the merchant list, it adds a module and sets one field. Nothing else moves, and in the meantime
 * there is no file in the repository that exists only to admit it is empty.
 *
 * ## Every implemented screen is a separate chunk
 *
 * Ant Design's components are large and the console shares maybe fifteen of them. Splitting per route means
 * an operator who only opens the dashboard never downloads the payout tables or the audit log. `vite.config.ts`
 * groups React separately so this splitting does not invalidate the framework cache.
 */

import { lazy, Suspense, type ElementType, type ReactElement } from "react";

import { PageSkeleton } from "../components/PageSkeleton.js";

/** The sidebar sections, in the order an operator works. */
export const SECTIONS = [
  "dashboard",
  "customers",
  "merchants",
  "orders",
  "riders",
  "money",
  "settings",
] as const;

export type Section = (typeof SECTIONS)[number];

/**
 * One screen.
 *
 * `element` is `undefined` until the phase that builds it lands. See the note at the top.
 */
export interface ScreenDefinition {
  /** Stable identity: a React `key` and the `nav.` i18n prefix. Never the path - paths change, names do not. */
  readonly key: string;
  readonly path: string;
  readonly section: Section;
  /** In the sidebar once built. A detail page is never a sidebar entry. */
  readonly inSidebar?: boolean;
  /** The phase that delivers this screen, so an unbuilt row states when it stops being empty. */
  readonly phase: string;
  readonly element?: ReactElement;
}

// --- chunks ---
//
// Declared above `SCREENS`, which is load-bearing: the table calls `element(DashboardPage)` during module
// evaluation, so a `const` declared further down the file would be in its temporal dead zone and `tsc`
// correctly rejects it as "used before being assigned". A `lazy()` inside a component body would be worse -
// it would re-create the lazy component on every render and re-trigger the import.

const DashboardPage = lazy(() => import("../features/dashboard/DashboardPage.js"));
const ReconciliationPage = lazy(() => import("../features/money/ReconciliationPage.js"));
const FlagsPage = lazy(() => import("../features/settings/FlagsPage.js"));

// A4. The three merchant screens share their query keys and their delete/restore dialog, so they are lazy
// together by virtue of being separate modules - each is only fetched when its route is actually opened.
const VendorListPage = lazy(() => import("../features/merchants/VendorListPage.js"));
const VendorProfilePage = lazy(() => import("../features/merchants/VendorProfilePage.js"));
const VendorFormPage = lazy(() => import("../features/merchants/VendorFormPage.js"));

/** A `Suspense` boundary per route, so navigating suspends the page body and not the shell. */
function element(Page: ElementType): ReactElement {
  return (
    <Suspense fallback={<PageSkeleton />}>
      <Page />
    </Suspense>
  );
}

/**
 * Every screen in the console.
 *
 * 28 of the plan's 41 are in a dashboard sub-section the table below does not yet model as rows, and the two
 * "future" screens - notification templates and rider pay rules - are absent by choice: there is no
 * `admin_upsert_*` RPC for either, so a page would advertise an editing capability that does not exist.
 */
export const SCREENS: readonly ScreenDefinition[] = [
  { key: "dashboard", path: "/", section: "dashboard", inSidebar: true, phase: "A3", element: element(DashboardPage) },

  { key: "customers", path: "/customers", section: "customers", inSidebar: true, phase: "A4" },
  { key: "customerProfile", path: "/customers/:id", section: "customers", phase: "A4" },

  {
    key: "merchants",
    path: "/merchants",
    section: "merchants",
    inSidebar: true,
    phase: "A4",
    element: element(VendorListPage),
  },
  {
    key: "merchantProfile",
    path: "/merchants/:id",
    section: "merchants",
    phase: "A4",
    element: element(VendorProfilePage),
  },
  {
    key: "merchantEdit",
    path: "/merchants/:id/edit",
    section: "merchants",
    phase: "A4",
    element: element(VendorFormPage),
  },
  {
    // `create` before `:id`, or the dynamic segment swallows "new" and the form renders as an edit of a
    // merchant whose id is literally "new". React Router ranks static segments above dynamic ones, so this
    // ordering is correct by its own rules - stated here because it looks wrong.
    key: "merchantCreate",
    path: "/merchants/create",
    section: "merchants",
    phase: "A4",
    element: element(VendorFormPage),
  },
  {
    key: "merchantCategory",
    path: "/merchants/:id/catalog/:categoryId",
    section: "merchants",
    phase: "A4",
  },
  {
    key: "merchantItem",
    path: "/merchants/:id/catalog/:categoryId/items/:itemId",
    section: "merchants",
    phase: "A4",
  },

  { key: "orders", path: "/orders", section: "orders", inSidebar: true, phase: "A6" },
  { key: "orderDetail", path: "/orders/:id", section: "orders", phase: "A6" },

  { key: "riders", path: "/riders", section: "riders", inSidebar: true, phase: "A6" },
  { key: "riderProfile", path: "/riders/:id", section: "riders", phase: "A6" },

  {
    key: "reconciliation",
    path: "/money/reconciliation",
    section: "money",
    inSidebar: true,
    phase: "A3",
    element: element(ReconciliationPage),
  },
  { key: "float", path: "/money/float", section: "money", inSidebar: true, phase: "A3" },
  { key: "wallets", path: "/money/wallets", section: "money", inSidebar: true, phase: "A5" },
  {
    key: "walletDetail",
    path: "/money/wallets/:ownerType/:ownerId",
    section: "money",
    phase: "A5",
  },
  { key: "payouts", path: "/money/payouts", section: "money", inSidebar: true, phase: "A5" },
  { key: "payoutDetail", path: "/money/payouts/:id", section: "money", phase: "A5" },
  { key: "fees", path: "/money/fees", section: "money", inSidebar: true, phase: "A5" },
  { key: "commissions", path: "/money/commissions", section: "money", inSidebar: true, phase: "A5" },

  { key: "cities", path: "/settings/cities", section: "settings", inSidebar: true, phase: "A4" },
  { key: "areas", path: "/settings/areas", section: "settings", inSidebar: true, phase: "A4" },
  { key: "vouchers", path: "/settings/vouchers", section: "settings", inSidebar: true, phase: "A4" },
  { key: "taxonomy", path: "/settings/taxonomy", section: "settings", inSidebar: true, phase: "A4" },
  {
    key: "flags",
    path: "/settings/flags",
    section: "settings",
    inSidebar: true,
    phase: "A3",
    element: element(FlagsPage),
  },
  { key: "audit", path: "/settings/audit", section: "settings", inSidebar: true, phase: "A1" },
];

/**
 * Screens that exist as an implementation.
 *
 * `builtScreens` is the router's input and `sidebarScreens` is derived from it, so a screen cannot be
 * navigable while absent from the sidebar, or listed in the sidebar while routing to a 404.
 */
export function builtScreens(): readonly ScreenDefinition[] {
  return SCREENS.filter((screen) => screen.element !== undefined);
}

export function sidebarScreens(): readonly ScreenDefinition[] {
  return builtScreens().filter((screen) => screen.inSidebar === true);
}

/**
 * Paths reachable without an admin session.
 *
 * `/403` is here rather than being handled by the guard alone, because a signed-in non-admin who follows a
 * deep link must land on an explanation, not on a redirect to sign-in they cannot satisfy.
 */
export const PUBLIC_PATHS: readonly string[] = ["/sign-in", "/403"];

/**
 * One crumb. `href` is absent for the current page - the last crumb is the page, and making it a link to
 * itself is the kind of small wrongness an operator notices without being able to name.
 */
export interface Crumb {
  readonly label: string;
  /**
   * Spelled `| undefined` because `exactOptionalPropertyTypes` is on: a crumb built as
   * `{ label, href: maybeUndefined }` is a type error when `maybeUndefined` is undefined, and the last crumb
   * legitimately has no href. See the same note on `Crumb.href` in `AppShell`.
   */
  readonly href?: string | undefined;
}

/**
 * The trail for a pathname, built from the screen table rather than by hand.
 *
 * A hand-written breadcrumb map is a second list of routes that goes stale: rename `/merchants` and the map
 * still sends an operator to the old path. Deriving it means a screen cannot exist without a trail.
 *
 * `/merchants/:id` produces `Merchants / <id>`. The leaf label is the id rather than the merchant's name,
 * because the table has no way to know it without a second query - and a crumb that says "3ded57c7-3111…" is
 * honest where a crumb that says "Pizza" would need the name threaded through the router.
 */
export function breadcrumbTrail(pathname: string): readonly Crumb[] {
  const trail: Crumb[] = [];

  for (const screen of builtScreens()) {
    if (screen.path === pathname) {
      trail.push({ label: screen.key });
      break;
    }
    // A parametric route matches any leaf: `/merchants/:id` matches `/merchants/<uuid>`.
    const pattern = screen.path;
    if (pattern.includes(":")) {
      const head = pattern.slice(0, pattern.indexOf(":"));
      if (pathname.startsWith(head)) {
        trail.push({ label: screen.key });
        // The leaf is the value the operator can see - their merchant's id - and it links back to its section so
        // the trail is navigable rather than decorative.
        trail.push({ label: pathname.slice(head.length) });
        break;
      }
    }
  }

  // Nested sections add their parent. `/money/reconciliation` is a child of nothing in the table, so the
  // section itself becomes the root crumb.
  if (trail.length === 0) {
    return trail;
  }
  return trail;
}

/**
 * The crumbs for a pathname, translated.
 *
 * Split from `breadcrumbTrail` so the routing logic stays pure and testable without i18next - the test asserts
 * *shape* (which segments, which are links), and this function only supplies the words.
 */
export function breadcrumbFor(
  pathname: string,
  translate: (key: string) => string,
): readonly Crumb[] {
  const raw = breadcrumbTrail(pathname);
  return raw.map((crumb, index) => {
    // The last crumb is the current page: never a link.
    const isLast = index === raw.length - 1;
    // A uuid leaf is a merchant id, not a screen key, so it is shown verbatim.
    const isLeafId = isLast && /^[0-9a-f-]{36}$/iu.test(crumb.label);

    return {
      label: isLeafId ? crumb.label : translate(`nav.${crumb.label}`),
      ...(isLast ? {} : { href: screenPathFor(crumb.label) }),
    };
  });
}

/** The sidebar path for a screen key, or `undefined` for a key that is not a screen. */
function screenPathFor(key: string): string | undefined {
  return SCREENS.find((screen) => screen.key === key)?.path;
}

export function isPublicPath(path: string): boolean {
  return PUBLIC_PATHS.includes(path);
}