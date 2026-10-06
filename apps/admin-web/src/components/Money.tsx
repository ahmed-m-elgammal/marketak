/**
 * `components/Money` - the only component that renders an amount.
 *
 * ## Why one component, and why it refuses to guess
 *
 * Every figure in this platform is an integer count of minor units - piastres - and `packages/shared` owns
 * that arithmetic. This component owns the two decisions the shared formatter deliberately does not make:
 *
 * 1. **The currency is always shown.** constitution 7: money constants are configuration. `formatMoney` has
 *    no default currency *by design*, because a default is a hardcoded constant wearing a disguise. So a
 *    currency argument is required here too, and an unusable value renders a visible marker rather than a
 *    bare number - a bare number is exactly how an operator misreads EGP 330 as SAR 330.
 *
 * 2. **A negative amount is styled.** A negative wallet balance is a real state, not an error - `wallets`
 *    intentionally has no non-negativity check. It gets the danger colour, so it cannot be mistaken for a
 *    rendering bug or silently averaged away.
 */

import type { ReactElement } from "react";

import { formatAmount } from "../i18n/format.js";
import { useLocale } from "../i18n/use-locale.js";

/**
 * Rendered when the amount is not a usable integer or the currency code is malformed.
 *
 * An em dash, not `0`, not an empty cell. An operator must be able to tell a formatting failure from a real
 * zero, and every other option reads as zero.
 */
const UNKNOWN = "—";

export interface MoneyProps {
  /** Integer minor units. Never a float: the schema stores money this way. */
  readonly amount: number;
  /** ISO 4217, three uppercase letters. Required, never defaulted. */
  readonly currency: string;
  /** Overrides the sign-driven styling. Defaults to the amount's own sign. */
  readonly negative?: boolean;
}

export function Money({ amount, currency, negative }: MoneyProps): ReactElement {
  const locale = useLocale();
  const formatted = formatAmount(amount, currency, locale);

  if (formatted === undefined) {
    return <span className="money">{UNKNOWN}</span>;
  }

  const isNegative = negative ?? amount < 0;
  const className = isNegative ? "money money--negative" : "money";

  // `dir="auto"` so a negative sign or an Arabic-Indic numeral is ordered by the Unicode algorithm rather
  // than by the element's inherited direction. Inside an RTL page an LTR amount needs isolating, or the minus
  // sign lands on the wrong side of the figure.
  return (
    <span className={className} dir="auto">
      {formatted}
    </span>
  );
}