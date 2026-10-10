/**
 * The single Supabase client (architecture rule R4).
 *
 * This module is the only file in `apps/mobile` that imports
 * `@supabase/supabase-js` — enforced mechanically by `no-restricted-imports`
 * (statement) and `.dependency-cruiser.cjs` (re-export). Everything else,
 * including the RPC boundary, goes through `getSupabaseClient()` and never
 * sees the package.
 *
 * Wiring note, stated plainly: `createSupabaseClient` passes `(url, key)`
 * positionally with no injection seam, so an argument swap would be silent
 * to unit tests. The seam was deliberately omitted — a seam here would need
 * package types in test files, which the same import ban forbids. Arg order
 * is covered by review plus the first live smoke of any RPC caller.
 */
// eslint-disable-next-line no-restricted-imports -- the single allowed importer (R4): this module creates the client; the ban applies to everything else.
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@marketak/shared";
import { readEnv, type SupabaseEnv } from "./env";

type DbFunctions = Database["public"]["Functions"];
export type DbFunctionName = Extract<keyof DbFunctions, string>;
export type AppSupabaseClient = SupabaseClient<Database>;

/** Build a typed client. `Database` is generated (rule 1: constraint, never a cast surface). */
export function createSupabaseClient(env: SupabaseEnv): AppSupabaseClient {
  return createClient<Database>(env.url, env.anonKey, {
    auth: { persistSession: true, autoRefreshToken: true },
  });
}

let singleton: AppSupabaseClient | null = null;

/** The app-wide client, memoized. `readEnv()` throws at first use when unconfigured. */
export function getSupabaseClient(): AppSupabaseClient {
  if (singleton === null) singleton = createSupabaseClient(readEnv());
  return singleton;
}

/**
 * One RPC invocation as a pluggable unit. The adapter exists so `call.ts`
 * programs against this small surface (fakes in tests) instead of the
 * full PostgREST builder, which test files may not import (same ban).
 *
 * `single()` switches to object-response mode (`maybeSingle` semantics:
 * null when empty) for the RPCs that return exactly one row. PostgREST
 * returns arrays for table functions otherwise, and an array where an
 * object belongs is a shape mismatch, not a row.
 */
export interface RpcCall {
  abortSignal(signal: AbortSignal): RpcCall;
  single(): RpcCall;
  execute(): Promise<{ data: unknown; error: { message: string } | null }>;
}

/**
 * Wrap one `client.rpc` call. Business errors resolve; transport rejects.
 *
 * `args` stays `Record<string, unknown>` rather than the generated Args
 * union: the generated union cannot accept the hand-typed readonly command
 * objects, and the overload resolves cleanly against `Record`. Runtime
 * soundness is unaffected — readonly vanishes in JSON, and every object
 * reaching here was built against `commands.ts`.
 */
export function rpcOn(
  client: AppSupabaseClient,
  method: DbFunctionName,
  args: Record<string, unknown>,
): RpcCall {
  const started = client.rpc(method, args);
  const call: RpcCall = {
    abortSignal(signal: AbortSignal): RpcCall {
      started.abortSignal(signal);
      return call;
    },
    single(): RpcCall {
      started.maybeSingle();
      return call;
    },
    async execute(): Promise<{ data: unknown; error: { message: string } | null }> {
      const outcome = await started;
      return {
        data: outcome.data,
        error: outcome.error === null ? null : { message: outcome.error.message },
      };
    },
  };
  return call;
}
