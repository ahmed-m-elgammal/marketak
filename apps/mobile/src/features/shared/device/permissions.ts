/**
 * Push-permission orchestration (DESIGN §14: request in context, one-line
 * why, always a manual path).
 *
 * The backend is injected (`services/push/fcm.ts` in prod, a fake in
 * tests) — this module never imports a native module, so the
 * denied/allowed matrix runs in node. Outcomes:
 *
 * - `granted` — register.
 * - `denied-retryable` — the OS prompt can show again; render the why-copy
 *   with a retry action.
 * - `denied-blocked` — the user said no twice or via settings; render the
 *   rationale with a settings action (`{ action: "open-settings" }` for the
 *   component, which owns `Linking`). Never a dead end.
 */
import type { PushBackend } from "../../../services/push/fcm";

export type PermissionOutcome = "granted" | "denied-retryable" | "denied-blocked";

function toOutcome(permission: { granted: boolean; canAskAgain: boolean }): PermissionOutcome {
  if (permission.granted) return "granted";
  if (permission.canAskAgain) return "denied-retryable";
  return "denied-blocked";
}

export async function checkPushPermission(backend: PushBackend): Promise<PermissionOutcome> {
  return toOutcome(await backend.permissionStatus());
}

export async function requestPushPermission(backend: PushBackend): Promise<PermissionOutcome> {
  return toOutcome(await backend.requestPermission());
}

export async function ensurePushChannels(backend: PushBackend): Promise<void> {
  await backend.ensureChannels();
}
