/**
 * `lib/queries/vendors` - the vendor list and the three write RPCs.
 *
 * ## Reads go through RLS, writes through RPCs
 *
 * `vendors` carries an admin `SELECT` policy (verified live: `vendors_admin_read`), so the list reads the table
 * directly. The writes cannot: `admin_upsert_vendor_v1`, `admin_delete_vendor_v1` and
 * `admin_restore_vendor_v1` are `SECURITY DEFINER` and carry the server-side whitelist and guard chain that the
 * table's own policies deliberately do not provide.
 *
 * ## Pagination is server-side, and `count: "exact"`
 *
 * `count: "exact"` makes PostgREST count the full filtered set rather than estimating, so the pager can say
 * "showing 20 of 214" truthfully. Without it PostgREST returns a *plan-based estimate*, which on a filtered
 * query can be off by a wide margin — and a pager whose total is wrong is worse than no pager, because an
 * operator trusts it when deciding whether a merchant has been missed.
 *
 * The alternative — fetching everything and slicing in the browser — was rejected in the plan: it cannot page
 * past the first few hundred rows and it transfers the whole table to do it.
 *
 * ## Every RPC is called with all of its arguments named
 *
 * `admin_upsert_vendor_v1(p_patch, p_id)` has no default on `p_id`, and PostgREST will not route a bodiless
 * `POST /rpc/f` to a function with declared parameters at all (that returns `PGRST202` and blames the schema
 * cache). So `p_id` is sent as `null` for a create. `tests/rpc-arguments.test.ts` enforces this for every call
 * in this directory.
 */

import type { PostgrestError } from "@supabase/supabase-js";

import { getSupabase } from "../supabase-client.js";
import { PostgrestQueryError } from "../postgrest.js";
import { VENDOR_FIELD_KEYS } from "../vendor-patch.js";
import { DEMO_VENDOR_LIST, isDemoMode } from "../demo.js";


/** A vendor as the list needs it. Deliberately narrow: one row, one line. */
export interface VendorRow {
  readonly id: string;
  readonly name: string;
  readonly name_ar: string | null;
  readonly slug: string;
  readonly vertical_type: string;
  readonly city_id: string;
  readonly is_open: boolean;
  readonly is_approved: boolean;
  readonly is_active: boolean;
  readonly prep_time_minutes: number;
  readonly rating_avg: number;
  readonly rating_count: number;
  readonly created_at: string;
  readonly deleted_at: string | null;
}

/** The full row, for the edit form. Every field the RPC accepts, plus what it refuses to accept. */
export interface VendorDetail extends VendorRow {
  readonly legal_name: string | null;
  readonly brand_id: string | null;
  readonly area_id: string | null;
  readonly latitude: number;
  readonly longitude: number;
  readonly geohash_prefix: string;
  readonly delivery_radius_km: number;
  readonly is_busy: boolean;
  readonly auto_open: boolean;
  readonly capacity_per_slot: number | null;
  readonly reject_rate: number;
  readonly delivery_fee_override: number | null;
  readonly minimum_order_value: number;
  readonly prep_time_max_minutes: number;
  readonly logo_path: string | null;
  readonly description: string | null;
  readonly description_ar: string | null;
  readonly contact_phone: string | null;
  readonly contact_landline: string | null;
}

/** A city or area, for the form's pickers. */
export interface PlaceOption {
  readonly id: string;
  readonly name: string;
  readonly name_ar: string | null;
}

export interface VendorListResult {
  readonly rows: readonly VendorRow[];
  /** Total matching the filter, from PostgREST's exact count. Not an estimate. */
  readonly total: number;
}

export interface VendorListFilters {
  readonly search?: string | undefined;
  readonly vertical?: string | undefined;
  readonly approved?: "all" | "yes" | "no" | undefined;
  /** `active` hides soft-deleted rows; `deleted` shows only them; `all` shows both. */
  readonly state?: "active" | "deleted" | "all" | undefined;
  readonly page: number;
  readonly pageSize: number;
}

export const DEFAULT_PAGE_SIZE = 20;

/**
 * The "no vertical filter" sentinel.
 *
 * A named constant rather than the bare string `"all"`, because the filter type is
 * `"all" | Vertical | undefined` - and a literal `"all"` inside a comparison widens `Vertical` to include it,
 * which then fails the `eq()` argument type. Naming it once here is what keeps the two spellings from drifting.
 */
export const ALL = "all";

