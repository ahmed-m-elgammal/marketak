/**
 * Session as server state (mobile README §6, R5).
 *
 * The session is a TanStack Query (`['session']`), not a store value — a
 * session in `state/` would be a second source of truth that drifts. This
 * module owns the Supabase Auth seam and the single subscriber that keeps
 * the query in sync; the hook (`features/shared/auth/use-session.ts`)
 * only reads.
 */
import type { QueryClient } from "@tanstack/react-query";
import { AppError } from "@marketak/shared";
import { getSupabaseClient, type AppSupabaseClient } from "../supabase/client";
import { sessionKey } from "../cache/query-keys";

export interface SessionInfo {
  readonly userId: string;
}

/** The Auth surface this layer needs — injected in tests, Supabase in prod. */
export interface SessionBackend {
  getSessionUserId(): Promise<string | null>;
  onSessionChange(callback: (userId: string | null) => void): { unsubscribe(): void };
  signOut(): Promise<void>;
}

export function supabaseSessionBackend(client: AppSupabaseClient): SessionBackend {
  return {
    async getSessionUserId(): Promise<string | null> {
      const { data } = await client.auth.getSession();
      return data.session?.user.id ?? null;
    },
    onSessionChange(callback: (userId: string | null) => void): { unsubscribe(): void } {
      const { data } = client.auth.onAuthStateChange((_event, session) => {
        callback(session?.user.id ?? null);
      });
      return {
        unsubscribe(): void {
          data.subscription.unsubscribe();
        },
      };
    },
    async signOut(): Promise<void> {
      const { error } = await client.auth.signOut();
      if (error !== null) throw new AppError("business", null, error.message, error);
    },
  };
}

function defaultBackend(): SessionBackend {
  return supabaseSessionBackend(getSupabaseClient());
}

export async function fetchSession(backend?: SessionBackend): Promise<SessionInfo | null> {
  const userId = await (backend ?? defaultBackend()).getSessionUserId();
  return userId === null ? null : { userId };
}

/**
 * The one session subscriber (provider mounts it once). Seeds `['session']`
 * from storage, then mirrors every Auth change into the query — including
 * `null` on sign-out, which is what routes to sign-in without a loop.
 */
export function subscribeSession(queryClient: QueryClient, backend?: SessionBackend): () => void {
  const resolved = backend ?? defaultBackend();
  void fetchSession(resolved).then((session) => {
    queryClient.setQueryData(sessionKey(), session);
  });
  const subscription = resolved.onSessionChange((userId) => {
    queryClient.setQueryData(sessionKey(), userId === null ? null : { userId });
  });
  return () => subscription.unsubscribe();
}
