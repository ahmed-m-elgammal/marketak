/**
 * Runtime configuration, read once and validated.
 *
 * Expo inlines `EXPO_PUBLIC_*` at build time from the project root `.env`, so these are
 * compile-time constants, not secrets. Two different kinds of key appear here, and the difference
 * matters:
 *
 * | Key | Kind | Safe to ship in the binary? |
 * |---|---|---|
 * | `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (`sb_publishable_…`) | RLS-scoped, paired with policies server-side | yes |
 * | `EXPO_PUBLIC_POSTHOG_KEY` (`phc_…`) | write-only ingest | yes |
 * | `service_role` / `phx_…` | bypasses RLS / reads the whole project | **never** |
 *
 * Validation is eager and throws with the variable *name*. A missing key that surfaces later as
 * an opaque failure costs far more than one loud boot-time error.
 */

/** The subset of `process.env` Expo guarantees to inline. */
type RawEnv = Readonly<
  Partial<
    Record<
      | "EXPO_PUBLIC_SUPABASE_URL"
      | "EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY"
      | "EXPO_PUBLIC_POSTHOG_KEY"
      | "EXPO_PUBLIC_POSTHOG_HOST",
      string
    >
  >
>;

export interface AppEnv {
  readonly supabaseUrl: string;
  readonly supabasePublishableKey: string;
  /** Null when analytics is not configured. Capture then no-ops rather than crashing. */
  readonly posthogKey: string | null;
  readonly posthogHost: string;
}

export class MissingConfigError extends Error {
  constructor(readonly variable: string) {
    super(`Missing ${variable}. Copy .env.example to .env and fill it in, then restart with --clear.`);
    this.name = "MissingConfigError";
  }
}

/**
 * Rejects a value that is absent or still the placeholder, so a copied `.env.example` fails at
 * boot instead of producing a confusing 401 from the API.
 */
function requireValue(raw: RawEnv, key: keyof RawEnv): string {
  const value = raw[key]?.trim();

  if (value === undefined || value.length === 0 || /^<.*>$/.test(value)) {
    throw new MissingConfigError(key);
  }

  return value;
}

/**
 * Reads a value that may legitimately be absent.
 *
 * PostHog is the one exception to the fail-loud rule: analytics that is not configured must not
 * stop a shopper ordering food, so an absent key disables capture instead of throwing. The
 * placeholder case is still rejected, which catches a copied `.env.example` silently sending
 * every event nowhere.
 */
function optionalValue(raw: RawEnv, key: keyof RawEnv): string | null {
  const value = raw[key]?.trim();

  if (value === undefined || value.length === 0) return null;
  if (/^<.*>$/.test(value)) throw new MissingConfigError(key);

  return value;
}

/**
 * Builds the config from a raw bag. Takes the bag as a parameter rather than reading
 * `process.env` inline so the validation rules are testable without module mocking.
 */
export function readEnv(raw: RawEnv): AppEnv {
  return {
    supabaseUrl: requireValue(raw, "EXPO_PUBLIC_SUPABASE_URL"),
    supabasePublishableKey: requireValue(raw, "EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    posthogKey: optionalValue(raw, "EXPO_PUBLIC_POSTHOG_KEY"),
    // US region is the default. A EU project would use https://eu.i.posthog.com.
    posthogHost: optionalValue(raw, "EXPO_PUBLIC_POSTHOG_HOST") ?? "https://us.i.posthog.com",
  };
}

/**
 * Validated config, read once. Throws on a missing or placeholder Supabase variable.
 *
 * A module-level throw is deliberate. Every screen needs config, so there is no partial state in
 * which the app works without it, and an early crash beats a feature that silently fails on one
 * device and not another.
 */
export const env: AppEnv = readEnv(process.env as RawEnv);