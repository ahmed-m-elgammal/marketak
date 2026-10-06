/**
 * `domain/notifications` - the push drain's wire contract.
 *
 * ## What this file is for
 *
 * One definition of the RPC shapes, so a database column rename cannot half-land: the Worker, the tests
 * and the docs all read from here.
 *
 * ## EVERY FIELD WAS CHECKED AGAINST THE LIVE DATABASE
 *
 * Not inferred from a migration file, and two things that looked obvious were wrong:
 *
 * - `users.preferred_language` is constrained by
 *   `users_preferred_language_check CHECK (preferred_language = ANY (ARRAY['ar','en']))`. So `Language` is
 *   the union of those two values and **not** `string`.
 * - There is **no** currency constant anywhere in this file. `currency` arrives per claim row, read from
 *   `orders.currency`, because it is a `bpchar` column on six tables and `admin_upsert_city_v1` lets an
 *   admin change it. Migration `038i` was written specifically to add the field to the claim, because the
 *   Worker could not format money without it.
 *
 * Migration `038i` added `currency` to the claim variables. `038g` added `eta`, sourced from the rider
 * assignment because `orders.promised_delivery_at` turned out to have no writer anywhere in the schema.
 */

export type { CurrencyCode, Piastres } from "../money/format-money.js";

/** `users.preferred_language`. The CHECK constraint admits exactly these two. */
export type Language = "ar" | "en";

/** Which party a notification is for. Matches `private.push_routing().v_recipient`. */
export type Recipient = "customer" | "vendor" | "rider";

/**
 * One row returned by `claim_events_v1`.
 *
 * COLLAPSED, not one-per-event: `event_ids` holds every event that produced this single notification, so
 * three sub-orders reaching `picked_up` on one order is one row carrying three ids. Marking therefore has
 * to close all of them together, and a partial failure leaves only the failed ones open.
 */
export interface ClaimedNotification {
  /** Every `events.id` this notification covers. Never empty. */
  readonly event_ids: readonly bigint[];
  /** `notification_templates.key`. */
  readonly template_key: string;
  readonly recipient: Recipient;
  /** The resolved addressee: the customer, the vendor, or the rider. */
  readonly recipient_id: string;
  readonly order_id: string;
  readonly order_number: string;
  /**
   * Per-order display values, already joined and collapsed by the RPC.
   *
   * Keys are ABSENT rather than null when the RPC could not supply one, because `jsonb_strip_nulls` runs
   * there and the renderer checks for presence. A field typed `null` here would be a lie about what
   * Postgres returned, so every field is optional rather than nullable.
   */
  readonly variables: NotificationVariables;
  readonly language: Language;
  readonly oldest_event: string;
}

/**
 * The variables `claim_events_v1` supplies.
 *
 * `total`, `refund_amount` and `rider_pay_total` are integer piastres and MUST go through `formatMoney`
 * before reaching a template. `eta` is `HH24:MI` in the city's timezone, formatted by the RPC in `038g`.
 */
export interface NotificationVariables {
  readonly order_number?: string;
  readonly vendor_count?: number;
  /** Piacres. Never a float. */
  readonly total?: number;
  readonly vendor_name?: string;
  readonly reason?: string;
  /** Piacres. Always present on `order.cancelled`; the RPC coalesces to 0 when there is no refund. */
  readonly refund_amount?: number;
  /** Piacres. `0` is legitimate and meaningful when no pay rule is configured. */
  readonly rider_pay_total?: number;
  readonly affected_items?: number;
  readonly rider_name?: string;
  readonly stops?: number;
  /** `HH24:MI`, city timezone. Absent when there is no rider assignment yet. */
  readonly eta?: string;
  readonly payment_method?: string;
  readonly item_count?: number;
  /**
   * ISO 4217 code, trimmed, from `orders.currency`. Added by `038i`.
   *
   * Not a union of known codes: the column is unconstrained `bpchar`, so narrowing the type here would
   * claim a guarantee the database does not make.
   */
  readonly currency?: string;
}

/**
 * The three variables the Worker owns and the database deliberately does not.
 *
 * Verified against the `notification_templates.variables` column: for all seven routed templates, these are
 * exactly the declared placeholders that `claim_events_v1` does not supply. The 12 unrouted templates want
 * others, and those are Phase 4 work.
 *
 * THE COPY IS A PRODUCT DECISION that has not been reviewed. The three strings below are a first draft and
 * are deliberately conservative: `prep_deadline` states a duration rather than a clock time, because a hard
 * "by 13:30" is a promise the platform cannot keep once vendors are late, and a push that lies about a
 * deadline erodes trust in every other push. Changing any of these is a copy change, not a code change,
 * and belongs with whoever owns the product wording.
 */
export const WORKER_STATIC_VARIABLES: Readonly<Record<string, string>> = Object.freeze({
  review_prompt: "Enjoy your meal? Leave a rating.",
  action_required: "remove the affected items and order them again",
  prep_deadline: "within the next 30 minutes",
});

/** One row of `public.device_tokens`, as the dispatcher needs it. Never read by a client. */
export interface DeviceTokenRow {
  readonly id: string;
  readonly token: string;
  /** The CHECK permits `{android, ios}`; `register_device_token_v1` refuses anything else from a client. */
  readonly platform: "android" | "ios";
  readonly app_role: string;
  readonly language: string;
}

/** One row of `public.notification_templates`. */
export interface TemplateRow {
  readonly key: string;
  readonly lang: Language;
  readonly title: string;
  readonly body: string;
  /**
   * The placeholders this template declares, from the `variables jsonb` column.
   *
   * The Worker reads this rather than hardcoding a variable list, so a template edited in the database
   * cannot drift from what the renderer thinks it needs.
   */
  readonly variables: readonly string[];
}

/** A rendered notification, ready for FCM. */
export interface RenderedNotification {
  readonly title: string;
  readonly body: string;
  /** Every placeholder the title or body named, whether or not a value was found. */
  readonly required_variables: readonly string[];
  /** Placeholders that no source filled. Must be empty for a send to be attempted. */
  readonly missing_variables: readonly string[];
}

/** The result of one collapsed notification's send attempt, across every device it targeted. */
export interface SendOutcome {
  readonly event_ids: readonly bigint[];
  /**
   * True only when EVERY targeted device accepted the message.
   *
   * The collapsed group is marked delivered as a unit, so a single failure keeps the whole group open and
   * it is retried. That means one stale token re-sends to devices that already succeeded - the alternative
   * is per-event marking, which `mark_events_delivered_v1` does not offer and which would let a partial
   * success close events whose notification never arrived.
   */
  readonly ok: boolean;
  /** FCM's error string, or a short reason. Written to `events.last_error`. */
  readonly error?: string;
}

/** What `mark_events_delivered_v1` returns. */
export interface MarkResult {
  readonly marked: number;
  readonly still_open: number;
}