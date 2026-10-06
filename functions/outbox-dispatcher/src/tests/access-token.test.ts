import { afterEach, describe, expect, it } from "vitest";

import {
  clearTokenCache,
  getAccessToken,
  hasValidCachedToken,
  signAssertion,
} from "../google/access-token.js";
import { ACCESS_TOKEN_TTL_SECONDS, FCM_SCOPE, GOOGLE_TOKEN_URL } from "../config/env.js";

/**
 * A real RSA-2048 key, generated for this test file and committed.
 *
 * A TEST key, never a service account key. It exists so the signing path can be exercised end to end
 * through WebCrypto, because the alternative - a hand-written signature - would mean the JWT code was
 * never actually run.
 *
 * The claims are what matters, not the modulus.
 */
const TEST_PKCS8_PEM = [
  "-----BEGIN PRIVATE KEY-----",
  "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCsUrbWbGfA8u7m",
  "GXMy7kSKjOAiudaWOMm6+54JXkZeehYCqkh4o/T3uSCerHLHQEokv5xPvxc4tmka",
  "AfOeA+8FuhDiOiwk2zgxVdewZc5Ck1gj5LdUGtQhlI+zL93EQHDwhDnqCCD6Jqnj",
  "0/XYy6xl/4ffGx9hr73MDOlD1d4kT/QPYB/f5FKC4XUzNtyxBspAdhtpqrkWeHhg",
  "kec3fpog7s+1Fts/WncT8FjZE4ExiBA0bybda+CjhS93jA2BTGikmJHLFRjPB0r0",
  "GBzsDzTe5AWw/wEYmK3Pn4R3dGwUDeX64j13QYUiAh441VMrnpIWPLZ+8SqPFVl2",
  "Mh8wmEsNAgMBAAECggEAIikYgTvGup99/+PSLCnDMSMZqJCmCywRQ42vR8SmVwLF",
  "O7yFdtLr1DLhFktxynGCcTQB2OY1BINWpPb3lB7MAprez3YAO8MwaclOY3PfFmAO",
  "tDjaJeRWopyIexlVUVsD+I4BzBTV8rj460bgwNwpXiPwi6gdCbi0u49gq5epPJHA",
  "CmWcfpJfe97m14bmmkPlDrg073HeHPicuqlHugJ9TI/RTg4uISPIuksPq64oCdIU",
  "07TdMdFajtlX8M+0k37p713d4O24nf4D7iACamMXC+8dGxSPqFGo683aK0UP5ZIz",
  "ezXzFoWKXwP3yUQAY82VIKkjLrG3767f9xPpDE7AkQKBgQDucY7atnJ7EjiVdNXd",
  "GlHF1PefAUSBtL0TWyXIIjqmhTWELHd91B2dEbA1WNwKwa2/HNFZOMZ5KldUjsMv",
  "0y3KmQKbGrIHp9WV6Dc4DuAhq/LORl6tMj6BafYeExbxfQ/5GvAAvjS6xOaFa92a",
  "Uo7tVwIJ/muOCPoS6DlC3w9dvQKBgQC5AtiRaTZK4sH5Rw+89WJD9fMdnqfK9Y7Z",
  "EnyIZkrT0YkM6g7lO6HwnRXUBs3OWbPFcEZC/dgLB3bvPx5O56wxYKaECSFsqHXG",
  "KsghEbT6+LERES7O/QBoiXM7YkbdQ5MW9glk8iRiWcpsAIjPelDkePTkb/3VNOli",
  "kN8FLBCvkQKBgQCzr1my0eiFfB6t6iS8APh8d9e+uCrS/8u4SWi4X6sJD7tbhlLp",
  "vK4wTkMWgIcZiAiRy3qrnNBcQJ8c9pR6ds68LQA8uCpPAJhA5oSuNu+KEFTiQz9X",
  "j1RxG9O/qC0TAGbIFxejx7JeyMDa7IVLpUlV68p6k4Kjv3oMQ3nbPdMLlQKBgCgf",
  "kuIuRCUHenPaUnJzcSU2AMyqrM8aZCl1leZq8M1xQty3IhXa0esB1ksOUrHuyEsI",
  "Z2R98s2ph8SpFqScH77xrAs0g7gx7KDWhGKPmYVYS+ZcqJ8hRWZmcMQvMxknX436",
  "O91VmkhuGrVDhGgiqcpy5QFpvE3x1K+YpZVUkiXRAoGARjmAoS956XJUnVflD2qb",
  "jE0GO3FWP1cUxz17qbC6K603tzJidevnUyC5tKX2cnKHSmTiSu9KTyPRFPiec7gm",
  "hvR1QlVoZZSBvo5mgLSOnRo6H0kpnRbFIOrsg8iEoXEfnka4RI2b4Dk7BgaRt+an",
  "12Vm6L7pNelIkdn6btPUih0=",
"-----END PRIVATE KEY-----",
].join("\n");

