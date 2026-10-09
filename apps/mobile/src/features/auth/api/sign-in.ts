/**
 * Google and Apple sign-in. The only two providers this app has.
 *
 * Constitution 18: no email, no password, no phone OTP. A user without `profile_completed_at` may
 * browse but cannot order — the gate is enforced by `place_order_v1`, and `ProfileStatus` only
 * tells the UI which screen to show.
 *
 * Both providers end in the same place: a Supabase session persisted to AsyncStorage. The
 * `on_auth_user_created` trigger on `auth.users` writes `public.users` and the `customer` role,
 * so nothing here creates a profile row.
 */

import * as AppleAuthentication from "expo-apple-authentication";
import * as Crypto from "expo-crypto";
import * as WebBrowser from "expo-web-browser";
import { Platform } from "react-native";
import { supabase } from "@/services/supabase/client";

/** Deep-link scheme from `app.json`, where the OAuth callback returns. */
const REDIRECT_TO = "marketak://auth/callback";

export const AUTH_PROVIDERS = {
  google: "google",
  apple: "apple",
} as const;

export type AuthProvider = (typeof AUTH_PROVIDERS)[keyof typeof AUTH_PROVIDERS];

/**
 * Outcome of a sign-in attempt.
 *
 * `cancelled` is separated from `failed` because a shopper who dismisses the consent sheet did
 * not encounter an error and must not be shown one.
 */
export type SignInResult = "signed-in" | "cancelled" | "failed";

/**
 * Opens the provider's consent screen and reports how it ended.
 *
 * `maybeCompleteAuthSession` closes the in-app browser on iOS, where `dismissAuthSession` alone
 * leaves the sheet on screen. A dismissal resolves as `cancelled`, not as an exception.
 */
async function openAuthSession(url: string): Promise<"cancelled" | "returned"> {
  // Synchronous in this SDK version. The await was there defensively, but awaiting a non-promise
  // is a lint error and buys nothing - if a later SDK makes it async the await returns anyway.
  WebBrowser.maybeCompleteAuthSession();

  try {
    const result = await WebBrowser.openAuthSessionAsync(url, REDIRECT_TO);
    return result.type === "success" ? "returned" : "cancelled";
  } catch {
    return "cancelled";
  }
}

/**
 * Signs in with Google through the system browser.
 *
 * `skipBrowserRedirect` is required: React Native has no page load for supabase-js to attach its
 * redirect handler to. The callback instead arrives on the deep link, which the session provider
 * picks up and hands to `applyAuthCallback`.
 */
export async function signInWithGoogle(): Promise<SignInResult> {
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: AUTH_PROVIDERS.google,
    options: { redirectTo: REDIRECT_TO, skipBrowserRedirect: true },
  });

  if (error !== null || data === null || data.url === null) return "failed";
  return runOAuthRedirect(data.url);
}

/**
 * Signs in with Sign in with Apple.
 *
 * On iOS this uses the native sheet, which Apple requires whenever an app offers other
 * third-party sign-ins; a web view would get the app rejected. Other platforms have no native
 * flow and take the same OAuth path as Google.
 */
export async function signInWithApple(): Promise<SignInResult> {
  if (Platform.OS !== "ios") return runOAuth(AUTH_PROVIDERS.apple);

  try {
    const credential = await AppleAuthentication.signInAsync({
      requestedScopes: [
        AppleAuthentication.AppleAuthenticationScope.FULL_NAME,
        AppleAuthentication.AppleAuthenticationScope.EMAIL,
      ],
    });

    if (typeof credential.identityToken !== "string") return "cancelled";

    const { error } = await supabase.auth.signInWithIdToken({
      provider: AUTH_PROVIDERS.apple,
      token: credential.identityToken,
      nonce: Crypto.randomUUID(),
    });

    return error === null ? "signed-in" : "failed";
  } catch {
    // The native sheet throws when the shopper dismisses it, which is a cancellation.
    return "cancelled";
  }
}

/** Shared OAuth path: build the URL, open the browser, apply the callback. */
async function runOAuth(provider: AuthProvider): Promise<SignInResult> {
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider,
    options: { redirectTo: REDIRECT_TO, skipBrowserRedirect: true },
  });

  if (error !== null || data === null || data.url === null) return "failed";
  return runOAuthRedirect(data.url);
}

async function runOAuthRedirect(url: string): Promise<SignInResult> {
  const outcome = await openAuthSession(url);
  return outcome === "cancelled" ? "cancelled" : "signed-in";
}

/**
 * Applies the deep link that carries the OAuth result.
 *
 * supabase-js reads the tokens itself from either the query string or the fragment, so the whole
 * URL is passed through rather than being parsed here. Its `onAuthStateChange` listener then
 * fires and the session provider picks up the new session, which is why this reports only
 * whether the URL was plausible.
 */
export async function applyAuthCallback(callbackUrl: string): Promise<void> {
  await supabase.auth.exchangeCodeForSession(callbackUrl).catch(() => undefined);
}

/**
 * Signs out and clears the persisted session.
 *
 * A network failure still clears local state: a shopper who asked to sign out must end up signed
 * out on this device whether or not the server answered.
 */
export async function signOut(): Promise<void> {
  await supabase.auth.signOut().catch(() => undefined);
}