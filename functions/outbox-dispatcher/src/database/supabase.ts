/**
 * `database/supabase` - the PostgREST calls the drain makes, and nothing else.
 *
 * ## Why these go through PostgREST and not a SQL client
 *
 * The RPCs are the ONLY sanctioned writer surface in this schema. `events` has exactly one policy,
 * `events_admin_read`, a SELECT policy gated on `private.is_admin()`, and **no INSERT or UPDATE policy at
 * all**. So the drain cannot write to `events` directly even with a service-role key - it must call
 * `mark_events_delivered_v1`, which is `security definer` and granted to `service_role` only.
 *
 * That is not a limitation to work around. It is the reason a client holding the publishable key cannot
 * suppress notifications, and it is asserted from `pg_proc` on every migration that touches these
 * functions.
 *
 * ## The key never appears in a URL
 *
 * The service-role key travels in the `apikey` and `Authorization` headers. It must never be a query
 * string parameter: URLs land in access logs, in Cloudflare's request logs, and in any error message that
 * echoes the request line.
 */

import type {
  ClaimedNotification,
  MarkResult,
  SendOutcome,
  TemplateRow,
  Language,
  DeviceTokenRow,
} from "@marketak/shared";

/** The rows the drain needs from `notification_templates`, in one round trip. */
const TEMPLATE_SELECT =
  "key,lang,title,body,variables";

/** `device_tokens` for one addressee. `is_active` is not a column; the table has `deleted_at`. */
const TOKEN_SELECT = "id,token,platform,app_role,language";

export interface SupabaseClientOptions {
  readonly baseUrl: string;
  readonly serviceRoleKey: string;
}

export interface PostgrestError {
  readonly message: string;
  readonly code?: string;
  readonly details?: string;
  readonly hint?: string;
}

/** Every PostgREST error body has this shape. */
interface PostgrestErrorBody {
  readonly message?: unknown;
  readonly code?: unknown;
  readonly details?: unknown;
  readonly hint?: unknown;
}

function isErrorBody(value: unknown): value is PostgrestErrorBody {
  return typeof value === "object" && value !== null && "message" in value;
}

/**
 * A JSON integer in the raw text: optional sign, digits, and NOT a fractional or exponent part.
 *
 * The trailing lookahead is what keeps `1.5` and `1e10` intact. Without it the match would take the `1` out
 * of both and leave `"…":.5`, which is not JSON.
 */
async function unwrap<T>(
  response: Response,
  operation: string,
  parse: (text: string) => unknown = JSON.parse,
): Promise<T> {
  const text = await response.text();
  let body: unknown;
  try {
    body = text.length > 0 ? parse(text) : null;
  } catch {
    throw new Error(`${operation}: response was not JSON (${String(response.status)}): ${text.slice(0, 200)}`);
  }

  if (!response.ok) {
    if (isErrorBody(body)) {
      const code = typeof body.code === "string" ? body.code : undefined;
      const hint = typeof body.hint === "string" ? body.hint : undefined;
      throw new Error(
        `${operation} failed: ${String(response.status)}` +
          `${code === undefined ? "" : ` ${code}`}` +
          `${typeof body.message === "string" ? ` - ${body.message}` : ""}` +
          `${hint === undefined ? "" : ` (${hint})`}`,
      );
    }
    throw new Error(`${operation} failed: ${String(response.status)}`);
  }

  return body as T;
}

