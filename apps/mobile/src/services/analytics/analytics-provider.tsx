/**
 * Mounts the PostHog context once. The client is a module singleton rather than the SDK provider's
 * inline init, which re-initialises on every mount and can drop the offline queue when the layout
 * re-renders.
 */

import { PostHogProvider } from "posthog-react-native";
import { useEffect, type ReactNode } from "react";
import { AppState } from "react-native";
import { flush, rawClient } from "@/services/analytics";

export function AnalyticsProvider({ children }: { readonly children: ReactNode }): ReactNode {
  useEffect(() => {
    // iOS suspends the process shortly after background, so flush on the transition itself rather
    // than on blur.
    const subscription = AppState.addEventListener("change", (status) => {
      if (status !== "active") flush();
    });

    return () => subscription.remove();
  }, []);

  const client = rawClient();
  // A missing phc_ key must not stop somebody ordering food.
  if (client === null) return <>{children}</>;

  // autocapture={false}: screen-view and touch capture off, so nothing is sent without an
  // explicit capture call. captureAppLifecycleEvents stays at its default — app-opened and
  // app-backgrounded explain every drop-off and carry no personal data.
  return (
    <PostHogProvider client={client} autocapture={false}>
      {children}
    </PostHogProvider>
  );
}