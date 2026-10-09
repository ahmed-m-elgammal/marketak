/**
 * Product analytics and error reporting. The only PostHog boundary in the app.
 *
 * Dependency-cruiser keeps `@supabase/supabase-js` inside `src/services/`, and this module sits
 * beside it for the same reason: one place that decides what leaves the device.
 *
 * ## What is never sent
 *
 * | Never | Why |
 * |---|---|
 * | email, phone, address, name | personal data. A report is not a place to put it |
 * | access or refresh token | a leaked `phc_` key is bad enough; a leaked JWT is a hijack |
 * | `AppError.cause` | holds the raw PostgREST payload, which may echo submitted values |
 * | full option lists, quantities | high-cardinality, low insight, and can identify a basket |
 *
 * The user is identified by the Supabase user id only. That is a random uuid: it ties events to
 * one person's history without carrying anything about them.
 *
 * ## Autocapture is off
 *
 * This SDK version takes autocapture as a `PostHogProvider` prop, not a client option, so it is
 * set in `analytics-provider.tsx` rather than here. It is disabled because nothing should be
 * recorded without an explicit `capture` call: until someone has chosen which events matter, an
 * autocaptured stream is noise that costs quota and hides the handful that do.
 *
 * `captureAppLifecycleEvents` is left at its default `true`. App-opened and app-backgrounded are
 * not autocapture — they are the two events that explain every drop-off in an MVP, and they carry
 * no personal data.
 */

import PostHog, { type PostHog as PostHogClient } from "posthog-react-native";
import { env } from "@/config/env";
import { AppError } from "@/services/errors/app-error";

/**
 * A flat, low-cardinality event. Values are `string | number | boolean` — never an object or an
 * array, because a nested payload is how a dashboard ends up with ten thousand series.
 */
export type EventProps = Readonly<Record<string, string | number | boolean>>;

/**
 * PostHog's own client, or null when analytics is not configured.
 *
 * Every export below no-ops on null. That is deliberate: a screen should not need to know whether
 * analytics is switched on, and an unconfigured build must not crash at boot.
 */
const client: PostHogClient | null =
  env.posthogKey === null
    ? null
    : new PostHog(env.posthogKey, {
        host: env.posthogHost,
        // Offline batching: the queue flushes on reconnect instead of dropping events.
        flushAt: 20,
        flushInterval: 5000,
        // 'file' lets PostHog pick the best available storage via its optional peers — we
        // installed both @react-native-async-storage and expo-file-system. 'memory' would lose
        // the queue whenever the process is killed, which is most background terminations.
        persistence: "file",
      });

/** True when events are actually being sent. Useful in tests and a debug screen. */
export const analyticsEnabled: boolean = client !== null;

/** Identifies the shopper by opaque id. Call on sign-in, and `reset()` on sign-out. */
export function identify(userId: string): void {
  client?.identify(userId);
}

/** Clears the identity on sign-out. Without this the next shopper inherits the previous events. */
export function resetIdentity(): void {
  client?.reset();
}

/** Records a product event. No-ops when analytics is off. */
export function capture(event: string, props: EventProps = {}): void {
  client?.capture(event, props);
}

/**
 * Records an event that marks a funnel step.
 *
 * Separate from `capture` because funnel ordering is a query concern: once the funnel is named
 * here, dashboards and PostHog both know the sequence without hard-coding it in a report.
 */
export function funnel(event: "sign_in_started" | "profile_completed" | "item_added" | "quote_shown" | "order_placed", props: EventProps = {}): void {
  client?.capture(event, { ...props, $current_url: event });
}

/**
 * Reports a failure, keeping only the fields that are safe to leave the device.
 *
 * `code` is the Postgres error code — `PRICE_CHANGED`, `ITEM_RETIRED` — which is the single most
 * useful thing in a report, because it says exactly which business rule stopped the shopper.
 * `message` is deliberately dropped: the database writes Arabic text for a human, and it can
 * embed a submitted value. `cause` is never attached, for the same reason.
 */
export function reportError(context: string, error: unknown): void {
  const app = error instanceof AppError ? error : null;

  client?.captureException?.(error instanceof Error ? error : new Error(String(error)), {
    context,
    code: app?.code ?? null,
    kind: app?.kind ?? "unknown",
    // Whether a retry could plausibly work. Not the stack: the remote SDK reads it from the
    // thrown Error, and shipping our own copy duplicates it.
    retryable: app?.retryable ?? false,
    requiresSignIn: app?.requiresSignIn ?? false,
  });
}

/**
 * Flushes immediately. Called when the app backgrounds, so queued events are not lost.
 *
 * Fire-and-forget by design: this runs from an AppState listener, and there is nowhere to await
 * to. A failed flush is not actionable — the queue is persisted to disk and retried on next
 * launch — so the rejection is swallowed rather than surfaced as an unhandled promise.
 */
export function flush(): void {
  void client?.flush().catch(() => undefined);
}

/** Exposed for the debug screen and for tests. Not part of the feature-facing API. */
export function rawClient(): PostHogClient | null {
  return client;
}