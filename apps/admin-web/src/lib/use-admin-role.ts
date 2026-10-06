/**
 * `lib/use-admin-role` - is this operator an admin?
 *
 * ## Why it reads `user_roles` rather than trusting a claim
 *
 * The role lives in `public.user_roles`, and `private.is_admin()` is the only thing that reads it - the RPCs
 * guard themselves, so a console that believed a client-supplied `role` would render admin screens and then
 * get `NOT_AUTHORIZED` from every mutation. The console's job is to *avoid showing* what the operator cannot
 * do, not to decide what they may.
 *
 * The policy on `user_roles` is `(user_id = auth.uid()) or is_admin()`, so a signed-in operator can read
 * their own row and nothing else. That is exactly the query this makes.
 *
 * ## Why `revoked_at` is checked here and not in SQL
 *
 * `private.is_admin()` filters on `revoked_at is null`, so a revoked admin row exists with a timestamp. This
 * hook filters identically. Two places checking the same condition is the duplication to avoid - but the
 * alternative is a `security definer` RPC that exists only to answer a boolean, and a narrower grant is
 * worth more than the duplication. The comment here exists so the two stay in step.
 */

import { useQuery } from "@tanstack/react-query";
import { getSupabase } from "./supabase-client.js";

export interface AdminRole {
  readonly isAdmin: boolean;
  readonly isPending: boolean;
  /** True once the session is known to be absent. Distinguishes "not an admin" from "not signed in". */
  readonly isSignedOut: boolean;
}

interface UserRoleRow {
  readonly role: string;
  readonly revoked_at: string | null;
}

export function useAdminRole(): AdminRole {
  const session = useQuery({
    queryKey: ["admin-session"],
    queryFn: async () => {
      const supabase = getSupabase();
      const { data } = await supabase.auth.getSession();
      return data.session;
    },
  });

  const role = useQuery({
    queryKey: ["admin-role", session.data?.user.id ?? "anon"],
    // Disabled rather than returning early: `useQuery` handles the disabled state and reports
    // `isPending: true`, which is what the guard renders while it waits.
    enabled: session.data !== null && session.data !== undefined,
    queryFn: async () => {
      const supabase = getSupabase();
      const userId = session.data?.user.id;
      if (userId === undefined) {
        return false;
      }
      const { data, error } = await supabase
        .from("user_roles")
        .select("role, revoked_at")
        .eq("user_id", userId);

      if (error !== null) {
        // A failed read must not read as "not an admin" without saying so. The guard treats any error as
        // not-admin, which locks the operator out rather than showing them controls that will fail.
        throw error;
      }

      const rows = (data ?? []) as UserRoleRow[];
      return rows.some((row) => row.role === "admin" && row.revoked_at === null);
    },
  });

  return {
    isPending: session.isPending || role.isPending,
    isAdmin: role.data === true,
    isSignedOut: session.data === null || session.data === undefined,
  };
}
