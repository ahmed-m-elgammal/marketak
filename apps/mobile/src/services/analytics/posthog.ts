/**
 * Product analytics and error reporting. The only PostHog boundary.
 *
 * Never send: email, phone, address, name, tokens, `AppError.cause` (the raw PostgREST payload can
 * echo submitted values), or the Arabic message the database writes for humans. Identify by the
 * Supabase user id alone — a uuid that ties events to one history and says nothing about them.
 */

import PostHog, { type PostHog as PostHogClient } from "posthog-react-native";
import { env } from "@/config/env";
import { AppError } from "@/services/errors/app-error";

/** Flat and low-cardinality. Nested payloads are how a dashboard gets ten thousand series. */
export type EventProps = Readonly<Record<string, string | number | boolean>>;

export type FunnelEvent =
  | "sign_in_started"
  | "profile_completed"
  | "item_added"
  | "quote_shown"
  | "order_placed";

/** Null when analytics is unconfigured, so capture no-ops rather than crashing at boot. */
const client: PostHogClient | null =
  env.posthogKey === null
    ? null
    : new PostHog(env.posthogKey, {
        host: env.posthogHost,
        flushAt: 20,
        flushInterval: 5000,
        // 'memory' loses the queue whenever the process is killed, which is most background
        // terminations on iOS.
        persistence: "file",
      });

export const analyticsEnabled: boolean = client !== null;

/** Autocapture is disabled in the provider, so nothing is sent without an explicit capture. */
export function identify(userId: string): void {
  client?.identify(userId);
}

/** Without this, the next shopper on a shared device inherits the previous one's events. */
export function resetIdentity(): void {
  client?.reset();
}

export function capture(event: string, props: EventProps = {}): void {
  client?.capture(event, props);
}

export function funnel(event: FunnelEvent, props: EventProps = {}): void {
  client?.capture(event, { ...props, $current_url: event });
}

/**
 * Reports a failure with only what is safe to leave the device. `code` is the most useful field in
 * the whole report: it names the business rule that stopped the shopper. The message is dropped
 * because the database writes Arabic copy for a human, and it can embed a submitted value.
 */
export function reportError(context: string, error: unknown): void {
  const app = error instanceof AppError ? error : null;

  client?.captureException?.(error instanceof Error ? error : new Error(String(error)), {
    context,
    code: app?.code ?? null,
    kind: app?.kind ?? "unknown",
    retryable: app?.retryable ?? false,
    requiresSignIn: app?.requiresSignIn ?? false,
  });
}

/** Called on background. A failed flush is not actionable — the queue is persisted and retried. */
export function flush(): void {
  void client?.flush().catch(() => undefined);
}

/** For the debug screen and tests. Not part of the feature-facing API. */
export function rawClient(): PostHogClient | null {
  return client;
}