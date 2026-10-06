/**
 * `lib/errors` - turning a database error into something a human can act on.
 *
 * ## Why this file exists
 *
 * `admin-console-screens.md` §5 rules 13 and 14:
 *
 * > 13. Errors say what to do next: "This vendor has open orders - close them first", not
 *     `foreign_key_violation`.
 * > 14. `PRICE_CHANGED`, `NOT_AUTHORIZED` and friends are internal codes. They never reach the screen.
 *
 * The RPCs raise a code as the first token of the message - `private.err('PATCH_EMPTY', ...)` produces
 * `PATCH_EMPTY: the patch carries no fields` - and Postgres supplies a `sqlstate` for the failures it
 * raises itself. Both are stable and both are internal. This module is the single place that turns either
 * into an operator-facing sentence plus an i18n key.
 *
 * ## Why codes are parsed from the message rather than stored
 *
 * `contracts.md` defines the error catalogue as prose in a table, and the functions raise it by string. There
 * is no error table in the database to join against, and inventing one would mean a second place to keep in
 * sync. Parsing the leading token is therefore the honest interface: if a function starts raising a code this
 * module has never heard of, `UNKNOWN_CODE` fires and the operator sees a generic message rather than a
 * blank screen - and the test asserts that path exists.
 */

/** An error the operator can act on, already resolved from an i18n key. */
export interface FriendlyError {
  /** The i18n key for the sentence. `i18n/en.json` holds the text; no message lives here. */
  readonly messageKey: string;
  /**
   * Values interpolated into the sentence. `VENDOR_NAME` in a key becomes a name the operator recognises,
   * which is the difference between a message and a diagnosis.
   */
  readonly values: Readonly<Record<string, string | number>>;
  /**
   * The internal code, retained for support and for `console.error`. Never rendered.
   *
   * Kept because it is the only way to correlate what an operator saw with what the database raised, and
   * dropping it would make every support question unanswerable.
   */
  readonly code: string;
  /** False when the code was not in the catalogue, so the UI can offer "copy details". */
  readonly known: boolean;
}

/**
 * Every code this module can explain, mapped to an i18n key.
 *
 * Deliberately not an exhaustive copy of `contracts.md`: it holds the codes an **admin** can actually cause.
 * Customer-side codes like `CART_EMPTY` or `VOUCHER_MINIMUM_NOT_MET` are reachable only through the mobile
 * app's own flows, and a code with no admin action behind it is better rendered as "something went wrong"
 * than as a confident-sounding sentence about a screen the operator is not on.
 */
const CATALOGUE: Readonly<Record<string, string>> = {
  // --- auth and role ---
  NOT_AUTHORIZED: "errors.notAuthorized",
  AUTH_REQUIRED: "errors.authRequired",

  // --- patch validation, shared by all 16 admin_upsert_* RPCs ---
  PATCH_EMPTY: "errors.patchEmpty",
  UNKNOWN_KEY: "errors.unknownKey",

  // --- entity lifecycle ---
  NOT_FOUND: "errors.notFound",
  ALREADY_EXISTS: "errors.alreadyExists",

  // --- referential integrity, raised by the private.assert_* triggers ---
  FOREIGN_KEY_VIOLATE: "errors.foreignKeyViolate",

  // --- money ---
  INSUFFICIENT_FUNDS: "errors.insufficientFunds",
  WALLET_FROZEN: "errors.walletFrozen",
  ALREADY_APPLIED: "errors.alreadyApplied",
  AMOUNT_INVALID: "errors.amountInvalid",

  // --- payout ---
  PAYOUT_NOT_APPROVED: "errors.payoutNotApproved",
  PAYOUT_STATE_INVALID: "errors.payoutStateInvalid",

  // --- reconciliation ---
  VARIANCE_ALREADY_EXPLAINED: "errors.varianceAlreadyExplained",

  // --- database-reported, with no RPC code of their own ---
  CHECK_VIOLATION: "errors.checkViolation",
  UNIQUE_VIOLATION: "errors.duplicate",
  NOT_NULL_VIOLATION: "errors.missingRequired",
};

/**
 * Pulls the internal code out of an RPC error.
 *
 * RPCs raise `CODE: human message`, so the code is the text before the first `: `. Postgres's own errors
 * arrive as `{ code: '23505' }` - a bare sqlstate with no such prefix - so those fall through to the
 * sqlstate branch of `toFriendlyError`.
 */
export function extractRpcCode(message: string): string | undefined {
  const separator = message.indexOf(": ");
  if (separator <= 0) {
    return undefined;
  }
  const head = message.slice(0, separator);
  // A code is upper snake case. Anything else in the first position is prose, not a code.
  return /^[A-Z][A-Z0-9_]*$/.test(head) ? head : undefined;
}

/**
 * Maps a sqlstate to a catalogue key.
 *
 * The five Postgres classes an admin action can realistically trigger. `42P01` (undefined table) and
 * `42703` (undefined column) are deliberately absent: they are bugs, not operator actions, and mapping
 * them to a sentence would tell an operator to do something about our mistake.
 */
const SQLSTATE_TO_KEY: Readonly<Record<string, string>> = {
  "23503": "errors.foreignKeyViolate",
  "23505": "errors.duplicate",
  "23514": "errors.checkViolation",
  "23502": "errors.missingRequired",
  "22001": "errors.valueTooLong",
  "22007": "errors.invalidValue",
  "22P02": "errors.invalidIdentifier",
  "P0001": "errors.rpcRaised",
};

/** The `PostgrestError` shape this module reads. Narrowed from `unknown` at the boundary. */
export interface DatabaseErrorLike {
  readonly message?: unknown;
  readonly code?: unknown;
  readonly details?: unknown;
  readonly hint?: unknown;
}

/**
 * Converts anything thrown by a query into a `FriendlyError`.
 *
 * Takes `unknown` because a `catch` binds `unknown` under `useUnknownInCatchVariables`, and every call site
 * has something to convert: a `PostgrestError`, a plain `Error` from our own code, or a thrown string.
 */
export function toFriendlyError(thrown: unknown): FriendlyError {
  const asError = isErrorLike(thrown) ? thrown : { message: String(thrown) };

  const rawMessage = typeof asError.message === "string" ? asError.message : "";
  const sqlstate = typeof asError.code === "string" ? asError.code : undefined;

  // An RPC code is more specific than a sqlstate, so it wins where both are present.
  const rpcCode = extractRpcCode(rawMessage);
  if (rpcCode !== undefined) {
    const key = CATALOGUE[rpcCode];
    return key === undefined
      ? { messageKey: "errors.unknownCode", values: { CODE: rpcCode }, code: rpcCode, known: false }
      : { messageKey: key, values: {}, code: rpcCode, known: true };
  }

  if (sqlstate !== undefined) {
    const key = SQLSTATE_TO_KEY[sqlstate];
    return key === undefined
      ? { messageKey: "errors.generic", values: {}, code: sqlstate, known: false }
      : { messageKey: key, values: {}, code: sqlstate, known: true };
  }

  return { messageKey: "errors.generic", values: {}, code: "UNKNOWN", known: false };
}

function isErrorLike(value: unknown): value is DatabaseErrorLike {
  return typeof value === "object" && value !== null;
}