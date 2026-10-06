/**
 * `domain/measure` - formatting rates, multipliers and instants.
 *
 * ## Why this file exists and `i18n/format.ts` in the console does not
 *
 * A0.3 requires the console to consume money and rate formatting from here rather than reimplement it, and
 * the first pass of that work got it wrong: `formatMultiplier`, `formatRateBps` and `formatWhen` were written
 * inside `apps/admin-web`. They are not console concerns. Every value they format comes out of a column the
 * mobile app also reads -
 *
 * | Function | Reads | Also needed by |
 * |---|---|---|
 * | `formatMultiplierBps` | `delivery_fee_tiers.multiplier_bps`, `commission_rules.value` | the vendor dashboard |
 * | `formatRateBps` | every rate in `get_admin_metrics_v1` | the rider app's stats screen |
 * | `formatWhen` | `placed_at`, `completed_at`, `picked_up_at` | the customer's order tracker |
 *
 * Two copies of a formatter is how two screens end up disagreeing about the same figure. The mobile app does
 * not exist yet, so the duplication would have been invisible until it did.
 *
 * ## Why a locale STRING and not a `Locale` union
 *
 * These functions take any BCP-47 tag. A `Locale` union would put the console's `{en, ar}` into a package the
 * mobile app imports, and the mobile app might ship `{en, ar, fr}` - at which point the shared union is a
 * constraint rather than a convenience. The caller owns the mapping.
 *
 * ## Why the timezone argument is required
 *
 * `get_admin_metrics_v1` derives its day boundary from `cities.timezone`, and the same is true of every
 * earnings window in `private.earnings_window`. A formatter that defaulted to the device timezone would show
 * a different day - in Cairo, for every evening hour - than the number beside it. Making the argument
 * mandatory makes that mistake impossible rather than merely discouraged.
 */

/** Basis points per unit multiplier. 10000 bps = 1.00x. */
export const BPS_PER_UNIT = 10_000;

/**
 * Converts a stored basis-point multiplier into a factor.
 *
 * A **number**, not a formatted string, so it composes: the caller decides the locale's decimal separator.
 * `1.25` renders as `1.25x` in English and `1.25x` in Arabic through `Intl`, which is why this is not a
 * template string.
 */
export function multiplierFromBps(bps: number): number {
  return bps / BPS_PER_UNIT;
}

/**
 * Formats a fee multiplier for a human.
 *
 * Two decimal places, because a fee multiplier is a pricing decision and `1.3` versus `1.30` should look
 * identical. Returns `undefined` for a non-finite input rather than `"NaNx"`, matching `formatMoney`: a
 * formatter that can print `NaN` will eventually do so on a screen.
 */
export function formatMultiplierBps(
  bps: number,
  locale: string,
  suffix = "x",
): string | undefined {
  if (!Number.isFinite(bps)) {
    return undefined;
  }
  const text = new Intl.NumberFormat(locale, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(multiplierFromBps(bps));
  return `${text}${suffix}`;
}

/**
 * Formats a percentage from basis points, which is how every rate in this schema is stored.
 *
 * `completion_rate_bps = 8425` means 84.25%. Rendering the raw integer is the same mistake as rendering
 * `multiplier_bps` raw, and an operator acting on it acts on a number twelve times too large.
 *
 * One decimal place: a rate that says "84.3%" is as precise as an order count supports.
 */
export function formatRateBps(bps: number, locale: string): string | undefined {
  if (!Number.isFinite(bps)) {
    return undefined;
  }
  return new Intl.NumberFormat(locale, {
    style: "percent",
    minimumFractionDigits: 1,
    maximumFractionDigits: 1,
  }).format(bps / BPS_PER_UNIT);
}

/** Formats an instant in an explicit timezone. */
export function formatDateTimeInZone(
  instant: string | Date,
  timeZone: string,
  locale: string,
): string | undefined {
  const date = instant instanceof Date ? instant : new Date(instant);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }
  return new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone,
  }).format(date);
}

/**
 * A relative time, for anything within the last day.
 *
 * Returns `undefined` past 24 hours so the caller falls back to `formatDateTimeInZone`. "23 hours ago" is
 * unhelpful on a support ticket; an absolute time is what gets copied into one.
 *
 * `now` is a parameter rather than a `Date.now()` call so every relative assertion in a test is deterministic
 * instead of drifting with the wall clock.
 */
export function formatRelativeInZone(
  instant: string | Date,
  locale: string,
  now: Date = new Date(),
): string | undefined {
  const date = instant instanceof Date ? instant : new Date(instant);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }
  const elapsedMs = now.getTime() - date.getTime();
  // A future instant returns `undefined` too: "in 3 minutes" on a delivered order means a clock skew, not
  // something to render as relative time.
  if (elapsedMs < 0 || elapsedMs > 24 * 60 * 60 * 1000) {
    return undefined;
  }
  return new Intl.RelativeTimeFormat(locale, { numeric: "auto" }).format(
    -Math.round(elapsedMs / 60_000),
    "minute",
  );
}

/**
 * Picks the right of the two time formats.
 *
 * This is what a component should call, so the "recent is relative, old is absolute" rule lives in one place
 * instead of being re-decided on every screen.
 */
export function formatWhen(
  instant: string | Date,
  timeZone: string,
  locale: string,
  now: Date = new Date(),
): string | undefined {
  return (
    formatRelativeInZone(instant, locale, now) ?? formatDateTimeInZone(instant, timeZone, locale)
  );
}