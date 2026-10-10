/**
 * Launch + sign-in registration trigger (specs-mobile §8d).
 *
 * Null-render component, mounted once inside the auth provider. Registers
 * when the trigger key (signer + wire role + version) moves: first launch
 * with a session, every sign-in, every version bump, every role switch.
 * The key dedup makes refires impossible — `TOKEN_ALREADY_REGISTERED`
 * cannot loop here because a second call with the same key never happens.
 *
 * Deliberately out: permission prompting (screens own the moment and the
 * why-copy via `notification-prompt.tsx`), language syncing (explicit user
 * action via `syncLanguageAndRegister`, never a boot side effect), and
 * version-less registration (a null manifest version skips rather than
 * registering a lie).
 */
import { useEffect, useRef } from "react";
import { expoPushBackend } from "../../../services/push/fcm";
import {
  registerPushToken,
  registrationKey,
  shouldRegister,
} from "../../../services/push/register";
import { checkPushPermission, ensurePushChannels } from "./permissions";
import { appVersion, deviceLanguage } from "./appInfo";
import { useSession } from "../auth/use-session";
import { getUiState } from "../../../state/ui";
import type { AppRole } from "@marketak/shared";

export function PushRegistration(): null {
  const { session } = useSession();
  const language = deviceLanguage();
  const version = appVersion();
  const lastKey = useRef<string | null>(null);

  useEffect(() => {
    const userId = session?.userId ?? null;
    if (userId === null || version === null) {
      lastKey.current = null;
      return;
    }
    const role: AppRole = getUiState().activeRole === "courier" ? "rider" : "customer";
    const key = registrationKey(userId, role, version);
    if (!shouldRegister(lastKey.current, key)) return;
    lastKey.current = key;
    void (async (): Promise<void> => {
      try {
        const backend = expoPushBackend();
        await ensurePushChannels(backend);
        if ((await checkPushPermission(backend)) !== "granted") return;
        const device = await backend.getDeviceToken();
        await registerPushToken({
          token: device.token,
          platform: device.platform,
          appRole: role,
          appVersion: version,
        });
      } catch {
        // Registration retries on the next launch or sign-in; throwing here
        // would crash boot for a failure the server already names.
      }
    })();
  }, [session, language, version]);

  return null;
}
