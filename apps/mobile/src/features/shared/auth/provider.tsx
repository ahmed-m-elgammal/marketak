/**
 * Auth provider (mobile README §1, §6). Mounted once at the root; holds the
 * single session subscriber and no business logic. Gates consume
 * `useSession()` / `useRole()`; they never compute them here.
 *
 * Session changes also re-identify analytics (F-08): Analytics identity
 * clears on sign-out; Crashlytics keeps the last id by SDK design (noted
 * in `services/analytics/firebase.ts`).
 */
import { useEffect, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { subscribeSession } from "../../../services/auth/session";
import { firebaseBackend } from "../../../services/analytics/firebase";
import { createTelemetry } from "../../../services/analytics/provider";
import { useSession } from "./use-session";

export function AuthProvider({ children }: { readonly children: ReactNode }): ReactNode {
  const queryClient = useQueryClient();
  const { session } = useSession();
  useEffect(() => subscribeSession(queryClient), [queryClient]);
  useEffect(() => {
    createTelemetry(firebaseBackend()).identify(session?.userId ?? null);
  }, [session]);
  return children;
}
