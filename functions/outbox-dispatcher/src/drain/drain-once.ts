/**
 * `drain/drain-once` - the whole pipeline, once.
 *
 * ## The order, and why each step is where it is
 *
 * ```
 * claim a batch           one collapsed row per (recipient, template, order)
 *   for each row:
 *     fetch the template    one round trip, keyed on key + lang + channel
 *     render it             variables + template -> text, refusing an unfilled placeholder
 *     fetch the tokens      one round trip per addressee
 *     send                  one request per device
 *     fold to one outcome   ALL devices must succeed
 *   mark the batch          one call, closing exactly the successful groups
 * ```
 *
 * ## One mark call, not one per notification
 *
 * `mark_events_delivered_v1` is documented as "one call per batch, never per event", and calling it once
 * for the whole batch turns N round trips into one. It also means a database failure in the middle cannot
 * leave the batch half-closed, because there is only one place it can fail.
 *
 * ## Rendering before sending, never during
 *
 * A notification whose template has an unfilled placeholder is marked FAILED, not sent. It is not silently
 * skipped, because a skipped notification is indistinguishable from a lost one, and the events staying open
 * means the section 11 backlog alarm counts it.
 */

import {
  isSendable,
  renderTemplate,
  type ClaimedNotification,
  type SendOutcome,
} from "@marketak/shared";

import type { Env } from "../config/env.js";
import {
  ErrorCode,
  describeError,
  log,
  newRunId,
  type ErrorCodeValue,
  type Severity,
} from "../config/logger.js";
import { SupabaseClient, type NotificationSource } from "../database/supabase.js";
import { FcmClient, type DeviceResult, type NotificationSender } from "../messaging/fcm-client.js";

/** Per-notification detail, so a failure names the notification instead of only the batch. */
export interface NotificationReport {
  readonly template_key: string;
  readonly recipient: string;
  readonly order_id: string;
  readonly event_ids: readonly string[];
  readonly devices_targeted: number;
  readonly devices_ok: number;
  readonly sent: boolean;
  /** Stable code for filtering. See `ErrorCode`. */
  readonly code?: ErrorCodeValue;
  /** Free text for `events.last_error` and the admin console. */
  readonly error?: string;
  /** The rendered text, only in `log` mode. Useful, and a data-minimisation cost, so it is opt-in. */
  readonly preview?: string;
}

export interface DrainReport {
  readonly dry_run: Env["dryRun"];
  readonly claimed: number;
  readonly sent: number;
  readonly failed: number;
  /** Notifications refused before any send, because a placeholder had no value. */
  readonly unrenderable: number;
  readonly marked: number;
  readonly still_open: number;
  readonly duration_ms: number;
  readonly notifications: readonly NotificationReport[];
  /** Anything thrown by an individual step. The batch continues; these are reported, not swallowed. */
  readonly errors: readonly string[];
}

/**
 * A group outcome plus the code that explains it.
 *
 * `code` is deliberately NOT on the shared `SendOutcome`: that type is the payload for
 * `mark_events_delivered_v1`, and a logging concern must not leak into a database contract. This local type
 * extends it, and is assignable to `SendOutcome` everywhere the mark call needs it.
 */
interface GroupOutcome extends SendOutcome {
  readonly code?: ErrorCodeValue;
}

/**
 * True for failures that are expected to recur and that an operator should not be paged for.
 *
 * `FCM_TOKEN_DEAD` is the stale-token case Phase 4 removes on sign-out; until then it will recur on every
 * tick for any customer who has ever reinstalled. `NO_DEVICE_TOKEN` means the recipient has never registered
 * a device, which is the normal state for staff accounts and for any account that completed a web order.
 *
 * Everything else - bad credentials, a throttle, an unfilled placeholder, a failed mark - is `error`, because
 * each one means something is actually broken.
 */
function isExpectedNoise(code: ErrorCodeValue): boolean {
  return code === ErrorCode.FCM_TOKEN_DEAD || code === ErrorCode.NO_DEVICE_TOKEN;
}

