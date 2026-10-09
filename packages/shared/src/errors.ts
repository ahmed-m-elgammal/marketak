/**
 * Errors - the code, the classification, and the parser.
 *
 * Every failure from this database is a Postgres exception whose **message
 * begins with a SCREAMING_SNAKE code**, followed by a colon and an Arabic
 * sentence written for the shopper:
 *
 *     ITEM_RETIRED: هذا الصنف لم يعد متاحا
 *
 * The code is the contract; the Arabic text after it is already user-facing and
 * must be shown verbatim. The code is **not** in PostgREST's `code` field - that
 * field is always the generic SQLSTATE `P0001`, so reading `error.code` returns
 * `P0001` for every business failure. This is the single most common mistake
 * against this database.
 */

/** The kinds the app *behaves* differently on. Everything else is `business`. */
export type AppErrorKind = "unauthenticated" | "invalid-input" | "conflict" | "business";

/**
 * Every code the database can raise, grouped by the RPC that raises it. A code
 * absent from this union is a code the database does not produce, and a screen
 * branching on it is dead code.
 */
export const APP_ERROR_CODES = [
  // ── cross-cutting ──
  "AUTH_REQUIRED",
  "NOT_AUTHORIZED",
  "PROFILE_INCOMPLETE",

  // ── profile ──
  "NOT_A_RIDER",

  // ── cart ──
  "ITEM_REQUIRED",
  "ITEM_RETIRED",
  "ITEM_UNAVAILABLE",
  "SIZE_REQUIRED",
  "SIZE_UNAVAILABLE",
  "SIZE_NOT_APPLICABLE",
  "OPTION_UNAVAILABLE",
  "INVALID_OPTIONS",
  "INVALID_QUANTITY",
  "CART_ITEM_REQUIRED",
  "CART_ITEM_NOT_FOUND",

  // ── quote ──
  "CART_NOT_FOUND",
  "CART_EMPTY",
  "CART_NOT_PLACABLE",
  "ADDRESS_NOT_FOUND",
  "NO_DELIVERY_ZONE",
  "MISSING_FEE_TIER",
  "TIP_INVALID",
  "DELIVERY_TYPE_INVALID",
  "GROUPING_INVALID",

  // ── address ──
  "PATCH_EMPTY",
  "UNKNOWN_KEY",
  "ADDRESS_REQUIRED",
  "ADDRESS_COORDS_REQUIRED",
  "ADDRESS_COORDS_INVALID",
  "ADDRESS_LABEL_INVALID",
  "AREA_REQUIRED",
  "AREA_UNAVAILABLE",

  // ── order placement ──
  "QUOTE_NOT_FOUND",
  "QUOTE_EXPIRED",
  "PRICE_CHANGED",
  "IDEMPOTENCY_KEY_REQUIRED",
  "IDEMPOTENCY_KEY_TAKEN",
  "PAYMENT_METHOD_INVALID",
  "PAYMENT_CHANNEL_INVALID",
  "PAYMENT_CHANNEL_REQUIRED",
  "PAYMENT_CHANNEL_MISMATCH",

  // ── cancellation ──
  "ORDER_NOT_FOUND",
  "ORDER_NOT_CANCELLABLE",
  "NOTHING_TO_CANCEL",
  "CANCEL_WINDOW_CLOSED",

  // ── rider ──
  "RIDER_REQUIRED",
  "RIDER_NOT_FOUND",
  "RIDER_NOT_ELIGIBLE",
  "RIDER_NOT_VERIFIED",
  "RIDER_LOCATION_REQUIRED",
  "RADIUS_INVALID",
  "ASSIGNMENT_NOT_FOUND",
  "ORDER_ALREADY_CLAIMED",
  "ORDER_NOT_CLAIMABLE",
  "SUB_ORDER_NOT_FOUND",
  "INVALID_TRANSITION",

  // ── collection and delivery ──
  "ORDER_NOT_ASSIGNED",
  "ALREADY_COLLECTED",
  "AMOUNT_INVALID",
  "AMOUNT_MISMATCH",
  "CASH_LIMIT_EXCEEDED",
  "ALREADY_DELIVERED",
  "SUB_ORDERS_INCOMPLETE",

  // ── device tokens ──
  "TOKEN_REQUIRED",
  "TOKEN_TOO_LONG",
  "PLATFORM_INVALID",
  "APP_ROLE_INVALID",
  "TOKEN_ALREADY_REGISTERED",
] as const;

export type AppErrorCode = (typeof APP_ERROR_CODES)[number];

export function isAppErrorCode(value: string): value is AppErrorCode {
  return (APP_ERROR_CODES as readonly string[]).includes(value);
}

/**
 * Codes that were listed in an earlier draft of the app's error mapper and that
 * **do not exist in any function body**. They are recorded here so a reader can
 * see they were checked and rejected, rather than wondering whether they were
 * forgotten:
 *
 * - `ITEM_PRICE_CHANGED`, `DELIVERY_FEE_CHANGED` - `place_order_v1` raises the
 *   single `PRICE_CHANGED` instead. There is no per-field variant.
 * - `OPTION_SELECTION_INVALID` - `upsert_cart_item_v1` raises `INVALID_OPTIONS`.
 * - `PHONE_INVALID`, `PHONE_IN_USE`, `NAME_INVALID` - no public function
 *   validates a phone or a name. `complete_profile_v1` takes three `text`
 *   arguments and raises nothing but `AUTH_REQUIRED`.
 */
