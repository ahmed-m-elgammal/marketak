/**
 * Supabase environment, validated once at boot.
 *
 * Two rules meet here. R4 says one module creates the client; this module
 * decides *what it is created with*. And a service-role key must never reach
 * a phone: it bypasses every RLS policy the schema enforces (live-verified:
 * zero tables without RLS, `authenticated` holds SELECT-only throughout §3),
 * so a renamed variable promoting one would silently escalate the whole app.
 * The refusal below is what makes that accident loud instead of silent.
 *
 * Key shapes, from the contract (§2): the app ships a publishable key
 * (`sb_publishable_…`, opaque, RLS-scoped) or a legacy JWT `anon` key. A
 * legacy key carries its role in its payload, which is readable without
 * verifying the signature — refusal needs no secret. Anything else
 * (service-role JWT, unknown role, garbage) throws.
 */

/** `process` is ambient in Node but the mobile tsconfig restricts `types` to
 * react/react-native (uniformity contract in tsconfig.base), so it is
 * declared file-locally rather than widening every workspace. */
declare const process: {
  readonly env: Readonly<Record<string, string | undefined>>;
};

export interface SupabaseEnv {
  readonly url: string;
  readonly anonKey: string;
}

const PUBLISHABLE_PREFIX = "sb_publishable_";

function decodeJwtRole(key: string): string | null {
  const segments = key.split(".");
  if (segments.length !== 3) return null;
  const payload = segments[1];
  if (payload === undefined || payload === "") return null;
  const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(normalized.length + ((4 - (normalized.length % 4)) % 4), "=");
  let parsed: unknown;
  try {
    parsed = JSON.parse(atob(padded)) as unknown;
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || !("role" in parsed)) return null;
  const role: unknown = parsed.role;
  return typeof role === "string" ? role : null;
}

function readUrl(raw: string | undefined): string {
  if (raw === undefined || raw === "") {
    throw new Error("SUPABASE_ENV_MISSING: EXPO_PUBLIC_SUPABASE_URL is not set.");
  }
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error("SUPABASE_ENV_INVALID: EXPO_PUBLIC_SUPABASE_URL is not a URL.");
  }
  const host = parsed.hostname.toLowerCase();
  const loopback = host === "localhost" || host === "127.0.0.1" || host === "::1";
  if (parsed.protocol !== "https:" && !loopback) {
    throw new Error("SUPABASE_ENV_INVALID: EXPO_PUBLIC_SUPABASE_URL must be https (http is allowed for loopback local development only).");
  }
  return raw;
}

function readKey(raw: string | undefined): string {
  if (raw === undefined || raw === "") {
    throw new Error("SUPABASE_ENV_MISSING: EXPO_PUBLIC_SUPABASE_ANON_KEY is not set.");
  }
  if (raw.startsWith(PUBLISHABLE_PREFIX)) return raw;
  const role = decodeJwtRole(raw);
  if (role !== "anon") {
    throw new Error(
      "SUPABASE_KEY_REFUSED: EXPO_PUBLIC_SUPABASE_ANON_KEY is not a publishable/anon key. A service-role key bypasses all RLS policies and must never ship in the app.",
    );
  }
  return raw;
}

/**
 * Read and validate the environment. `source` defaults to `process.env` and
 * exists so tests can pass fakes; production callers never pass it.
 */
export function readEnv(source: Readonly<Record<string, string | undefined>> = process.env): SupabaseEnv {
  return { url: readUrl(source["EXPO_PUBLIC_SUPABASE_URL"]), anonKey: readKey(source["EXPO_PUBLIC_SUPABASE_ANON_KEY"]) };
}