/**
 * `vendors_read` is an admin policy, and the list must show soft-deleted rows when asked for them - the restore
 * flow needs to find them. `select` is the explicit column list rather than `*`, which is both the documented
 * shape of the query and one reason a careless edit payload can never pick up `menu_version` or a
 * `*_normalized` column: they are never on the wire to begin with.
 */
const LIST_COLUMNS =
  "id, name, name_ar, slug, vertical_type, city_id, is_open, is_approved, is_active, prep_time_minutes, rating_avg, rating_count, created_at, deleted_at";

/**
 * Every column the edit form needs, and nothing else.
 *
 * Deliberately **not** `select("*")`. A `*` here would drag `menu_version`, the three `*_normalized` search
 * columns and `id` into the payload the form diffs against, and a naive `Object.keys(row)` diff would then
 * offer all of them for saving - each one rejected by the RPC with `UNKNOWN_KEY`. Naming the columns is what
 * makes `buildVendorPatch` provably whitelist-only.
 */
const VENDOR_DETAIL_COLUMNS = [
  ...VENDOR_FIELD_KEYS,
  "id",
  "created_at",
  "updated_at",
  "deleted_at",
  "rating_avg",
  "rating_count",
].join(", ");

/**
 * The vendor list, filtered and paged in the database.
 *
 * The `search` filter is `ilike` with the term wrapped in `%`. That is a leading-wildcard pattern, which means
 * `pg_trgm` or a full-text index is what makes it fast — neither is installed here. On a small city
 * (one city, a handful of merchants) that is the right trade: adding a GIN index for a pattern that is measured
 * in hundreds of rows would be cost without benefit. **If the vendor count passes roughly 5,000, add
 * `pg_trgm` and re-measure before shipping more filters.**
 */
export async function listVendors(filters: VendorListFilters): Promise<VendorListResult> {
  if (isDemoMode()) {
    return DEMO_VENDOR_LIST;
  }
  const db = getSupabase();
  const from = filters.page * filters.pageSize;
  const to = from + filters.pageSize - 1;

  /*
   * Built in one expression rather than through a helper that takes and returns the builder.
   *
   * `PostgrestFilterBuilder` carries its result type through seven generic parameters, and threading it through
   * a typed helper drives TypeScript into "excessively deep and possibly infinite" while still rejecting the
   * concrete instantiation as unassignable. Letting the chain stay in one expression gives the compiler the
   * single inference site it needs, and the filters are simple enough that the helper was not earning its keep.
   */
  const base = db.from("vendors").select(LIST_COLUMNS, { count: "exact" });

  const search = filters.search?.trim();
  const filtered =
    search !== undefined && search !== ""
      ? // Both the English and the Arabic name, so an operator searching "souq" and one searching "سوق" both
        // find the same row. `or` is the only way to search two columns through PostgREST.
        base.or(`name.ilike.%${search}%,name_ar.ilike.%${search}%`)
      : base;

  const byVertical =
    filters.vertical !== undefined && filters.vertical !== ALL
      ? filtered.eq("vertical_type", filters.vertical)
      : filtered;

  const byApproval =
    filters.approved === "yes"
      ? byVertical.is("is_approved", true)
      : filters.approved === "no"
        ? byVertical.is("is_approved", false)
        : byVertical;

  /*
   * The default hides soft-deleted rows: a deleted merchant is not a live merchant, and an operator opening the
   * list wants live ones. `is(null)` rather than `not.is`, which PostgREST does not offer.
   */
  const byState =
    filters.state === "deleted"
      ? byApproval.not("deleted_at", "is", null)
      : filters.state === "all"
        ? byApproval
        : byApproval.is("deleted_at", null);

  const { data, error, count } = await byState
    .order("created_at", { ascending: false })
    .range(from, to);

  if (error !== null && error !== undefined) {
    throw new PostgrestQueryError(error);
  }

  /*
   * Read through `unknown` first. With an untyped `supabase-js` client, `data` is `any`, and casting it straight
   * to `VendorRow[]` is the `any` reaching the call site that constitution rule 1 forbids - the cast would
   * assert a shape nothing had checked. Going via `unknown` makes the compiler verify that the intermediate is
   * not itself an `any`, so the assertion is a real boundary rather than a formality.
   */
  const rows: unknown = data ?? [];
  return { rows: rows as VendorRow[], total: count ?? 0 };
}

