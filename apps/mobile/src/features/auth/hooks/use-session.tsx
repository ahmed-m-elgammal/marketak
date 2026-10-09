/**
 * The session, and the profile gate that depends on it.
 *
 * One provider at the root, for the same reason `PanelUIProvider` is the only one: a second
 * subscription to `onAuthStateChange` means two token refreshers racing, and the loser's write
 * wins. This is the app's single source of truth for "who is signed in".
 *
 * The three states are explicit rather than a nullable session, because every screen branches on
 * them and a null-check at each call site is how a "flash of signed-out UI" bug is born:
 *
 * | State | Meaning | What the shopper sees |
 * |---|---|---|
 * | `loading` | Stored session is being restored from AsyncStorage | splash, already held |
 * | `signed-out` | No session | browse is still allowed; order is not |
 * | `signed-in` | Session exists; `profile` says whether the profile is complete | |
 */

import type { Session, User } from "@supabase/supabase-js";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import * as Linking from "expo-linking";
import { applyAuthCallback, signOut as signOutRequest } from "@/features/auth/api/sign-in";
import { identify, resetIdentity } from "@/services/analytics";
import { isAppError } from "@/services/errors/app-error";
import { completeProfile, fetchProfileStatus } from "@/services/rpc/api";
import type { ProfileStatus } from "@/services/rpc/dto";
import { supabase } from "@/services/supabase/client";

/** Who is signed in, independent of the profile. */
export type AuthSession =
  | { readonly status: "loading" }
  | { readonly status: "signed-out" }
  | { readonly status: "signed-in"; readonly user: User; readonly session: Session };

/** The three states a screen branches on: still restoring, no session, or a session. */
export type SessionState =
  | { readonly status: "loading" }
  | { readonly status: "signed-out" }
  | {
      readonly status: "signed-in";
      readonly user: User;
      readonly session: Session;
      readonly profile: ProfileStatus | null;
    };

export interface SessionContextValue {
  readonly state: SessionState;
  /** True when signed in and `profile_completed_at` is set. The gate for ordering. */
  readonly canOrder: boolean;
  readonly refreshProfile: () => Promise<void>;
  readonly submitProfile: (input: {
    firstName: string;
    lastName: string;
    phone: string;
  }) => Promise<void>;
  readonly signOut: () => Promise<void>;
}

const SessionContext = createContext<SessionContextValue | null>(null);

export function useSession(): SessionContextValue {
  const value = useContext(SessionContext);

  if (value === null) {
    throw new Error("useSession must be used inside <SessionProvider>.");
  }

  return value;
}

export function SessionProvider({ children }: { readonly children: ReactNode }): ReactNode {
  /**
   * Session and profile are separate states on purpose. Holding them together would make the
   * auth listener depend on the profile value, so every profile fetch would tear down and
   * rebuild the `onAuthStateChange` subscription — two token refreshers racing, which is the
   * exact bug this provider exists to prevent.
   */
  const [sessionState, setSessionState] = useState<AuthSession>({ status: "loading" });
  const [profile, setProfile] = useState<ProfileStatus | null>(null);

  /**
   * Guards the profile fetch. A shopper who signs out mid-flight must not have a stale profile
   * written back over the signed-out state.
   */
  const activeUserId = useRef<string | null>(null);

  const loadProfile = useCallback(async (userId: string) => {
    try {
      const next = await fetchProfileStatus();
      if (activeUserId.current === userId) setProfile(next);
    } catch (error) {
      // A failed profile read must not block the session. The shopper can still browse, and
      // ordering will be refused server-side with the real reason.
      if (activeUserId.current === userId && isAppError(error) && error.requiresSignIn) {
        setProfile(null);
      }
    }
  }, []);

  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      // TOKEN_REFRESHED fires routinely mid-session. Rebuilding state on it would discard and
      // refetch the profile on every refresh, so only the session-defining events are handled.
      if (event === "TOKEN_REFRESHED" || event === "USER_UPDATED") return;

      if (session === null) {
        activeUserId.current = null;
        setProfile(null);
        // Without this the next shopper's events attach to the previous shopper's identity on a
        // shared device, which is both wrong data and a privacy leak.
        resetIdentity();
        setSessionState({ status: "signed-out" });
        return;
      }

      activeUserId.current = session.user.id;
      // Analytics identity is the Supabase user id and nothing else - no email, no phone, no name.
      identify(session.user.id);
      setSessionState({ status: "signed-in", user: session.user, session });
      void loadProfile(session.user.id);
    });

    return () => {
      data.subscription.unsubscribe();
    };
  }, [loadProfile]);

  /**
   * The OAuth callback arrives as a deep link while no screen is mounted, so the provider owns
   * it. `applyAuthCallback` triggers `onAuthStateChange`, which updates state above.
   */
  useEffect(() => {
    const handleUrl = (url: string | null): void => {
      if (url !== null && url.startsWith("marketak://auth/callback")) void applyAuthCallback(url);
    };

    void Linking.getInitialURL().then(handleUrl);
    const subscription = Linking.addEventListener("url", (event) => handleUrl(event.url));

    return () => subscription.remove();
  }, []);

  const refreshProfile = useCallback(async () => {
    if (activeUserId.current === null) return;
    await loadProfile(activeUserId.current);
  }, [loadProfile]);

  const submitProfile = useCallback(
    async (input: { firstName: string; lastName: string; phone: string }) => {
      const next = await completeProfile(input);
      setProfile(next);
    },
    [],
  );

  const signOut = useCallback(async () => {
    await signOutRequest();
  }, []);

  const value = useMemo<SessionContextValue>(() => {
    if (sessionState.status !== "signed-in") {
      const state: SessionState = sessionState;
      return { state, canOrder: false, refreshProfile, submitProfile, signOut };
    }

    const state: SessionState = { ...sessionState, profile };
    return {
      state,
      canOrder: profile?.can_order === true,
      refreshProfile,
      submitProfile,
      signOut,
    };
  }, [sessionState, profile, refreshProfile, submitProfile, signOut]);

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}