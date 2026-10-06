/**
 * `google/access-token` - minting a Google access token with WebCrypto, cached.
 *
 * ## Why this exists at all
 *
 * FCM HTTP v1 has no unauthenticated send path and the legacy `Authorization: key=<server-key>` method is
 * dead. Every request must carry an OAuth2 access token, which is obtained by signing a JWT with the
 * service account's private key and exchanging it. That signing is 3-5 ms against a 10 ms per-invocation
 * budget, so signing per send is what breaks the budget - hence the cache.
 *
 * ## The cache is a module-level variable on purpose
 *
 * A Worker's isolate is reused across invocations, so a module-level cache survives between requests on the
 * same isolate. This is the standard pattern for token caching on Cloudflare and costs nothing extra.
 *
 * Two details that are easy to get wrong and expensive to debug:
 *
 * - **The expiry is recomputed from `Date.now()` on every hit**, not decremented. A countdown that is
 *   decremented once per call and read twice would drift.
 * - **A failed exchange does not clear a still-valid token.** The cache is only touched on success, so one
 *   transient 500 from Google cannot force every subsequent send in the minute to re-sign.
 */

import { ACCESS_TOKEN_TTL_SECONDS, FCM_SCOPE, GOOGLE_TOKEN_URL } from "../config/env.js";

/** The subset of the service account this module needs. Narrower than `Env["fcm"]` on purpose. */
export interface SigningKey {
  readonly projectId: string;
  readonly clientEmail: string;
  readonly privateKey: string;
}

interface CachedToken {
  readonly accessToken: string;
  /** Epoch milliseconds. */
  readonly expiresAt: number;
}

let cached: CachedToken | null = null;

const encoder = new TextEncoder();

/** Base64url, no padding. `btoa` produces standard base64, so the two swaps are required. */
function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const byte of view) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function encodeSegment(value: unknown): string {
  return base64url(encoder.encode(JSON.stringify(value)));
}

/**
 * Imports the PEM private key.
 *
 * Wraps the bare PEM in PKCS#8 headers because WebCrypto's `importKey` accepts only DER-encoded PKCS#8, and
 * the header is the only difference between a PEM file and that DER form. `-----BEGIN PRIVATE KEY-----` is
 * the PKCS#8 label; `BEGIN RSA PRIVATE KEY` would be PKCS#1 and is rejected here with a clear message rather
 * than an opaque one.
 */
async function importSigningKey(pem: string): Promise<CryptoKey> {
  const der = pemToDer(pem);
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/** Strips the PEM armour and base64-decodes to bytes. Throws with the PEM label, never the key. */
function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replaceAll(/\s+/gu, "");
  if (body.length === 0) {
    throw new Error("private key body is empty after removing the PEM armour");
  }
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

/**
 * Signs the JWT assertion Google expects: RS256, `aud` the token endpoint, `scope` the FCM scope, and a
 * one-hour `exp`.
 *
 * `iat` is 30 seconds in the past. Google's token endpoint rejects a token whose `iat` is in the future,
 * and a Worker whose clock has drifted a few seconds ahead of Google's would otherwise fail intermittently
 * in a way that looks like flakiness.
 */
export async function signAssertion(key: SigningKey, now: number = Date.now()): Promise<string> {
  const issuedAt = Math.floor(now / 1000) - 30;
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: key.clientEmail,
    scope: FCM_SCOPE,
    aud: GOOGLE_TOKEN_URL,
    iat: issuedAt,
    exp: issuedAt + 3_600,
  };

  const signingInput = `${encodeSegment(header)}.${encodeSegment(claims)}`;
  const cryptoKey = await importSigningKey(key.privateKey);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    encoder.encode(signingInput),
  );

  return `${signingInput}.${base64url(signature)}`;
}

/**
 * True when a cached token exists and has not expired. Exported so a test can prove the cache works.
 *
 * Takes the clock as an argument for the same reason `getAccessToken` does: a TTL assertion needs to
 * compare an expiry against a synthetic timeline, and a helper that read the real clock would make every
 * such comparison meaningless.
 */
export function hasValidCachedToken(now: number): boolean {
  return cached !== null && cached.expiresAt > now;
}


/** Drops the cached token. Only used by tests, and on an auth failure so the next call re-signs. */
export function clearTokenCache(): void {
  cached = null;
}

/**
 * Exchanges a signed assertion for an access token.
 *
 * `now` is threaded through rather than read from `Date.now()` inside, because the expiry is stored against
 * a timestamp and a caller that injected `now` for its own clock is entitled to an expiry on that same
 * timeline. Reading the real clock here would make the cache untestable: every TTL assertion would compare
 * a synthetic start time against a real one.
 */
async function exchange(assertion: string, now: number): Promise<CachedToken> {
  const response = await fetch(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    // Google's error body is echoed, because a wrong `scope` and a wrong `aud` produce nearly identical
    // generic failures and the body is the only thing that distinguishes them. It contains no key material.
    const detail = (await response.text()).slice(0, 300);
    throw new Error(`Google token exchange failed: ${String(response.status)} ${detail}`);
  }

  const body: unknown = await response.json();
  if (typeof body !== "object" || body === null) {
    throw new Error("Google token endpoint returned a non-object body");
  }
  const record = body as { access_token?: unknown; expires_in?: unknown };
  if (typeof record.access_token !== "string") {
    throw new Error("Google token response has no access_token");
  }

  const lifetime = typeof record.expires_in === "number" ? record.expires_in : 3_600;
  // Never trust Google's `expires_in` over our own TTL constant: the plan's budget is built on 55
  // minutes, and a response claiming a 24-hour lifetime would leave the cache holding a token that dies
  // mid-send with nothing to explain it.
  const ttl = Math.min(lifetime, ACCESS_TOKEN_TTL_SECONDS);

  return {
    accessToken: record.access_token,
    expiresAt: now + ttl * 1_000,
  };
}

/**
 * Returns a valid access token, signing a new one only when the cache has expired.
 *
 * A rejected cached token (FCM answering 401) is not handled here. This function cannot know a send
 * happened; the caller clears the cache on an auth failure so the next invocation re-signs.
 */
export async function getAccessToken(
  key: SigningKey,
  now: number = Date.now(),
): Promise<string> {
  if (cached !== null && cached.expiresAt > now) {
    return cached.accessToken;
  }
  const assertion = await signAssertion(key, now);
  const fresh = await exchange(assertion, now);
  cached = fresh;
  return fresh.accessToken;
}