/**
 * Folds several device results into one group outcome.
 *
 * ALL devices must succeed. `mark_events_delivered_v1` closes the collapsed group as a unit, so marking on a
 * partial success would close events whose notification never arrived. The cost is that one dead token
 * re-sends to the devices that already got it - which is at-least-once, and the same choice the plan made
 * when it chose at-least-once for the drain as a whole.
 */
function foldDeviceResults(
  eventIds: readonly bigint[],
  results: readonly DeviceResult[],
): GroupOutcome {
  if (results.length === 0) {
    // No device to send to is NOT a success. The customer has a token registered or they would not be the
    // recipient, and marking this delivered would quietly swallow the notification.
    return {
      event_ids: eventIds,
      ok: false,
      code: ErrorCode.NO_DEVICE_TOKEN,
      error: "no active device token for this recipient",
    };
  }

  const failures = results.filter((result) => !result.ok);
  if (failures.length === 0) {
    return { event_ids: eventIds, ok: true, code: ErrorCode.DELIVERED };
  }

  // Every failure, not just the first: `events.last_error` is a single text column and the log line is the
  // only place all of them will ever be visible.
  const reasons = failures.map((failure) => failure.error ?? "unknown").join("; ");
  // The first failure's code decides the severity of the group's log line. Ordering is deliberate: the
  // first device is the one an operator most often has to act on, and a mixed set is still fully described by
  // `reasons` in the message.
  const code = failures[0]?.code ?? ErrorCode.FCM_REJECTED;
  return { event_ids: eventIds, ok: false, code, error: reasons.slice(0, 500) };
}

/**
 * Renders, sends and marks one batch.
 *
 * Never throws. A Worker that throws is retried by Cloudflare with the whole batch, and the events are
 * still open, so a throw is not catastrophic - but it loses the report, and the report is how anyone finds
 * out the drain is broken. Failures are collected in `errors` and returned.
 */
