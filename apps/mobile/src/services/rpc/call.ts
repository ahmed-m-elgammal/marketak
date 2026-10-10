/**
 * The RPC transport: the only place `supabase.rpc` runs (architecture R4).
 *
 * Two failure kinds leave here, and they are distinguished by construction:
 *
 * - The call RESOLVES with `{ error }` → a business failure. `error.message`
 *   starts with a SCREAMING_SNAKE code (contract §1, including the 42501
 *   `FORBIDDEN` shape) and parses via the shared parser. The Arabic text
 *   travels untouched into `AppError.serverMessage`.
 * - The call REJECTS (network down, aborted signal, 5xx transport collapse)
 *   → a transport failure: `AppError` with `kind: "business"`, `code: null`,
 *   empty message, and the original error as `cause`. Callers tell the two
 *   apart by the cause — `cause instanceof TypeError` (or `DOMException`)
 *   means transport; a `ZodError` cause means the schema rejected the payload
 *   (see `decodeWith`). No invented codes: a `TRANSPORT_*` prefix would look
 *   exactly like a server code to the next reader.
 *
 * Mismatch recorder (mobile README §8 rule 3): the first schema failure per
 * RPC name is kept in-module so a whole class of drift is fixed in one pass,
 * not one crash at a time. Tests use unique RPC names instead of a reset
 * export — there is no test-only seam in production code.
 */
import { AppError, parseAppError } from "@marketak/shared";
import { getSupabaseClient, rpcOn, type DbFunctionName, type RpcCall } from "../supabase/client";

export interface RpcDeps {
  readonly call?: (method: DbFunctionName, args: Record<string, unknown>) => RpcCall;
  readonly signal?: AbortSignal;
  readonly single?: boolean;
}

const firstMismatchByRpc = new Map<string, string>();

export function recordMismatch(rpcName: string, issue: string): void {
  if (!firstMismatchByRpc.has(rpcName)) firstMismatchByRpc.set(rpcName, issue);
}

export function readMismatch(rpcName: string): string | undefined {
  return firstMismatchByRpc.get(rpcName);
}

/**
 * Validate one RPC payload. Throws `AppError` (code null, empty message,
 * `ZodError` cause — see header) on mismatch. Never returns a guess.
 */
export function decodeWith<T>(
  rpcName: string,
  schema: { parse(data: unknown): T },
  data: unknown,
): T {
  try {
    return schema.parse(data);
  } catch (error) {
    const issue = error instanceof Error ? error.message : "schema mismatch";
    recordMismatch(rpcName, issue);
    throw new AppError("business", null, "", error);
  }
}

function toTransportError(error: unknown): AppError {
  return new AppError("business", null, "", error);
}

const ABORT_PREFIX = "AbortError:";

/**
 * postgrest-js RESOLVES aborted requests (never rejects them) with an
 * `AbortError: ...` message carrying no server code. It must neither render
 * (not shopper copy) nor retry (cancelled means cancelled): empty message,
 * original preserved as cause. Reads.ts shares this helper.
 */
export function toBusinessError(raw: { message: string }): AppError {
  if (raw.message.startsWith(ABORT_PREFIX)) return new AppError("business", null, "", raw);
  return parseAppError(raw);
}

/**
 * Call one RPC and decode its payload. Writes never retry inside here:
 * a retry reuses the caller's idempotency key explicitly (F-04 retry
 * policy). Reads retry in `reads.ts`, not here.
 */
export async function callRpc<T>(
  rpcName: DbFunctionName,
  args: Record<string, unknown>,
  schema: { parse(data: unknown): T },
  deps?: RpcDeps,
): Promise<T> {
  const call = (deps?.call ?? ((method, a): RpcCall => rpcOn(getSupabaseClient(), method, a)))(rpcName, args);
  if (deps?.signal !== undefined) call.abortSignal(deps.signal);
  if (deps?.single === true) call.single();
  let outcome: { data: unknown; error: { message: string } | null };
  try {
    outcome = await call.execute();
  } catch (error) {
    throw toTransportError(error);
  }
  if (outcome.error !== null) throw toBusinessError(outcome.error);
  return decodeWith(rpcName, schema, outcome.data);
}
