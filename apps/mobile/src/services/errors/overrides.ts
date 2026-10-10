/**
 * Per-call overrides (mobile README §7), applied at the boundary.
 *
 * Precedence is load-bearing. The two named `NOT_AUTHORIZED` overrides win
 * explicitly — that is the whole point: `cancel`/`claim` `NOT_AUTHORIZED`
 * means "not your order", never a sign-in loop. Everywhere else the
 * authentication default stands: the quote call-level rule below refuses
 * auth codes, so no caller can override its way out of sign-in, and no
 * override kind is ever silent (re-quote shows the total, re-choose shows
 * the choices, not-your-order names the situation).
 *
 * What each override does:
 *
 * - `re-quote-consent` (`place_order_v1` + `PRICE_CHANGED`): re-quote, show
 *   the new total, wait for consent. Never re-place silently.
 * - `re-quote-choose` (any `quote_order_v1` failure): re-quote and let the
 *   shopper choose. Never drop a line for them. Quote rejections
 *   (`rejections[]`, including `OUT_OF_STOCK` and `VOUCHER_*`) are data, not
 *   errors, and ride along the same path at checkout.
 * - `not-your-order` (`cancel_order_v1` + `NOT_AUTHORIZED`): the session is
 *   fine, the row is not.
 * - `cannot-claim-as-other` (`claim_order_v1` + `NOT_AUTHORIZED`): the rider
 *   id on the call is not the caller.
 */
import { kindOfErrorCode, type AppError } from "./parse";
import { toBehaviour, type ErrorBehaviour } from "./behaviour";

export type OverrideKind =
  | "re-quote-consent"
  | "re-quote-choose"
  | "not-your-order"
  | "cannot-claim-as-other";

export interface ErrorOverride {
  readonly kind: OverrideKind;
  /** The default this override replaces, kept so the reader sees the delta. */
  readonly insteadOf: ErrorBehaviour;
}

const CODE_OVERRIDES: Readonly<Record<string, OverrideKind>> = {
  "place_order_v1:PRICE_CHANGED": "re-quote-consent",
  "cancel_order_v1:NOT_AUTHORIZED": "not-your-order",
  "claim_order_v1:NOT_AUTHORIZED": "cannot-claim-as-other",
};

export function getOverride(call: string, code: string | null): ErrorOverride | null {
  if (code === null || code === "") return null;
  const kind = CODE_OVERRIDES[`${call}:${code}`];
  if (kind !== undefined) return { kind, insteadOf: toBehaviour(code) };
  if (call === "quote_order_v1" && kindOfErrorCode(code) !== "unauthenticated") {
    return { kind: "re-quote-choose", insteadOf: toBehaviour(code) };
  }
  return null;
}

/** Everything a screen was going to decide, decided in one place. */
export type ResolvedBehaviour = ErrorBehaviour | OverrideKind;

export function resolveBehaviour(call: string, error: AppError): ResolvedBehaviour {
  const override = getOverride(call, error.code);
  if (override !== null) return override.kind;
  return toBehaviour(error.code ?? "");
}
