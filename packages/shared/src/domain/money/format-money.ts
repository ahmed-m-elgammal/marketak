/**
 * `domain/money` - formatting money for a human.
 *
 * ## Where the rules live
 *
 * | Concern | File |
 * |---|---|
 * | piastre formatting, currency validation | `format-money.ts` |
 * | what a claim row contains | `../notifications/contract.ts` |
 * | turning variables into a message | `../../application/render-notification.ts` |
 * | tests for all of the above | `../../tests/` |
 *
 * Nothing in `domain/` may import from `application/` or `adapters/`. The dependency direction is
 * one-way, and this is the layer that would be reusable by the mobile app and the admin console, so it has
 * to stay free of anything Cloudflare-specific.
 *
 * ## The rule that matters most
 *
 * **There is deliberately NO `CURRENCY = "EGP"` constant in this module.**
 *
 * constitution rule 4: every money constant is configuration, never a literal. `currency` is a per-row
 * `bpchar` column on six tables - `cities`, `delivery_zones`, `orders`, `payouts`, `ledger_entries`,
 * `wallets` - each defaulting to `'EGP'` but each overridable, and `admin_upsert_city_v1` accepts
 * `currency` in its patch allowlist. A constant here would label every notification in the wrong unit the
 * day an admin created a denominated city, with every database check still green.
 *
 * Verified against the live project: a probe order in a city configured `SAR` came back from
 * `claim_events_v1` with `currency: "SAR"`, and migration `038i` was written specifically to add that
 * field because it was missing.
 */

/**
 * An ISO 4217 alphabetic code as Postgres stores it in a `bpchar` column.
 *
 * A string rather than a union of the codes this project happens to use, because the schema does not
 * constrain the column to an enum and narrowing the type here would be a lie the compiler cannot check.
 */
export type CurrencyCode = string;

/** Integer piastres. The database stores money this way; `data-model.md` states it. */
export type Piastres = number;

const PIASBRES_PER_UNIT = 100;

/** The piastres-per-unit ratio, exported so a test can prove the arithmetic rather than trust it. */
export const PIASBRES = PIASBRES_PER_UNIT;

/**
 * True when a value is usable as a currency code: three uppercase letters.
 *
 * The Worker validates before calling `Intl.NumberFormat` because that function **throws** on a malformed
 * code, and a throw inside the drain loop abandons every remaining notification in the batch. Validating
 * up front turns "one bad city row silently eats every push" into "one skipped send with a logged reason".
 *
 * `bpchar` PADS, so a value can arrive as `"EGP "` on one row and `"EGP"` on another. `038i` trims in SQL;
 * this check refuses the padded form anyway rather than trusting the caller.
 */
export function isCurrencyCode(value: unknown): value is CurrencyCode {
  return typeof value === "string" && /^[A-Z]{3}$/.test(value);
}

/**
 * Formats piastres for a human, with thousands separators and exactly two decimals.
 *
 * Uses `Intl.NumberFormat` rather than `toFixed` on a divided number, because `(33000 / 100).toFixed(2)`
 * is only correct by accident: floating point makes `toFixed` produce `"329.99"` for piastre values that
 * are legitimately 330.00, and a customer who sees a total one piastre short stops trusting the app.
 * `Intl` takes the number and formats it as a decimal directly, so there is no intermediate rounding to
 * get wrong.
 *
 * Returns `undefined` for a non-integer amount or an invalid code rather than throwing. The renderer's
 * contract is that an unsupplied variable becomes a reported gap and a refused send, and this function is
 * one step in that chain - it must not be the step that throws.
 */
export function formatMoney(
  amount: Piastres,
  currency: CurrencyCode,
  locale = "en-EG",
): string | undefined {
  if (typeof amount !== "number" || !Number.isInteger(amount)) {
    return undefined;
  }
  if (!isCurrencyCode(currency)) {
    return undefined;
  }
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(amount / PIASBRES_PER_UNIT);
}

/**
 * Formats a count for a template that reads as prose: "3 vendor(s)" is the template's wording, not ours,
 * so there is no pluralisation here. Returns `undefined` for a non-finite number so `NaN` can never reach
 * a customer as the literal text "NaN".
 */
export function formatCount(count: number): string | undefined {
  return Number.isFinite(count) ? String(count) : undefined;
}