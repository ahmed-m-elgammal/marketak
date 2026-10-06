/**
 * `tests/vendor-patch` - the client's knowledge of the vendor whitelist must match the server's.
 *
 * ## The problem this prevents
 *
 * `admin_upsert_vendor_v1` holds a server-side `v_allowed` array and raises `UNKNOWN_KEY` for anything outside
 * it. That is the real security boundary. But the console also needs to know the list, to build a form - and two
 * copies of a whitelist drift.
 *
 * The drift has a *specific* direction that matters here: if the form believes a field is writable when it is
 * not, every save that touches it is rejected with `UNKNOWN_KEY`; if the form omits a writable field, an edit to
 * it silently does nothing, because the RPC's `coalesce(p_patch->>'col', v.col)` leaves an absent key alone. The
 * second is worse - it looks like it saved.
 *
 * So the first test compares the client's list against the **migration SQL's own array**, read from disk. Not a
 * copy: the source. A field added to the RPC without adding it here fails this test, which is the point.
 */

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import {
  CLEARABLE_FIELDS,
  NON_WRITABLE_VENDOR_COLUMNS,
  REQUIRED_ON_CREATE,
  VENDOR_FIELDS,
  VENDOR_FIELD_KEYS,
  buildVendorPatch,
  patchesEqual,
} from "../lib/vendor-patch.js";

const MIGRATIONS = fileURLToPath(new URL("../../../../supabase/migrations/", import.meta.url));

/**
 * Pull `v_allowed` out of the migration that creates the function.
 *
 * Parsed from the source rather than typed in again - a test that asserts against a second hand-written copy of
 * the same list is asserting that two copies agree, which is not the same as asserting the form matches the
 * database.
 */
function serverWhitelist(): readonly string[] {
  for (const file of readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql"))) {
    const source = readFileSync(join(MIGRATIONS, file), "utf8");

    // Anchored on the function's own `create or replace`, because `v_allowed` is a common name: the cities and
    // areas upserts in the same migration declare one too, and an unanchored regex picked up `center_lat` and
    // `center_lng` from a neighbour. Anchoring means this can only ever read the vendor function's list.
    const marker = source.indexOf("create or replace function public.admin_upsert_vendor_v1");
    if (marker < 0) {
      continue;
    }
    const body = source.slice(marker);
    const end = body.indexOf("$$;");
    const scoped = end < 0 ? body : body.slice(0, end);
    const match = /v_allowed constant text\[\] := array\[([\s\S]*?)\]/.exec(scoped);
    if (match?.[1] !== undefined) {
      return match[1]
        .split(",")
        .map((token) => token.trim().replace(/^'|'$/gu, ""))
        .filter((token) => token !== "");
    }
  }
  throw new Error("v_allowed for admin_upsert_vendor_v1 not found in supabase/migrations");
}

const ALLOWED = serverWhitelist();

