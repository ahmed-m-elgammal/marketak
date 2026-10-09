/**
 * The outbox Worker's contract.
 *
 * `functions/outbox-dispatcher` is the only consumer of this module, and it lives
 * here rather than in the Worker for one reason: the Worker and the mobile app
 * must agree on what a *rendered notification* is. The app renders a notification
 * centre row and the Worker renders a push body from the same
 * `notification_templates` rows, and if the two disagree about placeholder
 * handling the customer gets `{total}` in a push and `EGP 29.50` in the app.
 *
 * The database side is worth stating precisely, because it is easy to get wrong:
 *
 * - `notification_templates` has **one row per `(key, lang)`**, and `title` and
 *   `body` are `text`. A template is already resolved to a language when it is
 *   read. There is no language object to pick out of.
 * - `notifications` has `title` and `body` as **`jsonb` objects**,
 *   CHECK-constrained to `jsonb_typeof = 'object'` - a stored notification is
 *   `{ "ar": "…", "en": "…" }` and the reader picks their own key.
 *
 * Those are different tables with different shapes for the same words. Which is
 * why the types below are named for the table they come from.
 */

import type { Language } from "./money.js";
import type { AppRole, Platform } from "./status.js";

/* ── `notification_templates` ─────────────────────────────────────────────── */

/**
 * One `notification_templates` row, already scoped to a language by the
 * `(key, lang)` unique constraint. `title` and `body` are `text`, not objects.
 */
export interface TemplateRow {
  readonly key: string;
  readonly lang: Language;
  readonly title: string;
  readonly body: string;
  readonly variables: readonly string[];
}

/** A notification after its placeholders have been substituted. */
export interface RenderedNotification {
  readonly template_key: string;
  readonly lang: Language;
  readonly title: string;
  readonly body: string;
  /**
   * Declared variables that had no value in the claim. A non-empty list means the
   * notification is not sendable: a literal `{total}` in a push is worse than no
   * push, because the customer cannot tell it is broken.
   */
  readonly missing_variables: readonly string[];
}

/**
 * A claimed batch from `claim_events_v1(p_limit)`.
 *
 * `event_ids` is `bigint[]`. PostgREST sends a bigint as a JSON number today,
 * which a double cannot represent exactly, so the Worker parses to `BigInt` and
 * refuses a value outside the safe-integer range rather than corrupting it
 * silently (ADR 23).
 */
export interface ClaimedNotification {
  readonly event_ids: readonly bigint[];
  readonly template_key: string;
  readonly recipient: "customer" | "vendor" | "rider";
  readonly recipient_id: string;
  readonly order_id: string;
  readonly order_number: string;
  readonly variables: Readonly<Record<string, unknown>>;
  readonly language: Language;
  readonly oldest_event: string;
}

/** `mark_events_delivered_v1(p_ids, p_result)`. */
export interface MarkResult {
  readonly marked: number;
  readonly still_open: number;
}

/**
 * One notification's send outcome, folded into the group result.
 *
 * `event_ids` matches `ClaimedNotification.event_ids` because a claim covers every
 * event of one order that collapsed into one notification - marking `event_ids`
 * marks the batch, and marking too few leaves events open that the backlog alarm
 * then counts forever.
 */
export interface SendOutcome {
  readonly event_ids: readonly bigint[];
  readonly ok: boolean;
  readonly error?: string;
}

/* ── `device_tokens` ──────────────────────────────────────────────────────── */

/**
 * One `device_tokens` row as the drain reads it.
 *
 * `language` is per **registration**, not per account: a device registers its
 * language, so push can be sent in the reader's language rather than the
 * account's. That is why the Worker reads this column instead of
 * `users.preferred_language`.
 */
export interface DeviceTokenRow {
  readonly id: string;
  readonly token: string;
  readonly platform: Platform;
  /**
   * Normalised at the parse site to the device's real role. `device_tokens.app_role`
   * is a `text` column with a CHECK on `customer|rider|admin`, but the drain reads
   * it as free text, so an unexpected value would otherwise flow through as a
   * string the caller then has to check again.
   */
  readonly app_role: AppRole | "unknown";
  readonly language: Language;
}

/* ── rendering ────────────────────────────────────────────────────────────── */

/** `{name}`, matching the placeholder form the templates use. */
const PLACEHOLDER = /\{([a-z_][a-z0-9_]*)\}/giu;

/** Formats a substituted value. Numbers are localised; everything else is coerced. */
function renderValue(value: unknown, lang: Language): string {
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return "";
    return new Intl.NumberFormat(lang === "ar" ? "ar-EG-u-nu-arab" : "en-EG", {
      numberingSystem: lang === "ar" ? "arab" : "latn",
    }).format(value);
  }
  if (typeof value === "string") return value;
  if (typeof value === "boolean") return value ? "1" : "0";
  if (typeof value === "bigint") return value.toString();
  // `null` and `undefined` never reach here - the caller records them as missing.
  // Anything else is a structure, and JSON is the only lossless text form for it.
  return JSON.stringify(value) ?? "";
}

/**
 * Substitutes a template's declared placeholders with the claim's variables.
 *
 * Only the variables the template **declares** are substituted. A template that
 * declares no variables but whose body contains `{something}` is left alone rather
 * than having the literal silently dropped, because that is a template bug and it
 * should show up as `missing_variables` instead of vanishing into a push that
 * reads as if it were finished.
 */
export function renderTemplate(
  template: TemplateRow,
  claim: ClaimedNotification,
): RenderedNotification {
  const missing: string[] = [];

  const substitute = (source: string): string =>
    source.replace(PLACEHOLDER, (whole, name: string) => {
      const declared = template.variables.includes(name);
      if (!declared) {
        // Undeclared placeholder: record it once, leave the literal in place.
        if (!missing.includes(name)) missing.push(name);
        return whole;
      }
      const value = claim.variables[name];
      if (value === undefined || value === null || value === "") {
        if (!missing.includes(name)) missing.push(name);
        return whole;
      }
      return renderValue(value, claim.language);
    });

  return {
    template_key: template.key,
    lang: claim.language,
    title: substitute(template.title),
    body: substitute(template.body),
    missing_variables: missing,
  };
}

/** A notification is sendable when nothing is left unfilled. */
export function isSendable(rendered: RenderedNotification): boolean {
  return rendered.missing_variables.length === 0;
}
