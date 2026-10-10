import { describe, expect, it, vi } from "vitest";
import { QueryClient } from "@tanstack/react-query";
import { sessionKey } from "../cache/query-keys";
import { fetchSession, subscribeSession, type SessionBackend } from "./session";

function fakeBackend(initial: string | null): SessionBackend & {
  emit(userId: string | null): void;
  wasDropped(): boolean;
} {
  let listener: ((userId: string | null) => void) | null = null;
  let dropped = false;
  return {
    getSessionUserId(): Promise<string | null> {
      return Promise.resolve(initial);
    },
    onSessionChange(callback: (userId: string | null) => void): { unsubscribe(): void } {
      listener = callback;
      return {
        unsubscribe(): void {
          listener = null;
          dropped = true;
        },
      };
    },
    signOut(): Promise<void> {
      listener?.(null);
      return Promise.resolve();
    },
    emit(userId: string | null): void {
      listener?.(userId);
    },
    wasDropped(): boolean {
      return dropped;
    },
  };
}

describe("fetchSession", () => {
  it("returns the user id, or null signed out", async () => {
    await expect(fetchSession(fakeBackend("user-1"))).resolves.toEqual({ userId: "user-1" });
    await expect(fetchSession(fakeBackend(null))).resolves.toBeNull();
  });
});

describe("subscribeSession", () => {
  it("seeds from storage, mirrors changes, and stops on unsubscribe", async () => {
    const queryClient = new QueryClient();
    const backend = fakeBackend("user-1");
    const stop = subscribeSession(queryClient, backend);
    await vi.waitFor(() => {
      expect(queryClient.getQueryData(sessionKey())).toEqual({ userId: "user-1" });
    });

    backend.emit(null);
    await vi.waitFor(() => {
      expect(queryClient.getQueryData(sessionKey())).toBeNull();
    });

    stop();
    expect(backend.wasDropped()).toBe(true);
    backend.emit("user-2");
    await vi.waitFor(() => {
      expect(queryClient.getQueryData(sessionKey())).toBeNull();
    });
  });
});