/** One vendor, for the edit form. Returns `null` when there is none. */
export async function getVendor(id: string): Promise<VendorDetail | null> {
  const db = getSupabase();
  const { data, error } = await db.from("vendors").select(VENDOR_DETAIL_COLUMNS).eq("id", id).maybeSingle();

  if (error !== null && error !== undefined) {
    throw new PostgrestQueryError(error);
  }
  // Via `unknown`, so the assertion is a checked boundary rather than an `any` cast through. See the note in
  // `listVendors`.
  const row: unknown = data ?? null;
  return row === null ? null : (row as VendorDetail);
}

/** Cities for the form's picker. Soft-deleted ones are excluded - they cannot be assigned to. */
export async function listCities(): Promise<readonly PlaceOption[]> {
  const db = getSupabase();
  const { data, error } = await db
    .from("cities")
    .select("id, name, name_ar")
    .is("deleted_at", null)
    .order("name");

  if (error !== null && error !== undefined) {
    throw new PostgrestQueryError(error);
  }
  const rows: unknown = data ?? [];
  return rows as PlaceOption[];
}

/** Areas for the form's picker. */
export async function listAreas(cityId?: string): Promise<readonly PlaceOption[]> {
  const db = getSupabase();
  let query = db.from("areas").select("id, name, name_ar").is("deleted_at", null).order("name");
  if (cityId !== undefined && cityId !== "") {
    query = query.eq("city_id", cityId);
  }
  const { data, error } = await query;

  if (error !== null && error !== undefined) {
    throw new PostgrestQueryError(error);
  }
  const rows: unknown = data ?? [];
  return rows as PlaceOption[];
}

/**
 * Creates or updates a vendor.
 *
 * ## `p_id` is always sent
 *
 * `null` creates, a uuid updates. The signature has no default on `p_id`, so omitting the key entirely makes
 * the call unroutable (see the file header), and on INSERT the RPC applies no `coalesce` to any column - so a
 * create missing one of the eight `NOT NULL` fields fails with a raw `23502` rather than a message. The form
 * requires them; this function only forwards.
 *
 * Returns the vendor id. The RPC returns `uuid` directly rather than a `TABLE`, so this reads `data` as a
 * scalar - not through `rpcRows`, which would wrap a bare scalar in an array that never arrives.
 */
export async function upsertVendor(
  patch: Readonly<Record<string, string | number | boolean | null>>,
  id: string | null,
): Promise<string> {
  const db = getSupabase();
  /*
   * The `any` at the `rpc` edge is captured into `unknown` first, then narrowed - constitution rule 1 requires
   * the `any` to be *wrapped*, not cast through. Destructuring the call's result directly would destructure
   * `any`-typed properties, which is the same leak by another route.
   */
  const result: unknown = await db.rpc("admin_upsert_vendor_v1", {
    p_patch: patch,
    p_id: id,
  });
  const { data, error } = result as { data: unknown; error: PostgrestError | null };

  if (error !== null && error !== undefined) {
    throw new PostgrestQueryError(error);
  }
  // A `uuid` return arrives as a bare string. Anything else means the signature changed underneath this file,
  // which is worth failing loudly on rather than writing `undefined` into the cache.
  if (typeof data !== "string") {
    throw new PostgrestQueryError(new Error("admin_upsert_vendor_v1 did not return a vendor id"));
  }
  return data;
}

/**
 * Soft-deletes a vendor. `p_reason` is mandatory server-side (`REASON_REQUIRED`) and the form requires it too.
 *
 * Note what the RPC does *not* touch: `is_approved` is left alone, and `is_active` is set to `false`
 * alongside `deleted_at`. Restoring puts `is_active` back but deliberately leaves `is_approved` as it was, so a
 * restored vendor is still unapproved and does not reappear in the customer app without a separate decision.
 */
export async function deleteVendor(id: string, reason: string): Promise<void> {
  const db = getSupabase();
  const { error } = await db.rpc("admin_delete_vendor_v1", { p_id: id, p_reason: reason });
  if (error !== null && error !== undefined) {
    throw new PostgrestQueryError(error);
  }
}

/** Restores a soft-deleted vendor. `p_reason` is mandatory here too, which the plan did not mention. */
export async function restoreVendor(id: string, reason: string): Promise<void> {
  const db = getSupabase();
  const { error } = await db.rpc("admin_restore_vendor_v1", { p_id: id, p_reason: reason });
  if (error !== null && error !== undefined) {
    throw new PostgrestQueryError(error);
  }
}

/** Re-exported so a form module imports one thing for both the field list and its keys. */
export { VENDOR_FIELD_KEYS, VENDOR_FIELDS } from "../vendor-patch.js";
export type { VendorFieldKey } from "../vendor-patch.js";
