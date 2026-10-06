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
): SendOutcome {
  if (results.length === 0) {
    // No device to send to is NOT a success. The customer has a token registered or they would not be the
    // recipient, and marking this delivered would quietly swallow the notification.
    return { event_ids: eventIds, ok: false, error: "no active device token for this recipient" };
  }

  const failures = results.filter((result) => !result.ok);
  if (failures.length === 0) {
    return { event_ids: eventIds, ok: true };
  }

  // Every failure, not just the first: `events.last_error` is a single text column and the log line is the
  // only place all of them will ever be visible.
  const reasons = failures.map((failure) => failure.error ?? "unknown").join("; ");
  return { event_ids: eventIds, ok: false, error: reasons.slice(0, 500) };
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
    errors.push(`claim: ${error instanceof Error ? error.message : String(error)}`);
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

  const outcomes: SendOutcome[] = [];
  let sent = 0;
  let failed = 0;
  let unrenderable = 0;

  // Sequential, not parallel. A batch is at most 50 notifications and the tick is 60 seconds, so
  // concurrency buys nothing measurable and costs rate-limit headroom plus a harder failure mode when one
  // device hangs. If this ever becomes the bottleneck, the fix is a queue, not `Promise.all`.
  for (const claim of claims) {
    const eventIds = [...claim.event_ids];
    const ids = eventIds.map((id) => id.toString());

    try {
      const template = await supabase.getTemplate(claim.template_key, claim.language);
      if (template === null) {
        // The claim already filters on an active template, so reaching here means the row was deactivated
        // between the two calls. Failing the group is right: it keeps the events countable by the backlog
        // alarm rather than dropping them silently.
        unrenderable += 1;
        outcomes.push({ event_ids: eventIds, ok: false, error: "template missing or inactive" });
        notifications.push({
          template_key: claim.template_key,
          recipient: claim.recipient,
          order_id: claim.order_id,
          event_ids: ids,
          devices_targeted: 0,
          devices_ok: 0,
          sent: false,
          error: "template missing or inactive",
        });
        continue;
      }

      const rendered = renderTemplate(template, claim);
      if (!isSendable(rendered)) {
        unrenderable += 1;
        const reason = `unfilled placeholder(s): ${rendered.missing_variables.join(", ")}`;
        outcomes.push({ event_ids: eventIds, ok: false, error: reason });
        notifications.push({
          template_key: claim.template_key,
          recipient: claim.recipient,
          order_id: claim.order_id,
          event_ids: ids,
          devices_targeted: 0,
          devices_ok: 0,
          sent: false,
          error: reason,
        });
        continue;
      }

      const devices = await supabase.getDeviceTokens(claim.recipient_id);
      const results: DeviceResult[] = [];

      if (env.dryRun === "send") {
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
      } else {
        failed += 1;
      }

      notifications.push({
        template_key: claim.template_key,
        recipient: claim.recipient,
        order_id: claim.order_id,
        event_ids: ids,
        devices_targeted: results.length,
        devices_ok: devicesOk,
        sent: outcome.ok,
        ...(outcome.error === undefined ? {} : { error: outcome.error }),
        ...(env.dryRun === "log"
          ? { preview: `${rendered.title} | ${rendered.body}` }
          : {}),
      });
    } catch (error) {
      // One notification's failure must not abandon the rest of the batch.
      const reason = error instanceof Error ? error.message : String(error);
      errors.push(`${claim.template_key} (${claim.recipient}): ${reason}`);
      outcomes.push({ event_ids: eventIds, ok: false, error: reason.slice(0, 500) });
      failed += 1;
      notifications.push({
        template_key: claim.template_key,
        recipient: claim.recipient,
        order_id: claim.order_id,
        event_ids: ids,
        devices_targeted: 0,
        devices_ok: 0,
        sent: false,
        error: reason,
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
    errors.push(`mark: ${error instanceof Error ? error.message : String(error)}`);
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