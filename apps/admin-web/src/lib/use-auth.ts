/**
 * `lib/use-auth` - who is signed in, and are they an admin.
 *
 * ## The session lives in the query cache, with exactly one subscriber
 *
 * The obvious implementation calls `onAuthStateChange` inside `useSession`, which means every caller opens
 * its own subscription. With `useAuthStatus` reading both the session and the role, and the role hook reading
 * the session, that is two subscriptions and two copies of the same state that can disagree - the role hook
 * could see a signed-in session while the guard still saw the old one, and the screen would flash.
 *
 * So: the session is a React Query entry, and `providers.tsx` holds the single `onAuthStateChange` listener
 * that writes into it. Every reader shares one cached value and there is nothing to keep in sync.
 *
 * ## `staleTime: Infinity`
 *
 * The session is pushed to us, not fetched-and-cached. A 30-second staleness window - which is right for the
 * dashboard's data queries - would mean a signed-out operator kept a stale in-memory session for half a
 * minute after signing out.
 */

import { useQuery } from "@tanstack/react-query";
import type { Session } from "@supabase/supabase-js";

import { resolveAuthStatus, type AuthStatus } from "./auth.js";
import { getSupabase } from "./supabase-client.js";

/** The query key the single provider-side subscription writes to. Exported so both agree. */
export const SESSION_QUERY_KEY = ["auth", "session"] as const;

/**
 * The current session: a `Session`, `null` when signed out, or `undefined` while loading.
 *
 * `undefined` and `null` are deliberately different. `undefined` means "not asked yet"; `null` means "asked
 * and found empty". Collapsing them makes a signed-out operator indistinguishable from one still loading.
 */
export function useSession(): Session | null | undefined {
  return useQuery({
    queryKey: SESSION_QUERY_KEY,
    queryFn: async (): Promise<Session | null> => {
      const { data, error } = await getSupabase().auth.getSession();
      if (error !== null) {
        // Not the same as "signed out". A misconfigured client reports a failed read here, and reporting that
        // as an empty session would show an operator a sign-in button that can never work.
        throw error;
      }
      return data.session;
    },
    staleTime: Number.POSITIVE_INFINITY,
    retry: false,
  }).data;
}

/** One admin role row. `private.is_admin()` filters on `revoked_at is null`, so this does too. */
interface RoleRow {
  readonly role: string;
  readonly revoked_at: string | null;
}

/**
 * Is the signed-in user an admin?
 *
 * Reads `user_roles` through RLS, whose policy is `(user_id = auth.uid()) or is_admin()` - an operator can read
 * their own row and nothing else. `enabled` only once a session exists: querying earlier sends an
 * unauthenticated request that returns nothing, and `isAdmin` would then report a definitive "no".
 */
export function useIsAdmin(): {
  readonly isPending: boolean;
  readonly isError: boolean;
  readonly isAdmin: boolean;
} {
  const session = useSession();
  const isSignedIn = session !== undefined && session !== null;

  const query = useQuery({
    queryKey: ["auth", "role", session?.user.id ?? null],
    enabled: isSignedIn,
    queryFn: async () => {
      const userId = session?.user.id;
      if (userId === undefined) {
        return false;
      }
      const { data, error } = await getSupabase()
        .from("user_roles")
        .select("role, revoked_at")
        .eq("user_id", userId);

      if (error !== null) {
        throw error;
      }
      const rows = (data ?? []) as RoleRow[];
      return rows.some((row) => row.role === "admin" && row.revoked_at === null);
    },
  });

  return {
    // Not pending when there is no session: there is no role query to wait for, and reporting "pending"
    // forever is what makes a signed-out operator stare at a skeleton.
    isPending: isSignedIn && query.isPending,
    isError: query.isError,
    isAdmin: query.data === true,
  };
}

/**
 * The one value the route guard needs. Both hooks are called here so a screen cannot read the session but
 * not the role and get a state that disagrees with the guard's.
 */
export function useAuthStatus(): AuthStatus {
  const session = useSession();
  const roleQuery = useIsAdmin();
  return resolveAuthStatus({ session, roleQuery });
}