/**
 * Reads `event_ids` into BigInts, refusing any value a double cannot represent exactly.
 *
 * WHY A GUARD AND NOT A BIGGER PARSER. `JSON.parse` turns every number into a double, and a double is
 * lossy past 2^53 -1. Measured: `JSON.parse("9007199254740993")` is `9007199254740992`, permanently one
 * off, and no cast downstream can recover a digit the parser has already dropped.
 *
 * A character-level JSON rewriter that quotes integers before parsing was written for this and DELETED. It
 * corrupted `"1.5"` and mis-matched on sliced input, and a bespoke JSON parser is a large amount of
 * attack surface to protect a case that will not arise for many years: `events.id` is `bigserial`, currently
 * around 22 000, and at a sustained 10 000 events per second it would take roughly 28 years to reach 2^53.
 *
 * So the honest behaviour is to REFUSE rather than to guess. An unrepresentable id throws with a message
 * that says why, every event stays open, and the next tick retries. A drain that stops with a clear reason
 * is recoverable; one that quietly marks a group delivered under the wrong ids is not.
 *
 * STRINGS ARE EXACT AND NEED NO GUARD, because `BigInt("9007199254740993")` is lossless. A future PostgREST
 * serialising `bigint` as text therefore works unchanged.
 */
function toEventIds(value: unknown): readonly bigint[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const ids: bigint[] = [];
  for (const entry of value) {
    // `unknown` narrowed before use, rather than letting `Array.isArray` widen it to `any[]` and carrying an
    // `any` into `BigInt`. Both shapes are real: PostgREST sends a `bigint` as a JSON number today.
    if (typeof entry === "string") {
      const trimmed = entry.trim();
      if (trimmed.length > 0 && /^-?\d+$/u.test(trimmed)) {
        ids.push(BigInt(trimmed));
        continue;
      }
      throw new Error(`event_ids contains a non-integer value: "${entry}"`);
    }

    if (typeof entry === "number") {
      if (!Number.isFinite(entry)) {
        throw new Error(`event_ids contains a non-finite value: ${String(entry)}`);
      }
      if (!Number.isSafeInteger(entry)) {
        // The one case that would silently corrupt. Refusing here is the whole point of this function.
        throw new Error(
          `event_ids contains ${String(entry)}, which a double cannot represent exactly. ` +
            "PostgREST must be configured to send bigint as text; see ADR 23.",
        );
      }
      ids.push(BigInt(entry));
      continue;
    }

    throw new Error(`event_ids contains an unexpected ${typeof entry} value`);
  }
  return ids;
}

function toClaimRow(value: unknown): ClaimedNotification | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const row = value as Record<string, unknown>;
  const recipient = row["recipient"];
  if (recipient !== "customer" && recipient !== "vendor" && recipient !== "rider") {
    // A recipient this code has never heard of means the routing table grew a row, and guessing would mean
    // sending to the wrong party. Skip and report rather than coerce.
    return null;
  }

  const variables =
    typeof row["variables"] === "object" && row["variables"] !== null
      ? (row["variables"] as ClaimedNotification["variables"])
      : {};

  return {
    event_ids: toEventIds(row["event_ids"]),
    template_key: typeof row["template_key"] === "string" ? row["template_key"] : "",
    recipient,
    recipient_id: typeof row["recipient_id"] === "string" ? row["recipient_id"] : "",
    order_id: typeof row["order_id"] === "string" ? row["order_id"] : "",
    order_number: typeof row["order_number"] === "string" ? row["order_number"] : "",
    variables,
    language: row["language"] === "ar" ? "ar" : "en",
    oldest_event: typeof row["oldest_event"] === "string" ? row["oldest_event"] : "",
  };
}

function toTemplateRow(value: unknown): TemplateRow | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const row = value as Record<string, unknown>;
  if (typeof row["key"] !== "string" || typeof row["title"] !== "string") {
    return null;
  }
  const declared = Array.isArray(row["variables"])
    ? row["variables"].filter((entry): entry is string => typeof entry === "string")
    : [];
  return {
    key: row["key"],
    lang: row["lang"] === "ar" ? "ar" : "en",
    title: row["title"],
    body: typeof row["body"] === "string" ? row["body"] : "",
    variables: declared,
  };
}

function toDeviceRow(value: unknown): DeviceTokenRow | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const row = value as Record<string, unknown>;
  if (typeof row["token"] !== "string" || row["token"].length === 0) {
    return null;
  }
  const platform = row["platform"] === "ios" ? "ios" : "android";
  return {
    id: typeof row["id"] === "string" ? row["id"] : "",
    token: row["token"],
    platform,
    app_role: typeof row["app_role"] === "string" ? row["app_role"] : "",
    language: typeof row["language"] === "string" ? row["language"] : "en",
  };
}

