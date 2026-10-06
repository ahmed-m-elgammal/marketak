/**
 * `config/logger` - structured logging, and the error codes the drain reports.
 *
 * ## Why this module exists
 *
 * The first deployed Worker logged one `console.log` per run and nothing else. Tracing a live failure meant
 * querying Supabase's log stream by `sqlstate` and inferring the rest, because **Supabase's `postgres_logs`
 * returns an EMPTY `message` field** - only `parsed.sql_state_code`, `parsed.error_severity` and
 * `parsed.query` are populated. The diagnosis took four queries and a deliberate timestamp filter, and the
 * signal that identified the bug was the *pattern* - five `42703` per minute at :59, :00, :01 - not any text.
 *
 * So the Worker must be the place where an error becomes a readable sentence, because the database will not
 * do it for us.
 *
 * ## Three rules
 *
 * 1. **`console.error` for anything that needs attention, `console.log` for anything else.** Workers Logs
 *    indexes `$metadata.level`, so an error that goes to `log` is invisible to an error filter. That is the
 *    single highest-value line in this file.
 * 2. **A code, not prose.** Every failure carries a stable `code` from `ErrorCode`. Prose changes when someone
 *    rewords a message; a code does not, so a dashboard can count `FCM_AUTH` without matching on English.
 * 3. **Never a secret.** The log layer is the last place to defend, and a message is what ends up in a
 *    screenshot. `redact` is applied to anything derived from a response body.
 */

/**
 * Stable, greppable outcome codes. Never reword these; ADD to them.
 *
 * `DELIVERED` is here so that every emitted line has a `code`, which keeps the field meaningful rather than
 * occasionally-populated. It is not an error.
 */
export const ErrorCode = {
  // --- the success case. Present so every logged line carries a code, not so it can be alerted on ---
  DELIVERED: "DELIVERED",

  // --- configuration, before any work happens ---
  CONFIG_MISSING: "CONFIG_MISSING",
  CONFIG_INVALID: "CONFIG_INVALID",

  // --- reaching the database ---
  DB_CLAIM_FAILED: "DB_CLAIM_FAILED",
  DB_TEMPLATE_FAILED: "DB_TEMPLATE_FAILED",
  DB_TOKENS_FAILED: "DB_TOKENS_FAILED",
  DB_MARK_FAILED: "DB_MARK_FAILED",
  DB_EVENT_ID_UNSAFE: "DB_EVENT_ID_UNSAFE",

  // --- Google ---
  GOOGLE_TOKEN_FAILED: "GOOGLE_TOKEN_FAILED",

  // --- FCM. Split by what an operator should DO about it. ---
  /** Our credentials are wrong. `access-token.ts` clears its cache; a retry re-signs. */
  FCM_AUTH: "FCM_AUTH",
  /** The token itself is dead. Phase 4 deletes these on sign-out; until then they cost quota. */
  FCM_TOKEN_DEAD: "FCM_TOKEN_DEAD",
  /** FCM is busy or broken. Back off and retry next tick. */
  FCM_THROTTLED: "FCM_THROTTLED",
  /** Network never completed. */
  FCM_NETWORK: "FCM_NETWORK",
  /** Anything else FCM said, with its status. */
  FCM_REJECTED: "FCM_REJECTED",

  // --- notification content ---
  /** A template placeholder had no value. The message would have shipped a literal `{placeholder}`. */
  RENDER_UNFILLED: "RENDER_UNFILLED",
  TEMPLATE_MISSING: "TEMPLATE_MISSING",
  /** The recipient has no registered device. Legitimate; logged at info, not error. */
  NO_DEVICE_TOKEN: "NO_DEVICE_TOKEN",
} as const;

export type ErrorCodeValue = (typeof ErrorCode)[keyof typeof ErrorCode];

/** How a line is logged. Drives `console.error` vs `console.log`, and the searchable level. */
export type Severity = "info" | "warn" | "error";

/**
 * Anything that went wrong, in a shape that can be counted and filtered.
 *
 * `context` values are scalars on purpose: Workers Logs indexes the top-level fields, so a nested object
 * has to be flattened before it can be found by a query.
 */
