/**
 * Typed failure model.
 *
 * Every RPC in this database raises a Postgres exception whose *message* begins with a
 * SCREAMING_SNAKE code, e.g. `ITEM_RETIRED: الصنف غير متاح`. The Arabic text after the colon is
 * already localised for the shopper, so the client never writes its own message for a business
 * failure — it shows what the server sent and uses the code only to decide behaviour.
 *
 * `AppError` is the only error type that reaches a screen. Anything else is a bug or a transport
 * problem and is reported as `unknown`, because a screen that renders "something went wrong" for
 * a network blip teaches the user to distrust every message.
 */

/** Discriminates the cases a screen actually branches on. */
export type AppErrorKind =
  | "unauthenticated"
  | "invalid-input"
  | "conflict"
  | "business"
  | "transport"
  | "unknown";

/**
 * The subset of error codes that change what the app *does* rather than what it shows.
 *
 * Every other code is `business` and needs no client branch. This list is deliberately short: a
 * code belongs here only if the app has different behaviour for it, and inventing an entry for
 * every server code would move business rules into the client.
 */
export const BEHAVIOUR_CODES = {
  /** No session, or the session is not the owner. The app returns to sign-in. */
  unauthenticated: [
    "NOT_AUTHORIZED",
    "AUTH_REQUIRED",
    "OWNER_REQUIRED",
    "RIDER_REQUIRED",
    "ACCOUNT_REQUIRED",
  ],
  /** Bad input. The caller may retry with different values; never a global error. */
  invalidInput: [
    "INVALID_QUANTITY",
    "INVALID_OPTIONS",
    "OPTION_SELECTION_INVALID",
    "SIZE_REQUIRED",
    "PHONE_INVALID",
    "PHONE_IN_USE",
    "NAME_INVALID",
    "VENDOR_COUNT_INVALID",
    "PERIOD_INVALID",
    "DELIVERY_TYPE_INVALID",
  ],
  /** State moved underneath us. The caller re-reads and retries rather than showing an error. */
  conflict: [
    "PRICE_CHANGED",
    "ITEM_PRICE_CHANGED",
    "DELIVERY_FEE_CHANGED",
    "QUOTE_EXPIRED",
    "IDEMPOTENCY_KEY_TAKEN",
    "LEDGER_CONFLICT",
    "WALLET_CONFLICT",
    "INVALID_TRANSITION",
  ],
} as const satisfies Record<string, readonly string[]>;

/** Matches `CODE: message`, tolerating the `raise exception 'CODE: %', 'msg'` shape. */
const CODE_PATTERN = /^([A-Z][A-Z0-9_]+):\s*(.*)$/s;

function kindOf(code: string | null): AppErrorKind {
  if (code === null) return "transport";
  if ((BEHAVIOUR_CODES.unauthenticated as readonly string[]).includes(code)) return "unauthenticated";
  if ((BEHAVIOUR_CODES.invalidInput as readonly string[]).includes(code)) return "invalid-input";
  if ((BEHAVIOUR_CODES.conflict as readonly string[]).includes(code)) return "conflict";
  return "business";
}

export class AppError extends Error {
  /**
   * @param kind   Discriminator a screen branches on.
   * @param code   Server code when there was one, otherwise null for a transport failure.
   * @param serverMessage The Arabic text the database sent. Shown to the user verbatim.
   * @param cause  The original thrown value, kept for the logger and never rendered.
   */
  constructor(
    readonly kind: AppErrorKind,
    readonly code: string | null,
    readonly serverMessage: string,
    override readonly cause?: unknown,
  ) {
    super(serverMessage);
    this.name = "AppError";
  }

  /** True when retrying the same request could plausibly succeed. */
  get retryable(): boolean {
    return this.kind === "transport" || this.kind === "conflict";
  }

  /** True when the app should send the user back to sign-in rather than show a message. */
  get requiresSignIn(): boolean {
    return this.kind === "unauthenticated";
  }
}

/** Narrows an unknown catch value to an `AppError`. */
export function isAppError(value: unknown): value is AppError {
  return value instanceof AppError;
}

/**
 * Extracts `CODE: message` from a PostgREST error.
 *
 * PostgREST surfaces a Postgres `raise` as `{"message": "CODE: text", "code": "P0001"}`, so the
 * code lives at the *start of the message*, not in the `code` field, which is always the generic
 * SQLSTATE. Reading `error.code` would give `P0001` for every business failure.
 */
export function parseServerError(error: unknown): AppError {
  if (isAppError(error)) return error;

  if (typeof error !== "object" || error === null) {
    return new AppError("unknown", null, "حدث خطأ غير متوقع", error);
  }

  const candidate = error as { message?: unknown };
  if (typeof candidate.message !== "string") {
    return new AppError("unknown", null, "حدث خطأ غير متوقع", error);
  }

  const match = CODE_PATTERN.exec(candidate.message);
  if (match === null) {
    // No code. A bare SQLSTATE or a fetch failure lands here.
    return new AppError(
      "transport",
      null,
      "تعذر الاتصال. تحقق من الإنترنت وحاول مرة أخرى.",
      error,
    );
  }

  const [, code, message] = match;
  return new AppError(kindOf(code ?? null), code ?? null, message ?? "", error);
}