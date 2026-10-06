/**
 * `app/App` - the router, and the guard.
 *
 * ## One guard, wrapping a group
 *
 * A guard inside each page would be one chance per screen to forget one. A route element wraps every
 * protected screen by construction, and `PUBLIC_PATHS` is the only way out.
 *
 * ## Where each failure state lands, and why the two must differ
 *
 * | State | Lands on |
 * |---|---|
 * | no session yet | the skeleton |
 * | no session | `/sign-in` |
 * | session, no `admin` role | `/403` |
 * | session and `admin` | the app |
 *
 * Both "no session" and "no admin" mean *you cannot see this*, so the tempting implementation sends both to
 * one destination. That produces an infinite loop in both directions: a signed-out operator is bounced to
 * `/sign-in`, signs in, lands back on their deep link and is bounced again — because the guard was checking
 * the role and never asked whether a session existed. A signed-in non-admin sent to `/sign-in` is just as
 * broken: they authenticate successfully, arrive back, and are bounced forever.
 *
 * `resolveAuthStatus` is a pure function precisely so all four branches are unit-tested, because the loop only
 * shows up at runtime with a real session and a real router.
 */

import { Result } from "antd";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";
import { Navigate, Outlet, Route, Routes } from "react-router-dom";

import { AppShell } from "./AppShell.js";
import { builtScreens } from "./routes.js";
import { PageSkeleton } from "../components/PageSkeleton.js";
import { useAuthStatus } from "../lib/use-auth.js";
import SignInPage from "../features/auth/SignInPage.js";

/**
 * Wraps the app routes, so navigating between screens never re-renders the shell — which is what keeps the
 * sidebar from flashing and the operator's scroll position intact.
 */
function Shell(): ReactElement {
  return (
    <AppShell>
      <Outlet />
    </AppShell>
  );
}

/**
 * The guard every protected screen passes through.
 *
 * `noImplicitReturns` is what makes the switch exhaustive: add a fifth state to `AuthStatus` and this
 * function stops returning on every path, which is a compile error. A helper function whose only purpose was
 * to assert that was written and then deleted as dead code — the compiler already says it.
 */
function RequireAdmin(): ReactElement {
  const status = useAuthStatus();

  switch (status) {
    case "pending":
      // The session has not been read yet. Redirecting now would send an operator who is about to be
      // authenticated to the sign-in page, which is the flashiest version of the loop above.
      return <PageSkeleton />;
    case "signed-out":
      return <Navigate to="/sign-in" replace />;
    case "not-admin":
      return <Navigate to="/403" replace />;
    case "admin":
      return <Outlet />;
  }
}

function Forbidden(): ReactElement {
  const { t } = useTranslation();
  return <Result status="403" title={t("errors.forbiddenTitle")} subTitle={t("errors.forbiddenBody")} />;
}

function NotFound(): ReactElement {
  const { t } = useTranslation();
  return <Result status="404" title={t("errors.notFoundRoute")} />;
}

export function App(): ReactElement {
  return (
    <Routes>
      {/* Public. Reachable without a session, so a signed-out operator has somewhere to land. */}
      <Route path="/sign-in" element={<SignInPage />} />
      <Route path="/403" element={<Forbidden />} />

      {/* A screen that does not exist. Declared before the guard so an unknown URL does not first bounce
          through `/sign-in` on its way to a 404 — the operator would see a login page for a typo. */}
      <Route path="*" element={<NotFound />} />

      {/* Everything else. Only `builtScreens` is registered: a planned screen with no implementation is not
          a route, so it falls through to the `*` above, which is honest — it says the page does not exist,
          because it does not yet. */}
      <Route element={<RequireAdmin />}>
        <Route element={<Shell />}>
          {builtScreens().map((screen) => (
            <Route key={screen.key} path={screen.path} element={screen.element ?? <NotFound />} />
          ))}
        </Route>
      </Route>
    </Routes>
  );
}