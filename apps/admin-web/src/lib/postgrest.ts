/**
 * `lib/postgrest` - the one way the console calls a Postgres RPC.
 *
 * ## The error type
 *
 * PostgREST returns a plain object on failure — `{ message, code, details, hint }`. Not an `Error`: no `name`,
 * no `stack`, nothing a query cache can key on or an error boundary can recognise. Throwing it directly also
 * fails `only-throw-error`. Wrapping it means every call site throws the same kind of thing and `lib/errors.ts`
 * can read `code` and `message` without a `PostgrestError` import in every module.
 *
 * ## The one place `any` is narrowed
 *
 * `supabase.rpc` is typed `any`, because the return shape lives in the database rather than in a generated
 * type. constitution rule 1 permits `any` at the edge and requires it to be wrapped, not cast through. Four
 * query functions were each doing their own version of that wrapping, and two had drifted. `rpcRows` does it
 * once, so there is exactly one place to change if `supabase-js` ever generates real types.
 */
import { getSupabase } from "./supabase-client.js";

export class PostgrestQueryError extends Error {
  /** The sqlstate, or `undefined` when the failure did not come from Postgres. */
  public readonly code: string | undefined;

  public constructor(cause: unknown) {
    const record = typeof cause === "object" && cause !== null ? (cause as Record<string, unknown>) : {};
    const message = typeof record["message"] === "string" ? record["message"] : "RPC failed";
    const code = typeof record["code"] === "string" ? record["code"] : undefined;
    super(message, { cause });
    this.name = "PostgrestQueryError";
    this.code = code;
  }
}

/**
 * Calls an RPC and returns its rows as plain records.
 *
 * ## Why this helper exists
 *
 * `supabase.rpc` is typed `any` because the return shape lives in the database, not in a generated type.
 * constitution rule 1 permits `any` at the edge and requires it to be wrapped rather than cast through. Every
 * call site was doing the same four lines to achieve that - read `result.error` and `result.data` into `unknown`
 * before touching either - which is how four copies drifted and two of them were wrong.
 *
 * Doing it once here means every RPC in the console narrows the same way, and a future `supabase-js` release
 * that generates types has exactly one place to change.
 *
 * ## Why rows, not an object
 *
 * `returns TABLE(...)` means PostgREST answers with an **array**. An earlier draft of the drain work assumed an
 * object and silently defaulted every counter to zero, which on a dashboard is indistinguishable from a
 * database with no orders in it.
 */
export async function rpcRows(
  name: string,
  args?: Record<string, unknown>,
): Promise<readonly Record<string, unknown>[]> {
  const supabase = getSupabase();
  const result = args === undefined ? await supabase.rpc(name) : await supabase.rpc(name, args);
  // `unknown` first, then narrowed. Destructuring straight off `result` is what the lint rule objects to,
  // because `result.error` is `any` and every field read from it inherits that.
  const error: unknown = result.error;
  const data: unknown = result.data;

  if (error !== null && error !== undefined) {
    throw new PostgrestQueryError(error);
  }
  if (!Array.isArray(data)) {
    return [];
  }
  return data as readonly Record<string, unknown>[];
}