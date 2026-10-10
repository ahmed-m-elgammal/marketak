/**
 * Device-push seam (F-08).
 *
 * Despite the filename (contract), the token comes from
 * `expo-notifications` `getDevicePushTokenAsync` — which returns the NATIVE
 * FCM/APNs device token on bare workflow, not an Expo push ticket. That is
 * the token the outbox Worker sends to (specs-mobile §8a: FCM/APNs), so no
 * new messaging dependency was needed. Channels and permission prompts ride
 * the same seam; testable modules take the seam as an argument and import
 * only its types.
 */
import { Platform } from "react-native";
import {
  getDevicePushTokenAsync,
  getPermissionsAsync,
  requestPermissionsAsync,
  setNotificationChannelAsync,
} from "expo-notifications";
import type { Platform as WirePlatform } from "@marketak/shared";
import { PUSH_CHANNELS } from "./channels";

export interface DevicePushToken {
  readonly token: string;
  readonly platform: WirePlatform;
}

export interface PushPermission {
  readonly granted: boolean;
  readonly canAskAgain: boolean;
}

export interface PushBackend {
  getDeviceToken(): Promise<DevicePushToken>;
  permissionStatus(): Promise<PushPermission>;
  requestPermission(): Promise<PushPermission>;
  ensureChannels(): Promise<void>;
}

function toPermission(status: { granted: boolean; canAskAgain: boolean }): PushPermission {
  return { granted: status.granted, canAskAgain: status.canAskAgain };
}

export function expoPushBackend(): PushBackend {
  return {
    async getDeviceToken(): Promise<DevicePushToken> {
      const native = await getDevicePushTokenAsync();
      const data: unknown = native.data;
      if (typeof data !== "string" || data === "") {
        throw new Error(`Unusable push token of type: ${native.type}`);
      }
      if (native.type === "ios") return { token: data, platform: "ios" };
      if (native.type === "android") return { token: data, platform: "android" };
      throw new Error(`Unsupported push token type: ${native.type}`);
    },
    async permissionStatus(): Promise<PushPermission> {
      return toPermission(await getPermissionsAsync());
    },
    async requestPermission(): Promise<PushPermission> {
      return toPermission(await requestPermissionsAsync());
    },
    async ensureChannels(): Promise<void> {
      if (Platform.OS !== "android") return;
      for (const channel of PUSH_CHANNELS) {
        await setNotificationChannelAsync(channel.id, channel.input);
      }
    },
  };
}
