/**
 * `lib/queries/metrics` - reading `get_admin_metrics_v1`.
 *
 * ## Why the payload is narrowed here and nowhere else
 *
 * The RPC returns `TABLE(payload jsonb)`, which means TypeScript sees `any`. constitution rule 1 forbids
 * letting an `any` through, and the exception it allows - "generated Supabase types are `any` at the edge,
 * wrap them, do not cast through them" - is exactly this: the narrowing happens once, here, at the boundary.
 *
 * Every field below was read off the live function body, not guessed. `get_admin_metrics_v1` builds its
 * result with `jsonb_build_object` and the keys are literals in that call, so this interface is a
 * transcription rather than an inference - and `tests/metrics.test.ts` asserts the renderer survives a
 * payload missing any of them.
 *
 * ## Why it is imported dynamically in the page
 *
 * Not for bundle size - that is the route's lazy boundary's job. Because this module constructs a Supabase
 * client, and a test that imports the page should not need `VITE_SUPABASE_URL` in scope to render a loading
 * state.
 */

import { getSupabase } from "../supabase-client.js";

/** `cities.timezone` as the RPC resolved it, e.g. `Africa/Cairo`. */
export interface MetricsPayload {
  readonly business_date: string;
  readonly timezone: string;
  readonly orders: {
    readonly placed: number;
    readonly delivered: number;
    readonly cancelled: number;
    readonly open: number;
    readonly completion_rate_bps: number;
  };
  readonly revenue: {
    readonly currency: string;
    readonly delivery_fees_settled: number;
    readonly rider_tips: number;
    readonly cash_expected: number;
    readonly cash_remitted: number;
    readonly float_variance: number;
  };
  readonly vendors: {
    readonly active_approved: number;
    readonly open_now: number;
    readonly paused: number;
    readonly pending_approval: number;
  };
  readonly riders: {
    readonly active: number;
    readonly online_now: number;
    readonly verified_online: number;
  };
}

/**
 * Narrows an unknown value to `MetricsPayload`, or returns `null`.
 *
 * Deliberately total: it checks for the presence of the nested objects and the fields the dashboard reads,
 * and returns `null` rather than throwing on anything else. A `null` renders the empty state; a throw would
 * render the error state for what is really a shape change in a database function - and an operator would be
 * told "something went wrong" when the honest answer is "the dashboard's data changed".
 */
/**
 * Reads a value as a string, or returns `undefined` when it is not one.
 *
 * `String(value)` on an `unknown` is how `[object Object]` reaches a screen, so the type is checked before
 * the cast. Every call site below falls back to a default, which is the behaviour `String()` would have
 * produced for the well-typed cases anyway.
 */
function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

/** Reads a value as a finite number, or returns `undefined`. `NaN` from a corrupt figure is not a number. */
function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/** `n(value, fallback)` - a finite number or the fallback. Used for every count and every rate. */
function n(value: unknown, fallback: number): number {
  return asNumber(value) ?? fallback;
}

function narrowPayload(value: unknown): MetricsPayload | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const candidate = value as Record<string, unknown>;
  const orders = candidate["orders"];
  const revenue = candidate["revenue"];
  const vendors = candidate["vendors"];
  const riders = candidate["riders"];

  if (
    typeof orders !== "object" || orders === null ||
    typeof revenue !== "object" || revenue === null ||
    typeof vendors !== "object" || vendors === null ||
    typeof riders !== "object" || riders === null
  ) {
    return null;
  }

  const o = orders as Record<string, unknown>;
  const r = revenue as Record<string, unknown>;
  const v = vendors as Record<string, unknown>;
  const d = riders as Record<string, unknown>;

  return {
    // The date and timezone are echoed back from the RPC, which derived them from `cities.timezone`. Shown on
    // the dashboard so an operator knows which day and which zone the numbers describe.
    business_date: asString(candidate["business_date"]) ?? "unknown",
    timezone: asString(candidate["timezone"]) ?? "UTC",
    orders: {
      placed: n(o["placed"], 0),
      delivered: n(o["delivered"], 0),
      cancelled: n(o["cancelled"], 0),
      open: n(o["open"], 0),
      completion_rate_bps: n(o["completion_rate_bps"], 0),
    },
    revenue: {
      currency: asString(r["currency"]) ?? "EGP",
      delivery_fees_settled: n(r["delivery_fees_settled"], 0),
      rider_tips: n(r["rider_tips"], 0),
      cash_expected: n(r["cash_expected"], 0),
      cash_remitted: n(r["cash_remitted"], 0),
      float_variance: n(r["float_variance"], 0),
    },
    vendors: {
      active_approved: n(v["active_approved"], 0),
      open_now: n(v["open_now"], 0),
      paused: n(v["paused"], 0),
      pending_approval: n(v["pending_approval"], 0),
    },
    riders: {
      active: n(d["active"], 0),
      online_now: n(d["online_now"], 0),
      verified_online: n(d["verified_online"], 0),
    },
  };
}

/**
 * A failed RPC, as an `Error`.
 *
 * PostgREST returns a plain object on failure, not an `Error` - no `name`, no `stack`, nothing a query cache
 * or an error boundary can treat as a thrown error. Wrapping it here means every call site in the console
 * throws the same kind of thing, and `lib/errors.ts` can read `code` and `message` off it without a
 * `PostgrestError` import in every module.
 *
 * The `cause` is the original object, so nothing is lost and `Error.cause` keeps it in the stack trace.
 */
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
 * Calls `get_admin_metrics_v1` for today.
 *
 * No `p_date` argument, so the RPC applies its own default - "today in the city's timezone". Sending the
 * browser's date instead would be wrong by up to a day in Cairo, and would silently disagree with the
 * number the RPC computed.
 */
export async function getAdminMetrics(): Promise<MetricsPayload | null> {
  const supabase = getSupabase();
  // Destructured rather than accessed field by field: the rule flags any property read off an `any`, and
  // `rpc` is typed `any` because the return shape lives in the database. The two reads below are the whole
  // of the `any` surface, and each is immediately handed to a narrower type.
  const result = await supabase.rpc("get_admin_metrics_v1");
  const error: unknown = result.error;
  const raw: unknown = result.data;

  if (error !== null && error !== undefined) {
    // Re-wrapped rather than rethrown. A PostgREST error is a plain object with a `message`, a `code` and a
    // `details` - it is not an `Error`, and `lib/errors.ts` reads it as a `DatabaseErrorLike`, so wrapping it
    // in a real Error makes it a stack-traceable failure that a query cache can key on.
    throw new PostgrestQueryError(error);
  }

  // The RPC returns a single row, so PostgREST answers with an array of one.
  const first: unknown = Array.isArray(raw) ? raw[0] : raw;
  if (typeof first !== "object" || first === null) {
    return null;
  }

  return narrowPayload((first as Record<string, unknown>)["payload"]);
}