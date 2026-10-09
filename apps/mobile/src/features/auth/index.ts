/**
 * The auth feature's public surface.
 *
 * `.dependency-cruiser.cjs` rule 3 forbids reaching past this barrel. A route imports
 * `useSession` from `@/features/auth`; it never imports the provider file directly.
 */

export { SessionProvider, useSession } from "@/features/auth/hooks/use-session";
export type { AuthSession, SessionContextValue, SessionState } from "@/features/auth/hooks/use-session";

export { signInWithApple, signInWithGoogle, signOut } from "@/features/auth/api/sign-in";
export type { AuthProvider, SignInResult } from "@/features/auth/api/sign-in";