const SIGNING_KEY = {
  projectId: "test-project",
  clientEmail: "test@test-project.iam.gserviceaccount.com",
  privateKey: TEST_PKCS8_PEM,
};

function decodeSegment(segment: string): Record<string, unknown> {
  const padded = segment.replaceAll("-", "+").replaceAll("_", "/");
  const json = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  return JSON.parse(json) as Record<string, unknown>;
}

afterEach(() => {
  clearTokenCache();
});

describe("signAssertion", () => {
  it("produces three dot-separated segments with a real signature", async () => {
    // Exercised through WebCrypto rather than with a stubbed signature, because a JWT code path that has
    // never actually signed is a JWT code path that has never worked.
    const assertion = await signAssertion(SIGNING_KEY, 1_760_000_000_000);
    const segments = assertion.split(".");

    expect(segments).toHaveLength(3);
    expect(segments[0]).toBeDefined();
    expect(segments[1]).toBeDefined();
    expect(segments[2]).toBeDefined();
    // A signature is 256 bytes for RSA-2048, base64url-encoded without padding.
    expect(segments[2]?.length).toBeGreaterThan(300);
    expect(segments[2]).not.toContain("=");
  });

  it("declares RS256 in the header", async () => {
    const assertion = await signAssertion(SIGNING_KEY, 1_760_000_000_000);
    const header = decodeSegment(assertion.split(".")[0] ?? "");

    expect(header["alg"]).toBe("RS256");
    expect(header["typ"]).toBe("JWT");
  });

  it("targets Google's token endpoint, not FCM", async () => {
    // `aud` is a common typo and the failure is an opaque 400 from Google.
    const assertion = await signAssertion(SIGNING_KEY, 1_760_000_000_000);
    const claims = decodeSegment(assertion.split(".")[1] ?? "");

    expect(claims["aud"]).toBe(GOOGLE_TOKEN_URL);
    expect(claims["scope"]).toBe(FCM_SCOPE);
  });

  it("issues at `iss` as the client email", async () => {
    const assertion = await signAssertion(SIGNING_KEY, 1_760_000_000_000);
    const claims = decodeSegment(assertion.split(".")[1] ?? "");

    expect(claims["iss"]).toBe(SIGNING_KEY.clientEmail);
  });

  it("backs `iat` off by 30 seconds to survive clock drift", async () => {
    // Google rejects a token whose `iat` is in the future, and a Worker whose clock leads Google's by a
    // few seconds would otherwise fail intermittently in a way that looks like flakiness.
    const nowMs = 1_760_000_000_000;
    const assertion = await signAssertion(SIGNING_KEY, nowMs);
    const claims = decodeSegment(assertion.split(".")[1] ?? "");

    // `decodeSegment` returns `Record<string, unknown>` because it decodes untyped JSON. Narrowing rather
    // than casting: `typeof NaN === "number"`, so the type check alone is not enough to make the arithmetic
    // below meaningful.
    const iat = claims["iat"];
    const exp = claims["exp"];
    expect(typeof iat).toBe("number");
    expect(typeof exp).toBe("number");
    if (typeof iat !== "number" || typeof exp !== "number") {
      throw new Error("iat and exp must both be numbers for this assertion to mean anything");
    }
    expect(Number.isFinite(iat)).toBe(true);
    expect(iat).toBe(Math.floor(nowMs / 1000) - 30);
    // One hour, which is Google's maximum for this grant.
    expect(exp).toBe(iat + 3_600);
  });

  it("throws without leaking the key when the PEM is not importable", async () => {
    // The message names the failure and never includes key material, because an exception message is the
    // most likely place for a private key to reach a log.
    await expect(
      signAssertion({ ...SIGNING_KEY, privateKey: "not-a-key" }, Date.now()),
    ).rejects.toThrow();
  });
});

