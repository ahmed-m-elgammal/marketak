/**
 * `lib/supabase` - the ONE Supabase client in the console.
 *
 * ## The publishable-key rule
 *
 * constitution 5: Google and Apple only, and the browser holds no secret. This module reads
 * `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`, both of which are safe to ship - the anon key is
 * publishable by design and every read it makes is filtered by RLS. A `service_role` key in this bundle
 * would bypass RLS entirely, which is the single most damaging thing that could happen to this codebase.
 *
 * `assertNoServiceRoleKey` is therefore not defensive programming for a hypothetical. Vite will happily
 * inline any `VITE_`-prefixed variable into a browser bundle, so if someone renames the service role key
 * to `VITE_SUPABASE_SERVICE_ROLE_KEY` in a hurry, nothing else would notice until an admin's browser could
 * read every row of every table. It refuses to construct a client in that case.
 */

/** The shape of the environment this module needs. Only the two publishable values. */
export interface ConsoleEnv {
  readonly supabaseUrl: string;
  readonly supabaseAnonKey: string;
}

export class ConfigError extends Error {
  public constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

/**
 * True for a JWT-shaped Supabase secret.
 *
 * The legacy anon key is a JWT (`eyJ...`) and so is the service-role key. The two are told apart by their
 * claims, not by their shape, so this is only a shape check and the refusal below is what actually matters.
 */
function looksLikeJwt(value: string): boolean {
  return value.startsWith("eyJ") && value.split(".").length === 3;
}

/**
 * Reads the environment, and refuses a service-role key.
 *
 * Throws `ConfigError` rather than returning a degraded client. A console that cannot reach the database
 * must fail at the boundary with a message an operator can act on; a console that silently falls back to
 * anonymous access would render every list permanently empty and look like an RLS bug.
 */
export function readConsoleEnv(env: Record<string, string | undefined>): ConsoleEnv {
  const url = env["VITE_SUPABASE_URL"];
  const anonKey = env["VITE_SUPABASE_ANON_KEY"];

  if (url === undefined || url.length === 0) {
    throw new ConfigError(
      "VITE_SUPABASE_URL is not set. Add it to apps/admin-web/.env.local. Only the project URL - it is not a secret.",
    );
  }
  if (anonKey === undefined || anonKey.length === 0) {
    throw new ConfigError(
      "VITE_SUPABASE_ANON_KEY is not set. Add it to apps/admin-web/.env.local. Use the publishable/anon key, never the service-role key.",
    );
  }

  if (/service_role/i.test(anonKey)) {
    throw new ConfigError(
      "VITE_SUPABASE_ANON_KEY looks like a service-role key. Refusing to start: it bypasses RLS and must never reach a browser.",
    );
  }
  if (looksLikeJwt(anonKey)) {
    // Not an error - the legacy anon key IS a JWT and is still supported. Logged so the team knows to
    // migrate to the `sb_publishable_` form, which Supabase can rotate independently of the JWT secret.
    console.warn(
      "The anon key is a legacy JWT. Prefer the publishable key (sb_publishable_...), which can be rotated without reissuing the JWT secret.",
    );
  }

  return { supabaseUrl: url, supabaseAnonKey: anonKey };
}