/**
 * The narrow surface `drainOnce` needs from a database client.
 *
 * Extracted as an interface rather than typing the parameter as `SupabaseClient` because the concrete class
 * holds private `#` fields, and a test double cannot satisfy a type with private members. It also makes the
 * coupling explicit: this is the entire contract between the drain and the database, so adding a method to
 * the real client without adding one here is a compile error rather than a runtime surprise.
 */
export interface NotificationSource {
  claimEvents(batchSize: number): Promise<readonly ClaimedNotification[]>;
  getTemplate(key: string, lang: Language): Promise<TemplateRow | null>;
  getDeviceTokens(userId: string): Promise<readonly DeviceTokenRow[]>;
  markDelivered(outcomes: readonly SendOutcome[]): Promise<MarkResult>;
}

/**
 * A thin PostgREST client for the three RPCs the drain needs.
 *
 * Not a general database client. Every method here is one of the sanctioned surfaces, so adding a method
 * later means asking whether the new call has a policy behind it.
 */
export class SupabaseClient implements NotificationSource {
  readonly #base: string;
  readonly #key: string;

  public constructor(options: SupabaseClientOptions) {
    this.#base = `${options.baseUrl}/rest/v1`;
    this.#key = options.serviceRoleKey;
  }

  #headers(extra?: Record<string, string>): Headers {
    const headers = new Headers({
      apikey: this.#key,
      // The service-role JWT must also be the bearer, or PostgREST runs as `anon`.
      Authorization: `Bearer ${this.#key}`,
      "content-type": "application/json",
    });
    if (extra !== undefined) {
      for (const [name, value] of Object.entries(extra)) {
        headers.set(name, value);
      }
    }
    return headers;
  }

  /**
   * Claims up to `batchSize` collapsed notifications.
   *
   * `service_role` only. A 401 or 403 here means the grant was revoked or the key is wrong, and it must
   * surface loudly: a drain that cannot claim is not an error state the platform can absorb, because the
   * backlog grows silently until the section 11 alarm fires hours later.
   */
  public async claimEvents(batchSize: number): Promise<readonly ClaimedNotification[]> {
    const response = await fetch(`${this.#base}/rpc/claim_events_v1`, {
      method: "POST",
      headers: this.#headers(),
      body: JSON.stringify({ p_limit: batchSize }),
    });

    // `events.id` is a `bigint`, and `JSON.parse` is lossy past 2^53. `toEventIds` REFUSES an unrepresentable
    // id rather than rounding it - see the note on that function for why the fix is a refusal and not a
    // bigger parser.
    const body = await unwrap(response, "claim_events_v1");
    if (!Array.isArray(body)) {
      throw new Error(`claim_events_v1 returned ${typeof body}, expected an array`);
    }
    return body.map(toClaimRow).filter((row): row is ClaimedNotification => row !== null);
  }

  /**
   * Fetches the template for one key in one language.
   *
   * `eq` on `channel` as well as `key`: the same key exists for `push`, `inapp` and `sms`, and returning
   * the wrong channel's body would render an SMS fragment into a push notification.
   */
  public async getTemplate(key: string, lang: Language): Promise<TemplateRow | null> {
    const url =
      `${this.#base}/notification_templates` +
      `?key=eq.${encodeURIComponent(key)}` +
      `&channel=eq.push` +
      `&lang=eq.${lang}` +
      `&is_active=eq.true` +
      `&deleted_at=is.null` +
      `&select=${TEMPLATE_SELECT}`;

    const response = await fetch(url, { headers: this.#headers() });
    const body = await unwrap<unknown>(response, `getTemplate(${key}, ${lang})`);
    if (!Array.isArray(body)) {
      return null;
    }
    const first = toTemplateRow(body[0]);
    return first;
  }

  /**
   * Fetches every token for one addressee.
   *
   * NO `deleted_at` FILTER, because `device_tokens` HAS NO `deleted_at` COLUMN. Verified against
   * `information_schema.columns` on the live project: the nine columns are `id, user_id, token, platform,
   * app_role, app_version, language, last_seen_at, created_at`, and the constraints are the primary key, the
   * global `UNIQUE (token)`, the two CHECKs and the user FK. Nothing else.
   *
   * The first version of this file filtered on `deleted_at is null` anyway, on the assumption that Phase 4
   * would add a soft-delete column. It does not, and the query failed with
   * `42703 column device_tokens.deleted_at does not exist` on the first live drain. A filtered query that
   * cannot run is worse than an unfiltered one: it looks precise.
   *
   * The consequence is real and recorded rather than hidden: a signed-out device's token stays until
   * Phase 4 adds explicit removal, and every drain scans past it. FCM answers `UNREGISTERED` for it, the
   * notification is marked failed, and it is retried - so stale tokens cost quota until P4.2 lands.
   */
  public async getDeviceTokens(userId: string): Promise<readonly DeviceTokenRow[]> {
    const url =
      `${this.#base}/device_tokens` +
      `?user_id=eq.${encodeURIComponent(userId)}` +
      `&select=${TOKEN_SELECT}`;

    const response = await fetch(url, { headers: this.#headers() });
    const body = await unwrap<unknown>(response, `getDeviceTokens(${userId})`);
    if (!Array.isArray(body)) {
      return [];
    }
    return body.map(toDeviceRow).filter((row): row is DeviceTokenRow => row !== null);
  }

  /**
   * Closes the collapsed groups that were sent.
   *
   * `p_result` mirrors `p_ids` positionally: each entry is `{event_id, ok, error?}`, and a failed entry
   * leaves its event `delivered_at IS NULL` with `attempts` incremented and `last_error` written. The
   * function increments `attempts` only for failures, which is what the section 11 backlog alarm depends on.
   */
  public async markDelivered(outcomes: readonly SendOutcome[]): Promise<MarkResult> {
    // `p_ids` is `bigint[]`, so the ids are sent as STRINGS, not numbers.
    //
    // This is not a stylistic choice. `p_ids` is a Postgres `bigint[]` parameter and PostgREST parses the
    // request body with the same JSON machinery as `response.json()`, so a bare JSON number is read as a
    // double. Every id in this system is well inside the safe range today, and the first live drain proved
    // the failure mode anyway: `JSON.stringify` receives the `bigint[]`, cannot represent a BigInt, and the
    // whole call failed with `TypeError: Do not know how to serialize a BigInt` BEFORE any request left the
    // isolate. Not one event was marked, so every notification was retried - at-least-once working exactly
    // as designed, but costing a full round trip to discover.
    //
    // Strings are lossless, and Postgres casts `text` to `bigint` for the array parameter without complaint.
    const ids = outcomes.flatMap((outcome) => [...outcome.event_ids].map((id) => id.toString()));
    if (ids.length === 0) {
      return { marked: 0, still_open: 0 };
    }

    const result = outcomes.flatMap((outcome) =>
      [...outcome.event_ids].map((eventId) => {
        const entry: { event_id: string; ok: boolean; error?: string } = {
          event_id: eventId.toString(),
          ok: outcome.ok,
        };
        if (outcome.ok === false && outcome.error !== undefined) {
          entry.error = outcome.error;
        }
        return entry;
      }),
    );

    const response = await fetch(`${this.#base}/rpc/mark_events_delivered_v1`, {
      method: "POST",
      headers: this.#headers(),
      body: JSON.stringify({ p_ids: ids, p_result: result }),
    });

    const body = await unwrap<unknown>(response, "mark_events_delivered_v1");
    if (typeof body !== "object" || body === null) {
      throw new Error("mark_events_delivered_v1 returned a non-object body");
    }
    const row = body as Record<string, unknown>;
    return {
      marked: typeof row["marked"] === "number" ? row["marked"] : 0,
      still_open: typeof row["still_open"] === "number" ? row["still_open"] : 0,
    };
  }
}
