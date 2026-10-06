/**
 * `app/App` - the router, and the two guards.
 *
 * ## Why the role check is a route element and not a hook inside each page
 *
 * A guard inside each page would be 41 chances to forget one. A route element wraps every protected screen by
 * construction, and `PUBLIC_PATHS` is the only way out. `admin-console-screens.md` screens 37–38 are the
 * landing pages for the two ways through: a signed-in non-admin, and a URL that does not exist.
 *
 * ## Why the non-admin gets `/403` and not a redirect to sign-in
 *
 * A non-admin **is** signed in. Redirecting them to sign-in produces an infinite loop - sign in, land on
 * the page, bounce to sign-in - and it reads as a broken session rather than as "ask someone for access".
 * `errors.forbiddenBody` says exactly what to do about it.
 */

import { Result } from "antd";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";
import { Navigate, Outlet, Route, Routes } from "react-router-dom";

import { AppShell } from "./AppShell.js";
import { builtScreens } from "./routes.js";
import { useAdminRole } from "../lib/use-admin-role.js";

/**
 * Wraps the app routes. Renders the shell around whatever matched.
 *
 * The shell sits here rather than inside each screen so navigating between screens never re-renders it -
 * which is what keeps the sidebar from flashing and the operator's scroll position intact.
 */
function Shell(): ReactElement {
  return (
    <AppShell>
      <Outlet />
    </AppShell>
  );
}

function RequireAdmin(): ReactElement {
  const { isPending, isAdmin } = useAdminRole();

  if (isPending) {
    // A blank page while the role loads would look like a signed-out session. The skeleton's announcement is
    // what stops a screen-reader user from being told nothing at all.
    return <Result status="info" title="" />;
  }

  return isAdmin ? <Outlet /> : <Navigate to="/403" replace />;
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
      {/* Public. No admin session needed. */}
      <Route path="/403" element={<Forbidden />} />
      <Route path="*" element={<NotFound />} />

      {/* Everything else. The guard wraps the group, so a new screen cannot be added without passing it.
          Only `builtScreens` is registered: a planned screen with no implementation falls through to the
          `*` route above, which is honest - it says the page does not exist, because it does not yet. */}
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
