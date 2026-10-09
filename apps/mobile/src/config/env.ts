/** Validate at boot so a missing key fails here, not as an opaque 401 from PostgREST hours later. */

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
  /** Null when analytics is unconfigured: capture no-ops rather than crashing. */
  readonly posthogKey: string | null;
  readonly posthogHost: string;
}

export class MissingConfigError extends Error {
  constructor(readonly variable: string) {
    super(`Missing ${variable}. Copy .env.example to .env and fill it in, then restart with --clear.`);
    this.name = "MissingConfigError";
  }
}

function requireValue(raw: RawEnv, key: keyof RawEnv): string {
  const value = raw[key]?.trim();

  if (value === undefined || value.length === 0 || /^<.*>$/.test(value)) {
    throw new MissingConfigError(key);
  }

  return value;
}

/**
 * PostHog is the one optional value: analytics that is not configured must not stop somebody
 * ordering food. The placeholder case is still rejected, which catches a copied .env.example
 * silently sending every event nowhere.
 */
function optionalValue(raw: RawEnv, key: keyof RawEnv): string | null {
  const value = raw[key]?.trim();

  if (value === undefined || value.length === 0) return null;
  if (/^<.*>$/.test(value)) throw new MissingConfigError(key);

  return value;
}

/** Takes the bag as a parameter so the rules are testable without module mocking. */
export function readEnv(raw: RawEnv): AppEnv {
  return {
    supabaseUrl: requireValue(raw, "EXPO_PUBLIC_SUPABASE_URL"),
    supabasePublishableKey: requireValue(raw, "EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    posthogKey: optionalValue(raw, "EXPO_PUBLIC_POSTHOG_KEY"),
    // US region default. A EU-hosted project uses https://eu.i.posthog.com.
    posthogHost: optionalValue(raw, "EXPO_PUBLIC_POSTHOG_HOST") ?? "https://us.i.posthog.com",
  };
}

export const env: AppEnv = readEnv(process.env as RawEnv);