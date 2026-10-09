/**
 * PostHog boundary, mounted once at the root.
 *
 * This is `PostHogProvider` from the SDK docs, but it is wrapped rather than used directly because
 * of one behavioural difference: the SDK's `PostHogProvider` calls `init()` internally on every
 * mount. Mounted inside the root navigator, that means every navigation-driven re-render of the
 * layout tree re-initialises the client and can drop the offline queue.
 *
 * So the client is built once in `@/services/analytics/posthog` (a module singleton) and this
 * provider only supplies the context and lifecycle that the SDK's hooks read. Same behaviour, one
 * initialisation.
 *
 * ## Why a wrapper and not the SDK component inline in `_layout.tsx`
 *
 * `_layout.tsx` is a provider list. The moment analytics needs to flush on background, reset on
 * sign-out, or respect a debug flag, that logic would start accumulating in the layout. It lives
 * here instead, so the layout stays a list and the analytics rules stay testable.
 */

import { PostHogProvider } from "posthog-react-native";
import { useEffect, type ReactNode } from "react";
import { AppState } from "react-native";
import { flush, rawClient } from "@/services/analytics";

export function AnalyticsProvider({ children }: { readonly children: ReactNode }): ReactNode {
  /**
   * Flush when the app leaves the foreground.
   *
   * iOS suspends the process shortly after `background`, so anything still in the in-memory queue
   * is lost. Flushing on the transition — not on `blur` — is what gets events out in time.
   */
  useEffect(() => {
    const subscription = AppState.addEventListener("change", (status) => {
      if (status !== "active") flush();
    });

    return () => subscription.remove();
  }, []);

  // The SDK provider requires a client instance. The null case is the analytics-off build; it is
  // rendered as plain children rather than crashing, because a missing phc_ key must not stop a
  // shopper ordering food.
  const client = rawClient();
  if (client === null) return <>{children}</>;

  return (
    // autocapture={false} disables screen-view and touch capture. Nothing is recorded without an
    // explicit capture() call. captureAppLifecycleEvents is deliberately left at its default, so
    // app-opened and app-backgrounded still arrive - see the header of posthog.ts.
    <PostHogProvider client={client} autocapture={false}>
      {children}
    </PostHogProvider>
  );
}