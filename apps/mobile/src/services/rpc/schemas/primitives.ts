/**
 * Shared schema primitives for the RPC boundary.
 *
 * The fail-closed boundary, stated once so no schema re-decides it:
 *
 * - Money is strict: integer, non-negative, branded through the shared
 *   `toPiastres()` constructor. A parse failure throws and never renders 0.
 * - Branching vocabularies are strict unions: rejection codes, payment
 *   method/channel, delivery type/grouping, pricing mode, vertical type,
 *   discount type. These drive branches and charges; a value the app cannot
 *   classify is a state it cannot act on, so it throws into the mismatch
 *   path instead of guessing.
 * - Label vocabularies are strings: order/sub-order/assignment statuses,
 *   settlement status, address labels, actor roles, item status. The server
 *   CHECK owns these vocabularies and `npm run check:status-types` guards
 *   them statically; at runtime the app must still render a row carrying a
 *   status it has never seen (a new status must degrade to a label, never
 *   to a crashed screen). The `as` casts below are that decision, not
 *   laziness — each narrows `string` to the DTO union the server's CHECK
 *   already enforces.
 * - Unknown keys pass (`.passthrough()` everywhere): a server-side field
 *   addition must not crash the client. A new *shape* for a known field is
 *   not the same thing, and fails.
 */
import { z } from "zod";
import { toPiastres, type Piastres } from "@marketak/shared";

export const uuid = z.string().uuid();

/** Money fails closed. See header. */
export const piastres = z
  .number()
  .int()
  .nonnegative()
  .transform((value): Piastres => toPiastres(value));

export const nullablePiastres = z
  .number()
  .int()
  .nonnegative()
  .nullable()
  .transform((value): Piastres | null => (value === null ? null : toPiastres(value)));

/** `bpchar` columns arrive space-padded (`'EGP '`); the wire format, not the value. */
export const currency = z.string().trim();

/** `timestamptz` renders ISO. Presence + stringness only — the clock is the server's. */
export const isoDate = z.string();
