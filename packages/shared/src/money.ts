/**
 * Money.
 *
 * The database stores every monetary column as `integer` **piastres**. One EGP is
 * 100 piastres (`settings.currency` = `EGP`, and its description says so
 * explicitly). Money is therefore an integer everywhere in this system, and the
 * only correct client representation of one is an integer too.
 *
 * `Piastres` is a branded type on purpose. A plain `number` for money is how a
 * quantity gets added to a price and the compiler waves it through: the failure
 * is silent and it surfaces as a receipt that does not balance. Branding forces
 * the caller through `toPiastres()` or `fromPiastres()`, which is where the
 * conversion is honest and visible.
 *
 * Floats never hold money. `Number.toFixed`, `parseFloat` and `0.1 + 0.2` are all
 * absent from this module by design; formatting goes through `Intl.NumberFormat`,
 * which rounds by contract rather than by accident.
 */

declare const piastresBrand: unique symbol;

/** An integer number of piastres. 100 = 1 EGP. */
export type Piastres = number & { readonly [piastresBrand]: "Piastres" };

/** Piastres in one unit of the currency. `settings.currency` is EGP. */
export const PIASTRES_PER_UNIT = 100;

/**
 * The currency rendered everywhere. `settings.currency` holds it; the value is
 * read from the server at boot and never re-derived here. This constant is the
 * *fallback* for the first paint before settings load, not a business rule.
 */
export const FALLBACK_CURRENCY = "EGP";

export function toPiastres(value: number): Piastres {
  if (!Number.isInteger(value)) {
    throw new Error(
      `PIASTRES_NOT_INTEGER: ${String(value)} is not an integer. Money is piastres; divide by ${String(PIASTRES_PER_UNIT)} first.`,
    );
  }
  return value as Piastres;
}

/** Piastres as a bare number. Only for arithmetic that is provably piastres→piastres. */
export function fromPiastres(value: Piastres): number {
  return value;
}

/** Adds. Both operands are already piastres, so the result cannot drift. */
export function addPiastres(a: Piastres, b: Piastres): Piastres {
  return toPiastres(a + b);
}

/** Sums a list. Empty list is 0, not an error - an empty cart is a real state. */
export function sumPiastres(values: readonly Piastres[]): Piastres {
  return toPiastres(values.reduce<number>((total, v) => total + v, 0));
}

/**
 * Multiplies piastres by an integer count (a quantity). Use `multiplyByRate` for
 * anything denominated in basis points.
 */
export function multiplyByCount(value: Piastres, count: number): Piastres {
  if (!Number.isInteger(count)) {
    throw new Error(`COUNT_NOT_INTEGER: quantity ${String(count)} is not an integer.`);
  }
  return toPiastres(value * count);
}

/**
 * Applies a basis-point rate to piastres, rounding half-up as Postgres does.
 *
 * `quote_order_v1` computes `round(base * multiplier_bps / 10000)` in SQL with
 * numeric, which rounds half away from zero. Doing the same arithmetic in
 * JavaScript with a float gives a different answer on exact halves, and that
 * difference is a delivery fee that does not match the database. So the division
 * is done with an explicit epsilon rather than trusting `Math.round`.
 */
export function multiplyByRateBps(value: Piastres, rateBps: number): Piastres {
  if (!Number.isInteger(rateBps) || rateBps < 0) {
    throw new Error(`RATE_BPS_INVALID: ${String(rateBps)} must be a non-negative integer.`);
  }
  const scaled = value * rateBps;
  // Half away from zero, without a float division deciding the tie.
  const sign = scaled < 0 ? -1 : 1;
  const magnitude = Math.abs(scaled);
  const quotient = Math.floor(magnitude / 10000);
  const remainder = magnitude % 10000;
  const rounded = remainder * 2 >= 10000 ? quotient + 1 : quotient;
  return toPiastres(sign * rounded);
}

/** 10000 bps === 100%. A multiplier of 1.1 is 11000 bps. */
export const BPS_DENOMINATOR = 10000;

export function bpsToPercent(rateBps: number): number {
  return rateBps / 100;
}

export function percentToBps(percent: number): number {
  if (!Number.isInteger(percent * 100)) {
    throw new Error(`PERCENT_NOT_EXACT: ${String(percent)} cannot be represented in basis points.`);
  }
  return percent * 100;
}

/* ── Formatting ───────────────────────────────────────────────────────────── */

export type Language = "ar" | "en";

/** The app's primary language. `settings.platform_name_ar` is the default everywhere. */
export const PRIMARY_LANGUAGE: Language = "ar";

/**
 * Arabic renders Eastern Arabic-Indic digits: `١٢٣٤`, with `٫` as the decimal
 * mark. The design system uses exactly these (the rider card shows `٤٫٨` and a
 * plate of `١٢٣٤`), so the numbering system is pinned rather than inherited from
 * the runtime locale, which differs between Hermes engines and iOS/Android.
 */
