import { describe, expect, it, vi } from "vitest";
import { AppError, type DeviceToken, type ProfileStatus, type RegisterDeviceTokenArgs } from "@marketak/shared";
import {
  registerPushToken,
  registrationKey,
  shouldRegister,
  syncLanguageAndRegister,
} from "./register";

const INPUT = { token: "fcm-token-1", platform: "android", appRole: "customer", appVersion: "0.1.0" } as const;

const ROW: DeviceToken = {
  id: "d1",
  user_id: "u1",
  token: "fcm-token-1",
  platform: "android",
  app_role: "customer",
  app_version: "0.1.0",
  language: "ar",
  last_seen_at: "2026-10-10T10:00:00Z",
  created_at: "2026-10-10T10:00:00Z",
};

const STATUS: ProfileStatus = {
  profile_completed_at: null,
  has_phone: true,
  has_address: true,
  can_browse: true,
  can_order: true,
  missing: [],
};

describe("registerPushToken", () => {
  it("registers with the real version and counts server rows, never echoing them", async () => {
    const register = vi.fn((_args: RegisterDeviceTokenArgs): Promise<readonly DeviceToken[]> =>
      Promise.resolve([ROW, ROW]),
    );
    const outcome = await registerPushToken(INPUT, register);
    expect(outcome).toEqual({ status: "registered", registrations: 2 });
    expect(register).toHaveBeenCalledWith({
      p_token: "fcm-token-1",
      p_platform: "android",
      p_app_role: "customer",
      p_app_version: "0.1.0",
    });
  });

  it("surfaces already-registered with the server message, not a crash", async () => {
    const register = vi.fn((_args: RegisterDeviceTokenArgs): Promise<readonly DeviceToken[]> =>
      Promise.reject(new AppError("business", "TOKEN_ALREADY_REGISTERED", "another device is registered for this role")),
    );
    const outcome = await registerPushToken(INPUT, register);
    expect(outcome).toEqual({
      status: "already-registered",
      serverMessage: "another device is registered for this role",
    });
  });

  it("rethrows anything else", async () => {
    const register = vi.fn((_args: RegisterDeviceTokenArgs): Promise<readonly DeviceToken[]> =>
      Promise.reject(new AppError("unauthenticated", "AUTH_REQUIRED", "sign in first")),
    );
    await expect(registerPushToken(INPUT, register)).rejects.toBeInstanceOf(AppError);
  });
});

describe("registration trigger", () => {
  it("re-registers when signer, role or version moves, never twice for the same key", () => {
    const key = registrationKey("u1", "customer", "0.1.0");
    expect(shouldRegister(null, key)).toBe(true);
    expect(shouldRegister(key, key)).toBe(false);
    expect(shouldRegister(key, registrationKey("u1", "rider", "0.1.0"))).toBe(true);
    expect(shouldRegister(key, registrationKey("u1", "customer", "0.2.0"))).toBe(true);
    expect(shouldRegister(key, registrationKey("u2", "customer", "0.1.0"))).toBe(true);
  });
});

describe("syncLanguageAndRegister", () => {
  it("syncs the account language first, then registers", async () => {
    const order: string[] = [];
    const updateProfile = vi.fn((): Promise<ProfileStatus> => {
      order.push("language");
      return Promise.resolve(STATUS);
    });
    const register = vi.fn((): Promise<readonly DeviceToken[]> => Promise.resolve([ROW]));
    const outcome = await syncLanguageAndRegister(
      "en",
      { token: "t", platform: "ios", appRole: "rider", appVersion: "0.1.0" },
      { updateProfile, register },
    );
    expect(order).toEqual(["language"]);
    expect(updateProfile).toHaveBeenCalledWith({ preferred_language: "en" });
    expect(outcome).toEqual({ status: "registered", registrations: 1 });
  });
});
