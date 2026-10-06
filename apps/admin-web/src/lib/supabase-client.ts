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
      // PKCE, not implicit. The verifier is held in storage and only ever used server-side to redeem a
      // short-lived code, so an access token never sits in a URL where it lands in browser history, a
      // `Referer` header or a screenshot of the address bar. For a console that may be left open on a shared
      // tablet, that difference is worth the extra step.
      flowType: "pkce",

      persistSession: true,
      autoRefreshToken: true,

      // MUST be true, and this is the second half of the sign-in flow.
      //
      // Google → Supabase → `redirectTo` lands the browser back at `/auth/callback` carrying the
      // authorization result. `true` is what makes supabase-js read it: exchange the code for a session when
      // the flow is PKCE, or parse the fragment when it is implicit. Set to `false` - as it was - supabase-js
      // never looks, so **no session is ever established** and every protected route redirects to sign-in
      // forever. The app looked correct and could never be signed in.
      detectSessionInUrl: true,

      storageKey: "marketak-admin-auth",
    },
    global: {
      headers: { "x-client-info": "marketak-admin-web/0.1.0" },
    },
  });
  return cached;
}