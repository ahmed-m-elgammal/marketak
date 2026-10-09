/**
 * Runtime configuration, read once and validated.
 *
 * Expo inlines `EXPO_PUBLIC_*` at build time from the project root `.env`, so these are
 * compile-time constants, not secrets. The Supabase *publishable* key is safe to ship in a
 * binary: it is only ever paired with RLS on the server. The `service_role` key must never
 * appear here — it bypasses RLS entirely and belongs in a Worker, not on a phone.
 *
 * Validation is eager and throws with the variable *name*. A missing key that surfaces later
 * as an opaque PostgREST failure costs far more than one loud boot-time error.
 */

/** The subset of `process.env` Expo guarantees to inline. */
type RawEnv = Readonly<
  Partial<Record<"EXPO_PUBLIC_SUPABASE_URL" | "EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY", string>>
>;

export interface AppEnv {
  readonly supabaseUrl: string;
  readonly supabasePublishableKey: string;
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
 * Builds the config from a raw bag. Takes the bag as a parameter rather than reading
 * `process.env` inline so the validation rules are testable without module mocking.
 */
export function readEnv(raw: RawEnv): AppEnv {
  return {
    supabaseUrl: requireValue(raw, "EXPO_PUBLIC_SUPABASE_URL"),
    supabasePublishableKey: requireValue(raw, "EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
  };
}

/**
 * Validated config, read once. Throws on a missing or placeholder variable.
 *
 * A module-level throw is deliberate. Every screen needs config, so there is no partial state in
 * which the app works without it, and an early crash beats a feature that silently fails on one
 * device and not another.
 */
export const env: AppEnv = readEnv(process.env as RawEnv);