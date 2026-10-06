/**
 * `features/auth/AuthCallbackPage` - where Google sends the browser back to.
 *
 * ## Why this route has to exist
 *
 * `signInWithGoogle` sends `redirectTo` to `/auth/callback`, and supabase-js only settles the session once the
 * app has loaded at that path. The first version had **no route for it**, so the catch-all `*` matched and
 * rendered "That page does not exist" — which is exactly what happened on the first real login.
 *
 * Worth remembering as a shape of bug: the route table looked complete, every screen resolved, and `verify` was
 * green. Only completing a real sign-in revealed that the one URL the whole flow depends on had no handler.
 *
 * ## Why it waits instead of redirecting on the first frame
 *
 * `detectSessionInUrl: true` makes supabase-js read the URL **asynchronously** during client setup. A
 * `<Navigate to="/" />` on the first frame redirects before the exchange finishes, the guard finds no session,
 * and bounces back here — an infinite loop between two routes. So this page holds position and navigates only
 * once `useAuthStatus` actually reports one.
 */

import { useQuery } from "@tanstack/react-query";
import { useEffect, useState, type ReactElement } from "react";
import { useTranslation } from "react-i18next";
import { Navigate } from "react-router-dom";

import { EmptyState } from "../../components/StateBlock.js";
import { PageSkeleton } from "../../components/PageSkeleton.js";
import { getSession, type AuthStatus } from "../../lib/auth.js";
import { useAuthStatus } from "../../lib/use-auth.js";

/** Re-read storage on this cadence while waiting for the exchange to land. */
const POLL_INTERVAL_MS = 400;

/** Give up after this long with no session: the code was missing, expired, or already redeemed. */
const GRACE_MS = 4_000;

export type CallbackDestination = "home" | "forbidden" | "waiting" | "expired";

/**
 * Where the callback page should send the operator, given what is known right now.
 *
 * Pure, and therefore the part worth testing: the component around it is just polling and rendering.
 *
 * The subtle case is `waiting` with a session already present. `getSession` can return a session before
 * `AuthBridge` has written it into the cache and the role query has resolved, and `status` is still `pending` at
 * that moment. Navigating on `status === "signed-out"` alone would read as failure and bounce to sign-in — and
 * because the URL fragment has been consumed by then, the second attempt has nothing left to exchange. So a
 * present session always wins over `expired`, even when the grace period has passed.
 */
export function callbackDestination(input: {
  readonly status: AuthStatus;
  readonly hasSession: boolean;
  readonly expired: boolean;
}): CallbackDestination {
  if (input.status === "admin") {
    return "home";
  }
  if (input.status === "not-admin") {
    return "forbidden";
  }
  if (input.hasSession) {
    return "waiting";
  }
  return input.expired ? "expired" : "waiting";
}

export default function AuthCallbackPage(): ReactElement {
  const { t } = useTranslation();
  const status = useAuthStatus();

  const settle = useQuery({
    queryKey: ["auth", "callback-settle"],
    queryFn: getSession,
    refetchInterval: POLL_INTERVAL_MS,
    staleTime: 0,
  });

  // Armed once on mount and never re-armed. Re-arming on each poll result would restart the clock every
  // 400 ms and the page would wait forever.
  const [expired, setExpired] = useState(false);
  useEffect(() => {
    const timer = window.setTimeout(() => setExpired(true), GRACE_MS);
    return () => window.clearTimeout(timer);
  }, []);

  const destination = callbackDestination({
    status,
    hasSession: settle.data !== undefined && settle.data !== null,
    expired,
  });

  if (destination === "home") {
    return <Navigate to="/" replace />;
  }
  if (destination === "forbidden") {
    return <Navigate to="/403" replace />;
  }
  if (destination === "expired") {
    return (
      <EmptyState
        title={t("auth.callbackFailed")}
        hint={t("auth.callbackFailedHint")}
        action={{ label: t("auth.backToSignIn"), onClick: () => window.location.assign("/sign-in") }}
      />
    );
  }
  return <PageSkeleton />;
}