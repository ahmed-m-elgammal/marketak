import { describe, expect, it, vi } from "vitest";
import type { PushBackend } from "../../../services/push/fcm";
import { checkPushPermission, ensurePushChannels, requestPushPermission } from "./permissions";

function fakeBackend(permission: { granted: boolean; canAskAgain: boolean }): PushBackend & {
  readonly channelsEnsured: boolean;
} {
  const state = { channels: false };
  return {
    get channelsEnsured(): boolean {
      return state.channels;
    },
    getDeviceToken(): Promise<{ token: string; platform: "android" }> {
      return Promise.resolve({ token: "t", platform: "android" as const });
    },
    permissionStatus(): Promise<{ granted: boolean; canAskAgain: boolean }> {
      return Promise.resolve(permission);
    },
    requestPermission(): Promise<{ granted: boolean; canAskAgain: boolean }> {
      return Promise.resolve(permission);
    },
    ensureChannels(): Promise<void> {
      state.channels = true;
      return Promise.resolve();
    },
  };
}

describe("push permission", () => {
  it("maps granted, retryable and blocked states", async () => {
    await expect(checkPushPermission(fakeBackend({ granted: true, canAskAgain: true }))).resolves.toBe("granted");
    await expect(checkPushPermission(fakeBackend({ granted: false, canAskAgain: true }))).resolves.toBe(
      "denied-retryable",
    );
    await expect(checkPushPermission(fakeBackend({ granted: false, canAskAgain: false }))).resolves.toBe(
      "denied-blocked",
    );
  });

  it("requests through the same mapping", async () => {
    await expect(requestPushPermission(fakeBackend({ granted: true, canAskAgain: false }))).resolves.toBe("granted");
    await expect(requestPushPermission(fakeBackend({ granted: false, canAskAgain: false }))).resolves.toBe(
      "denied-blocked",
    );
  });

  it("delegates channel creation to the backend", async () => {
    const backend = fakeBackend({ granted: true, canAskAgain: true });
    const spy = vi.spyOn(backend, "ensureChannels");
    await ensurePushChannels(backend);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(backend.channelsEnsured).toBe(true);
  });
});
