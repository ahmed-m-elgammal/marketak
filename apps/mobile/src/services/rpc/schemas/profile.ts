import { z } from "zod";
import { isoDate } from "./primitives";

/** `get_profile_status_v1` / `complete_profile_v1` / `update_profile_v1`. */
export const profileStatusSchema = z
  .object({
    profile_completed_at: isoDate.nullable(),
    has_phone: z.boolean(),
    has_address: z.boolean(),
    can_browse: z.boolean(),
    can_order: z.boolean(),
    missing: z.array(z.string()).readonly(),
  })
  .passthrough();
