/**
 * `lib/auth` - sign in, sign out, and who the operator is.
 *
 * ## The distinction this module exists to keep
 *
 * Three states, not two, and collapsing any two of them produces a bug that is hard to diagnose:
 *
 * | State | Cause | Where it goes |
 * |---|---|---|
 * | `pending` | session not read yet | the shell skeleton |
 * | `signed-out` | no session | `/sign-in` |
 * | `not-admin` | a session, no `admin` role | `/403` |
 * | `admin` | a session and `user_roles.role = 'admin'` | the app |
 *
 * The one that gets collapsed is `signed-out` into `not-admin`. Both mean "you cannot see this", so both
 * redirect to the same place in most implementations, and the result is an infinite loop: a signed-out
 * operator is bounced to `/sign-in`, signs in, lands back, is bounced again — because the guard never asked
 * the right question. Asking "do I have a session?" before "am I an admin?" is the whole fix.
 *
 * ## Why the role comes from the database and not the JWT
 *
 * `private.is_admin()` is the only thing the RPCs trust, and it reads `user_roles` on every call. If the
 * console believed a role from a decoded JWT it would render admin screens and then receive
 * `NOT_AUTHORIZED` from every mutation. The console's job is to avoid *showing* what the operator cannot
 * *do* — never to decide what they may do.
 *
 * ## Google only
 *
 * constitution rule 18, as scoped in `decisions.md`: no email, no password, no phone OTP. There is exactly
 * one `signIn` path and it takes no arguments, so there is no way to add another.
 */

import type { Session } from "@supabase/supabase-js";

import { getSupabase } from "./supabase-client.js";
import { DEMO_SESSION, isDemoMode } from "./demo.js";
import { toFriendlyError, type FriendlyError } from "./errors.js";

/** Where Google sends the browser back to. Must match Supabase → URL Configuration exactly. */
export const AUTH_CALLBACK_PATH = "/auth/callback";

/** The three states above, as one value. Named so a reviewer can see the distinction is deliberate. */
export type AuthStatus = "pending" | "signed-out" | "not-admin" | "admin";

/** Reads the current session. Throws a `ConfigError` if the environment is missing the anon key. */
export async function getSession(): Promise<Session | null> {
  if (isDemoMode()) {
    return DEMO_SESSION as unknown as Session;
  }
  const { data, error } = await getSupabase().auth.getSession();
  // A failure here is not "signed out" - it is a misconfigured client, and reporting it as signed out
  // would show an operator a sign-in button that can never work.
  if (error !== null) {
    throw error;
  }
  return data.session;
}

/**
 * Starts the Google sign-in.
 *
 * `flowType: "pkce"` rather than the implicit flow: PKCE stores the verifier in local storage and never
 * exposes a token in the URL fragment, so a shared laptop cannot leak a session through browser history.
 * `detectSessionInUrl: false` is set on the client because this app has no `/auth/callback` route of its
 * own - Supabase consumes the code at `/auth/v1/callback` and the session is then read from storage.
 *
 * Throws rather than returning a result, because every caller wants to do the same thing on failure: show
 * the operator why the button did nothing.
 */
export async function signInWithGoogle(redirectTo: string): Promise<void> {
  const { error } = await getSupabase().auth.signInWithOAuth({
    provider: "google",
    options: { redirectTo, scopes: "openid email profile" },
  });
  if (error !== null) {
    throw error;
  }
}

/** Signs out and clears the cached session. Used by the shell's sign-out control. */
export async function signOut(): Promise<void> {
  if (isDemoMode()) {
    return;
  }
  const { error } = await getSupabase().auth.signOut();
  if (error !== null) {
    throw error;
  }
}

/**
 * Subscribes to session changes.
 *
 * Returns an unsubscribe function so React's effect cleanup can call it; without that, every mount leaks a
 * listener and a long-lived console tab accumulates hundreds of them.
 *
 * The callback fires on every token refresh, which is why `useSession` below keys its state by `user.id`
 * rather than storing the session object and comparing.
 */
export function onSessionChange(handler: (session: Session | null) => void): () => void {
  const { data } = getSupabase().auth.onAuthStateChange((_event, session) => {
    handler(session);
  });
  return () => {
    data.subscription.unsubscribe();
  };
}

/**
 * Turns whatever the auth layer returned into one of the four states.
 *
 * Pure and exported so it can be tested without a browser, a network, or a Supabase client - which is the
 * only way to cover the four-way branch exhaustively without standing up four live sessions.
 *
 * `session` is `undefined` while it has not been read yet, and `null` once it has been read and found
 * empty. Collapsing those two is the bug this signature exists to prevent: with only `Session | null`, a
 * signed-out operator is indistinguishable from one still loading, and the guard redirects them to
 * `/sign-in` before it has asked the question.
 */
export function resolveAuthStatus(input: {
  readonly session: Session | null | undefined;
  readonly roleQuery: { readonly isPending: boolean; readonly isError: boolean; readonly isAdmin: boolean };
}): AuthStatus {
  if (input.session === undefined) {
    return "pending";
  }
  if (input.session === null) {
    return "signed-out";
  }
  if (input.roleQuery.isPending) {
    return "pending";
  }
  // A failed role read is treated as not-admin. That is deliberately the *failing closed* direction: showing
  // admin controls to someone we could not verify is worse than showing a 403 to someone who was about to be
  // allowed in. The 403 page says to ask an admin, which is the correct next step either way.
  if (input.roleQuery.isError) {
    return "not-admin";
  }
  return input.roleQuery.isAdmin ? "admin" : "not-admin";
}

/** Wraps a thrown value as a `FriendlyError`, for a caller that has no `useTranslation`. */
export function authError(error: unknown): FriendlyError {
  return toFriendlyError(error);
}