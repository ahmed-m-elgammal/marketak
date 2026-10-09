/**
 * Analytics and error reporting. The public surface.
 *
 * A feature imports from here, never from `@/services/analytics/posthog` directly, so the
 * redaction rules in that file cannot be bypassed by reaching past the barrel.
 */

export {
  analyticsEnabled,
  capture,
  flush,
  funnel,
  identify,
  rawClient,
  reportError,
  resetIdentity,
} from "@/services/analytics/posthog";

export type { EventProps } from "@/services/analytics/posthog";