/**
 * The one Supabase client. Depcruise rule 6 confines it to src/services/, so no feature can open a
 * second one — two clients means two token refreshers racing and the loser's write wins.
 *
 * The client is typed by `RpcCaller` rather than by supabase-js's own generics. Without generated
 * database types those resolve to `any` in a way that defeats the compiler — `rpc()` ends up
 * rejecting its own arguments. Describing only the four fields we use keeps the boundary honest
 * and gives rpc/call.ts real types to work with.
 */

import { createClient, type Session, type User } from "@supabase/supabase-js";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { env } from "@/config/env";

/** Postgres RPC arguments are JSON, and a row value may be null. */
export type RpcParams = Readonly<Record<string, unknown>>;

export interface RpcResponse<Row> {
  readonly data: Row[] | null;
  readonly error: { readonly message: string } | null;
}

export interface RpcCaller {
  rpc<Row>(fn: string, params: RpcParams): Promise<RpcResponse<Row>>;
}

/**
 * The auth surface the app uses. Narrower than supabase-js's own on purpose: naming exactly what is
 * called here means a future SDK change shows up as a type error in this file, not at ten call
 * sites. Session and User are the SDK's real types, not `unknown` — the session is what identifies
 * a shopper, so losing its shape would lose the user id.
 */
export interface AuthSurface {
  readonly signOut: () => Promise<{ error: unknown }>;
  readonly signInWithOAuth: (options: {
    provider: string;
    options: { redirectTo: string; skipBrowserRedirect: boolean };
  }) => Promise<{ data: { url: string | null } | null; error: unknown }>;
  readonly signInWithIdToken: (options: {
    provider: string;
    token: string;
    nonce: string;
  }) => Promise<{ error: unknown }>;
  readonly exchangeCodeForSession: (url: string) => Promise<{ error: unknown }>;
  readonly onAuthStateChange: (
    callback: (event: string, session: Session | null) => void,
  ) => { data: { subscription: { unsubscribe: () => void } } };
}

export interface SupabaseClient extends RpcCaller {
  readonly auth: AuthSurface;
}

export type { Session, User };

function buildClient(): SupabaseClient {
  const client = createClient(env.supabaseUrl, env.supabasePublishableKey, {
    auth: {
      // supabase-js has no React Native storage default; without this the session is memory-only
      // and the shopper is signed out on every cold start.
      storage: AsyncStorage,
      autoRefreshToken: true,
      persistSession: true,
      // RN has no address bar for a redirect handler to attach to. The OAuth callback arrives on
      // the deep link instead, handled by the auth feature.
      detectSessionInUrl: false,
    },
  });

  // Contained here so no-unsafe-* does not fire at every call site. The schema is genuinely absent;
  // the Row generic re-establishes the type one layer up.
  return client as unknown as SupabaseClient;
}

export const supabase: SupabaseClient = buildClient();