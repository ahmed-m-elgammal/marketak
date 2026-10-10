/**
 * Push registration orchestration (specs-mobile §8d).
 *
 * Call on launch and on every sign-in. The two per-registration facts the
 * server keeps — `app_version` (sent) and `language` (read from
 * `users.preferred_language`, never accepted as an argument) — are why:
 * skipping the call makes a live device look dead (`last_seen_at` drives
 * liveness) and strands it on a stale version string.
 *
 * Language changes do NOT flow through here silently: flipping the
 * account's language as a side effect of boot would override an explicit
 * user choice. `syncLanguageAndRegister` is the explicit path — a language
 * switcher calls it after the user chooses, and it is idempotent
 * server-side (unchanged values write nothing, changed ones re-register).
 *
 * `TOKEN_ALREADY_REGISTERED` means another device holds this (user, role)
 * — the server message says so ("sign out on that device first") and it
 * travels in the outcome for screens to surface. Never a crash, never a
 * retry loop: the trigger key does not change, so refiring is impossible.
 * The response rows are server state, never echoed — only the count
 * leaves here.
 */
import { AppError, type AppRole, type Language, type Platform } from "@marketak/shared";
import { registerDeviceToken, updateProfile } from "../rpc/index";

export interface PushRegistration {
  readonly token: string;
  readonly platform: Platform;
  readonly appRole: AppRole;
  readonly appVersion: string;
}

export type RegistrationOutcome =
  | { readonly status: "registered"; readonly registrations: number }
  | { readonly status: "already-registered"; readonly serverMessage: string };

export async function registerPushToken(
  input: PushRegistration,
  register: typeof registerDeviceToken = registerDeviceToken,
): Promise<RegistrationOutcome> {
  try {
    const rows = await register({
      p_token: input.token,
      p_platform: input.platform,
      p_app_role: input.appRole,
      p_app_version: input.appVersion,
    });
    return { status: "registered", registrations: rows.length };
  } catch (error) {
    if (error instanceof AppError && error.code === "TOKEN_ALREADY_REGISTERED") {
      return { status: "already-registered", serverMessage: error.serverMessage };
    }
    throw error;
  }
}

/** Stable trigger key: re-register when the signer, role or version moves. */
export function registrationKey(userId: string, role: AppRole, appVersion: string): string {
  return `${userId}:${role}:${appVersion}`;
}

export function shouldRegister(lastKey: string | null, key: string): boolean {
  return lastKey !== key;
}

/**
 * Explicit language change path: sync the account language, then
 * re-register so the Worker's next render uses it. Both calls idempotent.
 */
export async function syncLanguageAndRegister(
  language: Language,
  input: PushRegistration,
  deps: {
    updateProfile?: typeof updateProfile;
    register?: typeof registerDeviceToken;
  } = {},
): Promise<RegistrationOutcome> {
  const update = deps.updateProfile ?? updateProfile;
  await update({ preferred_language: language });
  return registerPushToken(input, deps.register);
}
