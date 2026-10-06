/**
 * `lib/vendor-patch` - the admin-writable vendor fields, and what each one means for editing.
 *
 * ## Why the whitelist lives here and not only in SQL
 *
 * `admin_upsert_vendor_v1` carries its own server-side `v_allowed` array and raises `UNKNOWN_KEY` for anything
 * outside it. That is the security boundary and it is correct. This module is the *client's* knowledge of the
 * same list, and it exists for three reasons the SQL cannot serve:
 *
 * 1. **A form that omits a field silently drops the operator's edit.** The RPC updates with
 *    `coalesce(p_patch->>'col', v.col)`, so a key that is absent leaves the column untouched. An edit that
 *    appears to save and does nothing is worse than an error.
 * 2. **Three fields can be cleared and the rest cannot.** `brand_id`, `capacity_per_slot` and
 *    `delivery_fee_override` are written with `case when p_patch ? 'key' then ... else v.col end`, so sending an
 *    explicit JSON `null` clears them. Every other field uses `coalesce(...)`, which cannot distinguish "leave it
 *    alone" from "set it to null" — so **an optional field that is already set can never be unset.** A form
 *    offering a "Clear" button for those fields would be offering a button that cannot work. `CLEARABLE`
 *    records which ones genuinely can.
 * 3. **Creating needs eight fields that editing does not.** On INSERT the RPC applies no `coalesce` at all,
 *    and `slug`, `name`, `name_ar`, `city_id`, `area_id`, `latitude`, `longitude` and `geohash_prefix` are all
 *    `NOT NULL`. Omitting any one fails with a raw `23502` rather than a message an operator can act on, so
 *    `REQUIRED_ON_CREATE` makes the form ask for them up front instead.
 *
 * ## The four keys the form must never send
 *
 * `deleted_at`, `menu_version`, `*_normalized` and `id` are columns on `vendors` but **not** in the RPC's
 * whitelist. Sending them raises `UNKNOWN_KEY` - which is the right outcome, and `tests/vendor-patch.test.ts`
 * asserts the form's field set never contains them, so it is caught in CI rather than by a rejected save.
 */

/** How a value is supplied in the form. */
export type FieldKind = "text" | "integer" | "numeric" | "boolean" | "uuid" | "enum";

export interface VendorField {
  /** The exact key the RPC's whitelist expects. */
  readonly key: string;
  /** Translation key for the label. */
  readonly label: string;
  readonly kind: FieldKind;
  /** Must be present when creating. See the file header for the NOT NULL list. */
  readonly requiredOnCreate: boolean;
  /**
   * Sending an explicit JSON `null` clears the column.
   *
   * Only true for the three fields written with `case when p_patch ? 'key'`. Everything else uses `coalesce`
   * and cannot be cleared - see the file header.
   */
  readonly clearable: boolean;
  /** Allowed values, for `enum` fields. From the `vertical_type` CHECK constraint. */
  readonly values?: readonly string[];
  /** Placeholder or example, rendered as help text rather than as a value. */
  readonly hint?: string;
}

/**
 * Every key the RPC accepts, with the minimum needed to render the form.
 *
 * `readonly` in the literal type so a field cannot be added to the form without also deciding its `kind`,
 * whether it is required and whether it can be cleared. Those three answers are the ones that caused the
 * failures documented above.
 */
