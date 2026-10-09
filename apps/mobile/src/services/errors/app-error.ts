/**
 * Typed failure model.
 *
 * Postgres raises `CODE: message` and the Arabic text after the colon is already written for the
 * shopper, so the client shows it verbatim and uses the code only to decide behaviour. The code is
 * at the start of the *message*, not in PostgREST's `code` field — that is always the generic
 * SQLSTATE, so reading it returns P0001 for every business failure.
 */

export type AppErrorKind =
  | "unauthenticated"
  | "invalid-input"
  | "conflict"
  | "business"
  | "transport"
  | "unknown";

/**
 * Codes the app *behaves* differently on. Everything else is `business` and needs no client branch,
 * so adding an entry for every server code would move business rules into the client.
 */
export const BEHAVIOUR_CODES = {
  unauthenticated: [
    "NOT_AUTHORIZED",
    "AUTH_REQUIRED",
    "OWNER_REQUIRED",
    "RIDER_REQUIRED",
    "ACCOUNT_REQUIRED",
  ],
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

const CODE_PATTERN = /^([A-Z][A-Z0-9_]+):\s*(.*)$/s;

function kindOf(code: string | null): AppErrorKind {
  if (code === null) return "transport";
  if ((BEHAVIOUR_CODES.unauthenticated as readonly string[]).includes(code)) return "unauthenticated";
  if ((BEHAVIOUR_CODES.invalidInput as readonly string[]).includes(code)) return "invalid-input";
  if ((BEHAVIOUR_CODES.conflict as readonly string[]).includes(code)) return "conflict";
  return "business";
}

export class AppError extends Error {
  constructor(
    readonly kind: AppErrorKind,
    readonly code: string | null,
    readonly serverMessage: string,
    override readonly cause?: unknown,
  ) {
    super(serverMessage);
    this.name = "AppError";
  }

  get retryable(): boolean {
    return this.kind === "transport" || this.kind === "conflict";
  }

  get requiresSignIn(): boolean {
    return this.kind === "unauthenticated";
  }
}

export function isAppError(value: unknown): value is AppError {
  return value instanceof AppError;
}

export function parseServerError(error: unknown): AppError {
  if (isAppError(error)) return error;

  const message = (error as { message?: unknown } | null)?.message;
  if (typeof message !== "string") {
    return new AppError("unknown", null, "حدث خطأ غير متوقع", error);
  }

  const match = CODE_PATTERN.exec(message);
  // No code means a bare SQLSTATE or a fetch failure.
  if (match === null) {
    return new AppError("transport", null, "تعذر الاتصال. تحقق من الإنترنت وحاول مرة أخرى.", error);
  }

  const [, code, text] = match;
  return new AppError(kindOf(code ?? null), code ?? null, text ?? "", error);
}