import { describe, expect, it } from "vitest";
import { addressSchema } from "./addresses";
import { nullablePiastres, piastres } from "./primitives";
import { quoteRejectionSchema } from "./quote";

describe("boundary primitives", () => {
  it("brands integer piastres and rejects floats and negatives", () => {
    expect(piastres.parse(5)).toBe(5);
    expect(() => piastres.parse(5.5)).toThrow();
    expect(() => piastres.parse(-1)).toThrow();
  });

  it("passes null through nullable money untouched", () => {
    expect(nullablePiastres.parse(null)).toBeNull();
    expect(nullablePiastres.parse(0)).toBe(0);
  });

  it("accepts every known rejection code and rejects the unknown", () => {
    expect(quoteRejectionSchema.parse({ vendor_id: null, code: "OUT_OF_STOCK", message_ar: "…" }).code).toBe(
      "OUT_OF_STOCK",
    );
    expect(() => quoteRejectionSchema.parse({ vendor_id: null, code: "FUTURE_CODE", message_ar: "…" })).toThrow();
  });

  it("keeps unknown object keys instead of crashing on server additions", () => {
    const row = addressSchema.parse({
      id: "123e4567-e89b-12d3-a456-426614174000",
      user_id: "123e4567-e89b-12d3-a456-426614174000",
      label: "home",
      area_id: null,
      geohash: "x",
      geohash_prefix: "y",
      latitude: 1,
      longitude: 2,
      area_name: null,
      building: null,
      floor: null,
      apartment: null,
      landmark: null,
      delivery_instructions: null,
      is_default: false,
      last_used_at: null,
      created_at: "2026-10-10T00:00:00Z",
      updated_at: "2026-10-10T00:00:00Z",
      deleted_at: null,
      future_column: "new",
    });
    expect(row).toMatchObject({ label: "home" });
  });

  it("renders unseen labels rather than throwing the address book away", () => {
    const row = addressSchema.parse({
      id: "123e4567-e89b-12d3-a456-426614174000",
      user_id: "123e4567-e89b-12d3-a456-426614174000",
      label: "planet",
      area_id: null,
      geohash: "x",
      geohash_prefix: "y",
      latitude: 1,
      longitude: 2,
      area_name: null,
      building: null,
      floor: null,
      apartment: null,
      landmark: null,
      delivery_instructions: null,
      is_default: false,
      last_used_at: null,
      created_at: "2026-10-10T00:00:00Z",
      updated_at: "2026-10-10T00:00:00Z",
      deleted_at: null,
    });
    expect(row.label).toBe("planet");
  });
});
