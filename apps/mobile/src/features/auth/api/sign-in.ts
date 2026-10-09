/**
 * Google and Apple sign-in (constitution 18: no email, password or OTP). The
 * on_auth_user_created trigger writes public.users and the customer role, so nothing here creates a
 * profile row.
 */

import * as AppleAuthentication from "expo-apple-authentication";
import * as Crypto from "expo-crypto";
import * as WebBrowser from "expo-web-browser";
import { Platform } from "react-native";
import { supabase } from "@/services/supabase/client";

const REDIRECT_TO = "marketak://auth/callback";

export const AUTH_PROVIDERS = { google: "google", apple: "apple" } as const;
export type AuthProvider = (typeof AUTH_PROVIDERS)[keyof typeof AUTH_PROVIDERS];

/** `cancelled` is separate from `failed`: somebody who dismissed the sheet is not an error. */
export type SignInResult = "signed-in" | "cancelled" | "failed";

async function openAuthSession(url: string): Promise<"cancelled" | "returned"> {
  // Sync in this SDK version; also closes the sheet on iOS where dismiss alone does not.
  WebBrowser.maybeCompleteAuthSession();

  try {
    const result = await WebBrowser.openAuthSessionAsync(url, REDIRECT_TO);
    return result.type === "success" ? "returned" : "cancelled";
  } catch {
    return "cancelled";
  }
}

export async function signInWithGoogle(): Promise<SignInResult> {
  return runOAuth(AUTH_PROVIDERS.google);
}

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
    // The sheet throws when dismissed.
    return "cancelled";
  }
}

async function runOAuth(provider: AuthProvider): Promise<SignInResult> {
  // skipBrowserRedirect: RN has no page load for supabase-js to attach its redirect handler to.
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider,
    options: { redirectTo: REDIRECT_TO, skipBrowserRedirect: true },
  });

  if (error !== null || data === null || data.url === null) return "failed";

  const outcome = await openAuthSession(data.url);
  return outcome === "cancelled" ? "cancelled" : "signed-in";
}

/**
 * Hands the deep link to supabase-js, which reads the tokens itself and then fires
 * onAuthStateChange for the session provider to pick up.
 */
export async function applyAuthCallback(callbackUrl: string): Promise<void> {
  await supabase.auth.exchangeCodeForSession(callbackUrl).catch(() => undefined);
}

/** Clears local state even on a network failure: the shopper asked to sign out, so they have. */
export async function signOut(): Promise<void> {
  await supabase.auth.signOut().catch(() => undefined);
}