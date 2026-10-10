import { z } from "zod";
import { APP_ROLE, PLATFORM } from "@marketak/shared";
import { isoDate } from "./primitives";

/**
 * `register_device_token_v1` → `SETOF device_tokens`. The call returns every
 * token the user registered, not just this one — server state, never echoed.
 */
export const deviceTokenSchema = z
  .object({
    id: z.string().uuid(),
    user_id: z.string().uuid(),
    token: z.string(),
    platform: z.enum(PLATFORM.values),
    app_role: z.enum(APP_ROLE.values),
    app_version: z.string().nullable(),
    language: z.enum(["ar", "en"]),
    last_seen_at: isoDate,
    created_at: isoDate,
  })
  .passthrough();

export const deviceTokenListSchema = z.array(deviceTokenSchema).readonly();
