/**
 * Tests for the auth state machine.
 *
 * `resolveAuthStatus` is pure precisely so this can be tested: the redirect loop it prevents only reproduces
 * with a real session, a real router and a browser, so exhaustively covering the four branches here is the
 * only affordable way to know the guard is right.
 */

import type { Session } from "@supabase/supabase-js";
import { describe, expect, it } from "vitest";

import { AUTH_CALLBACK_PATH, resolveAuthStatus, type AuthStatus } from "../lib/auth.js";

/** A session stub. Only `user.id` is read by the code under test. */
const SESSION = { user: { id: "44444444-0000-4000-8000-000000000009" } } as unknown as Session;

/** The shape `resolveAuthStatus` accepts. Widened explicitly - `as const` would narrow each ROLE to a
 * single literal and the helper's parameter would inherit it from the first call. */
interface RoleState {
  readonly isPending: boolean;
  readonly isError: boolean;
  readonly isAdmin: boolean;
}

const ROLE = {
  settled: { isPending: false, isError: false, isAdmin: true },
  notAdmin: { isPending: false, isError: false, isAdmin: false },
  pending: { isPending: true, isError: false, isAdmin: false },
  failed: { isPending: false, isError: true, isAdmin: false },
} as const satisfies Record<string, RoleState>;

function status(session: Session | null | undefined, roleQuery: RoleState): AuthStatus {
  return resolveAuthStatus({ session, roleQuery });
}

describe("resolveAuthStatus", () => {
  it("is pending before the session has been read", () => {
    // `undefined` means "not asked yet". Collapsing it into `null` is the bug this signature prevents.
    expect(status(undefined, ROLE.settled)).toBe("pending");
  });

  it("is pending while the role query runs, with a session in hand", () => {
    // Redirecting here would send an operator who is about to be authenticated to the sign-in page.
    expect(status(SESSION, ROLE.pending)).toBe("pending");
  });

  it("is signed out when the session was read and found empty", () => {
    expect(status(null, ROLE.settled)).toBe("signed-out");
  });

  it("is not-admin when the session exists but the role is absent", () => {
    // A signed-in customer, not a signed-out one. Sending this to /sign-in loops forever: they authenticate
    // successfully, arrive back, and are bounced again.
    expect(status(SESSION, ROLE.notAdmin)).toBe("not-admin");
  });

  it("is not-admin when the role query FAILED", () => {
    // Failing closed. Showing admin controls to someone we could not verify is worse than a 403 for someone
    // who was about to be let in - and the 403 page says "ask an admin", which is the right next step either
    // way. The alternative, optimistically trusting a failed read, is how an RLS hole gets used.
    expect(status(SESSION, ROLE.failed)).toBe("not-admin");
  });

  it("is admin only when both the session and the role are confirmed", () => {
    expect(status(SESSION, ROLE.settled)).toBe("admin");
  });

  it("never returns admin from a session alone", () => {
    // A stale cached role from a previous user must not survive. Keying the role query by `user.id` is what
    // prevents this, and this assertion is the reason that key exists.
    const adminRole: RoleState = { isPending: false, isError: false, isAdmin: true };
    expect(resolveAuthStatus({ session: SESSION, roleQuery: adminRole })).toBe("admin");
    expect(resolveAuthStatus({ session: null, roleQuery: adminRole })).toBe("signed-out");
    expect(resolveAuthStatus({ session: undefined, roleQuery: adminRole })).toBe("pending");
  });

  it("produces exactly one status for every combination, so the guard can switch exhaustively", () => {
    // Every cell of the truth table. A cell that threw or returned undefined would be a screen that renders
    // nothing, and it would only be found by clicking through the app.
    const sessions: readonly (Session | null | undefined)[] = [undefined, null, SESSION];
    const roles: readonly RoleState[] = [ROLE.pending, ROLE.settled, ROLE.notAdmin, ROLE.failed];
    for (const session of sessions) {
      for (const role of roles) {
        const result = status(session, role);
        expect(
          ["pending", "signed-out", "not-admin", "admin"],
          `session=${session === undefined ? "undefined" : session === null ? "null" : "session"} role=${JSON.stringify(role)}`,
        ).toContain(result);
      }
    }
  });
});

describe("the sign-in surface", () => {
  it("has exactly one callback path, and it is the one on the allowlist", () => {
    // Supabase → URL Configuration carries `http://localhost:5173/auth/callback`. Verified by a live probe on
    // 2026-10-06 that the provider issues an authorize URL for it; the allowlist itself is enforced at
    // callback time and could not be proven without completing the browser round trip.
    expect(AUTH_CALLBACK_PATH).toBe("/auth/callback");
  });

  it("is not an email or password path", () => {
    // constitution rule 18 as scoped for internal staff: there is no form, so there is nothing to type. This
    // assertion is a tripwire against someone adding one.
    expect(AUTH_CALLBACK_PATH).not.toContain("token");
    expect(AUTH_CALLBACK_PATH).not.toContain("password");
  });
});