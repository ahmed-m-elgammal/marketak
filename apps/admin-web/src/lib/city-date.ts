/**
 * `lib/city-date` - "today" in the city's timezone.
 *
 * ## Why this module exists
 *
 * Every date-window function in the database derives its day boundary from `cities.timezone`
 * (`Africa/Cairo`), not from `current_date`. `get_admin_metrics_v1` does:
 *
 * ```sql
 * select c.timezone into v_tz from public.cities c where c.is_primary;
 * v_date := coalesce(p_date, (now() at time zone v_tz)::date);
 * ```
 *
 * The console therefore has to agree with that definition, or it shows a *different day* than the number
 * beside it. `new Date().toISOString().slice(0, 10)` is UTC — which for every evening hour in Cairo is
 * tomorrow's date. That is not a rounding bug, it is an operator reconciling yesterday's takings against a
 * figure computed for today.
 *
 * ## Why it reads the timezone from the database
 *
 * Hard-coding `"Africa/Cairo"` would be constitution rule 4 in reverse: a constant that silently disagrees
 * with the city row the moment a second city exists. The RPC echoes the timezone it used in
 * `payload.timezone`, so the console takes it from there and holds no timezone of its own.
 *
 * ## How a date is extracted from an instant in a zone
 *
 * `Intl.DateTimeFormat` with `timeZone` and no time components is the only correct way. `date.getDate()`
 * returns the *runtime's* local day, which is the bug.
 */

/**
 * The UTC offset of `timeZone` at `instant`, in minutes. Positive east of Greenwich.
 *
 * Built from `formatToParts` rather than `format` + `new Date(string)`. That looks equivalent and is not:
 * `format` produces something like `"10/06/2026, 22:30:00"`, and `new Date()` on that string parses it in the
 * **runtime's** local zone — so the function returned the host machine's offset while claiming to return the
 * target zone's. Every test that expected a date different from the host's failed.
 *
 * `formatToParts` gives the fields, and `Date.UTC` on those fields is exactly "that wall clock, read as if it
 * were UTC". The difference from the real instant is the offset.
 *
 * `hour % 24` guards a real `Intl` quirk: with `hour12: false` some locales render midnight as hour `24`.
 */
function zoneOffsetMinutes(timeZone: string, instant: Date): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(instant);

  const field = (type: Intl.DateTimeFormatPartTypes): number => {
    const found = parts.find((part) => part.type === type);
    return found === undefined ? Number.NaN : Number(found.value);
  };

  const asZoneUtc = Date.UTC(
    field("year"),
    field("month") - 1,
    field("day"),
    field("hour") % 24,
    field("minute"),
    field("second"),
  );

  if (Number.isNaN(asZoneUtc)) {
    return Number.NaN;
  }
  // `instant` carries milliseconds; the parts do not, so both sides are floored to whole seconds before the
  // subtraction. Otherwise the difference carries a fractional minute and the arithmetic drifts.
  return (asZoneUtc - Math.floor(instant.getTime() / 1000) * 1000) / 60_000;
}

/**
 * The calendar date `instant` falls on in `timeZone`, as `YYYY-MM-DD`.
 *
 * The two-step is deliberate: shift the instant by the zone's offset, THEN read the UTC parts of the result.
 * Reading the parts of the shifted instant is what makes it independent of where the browser is running — a
 * laptop in UTC and a tablet in Cairo produce the same answer.
 *
 * Returns `undefined` for an unparseable instant or an unknown zone, so a caller renders a visible marker
 * rather than a confidently wrong date.
 */
export function cityDate(instant: Date, timeZone: string): string | undefined {
  if (Number.isNaN(instant.getTime())) {
    return undefined;
  }
  try {
    const offset = zoneOffsetMinutes(timeZone, instant);
    if (Number.isNaN(offset)) {
      return undefined;
    }
    const shifted = new Date(instant.getTime() + offset * 60_000);
    const year = String(shifted.getUTCFullYear()).padStart(4, "0");
    const month = String(shifted.getUTCMonth() + 1).padStart(2, "0");
    const day = String(shifted.getUTCDate()).padStart(2, "0");
    return `${year}-${month}-${day}`;
  } catch {
    // `Intl.DateTimeFormat` throws `RangeError` on an unknown IANA zone. A bad `cities.timezone` must not
    // take the dashboard down, and must not silently fall back to UTC either.
    return undefined;
  }
}

/** Today's date in `timeZone`. The argument is a `Date` so a test can pin "now". */
export function cityToday(timeZone: string, now: Date = new Date()): string | undefined {
  return cityDate(now, timeZone);
}

/** `days` before `date`, as `YYYY-MM-DD`. Used for the variance window's default. */
export function shiftDays(date: string, days: number): string | undefined {
  const parsed = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(date);
  if (parsed === null) {
    return undefined;
  }
  const [, year, month, day] = parsed;
  const base = Date.UTC(Number(year), Number(month) - 1, Number(day));
  if (Number.isNaN(base)) {
    return undefined;
  }
  // UTC arithmetic, not `cityDate`. A bare `YYYY-MM-DD` shifted by whole days has no zone attached, so
  // routing it through a zone-aware function would reintroduce an offset the caller never asked for - and
  // `Date.UTC` handles month and year rollover for free.
  const shifted = new Date(base + days * 86_400_000);
  return shifted.toISOString().slice(0, 10);
}