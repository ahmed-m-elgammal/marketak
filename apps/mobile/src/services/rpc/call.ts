/**
 * The single entry point to the database: one place that turns a Postgres failure into an AppError,
 * auditable to prove no feature calls supabase.rpc by hand.
 */

import { reportError } from "@/services/analytics";
import { parseServerError } from "@/services/errors/app-error";
import { supabase, type RpcParams } from "@/services/supabase/client";

export type { RpcParams };

async function invoke<Row>(fn: string, params: RpcParams): Promise<Row[]> {
  try {
    const response = await supabase.rpc<Row>(fn, params);

    if (response.error !== null) throw parseServerError(response.error);
    return response.data ?? [];
  } catch (error) {
    const parsed = parseServerError(error);
    reportError(`rpc:${fn}`, parsed);
    throw parsed;
  }
}

/**
 * First row, or null when the function returned none. PostgREST answers 200 with an empty array
 * for a function that produced no rows — a success with no payload, not a failure.
 */
export async function callRpc<Row>(fn: string, params: RpcParams = {}): Promise<Row | null> {
  const rows = await invoke<Row>(fn, params);
  return rows[0] ?? null;
}

export async function callRpcList<Row>(fn: string, params: RpcParams = {}): Promise<Row[]> {
  return invoke<Row>(fn, params);
}