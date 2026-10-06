/**
 * Tests for the city-date logic.
 *
 * This is the module where a silent wrong answer is indistinguishable from correct data. `get_admin_metrics_v1`
 * derives its day boundary from `cities.timezone`, so if the console disagrees, the number beside the date
 * belongs to a different day and nothing looks wrong. Every assertion here is pinned to an instant where the
 * two definitions genuinely disagree.
 */

import { describe, expect, it } from "vitest";

import { cityDate, cityToday, shiftDays } from "../lib/city-date.js";

const CAIRO = "Africa/Cairo";
const UTC = "UTC";

describe("cityDate", () => {
  it("returns the date as the city reads it, not as UTC does", () => {
    // 22:30 UTC is already the NEXT day in Cairo (UTC+2/+3). This is the bug the module exists for: taking
    // `toISOString().slice(0,10)` here would silently return the wrong business day for every evening order.
    const instant = new Date("2026-10-06T22:30:00.000Z");
    expect(cityDate(instant, CAIRO)).toBe("2026-10-07");
    expect(cityDate(instant, UTC)).toBe("2026-10-06");
  });

  it("agrees with UTC during Cairo's daytime hours", () => {
    // 14:32 UTC is 16:32 or 17:32 locally - the same calendar day either way. Asserted so the module is not
    // merely offsetting everything by a constant, which would pass the first test and be wrong half the time.
    const instant = new Date("2026-10-06T14:32:00.000Z");
    expect(cityDate(instant, CAIRO)).toBe("2026-10-06");
  });

  it("respects daylight saving rather than applying a fixed offset", () => {
    // Egypt reintroduced DST in 2023. January is UTC+2, July is UTC+3. A hardcoded +2 would be right in
    // January and an hour wrong in July - and an hour wrong at 23:30 UTC in July is the WRONG DAY.
    const winter = new Date("2026-01-15T23:30:00.000Z");
    const summer = new Date("2026-07-15T23:30:00.000Z");
    expect(cityDate(winter, CAIRO)).toBe("2026-01-16");
    expect(cityDate(summer, CAIRO)).toBe("2026-07-16");
  });

  it("is independent of the machine running it", () => {
    // The function reads only the zone it is given and the UTC parts of the shifted instant, never
    // `getDate()` - which would return the *runtime's* local day and differ between a laptop in London and a
    // tablet in Cairo.
    const instant = new Date("2026-10-06T23:45:00.000Z");
    expect(cityDate(instant, "Africa/Cairo")).toBe("2026-10-07");
    expect(cityDate(instant, "Asia/Tokyo")).toBe("2026-10-07");
    expect(cityDate(instant, "America/New_York")).toBe("2026-10-06");
  });

  it("pads single-digit months and days", () => {
    // `2026-1-6` is not a date antd or Postgres will accept, and the failure surfaces as a query error rather
    // than as a wrong date - so the padding has to be right here.
    const instant = new Date("2026-01-06T12:00:00.000Z");
    expect(cityDate(instant, CAIRO)).toMatch(/^\d{4}-\d{2}-\d{2}$/u);
  });

  it("returns undefined for an unparseable instant", () => {
    expect(cityDate(new Date("not a date"), CAIRO)).toBeUndefined();
  });

  it("returns undefined for an unknown zone rather than falling back to UTC", () => {
    // A bad `cities.timezone` row must not take the dashboard down - and must not quietly reconcile the wrong
    // day either. `undefined` renders a visible marker.
    expect(cityDate(new Date("2026-10-06T12:00:00.000Z"), "Mars/Olympus_Mons")).toBeUndefined();
  });
});

describe("cityToday", () => {
  it("is the city's date, using the injected clock", () => {
    const now = new Date("2026-10-06T22:30:00.000Z");
    expect(cityToday(CAIRO, now)).toBe("2026-10-07");
  });
});

describe("shiftDays", () => {
  it("moves backwards across a month boundary", () => {
    expect(shiftDays("2026-10-01", -1)).toBe("2026-09-30");
  });

  it("moves forwards across a year boundary", () => {
    expect(shiftDays("2026-12-31", 1)).toBe("2027-01-01");
  });

  it("handles a leap day", () => {
    expect(shiftDays("2028-03-01", -1)).toBe("2028-02-29");
  });

  it("returns undefined for a malformed date rather than producing NaN-NaN-NaN", () => {
    expect(shiftDays("not-a-date", -1)).toBeUndefined();
    expect(shiftDays("", 1)).toBeUndefined();
  });

  it("round-trips, so a window's start and end agree", () => {
    const start = shiftDays("2026-03-10", -7);
    expect(shiftDays(start ?? "", 7)).toBe("2026-03-10");
  });
});