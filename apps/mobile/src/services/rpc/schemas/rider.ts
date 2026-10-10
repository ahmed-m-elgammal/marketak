import { z } from "zod";
import {
  COLLECTION_METHOD,
  PAYMENT_CHANNEL,
  type AssignedBy,
  type AssignmentStatus,
  type RiderStatus,
  type VehicleType,
} from "@marketak/shared";
import { isoDate, piastres, uuid } from "./primitives";

/** `get_my_rider_profile_v1` row. Vocabularies are labels (primitives header): the CHECK owns them. */
export const riderProfileSchema = z
  .object({
    rider_id: uuid,
    first_name: z.string(),
    last_name: z.string().nullable(),
    phone_number: z.string(),
    country_code: z.string(),
    vehicle_type: z.string().transform((value): VehicleType => value as VehicleType),
    vehicle_plate: z.string().nullable(),
    home_area_id: uuid.nullable(),
    status: z.string().transform((value): RiderStatus => value as RiderStatus),
    is_online: z.boolean(),
    is_active: z.boolean(),
    is_verified: z.boolean(),
    rating_avg: z.number(),
    rating_count: z.number().int(),
    completed_deliveries: z.number().int(),
    cancelled_deliveries: z.number().int(),
    cash_held: piastres,
    effective_cash_limit: piastres,
    current_latitude: z.number().nullable(),
    current_longitude: z.number().nullable(),
    last_location_at: isoDate.nullable(),
    created_at: isoDate,
  })
  .passthrough();

/**
 * `delivery_assignments` row. Pay figures are strict money; `status` is a
 * label the CHECK owns. `stop_sequence` is jsonb the trip renders as
 * returned, never recomputed — `unknown` on purpose.
 */
export const assignmentSchema = z
  .object({
    id: uuid,
    order_id: uuid,
    sub_order_id: uuid.nullable(),
    rider_id: uuid,
    status: z.string().transform((value): AssignmentStatus => value as AssignmentStatus),
    stop_sequence: z.unknown(),
    assigned_by: z.string().transform((value): AssignedBy => value as AssignedBy),
    assigned_at: isoDate,
    claimed_at: isoDate.nullable(),
    arrived_vendor_at: isoDate.nullable(),
    picked_up_at: isoDate.nullable(),
    arrived_at: isoDate.nullable(),
    delivered_at: isoDate.nullable(),
    distance_km: z.number().nullable(),
    eta_minutes: z.number().int().nullable(),
    rider_pay_base: piastres,
    rider_pay_distance: piastres,
    rider_pay_bonus: piastres,
    rider_pay_total: piastres,
    platform_revenue: piastres,
    collected_amount: piastres,
    collection_method: z.enum(COLLECTION_METHOD.values),
    collection_channel: z.enum(PAYMENT_CHANNEL.values).nullable(),
    collection_reference: z.string().nullable(),
    proof_path: z.string().nullable(),
    signature_path: z.string().nullable(),
  })
  .passthrough();
