/**
 * `outbox-dispatcher` - the Worker entry point.
 *
 * ## Trigger
 *
 * A Cloudflare Cron Trigger every 60 seconds. The plan asked for 15 seconds, and this is a recorded
 * deviation rather than a silent change: **Cloudflare cron triggers have a one-minute floor**, so the plan's
 * 15 s route had to be `pg_cron` plus `pg_net`, a second scheduler and a new extension for a latency nobody
 * asked for. `pg_net` is deliberately NOT installed. See the ADR.
 *
 * `scheduled` and an optional `POST /drain` share one handler, so the drain can be invoked by hand during
 * development without waiting for a tick. The manual route requires `x-drain-token`, because a Worker with
 * the service-role key reachable by anyone on the internet is a way to send arbitrary notifications to
 * every user of the platform.
 */

import type { DrainReport } from "./drain/drain-once.js";
import { drainOnce } from "./drain/drain-once.js";
import { ConfigError, readEnv } from "./config/env.js";

export interface ScheduledEvent {
  readonly scheduledTime: number;
  readonly cron: string;
}

/** A hand-invoked drain, used during development. `export default` also receives plain `Request`s. */
interface ManualRequest {
  readonly request: Request;
}

/**
 * A bare, honest response for a manual invocation.
 *
 * No secret is echoed. The report contains order ids and rendered message text, which is enough to confirm
 * the drain works and is still more than an unauthenticated caller should see.
 */


/**
 * Serialises a report for a response body.
 *
 * `events.event_ids` is `bigint[]`, and `JSON.stringify` throws `TypeError: Do not know how to serialize a
 * BigInt` on a BigInt - it is one of very few JavaScript values JSON cannot represent at all. The first live
 * drain hit this: the report was correct, and the response was a 500 with an opaque body, because
 * serialisation failed AFTER the work had been done.
 *
 * `DrainReport` keeps `bigint` internally because `events.id` really is `bigint` and coercing it to a number
 * in the data layer would be the wrong place to lose precision. The conversion happens here, at the
 * boundary, where a report becomes JSON.
 */
function serialiseReport(report: DrainReport): string {
  return JSON.stringify(
    report,
    (_key, value: unknown) => (typeof value === "bigint" ? value.toString() : value),
    2,
  );
}

function errorResponse(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function handleScheduled(env: unknown): Promise<Response> {
  let report: DrainReport;
  try {
    const config = readEnv(env as Record<string, string | undefined>);
    report = await drainOnce(config);
  } catch (error) {
    if (error instanceof ConfigError) {
      // A missing secret is an operator problem, not a customer problem. The message names the variable
      // and never its value.
      return errorResponse(500, error.message);
    }
    return errorResponse(500, error instanceof Error ? error.message : String(error));
  }

  // `console.log` rather than a structured logger: Workers Observability picks it up, and the drain's
  // report is the thing an operator reads when the backlog alarm fires. No secret is in it - the report
  // holds order ids and message text, not credentials.
  console.log(
    JSON.stringify({
      event: "drain",
      dry_run: report.dry_run,
      claimed: report.claimed,
      sent: report.sent,
      failed: report.failed,
      unrenderable: report.unrenderable,
      marked: report.marked,
      still_open: report.still_open,
      duration_ms: report.duration_ms,
      errors: report.errors,
    }),
  );

  // A cron invocation's status code is not visible anywhere, so the status is chosen for the manual route
  // and the log is what actually records success or failure on a tick.
  return new Response(serialiseReport(report), {
    status: report.errors.length > 0 ? 500 : 200,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function handleManual(request: Request, env: unknown, token: string | undefined): Promise<Response> {
  if (token === undefined || token.length === 0) {
    return errorResponse(
      503,
      "DRAIN_TOKEN is not set. The manual /drain route is disabled; the cron trigger still works.",
    );
  }

  const supplied = request.headers.get("x-drain-token");
  if (supplied !== token) {
    // 401 rather than 403: the caller has not proved it is allowed, and the distinction tells an attacker
    // the token exists.
    return errorResponse(401, "invalid or missing x-drain-token");
  }

  let config: ReturnType<typeof readEnv>;
  try {
    config = readEnv(env as Record<string, string | undefined>);
  } catch (error) {
    if (error instanceof ConfigError) {
      return errorResponse(500, error.message);
    }
    throw error;
  }

  // A manual drain always runs in `log` mode unless the caller explicitly asks otherwise, because a hand
  // test that silently sent real notifications to real customers is not a test anyone intended.
  const wantsSend = request.headers.get("x-drain-mode") === "send";
  const mode = wantsSend ? config.dryRun : "log";

  const report = await drainOnce({ ...config, dryRun: mode });
  console.log(
    JSON.stringify(
      { event: "drain-manual", mode, ...report },
      (_key, value: unknown) => (typeof value === "bigint" ? value.toString() : value),
    ),
  );
  return new Response(serialiseReport(report), {
    status: report.errors.length > 0 ? 500 : 200,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export default {
  /**
   * Cloudflare's scheduled handler. `env` is the Worker bindings object.
   */
  async scheduled(_controller: ScheduledController, env: unknown): Promise<void> {
    // Returns void because `ExportedHandlerScheduledHandler` requires it, and because the status code of a
    // cron invocation goes nowhere. The report is logged, and Workers Observability keeps it - which is the
    // only place anyone looks when the section 11 backlog alarm fires.
    await handleScheduled(env);
  },

  /**
   * The fetch handler exists for manual invocation only. `GET /health` answers without a secret so a
   * deployment can be checked without holding the token.
   */
  async fetch(request: Request, env: unknown): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ ok: true, service: "outbox-dispatcher" }), {
        headers: { "content-type": "application/json; charset=utf-8" },
      });
    }

    if (url.pathname === "/drain") {
      if (request.method !== "POST") {
        return errorResponse(405, "use POST /drain");
      }
      const bindings = (env ?? {}) as Record<string, string | undefined>;
      return handleManual(request, env, bindings["DRAIN_TOKEN"]);
    }

    return errorResponse(404, "not found");
  },
} satisfies ExportedHandler<unknown>;

export type { DrainReport, ManualRequest };