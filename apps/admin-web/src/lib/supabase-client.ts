/**
 * `lib/supabase-client` - the single client instance.
 *
 * ## Why it is lazy
 *
 * Constructing a Supabase client at module scope would read `import.meta.env` during import, which means
 * importing any query module in a test requires the environment variables to exist. Lazy construction means
 * a test of `errors.ts` or a component's loading state runs with no `.env` at all, and the console still
 * fails loudly at the first real query.
 *
 * ## The anon key, restated
 *
 * `readConsoleEnv` refuses a service-role key. This module is the only caller, which means that refusal is on
 * the single path every query in the console takes - there is no way to build a privileged client by
 * reaching past it.
 */

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { readConsoleEnv } from "./supabase.js";

let cached: SupabaseClient | undefined;

/** The client, built on first use. */
export function getSupabase(): SupabaseClient {
  if (cached !== undefined) {
    return cached;
  }
  const env = readConsoleEnv(import.meta.env);
  cached = createClient(env.supabaseUrl, env.supabaseAnonKey, {
    auth: {
      // The console is a Google-only sign-in surface (constitution 5). No email, no password, no OTP, so
      // only the implicit flow is configured and nothing else can be attempted from here.
      flowType: "implicit",
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
      storageKey: "marketak-admin-auth",
    },
    global: {
      headers: { "x-client-info": "marketak-admin-web/0.1.0" },
    },
  });
  return cached;
}