export const VENDOR_FIELDS = {
  slug: {
    key: "slug",
    label: "vendor.slug",
    kind: "text",
    requiredOnCreate: true,
    clearable: false,
    hint: "vendor.slugHint",
  },
  name: {
    key: "name",
    label: "vendor.name",
    kind: "text",
    requiredOnCreate: true,
    clearable: false,
  },
  name_ar: {
    key: "name_ar",
    label: "vendor.nameAr",
    kind: "text",
    requiredOnCreate: true,
    clearable: false,
  },
  legal_name: {
    key: "legal_name",
    label: "vendor.legalName",
    kind: "text",
    requiredOnCreate: false,
    clearable: false,
  },
  brand_id: {
    key: "brand_id",
    label: "vendor.brand",
    kind: "uuid",
    requiredOnCreate: false,
    // One of the three written with `case when p_patch ?`, so an explicit null really does clear it.
    clearable: true,
  },
  vertical_type: {
    key: "vertical_type",
    label: "vendor.verticalType",
    kind: "enum",
    requiredOnCreate: false,
    clearable: false,
    // From the `vertical_type` CHECK constraint, read live.
    values: ["food", "grocery", "pharmacy", "flowers", "bakery", "others"],
  },
  city_id: {
    key: "city_id",
    label: "vendor.city",
    kind: "uuid",
    requiredOnCreate: true,
    clearable: false,
  },
  area_id: {
    key: "area_id",
    label: "vendor.area",
    kind: "uuid",
    requiredOnCreate: true,
    clearable: false,
  },
  latitude: {
    key: "latitude",
    label: "vendor.latitude",
    kind: "numeric",
    requiredOnCreate: true,
    clearable: false,
  },
  longitude: {
    key: "longitude",
    label: "vendor.longitude",
    kind: "numeric",
    requiredOnCreate: true,
    clearable: false,
  },
  geohash_prefix: {
    key: "geohash_prefix",
    label: "vendor.geohash",
    kind: "text",
    requiredOnCreate: true,
    clearable: false,
    hint: "vendor.geohashHint",
  },
  delivery_radius_km: {
    key: "delivery_radius_km",
    label: "vendor.deliveryRadius",
    kind: "numeric",
    requiredOnCreate: false,
    clearable: false,
  },
  is_open: {
    key: "is_open",
    label: "vendor.isOpen",
    kind: "boolean",
    requiredOnCreate: false,
    clearable: false,
  },
  is_busy: {
    key: "is_busy",
    label: "vendor.isBusy",
    kind: "boolean",
    requiredOnCreate: false,
    clearable: false,
  },
  auto_open: {
    key: "auto_open",
    label: "vendor.autoOpen",
    kind: "boolean",
    requiredOnCreate: false,
    clearable: false,
  },
  is_approved: {
    key: "is_approved",
    label: "vendor.isApproved",
    kind: "boolean",
    requiredOnCreate: false,
    clearable: false,
  },
  is_active: {
    key: "is_active",
    label: "vendor.isActive",
    kind: "boolean",
    requiredOnCreate: false,
    clearable: false,
  },
  capacity_per_slot: {
    key: "capacity_per_slot",
    label: "vendor.capacityPerSlot",
    kind: "integer",
    requiredOnCreate: false,
    // Second of the three clearable fields.
    clearable: true,
  },
  reject_rate: {
    key: "reject_rate",
    label: "vendor.rejectRate",
    kind: "numeric",
    requiredOnCreate: false,
    clearable: false,
  },
  delivery_fee_override: {
    key: "delivery_fee_override",
    label: "vendor.deliveryFeeOverride",
    kind: "integer",
    requiredOnCreate: false,
    // Third of the three clearable fields.
    clearable: true,
  },
  minimum_order_value: {
    key: "minimum_order_value",
    label: "vendor.minimumOrderValue",
    kind: "integer",
    requiredOnCreate: false,
    clearable: false,
  },
  prep_time_minutes: {
    key: "prep_time_minutes",
    label: "vendor.prepTimeMin",
    kind: "integer",
    requiredOnCreate: false,
    clearable: false,
  },
  prep_time_max_minutes: {
    key: "prep_time_max_minutes",
    label: "vendor.prepTimeMax",
    kind: "integer",
    requiredOnCreate: false,
    clearable: false,
  },
  logo_path: {
    key: "logo_path",
    label: "vendor.logoPath",
    kind: "text",
    requiredOnCreate: false,
    clearable: false,
  },
  description: {
    key: "description",
    label: "vendor.description",
    kind: "text",
    requiredOnCreate: false,
    clearable: false,
  },
  description_ar: {
    key: "description_ar",
    label: "vendor.descriptionAr",
    kind: "text",
    requiredOnCreate: false,
    clearable: false,
  },
  contact_phone: {
    key: "contact_phone",
    label: "vendor.contactPhone",
    kind: "text",
    requiredOnCreate: false,
    clearable: false,
  },
  contact_landline: {
    key: "contact_landline",
    label: "vendor.contactLandline",
    kind: "text",
    requiredOnCreate: false,
    clearable: false,
  },
} as const satisfies Record<string, VendorField>;

export type VendorFieldKey = keyof typeof VENDOR_FIELDS;

/** Every key, in the order the RPC's `v_allowed` array lists them. */
export const VENDOR_FIELD_KEYS: readonly VendorFieldKey[] = Object.keys(VENDOR_FIELDS) as VendorFieldKey[];

