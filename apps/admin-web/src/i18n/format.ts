/**
 * `i18n/format` - the console's presentation-only formatters.
 *
 * ## What is NOT here, and why
 *
 * A0.3 requires the console to consume money, rate, multiplier and timestamp formatting from
 * `packages/shared` rather than reimplement it. An earlier pass of this work put `formatMultiplier`,
 * `formatRateBps`, `formatRelative`, `formatDateTime` and `formatWhen` here, which meant a second copy of
 * every one of them - and the mobile app reads the same columns, so the duplication would have surfaced as
 * two apps disagreeing about a delivery fee.
 *
 * They now live in `packages/shared/src/domain/measure/format-measure.ts` and `.../money/format-money.ts`.
 * This file holds only what is genuinely console-specific:
 *
 * - `formatAmount` / `formatMultiplier`, thin wrappers that resolve the console's `{en, ar}` into a BCP-47
 *   tag and hand it to the shared formatter. The mapping stays here because `Locale` is a console concept.
 * - `toTelHref` and `toMapHref`, which build links. That is presentation, not DTO formatting, and the mobile
 *   app renders these values as text rather than as links.
 */

import { formatMoney, type CurrencyCode, type Piastres } from "@marketak/shared";
import { formatMultiplierBps } from "@marketak/shared";

import { intlTagFor, type Locale } from "./index.js";

/**
 * Formats integer minor units, resolving the console's locale first.
 *
 * A thin pass-through to `formatMoney`, exported so components import one symbol from one place rather than
 * reaching into `packages/shared` directly. That indirection is what lets a future zero-decimal currency like
 * JPY change in one file instead of forty-one.
 */
export function formatAmount(
  amount: Piastres,
  currency: CurrencyCode,
  locale: Locale = "en",
): string | undefined {
  return formatMoney(amount, currency, intlTagFor(locale));
}

/** Formats a fee multiplier, e.g. `12500` bps as `1.25x`. Delegates to the shared formatter. */
export function formatMultiplier(bps: number, locale: Locale = "en"): string | undefined {
  return formatMultiplierBps(bps, intlTagFor(locale));
}

/**
 * A `tel:` href.
 *
 * Strips everything but digits and a leading `+`. `tel:` with spaces or Arabic-Indic digits fails silently
 * on iOS, and "the call button does nothing" is a bug report nobody can reproduce from a screenshot - which
 * is why an Egyptian phone number needs converting, and why this cannot live in `packages/shared` without
 * becoming an assumption about the product's market rather than a presentation rule.
 */
export function toTelHref(phone: string): string | undefined {
  const trimmed = phone.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  // Arabic-Indic (U+0660) and Eastern Arabic-Indic (U+06F0) digits are what an Egyptian keyboard produces.
  const digits = trimmed
    .replace(/[٠-٩]/gu, (digit) => String(digit.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/gu, (digit) => String(digit.charCodeAt(0) - 0x06f0))
    .replace(/[^\d+]/gu, "");
  if (digits.replace("+", "").length < 7) {
    return undefined;
  }
  return `tel:${digits}`;
}

/**
 * A map link for a coordinate.
 *
 * `admin-console-screens.md` §5 rule 7: `30.0444, 31.2357` is not information a person can use. Rendered
 * beside the raw value in a monospace cell, so it stays copyable for support while the operator gets a way to
 * act on it.
 */
export function toMapHref(
  latitude: number | null | undefined,
  longitude: number | null | undefined,
): string | undefined {
  if (latitude === null || latitude === undefined) return undefined;
  if (longitude === null || longitude === undefined) return undefined;
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return undefined;
  return `https://www.google.com/maps/search/?api=1&query=${String(latitude)},${String(longitude)}`;
}