export interface LogEntry {
  readonly severity: Severity;
  readonly code: ErrorCodeValue;
  readonly message: string;
  /** Which line this is. `drain-manual` and `drain` are summary lines; the rest are per-notification. */
  readonly event?: string;
  readonly drain_run_id?: string;
  readonly template_key?: string;
  readonly recipient?: string;
  readonly order_id?: string;
  /**
   * `number | bigint` on purpose.
   *
   * Event counts come from `readonly bigint[]` arrays, so a caller passing `claim.event_ids.length` naturally
   * has a `number` - but a caller echoing an id (`event_ids[0]`) has a `bigint`. Allowing both here is what lets
   * `log` own the bigint-to-string conversion instead of every call site remembering to do it, which is the
   * mistake that crashed the first live drain.
   */
  readonly event_count?: number | bigint;
  readonly elapsed_ms?: number;
  /**
   * Cloudflare's request id, and the HTTP details alongside it.
   *
   * `cf_ray` is the join key to Cloudflare's dashboard, and it is the only identifier that exists before any
   * application code runs - so it is what turns "the drain failed at 03:12" into "this specific request
   * failed". `drain_run_id` is deliberately optional because a 404 or a 401 has no drain behind it.
   */
  readonly cf_ray?: string;
  readonly http_status?: string;
  readonly method?: string;
  readonly path?: string;
  /** The drain counters, on a summary line only. */
  readonly dry_run?: string;
  readonly claimed?: number;
  readonly sent?: number;
  readonly failed?: number;
  readonly unrenderable?: number;
  readonly marked?: number;
  readonly still_open?: number;
  readonly duration_ms?: number;
  readonly errors?: readonly string[];
}

/**
 * The key that must never reach a log.
 *
 * Redaction is done HERE rather than at each call site, because the call sites are where mistakes happen.
 * A key is a 200+ character opaque string; a substring match against a 12-character pattern is enough to
 * catch it whatever shape it takes.
 */
const SECRET_MARKERS = [
  "sb_secret_",
  "eyJhbGciOi",
  "-----BEGIN",
  "private_key",
];

/**
 * Strips anything that looks like a credential from a message or a context value.
 *
 * Length-capped as well as filtered, for a reason that is not paranoia: `last_error` is written to
 * `events.last_error` and shown in the admin console, so an unbounded error string is a place for a whole
 * FCM response body to accumulate.
 */
export function redact(value: string, maxLength = 300): string {
  let out = value;
  for (const marker of SECRET_MARKERS) {
    if (out.includes(marker)) {
      return `[redacted: contained ${marker}]`;
    }
  }
  if (out.length > maxLength) {
    out = `${out.slice(0, maxLength)}…[truncated ${String(out.length - maxLength)} chars]`;
  }
  return out;
}

/** A short, unique id for one drain invocation. Makes a run's log lines groupable. */
export function newRunId(): string {
  return `run_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Writes one structured line.
 *
 * The shape is chosen for querying: `severity` and `code` are top-level scalars, so a filter for
 * `code = "FCM_AUTH"` finds every occurrence without touching the message text.
 *
 * `console.error` for `error`, `console.warn` for `warn`, `console.log` otherwise. Workers Logs maps these to
 * `$metadata.level`, and a `wrangler tail --status error` filter only ever sees the first one.
 */
export function log(entry: LogEntry): void {
  // BigInt would throw here exactly as it did in `JSON.stringify` on the first live drain. The report
  // already converts ids to strings; this is the belt to that braces.
  const payload = JSON.stringify(
    { ...entry, message: redact(entry.message) },
    (_key, value: unknown) => (typeof value === "bigint" ? value.toString() : value),
  );

  if (entry.severity === "error") {
    console.error(payload);
    return;
  }
  if (entry.severity === "warn") {
    console.warn(payload);
    return;
  }
  console.log(payload);
}

/**
 * Turns a thrown value into a redacted one-line message.
 *
 * `Error.message` for an Error, `String()` for anything else, never the whole stack in the line. The stack
 * is available through the platform's own error tracking; duplicating it in the message field makes the
 * message unreadable in a log search.
 */
export function describeError(error: unknown): string {
  if (error instanceof Error) {
    return redact(`${error.name}: ${error.message}`);
  }
  return redact(String(error));
}