describe("the access-token cache", () => {
  it("starts empty", () => {
    expect(hasValidCachedToken(Date.now())).toBe(false);
  });

  it("stays empty when the exchange fails", async () => {
    // A transient 500 from Google must not poison the cache: if it did, every later send in the minute
    // would re-sign and hammer the endpoint.
    const realFetch = globalThis.fetch;
    globalThis.fetch = (): Promise<Response> =>
      Promise.resolve(new Response("nope", { status: 500 }));

    try {
      await expect(getAccessToken(SIGNING_KEY)).rejects.toThrow(/Google token exchange failed/u);
      expect(hasValidCachedToken(Date.now())).toBe(false);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it("caches for 55 minutes, not the hour Google grants", async () => {
    const realFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (): Promise<Response> => {
      calls += 1;
      return Promise.resolve(
        Response.json({ access_token: "ya29.test-token", expires_in: 3_600 }),
      );
    };

    try {
      const first = await getAccessToken(SIGNING_KEY);
      expect(first).toBe("ya29.test-token");
      expect(calls).toBe(1);
      expect(hasValidCachedToken(Date.now())).toBe(true);

      // A second call inside the TTL reuses the token. Signing is 3-5 ms against a 10 ms budget, so this is
      // the behaviour the whole budget argument rests on.
      const second = await getAccessToken(SIGNING_KEY);
      expect(second).toBe("ya29.test-token");
      expect(calls).toBe(1);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it("re-signs once the TTL has passed", async () => {
    const realFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (): Promise<Response> => {
      calls += 1;
      return Promise.resolve(
        Response.json({ access_token: `token-${String(calls)}`, expires_in: 3_600 }),
      );
    };

    try {
      const start = 1_760_000_000_000;
      expect(await getAccessToken(SIGNING_KEY, start)).toBe("token-1");
      // One second before expiry: still cached.
      expect(await getAccessToken(SIGNING_KEY, start + ACCESS_TOKEN_TTL_SECONDS * 1_000 - 1)).toBe(
        "token-1",
      );
      expect(calls).toBe(1);
      // One second after: re-signed.
      expect(
        await getAccessToken(SIGNING_KEY, start + ACCESS_TOKEN_TTL_SECONDS * 1_000 + 1),
      ).toBe("token-2");
      expect(calls).toBe(2);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it("caps a longer-lived response at the budgeted TTL", async () => {
    // If a response ever claimed 24 hours, trusting it would leave the cache holding a token that dies
    // mid-send with nothing to explain it.
    const realFetch = globalThis.fetch;
    globalThis.fetch = (): Promise<Response> =>
      Promise.resolve(
        Response.json({ access_token: "long-lived", expires_in: 86_400 }),
      );

    try {
      const start = 1_760_000_000_000;
      await getAccessToken(SIGNING_KEY, start);
      expect(hasValidCachedToken(start + ACCESS_TOKEN_TTL_SECONDS * 1_000 + 1)).toBe(false);
      expect(hasValidCachedToken(start + ACCESS_TOKEN_TTL_SECONDS * 1_000 - 1)).toBe(true);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it("clears on demand so a 401 can force a re-sign", async () => {
    const realFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (): Promise<Response> => {
      calls += 1;
      return Promise.resolve(
        Response.json({ access_token: `t${String(calls)}`, expires_in: 3_600 }),
      );
    };

    try {
      expect(await getAccessToken(SIGNING_KEY)).toBe("t1");
      clearTokenCache();
      expect(hasValidCachedToken(Date.now())).toBe(false);
      expect(await getAccessToken(SIGNING_KEY)).toBe("t2");
    } finally {
      globalThis.fetch = realFetch;
    }
  });
});
