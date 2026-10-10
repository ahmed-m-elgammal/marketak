/**
 * Default behaviour per error code (mobile README §7).
 *
 * The groups live in `@marketak/shared` (`BEHAVIOUR_CODES`, verified live
 * against `pg_proc`); this module only translates the shared *kind* into the
 * *default behaviour* a screen starts from. No code list lives here — a
 * second list is how the two disagree six months from now.
 *
 * `toBehaviour` returns a default; the caller decides. A single global
 * handler that silently retries checkout is how a shopper is charged a price
 * they never agreed to, so the global handler acts on authentication and
 * nothing else: `conflict` is not global, because silence is correct for a
 * retried read and wrong for a price. Per-call overrides live in
 * `overrides.ts`.
 */
import { kindOfErrorCode } from "./parse";

/** What a screen does first with a failure. */
export type ErrorBehaviour = "sign-in" | "invalid-input" | "conflict" | "business";

/**
 * The default behaviour for a code. Unknown codes — including codes raised
 * only on admin paths (`ACCOUNT_REQUIRED`, `LEDGER_CONFLICT`,
 * `WALLET_CONFLICT`, `OWNER_REQUIRED`) and rejection payloads that are data,
 * never exceptions (`OUT_OF_STOCK`, `VOUCHER_*` arrive in the quote
 * `rejections[]`, handled at checkout) — fall to `business`: render the
 * server message verbatim, take no action. A code with no branch is a code
 * that cannot misbehave.
 */
export function toBehaviour(code: string): ErrorBehaviour {
  const kind = kindOfErrorCode(code);
  if (kind === "unauthenticated") return "sign-in";
  if (kind === "invalid-input") return "invalid-input";
  if (kind === "conflict") return "conflict";
  return "business";
}

/**
 * The form slot an `invalid-input` code attaches to. `null` means the code
 * is not fixable in a form field: a device concern (`TOKEN_*`,
 * `PLATFORM_INVALID`, `APP_ROLE_INVALID`), a programmer error
 * (`UNKNOWN_KEY`, `PATCH_EMPTY`), or a situation that routes elsewhere
 * (`PROFILE_ALREADY_COMPLETE` routes to update, `PHONE_IN_USE_BY_RIDER`
 * routes to support).
 */
export function fieldFor(code: string): string | null {
  switch (code) {
    case "NAME_INVALID":
      return "name";
    case "PHONE_INVALID":
    case "PHONE_IN_USE":
    case "PHONE_IN_USE_BY_RIDER":
      return "phone";
    case "INVALID_PATCH":
      return "profile";
    case "INVALID_QUANTITY":
      return "quantity";
    case "INVALID_OPTIONS":
    case "OPTION_UNAVAILABLE":
      return "options";
    case "SIZE_REQUIRED":
    case "SIZE_UNAVAILABLE":
    case "SIZE_NOT_APPLICABLE":
    case "ITEM_SIZED_BUT_NO_SIZES":
      return "size";
    case "TIP_INVALID":
      return "tip";
    case "DELIVERY_TYPE_INVALID":
      return "deliveryType";
    case "GROUPING_INVALID":
      return "grouping";
    case "PAYMENT_METHOD_INVALID":
      return "paymentMethod";
    case "PAYMENT_CHANNEL_INVALID":
    case "PAYMENT_CHANNEL_REQUIRED":
    case "PAYMENT_CHANNEL_MISMATCH":
      return "paymentChannel";
    case "ADDRESS_REQUIRED":
    case "ADDRESS_COORDS_REQUIRED":
    case "ADDRESS_COORDS_INVALID":
      return "address";
    case "ADDRESS_LABEL_INVALID":
      return "label";
    case "AREA_REQUIRED":
    case "AREA_UNAVAILABLE":
      return "area";
    case "AMOUNT_INVALID":
      return "amount";
    case "RADIUS_INVALID":
      return "radius";
    case "CART_ITEM_RETIRED":
    case "CART_ITEM_UNAVAILABLE":
      return "cartLine";
    default:
      return null;
  }
}
