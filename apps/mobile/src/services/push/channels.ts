/**
 * Android notification channels (DESIGN §9.11).
 *
 * Pure descriptors — no `expo-notifications` import, so tests assert them
 * without the native module. Importance/visibility are numeric literals
 * matching the installed SDK's enums (`AndroidImportance.MAX = 7`,
 * `DEFAULT = 5`; `AndroidNotificationVisibility.PUBLIC = 1`,
 * `PRIVATE = 2`); the adapter in `fcm.ts` maps them onto the real enums.
 *
 * Two channels, and the split is the design: dispatch interrupts (courier
 * offer with countdown, MAX importance, badge + sound + vibration), updates
 * inform (DEFAULT, lockscreen PRIVATE). Pharmacy payloads are sealed copy
 * (§14) — the seal is in the payload the Worker renders, and this channel
 * never previews more than the sealed line.
 */
import type { NotificationChannelInput } from "expo-notifications";

export interface ChannelDescriptor {
  readonly id: string;
  readonly input: NotificationChannelInput;
}

export const DISPATCH_CHANNEL_ID = "dispatch";
export const UPDATES_CHANNEL_ID = "updates";

export const PUSH_CHANNELS: readonly ChannelDescriptor[] = [
  {
    id: DISPATCH_CHANNEL_ID,
    input: {
      name: "Dispatch offers",
      description: "Incoming courier dispatch: sound, vibration and badge until answered or expired.",
      importance: 7,
      lockscreenVisibility: 1,
      enableVibrate: true,
      vibrationPattern: [0, 250, 250, 250],
      showBadge: true,
    },
  },
  {
    id: UPDATES_CHANNEL_ID,
    input: {
      name: "Order updates",
      description: "Status, cancellation and voucher updates. Pharmacy rows carry sealed copy only.",
      importance: 5,
      lockscreenVisibility: 2,
      enableVibrate: false,
      showBadge: true,
    },
  },
];
