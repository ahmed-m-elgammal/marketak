import { z } from "zod";

/** `riders_public` view row. See the DTO: every field nullable. */
export const riderPublicSchema = z
  .object({
    id: z.string().uuid().nullable(),
    first_name: z.string().nullable(),
    last_name: z.string().nullable(),
    phone_number: z.string().nullable(),
    vehicle_type: z.string().nullable(),
    vehicle_plate: z.string().nullable(),
    rating_avg: z.number().nullable(),
    rating_count: z.number().int().nullable(),
  })
  .passthrough();
