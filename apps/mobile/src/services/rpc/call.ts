/**
 * The single entry point to the database.
 *
 * Every RPC goes through `callRpc`. That is deliberate: it is the one place that knows how a
 * Postgres failure becomes an `AppError`, and the one place that can be audited to prove no
 * feature is calling `supabase.rpc` by hand and skipping the mapping.
 *
 * ## Why the result is narrowed here
 *
 * PostgREST returns `200 OK` with an empty `data` array when a SELECT-family function produces
 * no rows. That is a success with no payload, not a failure, and treating it as one produces an
 * error toast for a legitimately empty list. `single` makes that choice explicit per call site
 * instead of letting each feature invent its own check.
 */

import { reportError } from "@/services/analytics";
import { parseServerError } from "@/services/errors/app-error";
import { supabase } from "@/services/supabase/client";

/** Postgres RPC arguments are JSON, and a row value may be null. */
export type RpcParams = Readonly<Record<string, unknown>>;

async function invoke<Row>(fn: string, params: RpcParams): Promise<Row[]> {
  try {
    // `data` and `error` are typed `any` because the client carries no generated schema. This
    // is the single place that is true, and the cast below is what turns it back into `Row`.
    // Destructuring an `any` is flagged by lint, so the result is held whole and narrowed once.
    const response = await supabase.rpc(fn, params);

    if (response.error !== null) throw parseServerError(response.error);
    return (response.data ?? []) as Row[];
  } catch (error) {
    // Report before rethrowing, and report the parsed error so the RPC name is the only context
    // needed to locate the failure. The parsed form carries no payload, so nothing personal is
    // attached.
    const parsed = parseServerError(error);
    reportError(`rpc:${fn}`, parsed);
    throw parsed;
  }
}

/**
 * Calls a function that returns a table and yields its first row, or `null` when it returned
 * none. Use for functions whose answer is a single row: quote, place, complete-profile.
 */
export async function callRpc<Row>(fn: string, params: RpcParams = {}): Promise<Row | null> {
  const rows = await invoke<Row>(fn, params);
  return rows[0] ?? null;
}

/**
 * Calls a function that returns a table and yields all rows. Use for functions whose answer is a
 * collection: an order list, an address list.
 */
export async function callRpcList<Row>(fn: string, params: RpcParams = {}): Promise<Row[]> {
  return invoke<Row>(fn, params);
}