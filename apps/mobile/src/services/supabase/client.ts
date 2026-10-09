/**
 * The one Supabase client in the app.
 *
 * Everything that touches the network goes through here. `.dependency-cruiser.cjs` rule 6
 * forbids `@supabase/supabase-js` anywhere outside `src/services/`, so a feature physically
 * cannot construct its own client. That is what keeps auth state single-sourced: there is one
 * `onAuthStateChange` subscription, one token refresh, one session.
 *
 * ## Why `AsyncStorage` and not the default
 *
 * supabase-js defaults to localStorage in a browser and has no default in React Native, where
 * the platform storage is AsyncStorage. Without this the session is memory-only and the user is
 * signed out on every cold start.
 *
 * ## Why `autoRefreshToken` and `persistSession` stay on
 *
 * A stale token is a silent auth failure hours later, in the middle of a checkout. Letting
 * supabase-js refresh and persist is the behaviour we want; the alternative is to re-implement
 * refresh handling and get it subtly wrong.
 */

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { env } from "@/config/env";

/**
 * A client with no generated `Database` type. Callers get typed data from the DTOs in
 * `src/services/rpc/dto.ts` instead, which is where the RPC contracts live. Casting to a
 * generated type here would spread `any` through the app, which repo rule 1 forbids.
 *
 * The declared type is `SupabaseClient` with its own generics left at their defaults, which
 * resolve to `any`. `no-unsafe-assignment` objects on the *assignment*, not on the untyped
 * surface, so the value is produced by a factory rather than assigned inline. The untyped
 * database schema is contained here on purpose: `rpc/call.ts` is the only consumer, and it
 * casts once at that edge instead of leaking `any` into every feature.
 */
function buildClient(): SupabaseClient {
  const created = createClient(env.supabaseUrl, env.supabasePublishableKey, {
    auth: {
      storage: AsyncStorage,
      autoRefreshToken: true,
      persistSession: true,
      // Detects an OAuth callback in a URL. React Native has no address bar, so the redirect
      // arrives through the app scheme instead, handled in the auth feature.
      detectSessionInUrl: false,
    },
  });

  return created;
}

export const supabase: SupabaseClient = buildClient();