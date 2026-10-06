/**
 * `application/render-notification` - turning a claim row plus a template into a message.
 *
 * ## Why this is `application` and not `domain`
 *
 * Rendering is a use case, not a fact about the world. It depends on which variables happen to be
 * Worker-owned strings this quarter, so it must not be imported by the mobile app or the admin console.
 * `domain/` stays free of it.
 *
 * ## The one behaviour worth arguing about
 *
 * An unfilled placeholder is **not** replaced with an empty string. It is left verbatim and reported in
 * `missing_variables`, and `isSendable` returns false so the caller refuses to send.
 *
 * The alternative is a customer receiving "Estimated arrival {eta}" because one join returned null. That
 * reads as broken, and nothing in the logs would explain it, because every function returned successfully.
 */

import {
  formatCount,
  formatMoney,
  type CurrencyCode,
} from "../domain/money/format-money.js";
import type {
  ClaimedNotification,
  NotificationVariables,
  RenderedNotification,
  TemplateRow,
} from "../domain/notifications/claim-contract.js";
import { WORKER_STATIC_VARIABLES } from "../domain/notifications/claim-contract.js";

/** A placeholder as it appears in a template: `{order_number}`. */
const PLACEHOLDER = /\{(\w+)\}/g;

/** Every placeholder the given parts name, in first-appearance order, deduplicated. */
export function placeholdersIn(...parts: readonly string[]): readonly string[] {
  const found: string[] = [];
  const seen = new Set<string>();
  for (const part of parts) {
    for (const match of part.matchAll(PLACEHOLDER)) {
      const name = match[1];
      // `noUncheckedIndexedAccess` makes this `string | undefined`; the regex guarantees group 1 exists
      // whenever the whole match does. Saying so beats a non-null assertion.
      if (name !== undefined && !seen.has(name)) {
        seen.add(name);
        found.push(name);
      }
    }
  }
  return found;
}

/** Claim variables holding piastres. Formatted, never stringified raw. */
const MONEY_VARIABLES: ReadonlySet<string> = new Set([
  "total",
  "refund_amount",
  "rider_pay_total",
]);

/** Claim variables holding counts. */
const COUNT_VARIABLES: ReadonlySet<string> = new Set([
  "vendor_count",
  "affected_items",
  "stops",
  "item_count",
]);

/**
 * Turns one variable into the string that goes into a template.
 *
 * Returns `undefined` rather than an empty string when there is nothing to say, because an empty string
 * renders as a sentence with a hole in it and that is indistinguishable from a bug the customer can see.
 */
function scalar(
  name: string,
  variables: NotificationVariables,
  currency: CurrencyCode,
): string | undefined {
  if (MONEY_VARIABLES.has(name)) {
    const raw = variables[name as keyof NotificationVariables];
    return typeof raw === "number" ? formatMoney(raw, currency) : undefined;
  }
  if (COUNT_VARIABLES.has(name)) {
    const raw = variables[name as keyof NotificationVariables];
    return typeof raw === "number" ? formatCount(raw) : undefined;
  }

  // Everything else is a string the RPC already formatted (`eta`, `order_number`) or a literal from the
  // database (`vendor_name`, `rider_name`, `reason`, `payment_method`). An object here would mean the RPC
  // changed shape, so it is refused rather than rendered as `[object Object]`.
  const raw: unknown = variables[name as keyof NotificationVariables];
  return typeof raw === "string" ? raw : undefined;
}

/**
 * Renders one template against one claim row.
 *
 * Substitution is whole-token only: `{order_number}` is replaced, `{order_number_suffix}` is not. A naive
 * `replaceAll` on the bare name would corrupt any future template with two placeholders sharing a prefix,
 * and the bug would only appear once such a template existed.
 *
 * `staticVariables` is injectable so a test can prove the substitution precedence without depending on the
 * production copy.
 */
export function renderTemplate(
  template: TemplateRow,
  claim: ClaimedNotification,
  staticVariables: Readonly<Record<string, string>> = WORKER_STATIC_VARIABLES,
): RenderedNotification {
  // Read from the claim, never from a constant. Per-order configuration, verified against
  // `cities.currency`, `delivery_zones.currency` and `orders.currency`.
  const currency = claim.variables.currency ?? "";
  const required = placeholdersIn(template.title, template.body);
  const missing: string[] = [];

  const substitute = (input: string): string =>
    input.replaceAll(PLACEHOLDER, (whole: string, name: string): string => {
      const fromStatic = staticVariables[name];
      if (fromStatic !== undefined) {
        return fromStatic;
      }
      const value = scalar(name, claim.variables, currency);
      if (value === undefined) {
        missing.push(name);
        return whole;
      }
      return value;
    });

  return {
    title: substitute(template.title),
    body: substitute(template.body),
    required_variables: required,
    missing_variables: [...new Set(missing)],
  };
}

/**
 * True when a rendered notification is safe to send.
 *
 * The only condition is that no placeholder is unfilled. Everything else - a short body, an Arabic title, a
 * zero amount - is legitimate content, and refusing on any of those would mean the drain stops delivering
 * over cosmetics.
 */
export function isSendable(rendered: RenderedNotification): boolean {
  return rendered.missing_variables.length === 0;
}