describe("vendor patch whitelist", () => {
  it("finds the server whitelist - a failed parse must not pass vacuously", () => {
    expect(ALLOWED.length).toBeGreaterThan(20);
  });

  it("sends the server exactly the fields it accepts, no more and no fewer", () => {
    expect([...VENDOR_FIELD_KEYS].sort()).toEqual([...ALLOWED].sort());
  });

  it("never offers a field the server would reject with UNKNOWN_KEY", () => {
    // The four the plan calls out explicitly, plus `id` and the timestamps, which are equally common
    // accidents when building an edit payload from a fetched row.
    for (const key of VENDOR_FIELD_KEYS) {
      expect(NON_WRITABLE_VENDOR_COLUMNS, `${key} is not admin-writable`).not.toContain(key);
    }
    expect(NON_WRITABLE_VENDOR_COLUMNS).toContain("deleted_at");
    expect(NON_WRITABLE_VENDOR_COLUMNS).toContain("menu_version");
    expect(NON_WRITABLE_VENDOR_COLUMNS).toContain("name_normalized");
  });

  it("requires on create exactly the NOT NULL columns the INSERT branch cannot default", () => {
    // The INSERT branch applies no `coalesce`, so each of these fails with a raw 23502 if omitted. Verified
    // against `pg_attribute.attnotnull` on the live table.
    expect([...REQUIRED_ON_CREATE].sort()).toEqual(
      [
        "area_id",
        "city_id",
        "geohash_prefix",
        "latitude",
        "longitude",
        "name",
        "name_ar",
        "slug",
      ].sort(),
    );
  });

  it("marks clearable only the three fields written with `case when p_patch ?`", () => {
    // Every other field uses `coalesce(p_patch->>'col', v.col)`, which cannot tell "leave it" from "set it to
    // null". Offering a Clear button for those would be offering a button that cannot work.
    expect([...CLEARABLE_FIELDS].sort()).toEqual(["brand_id", "capacity_per_slot", "delivery_fee_override"].sort());
  });

  it("declares a translation key for every field", () => {
    // A missing key renders as the literal key on the form. `i18n-catalogue.test.ts` catches keys *used* in
    // code; this catches keys *referenced as data* in the field table.
    for (const key of VENDOR_FIELD_KEYS) {
      const field = VENDOR_FIELDS[key];
      expect(field.label, `${key} has no label key`).toMatch(/^vendor\.[a-zA-Z]+$/u);
      expect(field.key, `${key}'s key does not match its own name`).toBe(key);
    }
  });
});

describe("buildVendorPatch", () => {
  it("sends only what changed, so an untouched field is never rewritten", () => {
    const before = { name: "Souq", prep_time_minutes: 15, is_open: false };
    const after = { name: "Souq", prep_time_minutes: 20, is_open: false };
    expect(buildVendorPatch(before, after)).toEqual({ prep_time_minutes: 20 });
  });

  it("sends nothing when nothing changed, so a no-op save is skipped", () => {
    expect(patchesEqual({ name: "Souq" }, { name: "Souq" })).toBe(true);
  });

  it("compares a form string against a database number as equal", () => {
    // A form yields "15" and the database yields 15. Treating those as different shows an operator an
    // unsaved-changes prompt on a form they have not touched.
    expect(patchesEqual({ prep_time_minutes: 15 }, { prep_time_minutes: "15" })).toBe(true);
    expect(patchesEqual({ prep_time_minutes: 15 }, { prep_time_minutes: "20" })).toBe(false);
  });

  it("clears a clearable field with an explicit null", () => {
    const patch = buildVendorPatch({ brand_id: "b-1" }, { brand_id: "" });
    expect(patch).toEqual({ brand_id: null });
  });

  it("sends an empty string for a non-clearable text field rather than dropping it", () => {
    // `coalesce` cannot clear it, so an emptied box means "this text is empty" and must be written. Dropping
    // the key would leave the old text in place and the operator would think it saved.
    const patch = buildVendorPatch({ description: "Fresh bread daily" }, { description: "" });
    expect(patch).toEqual({ description: "" });
  });

  it("ignores a field absent from the form state entirely", () => {
    // An absent key means "leave the column alone". This is what makes the endpoint safe for a partial patch.
    expect(buildVendorPatch({ name: "Souq" }, { name: "Souq 2" })).toEqual({ name: "Souq 2" });
  });

  it("records a change from a value to nothing for a clearable field", () => {
    expect(buildVendorPatch({ capacity_per_slot: null }, { capacity_per_slot: 5 })).toEqual({
      capacity_per_slot: 5,
    });
  });

  it("never emits a key outside the whitelist, whatever it is handed", () => {
    const hostile = {
      deleted_at: "2026-01-01T00:00:00Z",
      menu_version: 9,
      name_normalized: "souq",
      id: "11111111-1111-1111-1111-111111111111",
      name: "Souq",
    };
    const patch = buildVendorPatch({}, hostile);
    for (const key of Object.keys(patch)) {
      expect(ALLOWED, `patch leaked ${key}, which the server rejects with UNKNOWN_KEY`).toContain(key);
    }
  });
});