export { SessionProvider, useSession } from "@/features/auth/hooks/use-session";
export type { AuthSession, SessionContextValue, SessionState } from "@/features/auth/hooks/use-session";

export { signInWithApple, signInWithGoogle, signOut } from "@/features/auth/api/sign-in";
export type { AuthProvider, SignInResult } from "@/features/auth/api/sign-in";

export { useSignIn } from "@/features/auth/hooks/use-sign-in";
export type { SignInPhase, UseSignIn } from "@/features/auth/hooks/use-sign-in";

// Screens are re-exported so a route can use the barrel, but every screen imports a sibling path
// instead. A screen importing the barrel that re-exports it is a cycle.
export { WelcomeScreen } from "@/features/auth/screens/WelcomeScreen";
export { SignInScreen } from "@/features/auth/screens/SignInScreen";
export { CompleteProfileScreen } from "@/features/auth/screens/CompleteProfileScreen";