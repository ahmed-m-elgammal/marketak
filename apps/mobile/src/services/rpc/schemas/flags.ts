import { z } from "zod";

/** `get_flags_v1` row. `value` shape varies per flag — decode per use. */
export const flagRowSchema = z
  .object({
    flag_key: z.string(),
    value: z.unknown(),
  })
  .passthrough();

export const flagListSchema = z.array(flagRowSchema).readonly();
