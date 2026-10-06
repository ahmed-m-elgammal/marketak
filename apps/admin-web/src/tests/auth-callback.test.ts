/**
 * `callbackDestination` is the whole policy of the OAuth callback screen, so it gets tested directly. The
 * component around it is polling and rendering; the decisions worth trusting are these.
 *
 * The case that motivated each test is in the comment on the function: a session present in storage but not yet
 * propagated to the role query must never be read as failure, because the authorization result has already been
 * consumed from the URL by then and a second attempt has nothing to exchange.
 */

import { describe, expect, it } from "vitest";

import { callbackDestination } from "../features/auth/AuthCallbackPage.js";
import type { AuthStatus } from "../lib/auth.js";

const STATUSES: readonly AuthStatus[] = ["pending", "signed-out", "not-admin", "admin"];

function destinationFor(
  status: AuthStatus,
  hasSession: boolean,
  expired: boolean,
): ReturnType<typeof callbackDestination> {
  return callbackDestination({ status, hasSession, expired });
}

describe("callbackDestination", () => {
  it("sends an admin to the dashboard and a signed-in non-admin to 403", () => {
    expect(destinationFor("admin", true, false)).toBe("home");
    expect(destinationFor("not-admin", true, false)).toBe("forbidden");
  });

  it("waits rather than redirecting while the role query is still resolving", () => {
    expect(destinationFor("pending", false, false)).toBe("waiting");
  });

  it("reports expiry only once the grace period has passed", () => {
    expect(destinationFor("signed-out", false, false)).toBe("waiting");
    expect(destinationFor("signed-out", false, true)).toBe("expired");
  });

  it("treats a session in storage as success even after the grace period", () => {
    // The regression this encodes: the token is already redeemed, so redirecting to sign-in here would
    // strand the operator in a loop with nothing left to exchange.
    expect(destinationFor("pending", true, true)).toBe("waiting");
    expect(destinationFor("signed-out", true, true)).toBe("waiting");
  });

  it("never expires a route that has a session, whatever the status", () => {
    for (const status of STATUSES) {
      if (status === "admin" || status === "not-admin") {
        continue;
      }
      expect(destinationFor(status, true, true)).toBe("waiting");
    }
  });

  it("only reports expiry when there is genuinely no session", () => {
    for (const status of STATUSES) {
      if (status === "admin" || status === "not-admin") {
        continue;
      }
      expect(destinationFor(status, false, true)).toBe("expired");
    }
  });
});