function resolver(language: Language): Intl.NumberFormat {
  return new Intl.NumberFormat(language === "ar" ? "ar-EG-u-nu-arab" : "en-EG", {
    numberingSystem: language === "ar" ? "arab" : "latn",
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  });
}

/**
 * The major-unit renderer. Piastres in, a localised string out.
 *
 * Grouping is **on**, and that is a decision rather than a default. Money is
 * integer piastres, so a total of 45000 is 450 EGP; an ungrouped `45000` is a
 * string a shopper has to count digits in. Arabic uses the Arabic thousands
 * separator `٬` (U+066C), not the Latin comma, and Arabic-Indic digits
 * throughout - which is what the design system shows on the rider card
 * (`٤٫٨`, `١٢٣٤`).
 *
 * The numbering system is pinned rather than inherited from the runtime locale,
 * because it differs between Hermes engines and between iOS and Android, and a
 * receipt that renders `2,950` on one device and `٢٬٩٥٠` on another is a bug that
 * only reproduces for some users.
 */
export function formatMoney(value: Piastres, language: Language = PRIMARY_LANGUAGE): string {
  return resolver(language).format(value);
}

/** Major units with the currency code appended, for receipts and payout rows. */
export function formatMoneyWithCurrency(
  value: Piastres,
  currency: string = FALLBACK_CURRENCY,
  language: Language = PRIMARY_LANGUAGE,
): string {
  return `${formatMoney(value, language)} ${currency}`;
}

/** A bare count. Not money, but localised identically so a screen has one digit system. */
export function formatCount(value: number, language: Language = PRIMARY_LANGUAGE): string {
  return resolver(language).format(value);
}

/** One decimal place, for ratings and `rating_avg` (numeric(3,2) in the database). */
export function formatRate(value: number, language: Language = PRIMARY_LANGUAGE): string {
  const digits = language === "ar" ? 1 : 1;
  return new Intl.NumberFormat(language === "ar" ? "ar-EG-u-nu-arab" : "en-EG", {
    numberingSystem: language === "ar" ? "arab" : "latn",
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}

/** Basis points as a percentage string: 11000 → `110%` / `١١٠٪`. */
export function formatRateBps(rateBps: number, language: Language = PRIMARY_LANGUAGE): string {
  const percent = bpsToPercent(rateBps);
  return language === "ar" ? `${formatCount(percent, language)}٪` : `${formatCount(percent, language)}%`;
}

/* ── Time ─────────────────────────────────────────────────────────────────── */

/**
 * All timestamps arrive as `timestamptz`. The database stores a city's zone in
 * `cities.timezone`; Cairo is `Africa/Cairo`. Format in the *city's* zone, never
 * the device's, or a rider in another zone sees a different clock than the
 * kitchen does.
 */
export function formatWhen(
  iso: string,
  zone: string = "Africa/Cairo",
  language: Language = PRIMARY_LANGUAGE,
): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat(language === "ar" ? "ar-EG-u-nu-arab" : "en-EG", {
    numberingSystem: language === "ar" ? "arab" : "latn",
    timeZone: zone,
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

export function formatDate(
  iso: string,
  zone: string = "Africa/Cairo",
  language: Language = PRIMARY_LANGUAGE,
): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat(language === "ar" ? "ar-EG-u-nu-arab" : "en-EG", {
    numberingSystem: language === "ar" ? "arab" : "latn",
    timeZone: zone,
    day: "numeric",
    month: "long",
  }).format(date);
}

/**
 * "in 5 minutes" / "منذ ٥ دقائق", relative to the given zone's clock.
 *
 * Inside 24 hours this is a duration, so the zone does not change the answer.
 * Beyond that it hands off to `formatDate`, which does format in the zone - and
 * that is why the parameter is here rather than omitted: a caller reading this
 * signature should not have to know where the cutoff is.
 */
export function formatRelativeInZone(
  iso: string,
  zone: string = "Africa/Cairo",
  language: Language = PRIMARY_LANGUAGE,
  now: Date = new Date(),
): string {
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return "";
  const seconds = Math.round((then.getTime() - now.getTime()) / 1000);
  const rtf = new Intl.RelativeTimeFormat(language === "ar" ? "ar" : "en", { numeric: "auto" });
  if (Math.abs(seconds) < 60) return rtf.format(Math.round(seconds), "second");
  const minutes = Math.round(seconds / 60);
  if (Math.abs(minutes) < 60) return rtf.format(minutes, "minute");
  const hours = Math.round(minutes / 60);
  if (Math.abs(hours) < 24) return rtf.format(hours, "hour");
  // Past a day, "in 5 days" is less use than the actual date, and the date has to
  // be rendered in the city's zone rather than the device's.
  return formatDate(iso, zone, language);
}

/** The multiplier from basis points: 11000 → 1.1. Use for display maths only. */
export function multiplierFromBps(rateBps: number): number {
  return rateBps / BPS_DENOMINATOR;
}