export const RETIRED_ERROR_CODES = [
  "ITEM_PRICE_CHANGED",
  "DELIVERY_FEE_CHANGED",
  "OPTION_SELECTION_INVALID",
  "PHONE_INVALID",
  "PHONE_IN_USE",
  "NAME_INVALID",
] as const;

/**
 * The behaviour groups. Only a code the app acts differently on belongs here;
 * everything else renders `serverMessage` unchanged and needs no branch. Adding
 * a code that does not change behaviour is how business rules leak into the
 * client.
 */
export const BEHAVIOUR_CODES = {
  /** Return to sign-in. */
  unauthenticated: ["NOT_AUTHORIZED", "AUTH_REQUIRED", "RIDER_REQUIRED", "NOT_A_RIDER"],
  /** The input was wrong. Let the shopper fix it rather than retrying blindly. */
  invalidInput: [
    "INVALID_QUANTITY",
    "INVALID_OPTIONS",
    "SIZE_REQUIRED",
    "TIP_INVALID",
    "DELIVERY_TYPE_INVALID",
    "GROUPING_INVALID",
    "PAYMENT_METHOD_INVALID",
    "PAYMENT_CHANNEL_INVALID",
    "RADIUS_INVALID",
    "PLATFORM_INVALID",
    "APP_ROLE_INVALID",
    "ADDRESS_LABEL_INVALID",
    "UNKNOWN_KEY",
    "PATCH_EMPTY",
    "TOKEN_REQUIRED",
    "TOKEN_TOO_LONG",
  ],
  /** Re-read from the server and retry silently. Never surface these as errors. */
  conflict: [
    "PRICE_CHANGED",
    "QUOTE_EXPIRED",
    "IDEMPOTENCY_KEY_TAKEN",
    "INVALID_TRANSITION",
    "ORDER_ALREADY_CLAIMED",
    "ALREADY_COLLECTED",
    "ALREADY_DELIVERED",
    "TOKEN_ALREADY_REGISTERED",
  ],
} as const satisfies Record<string, readonly AppErrorCode[]>;

export function kindOfErrorCode(code: string): AppErrorKind {
  if ((BEHAVIOUR_CODES.unauthenticated as readonly string[]).includes(code)) {
    return "unauthenticated";
  }
  if ((BEHAVIOUR_CODES.invalidInput as readonly string[]).includes(code)) {
    return "invalid-input";
  }
  if ((BEHAVIOUR_CODES.conflict as readonly string[]).includes(code)) {
    return "conflict";
  }
  return "business";
}

/** `CODE: message` at the very start of the message. */
export const ERROR_MESSAGE_PATTERN = /^([A-Z][A-Z0-9_]+):\s*([\s\S]*)$/u;

export interface ParsedError {
  readonly code: string | null;
  readonly message: string;
  readonly kind: AppErrorKind;
}

/**
 * Splits a Postgres exception message into its code and its shopper-facing text.
 * A message with no code prefix is a transport failure or a bare SQLSTATE, never
 * a business error.
 */
export function parseServerMessage(raw: string): ParsedError {
  const match = ERROR_MESSAGE_PATTERN.exec(raw);
  if (match === null) {
    return { code: null, message: raw, kind: "business" };
  }
  const [, code, message] = match;
  return { code: code ?? null, message: (message ?? "").trim(), kind: kindOfErrorCode(code ?? "") };
}

/**
 * A parsed failure, thrown by the data layer and caught by a screen.
 *
 * A class rather than a plain object, because `instanceof` is the only check that
 * survives a component boundary: a discriminated union gets widened the moment it
 * crosses a prop, whereas `error instanceof AppError` does not.
 */
export class AppError extends Error {
  constructor(
    readonly kind: AppErrorKind,
    /** The extracted code, or `null` for a transport failure. */
    readonly code: string | null,
    /** The server's Arabic message, verbatim. Render it unchanged. */
    readonly serverMessage: string,
    override readonly cause?: unknown,
  ) {
    super(serverMessage);
    this.name = "AppError";
  }

  /** True when the same request can be sent again unchanged. */
  get retryable(): boolean {
    return this.kind === "conflict";
  }

  /** True when the app should return to sign-in. */
  get requiresSignIn(): boolean {
    return this.kind === "unauthenticated";
  }
}

export function isAppError(value: unknown): value is AppError {
  return value instanceof AppError;
}

/**
 * Parses anything a `supabase.rpc` or `supabase.from` call can throw.
 *
 * Accepts `unknown` because that is what a `catch` gives you, and a parser that
 * demands a specific type is a parser that throws on the one error it did not
 * anticipate.
 */
export function parseAppError(error: unknown): AppError {
  if (isAppError(error)) return error;

  const message =
    typeof error === "object" && error !== null && "message" in error
      ? (error as { message: unknown }).message
      : undefined;

  if (typeof message !== "string" || message === "") {
    return new AppError("business", null, "", error);
  }

  const parsed = parseServerMessage(message);
  return new AppError(parsed.kind, parsed.code, parsed.message, error);
}