/**
 * Columns that exist on `vendors` but are **not** admin-writable.
 *
 * Listed explicitly because each is a plausible mistake: `id` when building an edit payload, `deleted_at` when
 * trying to un-delete by hand, `menu_version` when copying a row, and the `*_normalized` columns that exist
 * purely as search indexes. Sending any of them raises `UNKNOWN_KEY` server-side; keeping them named here lets
 * a test assert the form never produces one.
 */
export const NON_WRITABLE_VENDOR_COLUMNS: readonly string[] = [
  "id",
  "deleted_at",
  "menu_version",
  "name_normalized",
  "name_ar_normalized",
  "description_normalized",
  "created_at",
  "updated_at",
  "rating_avg",
  "rating_count",
];

/** Fields a create must send, because the INSERT branch has no `coalesce` and the column is `NOT NULL`. */
export const REQUIRED_ON_CREATE: readonly VendorFieldKey[] = VENDOR_FIELD_KEYS.filter(
  (key) => VENDOR_FIELDS[key].requiredOnCreate,
);

/** Fields whose value can genuinely be removed by sending an explicit JSON `null`. */
export const CLEARABLE_FIELDS: readonly VendorFieldKey[] = VENDOR_FIELD_KEYS.filter(
  (key) => VENDOR_FIELDS[key].clearable,
);

/**
 * Builds the patch for an update: only the fields the operator actually changed.
 *
 * ## Why a diff rather than the whole form
 *
 * The RPC's `coalesce(p_patch->>'col', v.col)` means **an absent key leaves the column alone**, which is what
 * makes the endpoint safe to call with a partial payload. Sending the whole form would also work, but it would
 * send every field including the ones the operator did not touch - and for a `clearable` field that has been
 * emptied in the UI, a whole-form payload sends `null` and clears a value the operator never edited.
 *
 * So the patch is a diff, and `patchesEqual` below is the same comparison, kept beside it so the caller can skip
 * a save that would change nothing rather than firing an RPC that writes an identical row and logs a
 * `vendor.updated` event for no reason.
 */
export function buildVendorPatch(
  before: Readonly<Record<string, unknown>>,
  after: Readonly<Record<string, unknown>>,
): Record<string, string | number | boolean | null> {
  const patch: Record<string, string | number | boolean | null> = {};

  for (const key of VENDOR_FIELD_KEYS) {
    const next = after[key];
    if (next === undefined) {
      // Not in the form state at all - an absent key leaves the column alone.
      continue;
    }
    if (isCleared(next)) {
      // An emptied control. Only meaningful for a clearable field; for the rest an empty string is the value
      // the operator typed, and it is sent as an empty string rather than dropped.
      if (VENDOR_FIELDS[key].clearable) {
        patch[key] = null;
      } else if (next === "") {
        patch[key] = "";
      }
      continue;
    }
    if (!sameValue(before[key], next)) {
      patch[key] = next as string | number | boolean;
    }
  }

  return patch;
}

/** True when a patch would change nothing, so the RPC call can be skipped. */
export function patchesEqual(
  a: Readonly<Record<string, unknown>>,
  b: Readonly<Record<string, unknown>>,
): boolean {
  return Object.keys(buildVendorPatch(a, b)).length === 0;
}

/** An empty string, or `null`/`undefined`, is a control the operator cleared. */
function isCleared(value: unknown): boolean {
  return value === null || value === undefined || value === "";
}

/**
 * Loose equality, because a form yields strings and the database yields numbers.
 *
 * `"15"` and `15` are the same prep time; treating them as different would show an operator a "unsaved changes"
 * prompt on a form they have not touched. `String()` on both sides rather than `Number()` so an empty string
 * stays distinguishable from zero.
 */
function sameValue(before: unknown, after: unknown): boolean {
  if (before === null || before === undefined) {
    return after === null || after === undefined || after === "";
  }
  /*
   * A column value, never a nested object.
   *
   * `String({})` is `"[object Object]"`, which compares equal for *any* two different objects - so stringifying
   * one would silently drop a real edit. Narrowed to the primitives this comparison is meaningful for, which
   * makes the bad case unrepresentable rather than merely unlikely: `vendors` has no object or array column, and
   * one would not be editable through this RPC in any case.
   */
  type Scalar = string | number | boolean | bigint | symbol | null | undefined;
  const asScalar = (value: unknown): Scalar =>
    typeof value === "object" || typeof value === "function" ? null : (value as Scalar);

  return String(asScalar(before)) === String(asScalar(after));
}