export async function drainOnce(
  env: Env,
  dependencies?: {
    readonly supabase?: NotificationSource;
    readonly fcm?: NotificationSender;
  },
): Promise<DrainReport> {
  const startedAt = Date.now();
  // One id per invocation. Every log line this run emits carries it, so a single drain's lines can be
  // grouped even when several ticks overlap or a manual call interleaves with a cron one.
  const runId = newRunId();
  const errors: string[] = [];
  const notifications: NotificationReport[] = [];

  const supabase =
    dependencies?.supabase ??
    new SupabaseClient({
      baseUrl: env.supabaseUrl,
      serviceRoleKey: env.supabaseServiceRoleKey,
    });
  const fcm =
    dependencies?.fcm ??
    new FcmClient({ projectId: env.fcm.projectId, signingKey: env.fcm });

  let claims: readonly ClaimedNotification[];
  try {
    claims = await supabase.claimEvents(env.batchSize);
  } catch (error) {
    const reason = describeError(error);
    errors.push(`claim: ${reason}`);
    log({
      severity: "error",
      code: ErrorCode.DB_CLAIM_FAILED,
      message: reason,
      drain_run_id: runId,
      elapsed_ms: Date.now() - startedAt,
    });
    return {
      dry_run: env.dryRun,
      claimed: 0,
      sent: 0,
      failed: 0,
      unrenderable: 0,
      marked: 0,
      still_open: 0,
      duration_ms: Date.now() - startedAt,
      notifications,
      errors,
    };
  }

  if (claims.length === 0) {
    // Nothing to do is the common case, and the fastest path in the whole Worker. Returning early avoids
    // a pointless mark call and keeps the 60-second tick cheap.
    return {
      dry_run: env.dryRun,
      claimed: 0,
      sent: 0,
      failed: 0,
      unrenderable: 0,
      marked: 0,
      still_open: 0,
      duration_ms: Date.now() - startedAt,
      notifications,
      errors,
    };
  }

  const outcomes: GroupOutcome[] = [];
  let sent = 0;
  let failed = 0;
  let unrenderable = 0;

  // Sequential, not parallel. A batch is at most 50 notifications and the tick is 60 seconds, so
  // concurrency buys nothing measurable and costs rate-limit headroom plus a harder failure mode when one
  // device hangs. If this ever becomes the bottleneck, the fix is a queue, not `Promise.all`.
  for (const claim of claims) {
    const eventIds = [...claim.event_ids];
    const ids = eventIds.map((id) => id.toString());
    // Advances through the steps below so the catch can name the one that threw. Defaulted rather than
    // declared undefined so a throw from the spread or the map above cannot produce "unknown".
    let stage = "get_template";

    try {
      const template = await supabase.getTemplate(claim.template_key, claim.language);
      if (template === null) {
        // The claim already filters on an active template, so reaching here means the row was deactivated
        // between the two calls. Failing the group is right: it keeps the events countable by the backlog
        // alarm rather than dropping them silently.
        unrenderable += 1;
        outcomes.push({
          event_ids: eventIds,
          ok: false,
          error: "template missing or inactive",
        });
        log({
          severity: "error",
          code: ErrorCode.TEMPLATE_MISSING,
          message:
            "the template was deactivated between the claim and the fetch, so the group stays open for the backlog alarm",
          drain_run_id: runId,
          template_key: claim.template_key,
          recipient: claim.recipient,
          order_id: claim.order_id,
          event_count: eventIds.length,
        });
        notifications.push({
          template_key: claim.template_key,
          recipient: claim.recipient,
          order_id: claim.order_id,
          event_ids: ids,
          devices_targeted: 0,
          devices_ok: 0,
          sent: false,
          code: ErrorCode.TEMPLATE_MISSING,
          error: "template missing or inactive",
        });
        continue;
      }

      const rendered = renderTemplate(template, claim);
      if (!isSendable(rendered)) {
        unrenderable += 1;
        const reason = `unfilled placeholder(s): ${rendered.missing_variables.join(", ")}`;
        outcomes.push({ event_ids: eventIds, ok: false, error: reason });
        log({
          severity: "error",
          code: ErrorCode.RENDER_UNFILLED,
          message: `${reason}. Sending would have delivered a literal {placeholder} to a customer.`,
          drain_run_id: runId,
          template_key: claim.template_key,
          recipient: claim.recipient,
          order_id: claim.order_id,
          event_count: eventIds.length,
        });
        notifications.push({
          template_key: claim.template_key,
          recipient: claim.recipient,
          order_id: claim.order_id,
          event_ids: ids,
          devices_targeted: 0,
          devices_ok: 0,
          sent: false,
          code: ErrorCode.RENDER_UNFILLED,
          error: reason,
        });
        continue;
      }

      stage = "get_device_tokens";
      const devices = await supabase.getDeviceTokens(claim.recipient_id);
      const results: DeviceResult[] = [];

      if (env.dryRun === "send") {
        stage = "fcm_send";
        for (const device of devices) {
          results.push(
            await fcm.sendToDevice(device, rendered, {
              templateKey: claim.template_key,
              orderId: claim.order_id,
              orderNumber: claim.order_number,
              recipient: claim.recipient,
              language: claim.language,
            }),
          );
        }
      } else {
        // `log` mode walks the same loop so the report shape, the device count and the folding logic are
        // identical to a real send. The only difference is that no HTTP request leaves the isolate.
        for (const device of devices) {
          results.push({ token: device.token, ok: true });
        }
      }

      const outcome = foldDeviceResults(eventIds, results);
      outcomes.push(outcome);
      const devicesOk = results.filter((result) => result.ok).length;

      if (outcome.ok) {
        sent += 1;
        // INFO, not warn. A successful send is the expected case, and logging it louder makes the error
        // stream useless.
        log({
          severity: "info",
          code: ErrorCode.DELIVERED,
          message: env.dryRun === "log" ? "rendered, not sent (DRY_RUN=log)" : "accepted by FCM",
          drain_run_id: runId,
          template_key: claim.template_key,
          recipient: claim.recipient,
          order_id: claim.order_id,
          event_count: eventIds.length,
        });
      } else {
        failed += 1;
        // WARN, not ERROR, for the two failures that are part of normal operation and self-heal: a token
        // FCM has declared dead, and a recipient with no registered device. An operator woken by those
        // every tick would stop reading the stream, which costs more than the alarm is worth.
        const code = outcome.code ?? ErrorCode.FCM_REJECTED;
        const severity: Severity = isExpectedNoise(code) ? "warn" : "error";
        log({
          severity,
          code,
          message: outcome.error ?? "send failed",
          drain_run_id: runId,
          template_key: claim.template_key,
          recipient: claim.recipient,
          order_id: claim.order_id,
          event_count: eventIds.length,
        });
      }

      notifications.push({
        template_key: claim.template_key,
        recipient: claim.recipient,
        order_id: claim.order_id,
        event_ids: ids,
        devices_targeted: results.length,
        devices_ok: devicesOk,
        sent: outcome.ok,
        ...(outcome.code === undefined ? {} : { code: outcome.code }),
        ...(outcome.error === undefined ? {} : { error: outcome.error }),
        ...(env.dryRun === "log"
          ? { preview: `${rendered.title} | ${rendered.body}` }
          : {}),
      });
    } catch (error) {
      // One notification's failure must not abandon the rest of the batch. `stage` is what makes this line
      // actionable: the same catch guards the template fetch and the token fetch, and "request failed" alone
      // does not say which of them did.
      const reason = describeError(error);
      errors.push(`${claim.template_key} (${claim.recipient}): ${stage}: ${reason}`);
      outcomes.push({
        event_ids: eventIds,
        ok: false,
        code: stage === "get_template" ? ErrorCode.DB_TEMPLATE_FAILED : ErrorCode.DB_TOKENS_FAILED,
        error: `${stage}: ${reason}`,
      });
      failed += 1;
      log({
        severity: "error",
        code: stage === "get_template" ? ErrorCode.DB_TEMPLATE_FAILED : ErrorCode.DB_TOKENS_FAILED,
        message: `${stage}: ${reason}`,
        drain_run_id: runId,
        template_key: claim.template_key,
        recipient: claim.recipient,
        order_id: claim.order_id,
        event_count: eventIds.length,
      });
      notifications.push({
        template_key: claim.template_key,
        recipient: claim.recipient,
        order_id: claim.order_id,
        event_ids: ids,
        devices_targeted: 0,
        devices_ok: 0,
        sent: false,
        // The stage decides the code, so a template-fetch failure and a token-fetch failure stay
        // distinguishable in the report as well as in the log.
        code: stage === "get_template" ? ErrorCode.DB_TEMPLATE_FAILED : ErrorCode.DB_TOKENS_FAILED,
        error: `${stage}: ${reason}`,
      });
    }
  }

  let marked = 0;
  let stillOpen = 0;
  try {
    const result = await supabase.markDelivered(outcomes);
    marked = result.marked;
    stillOpen = result.still_open;
  } catch (error) {
    // The events stay open, so the next tick retries the whole batch. That is the intended failure mode,
    // and it is why nothing is marked optimistically before the send.
    const reason = describeError(error);
    errors.push(`mark: ${reason}`);
    log({
      severity: "error",
      code: ErrorCode.DB_MARK_FAILED,
      message: `${reason}. Every event in this batch stays open and the whole batch is retried.`,
      drain_run_id: runId,
      elapsed_ms: Date.now() - startedAt,
    });
  }

  return {
    dry_run: env.dryRun,
    claimed: claims.length,
    sent,
    failed,
    unrenderable,
    marked,
    still_open: stillOpen,
    duration_ms: Date.now() - startedAt,
    notifications,
    errors,
  };
}