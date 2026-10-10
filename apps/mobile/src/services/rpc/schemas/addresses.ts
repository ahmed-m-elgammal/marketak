import { z } from "zod";
import type { Address } from "@marketak/shared";
import { isoDate, uuid } from "./primitives";

/**
 * One `addresses` row. `label` is a display vocabulary (primitives header):
 * the server CHECK owns it, so an unseen label renders rather than throws.
 */
export const addressSchema = z
  .object({
    id: uuid,
    user_id: uuid,
    label: z.string().transform((value): Address["label"] => value as Address["label"]),
    area_id: uuid.nullable(),
    geohash: z.string(),
    geohash_prefix: z.string(),
    latitude: z.number(),
    longitude: z.number(),
    area_name: z.string().nullable(),
    building: z.string().nullable(),
    floor: z.string().nullable(),
    apartment: z.string().nullable(),
    landmark: z.string().nullable(),
    delivery_instructions: z.string().nullable(),
    is_default: z.boolean(),
    last_used_at: isoDate.nullable(),
    created_at: isoDate,
    updated_at: isoDate,
    deleted_at: isoDate.nullable(),
  })
  .passthrough();

export const addressListSchema = z.array(addressSchema).readonly();

/** `delete_address_v1` returns a bare boolean. */
export const deleteAddressSchema = z.boolean();
