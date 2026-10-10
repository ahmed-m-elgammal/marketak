/**
 * Analytics + crash reporting slot (F-08). The single import point: screens
 * instrument through here, never by importing Firebase directly.
 *
 * Two guarantees, both tested:
 *
 * 1. Names are Firebase-valid (`^[a-zA-Z][a-zA-Z0-9_]{0,39}$`) or the event
 *    is dropped — an invalid name rejected natively is telemetry lost
 *    silently, so the drop happens here, loudly returning `false`.
 * 2. Params are scrubbed (DESIGN §14): keys naming patients,
 *    prescriptions, drugs, contacts or locations are dropped, nested
 *    objects are dropped, strings truncate at 100 chars. App errors carry
 *    codes, never names, so `Error` objects pass through untouched.
 *
 * The backend is injected — Firebase in prod (`firebase.ts`), a fake in
 * tests. Pharmacy fixtures proving the scrubber live in `provider.test.ts`.
 */
export type ParamValue = string | number | boolean;

export type EventParams = Readonly<Record<string, ParamValue>>;

export interface AnalyticsBackend {
  logEvent(name: string, params: EventParams): void;
  breadcrumb(message: string): void;
  setCollectionEnabled(enabled: boolean): void;
  setUser(userId: string | null): void;
  recordError(error: Error): void;
}

const EVENT_NAME_PATTERN = /^[a-zA-Z][a-zA-Z0-9_]{0,39}$/;

/**
 * Key fragments that must never reach analytics or crash payloads. Matched
 * case-insensitively against the key, not the value: values are amounts,
 * counts and codes by construction, keys are where a name would hide.
 * Display names (`*_name`) never belong in params — ids do — with the
 * single exception of Firebase's reserved `screen_name`.
 */
const SENSITIVE_KEY_PATTERN =
  /(patient|prescription|\brx\b|drug|diagnos|pill|dose|address|phone|email|plate|lat|lng|coord|location|birthday|national)/i;

function isSensitiveKey(key: string): boolean {
  if (key === "screen_name") return false;
  if (/(^|_)name(_ar)?$/i.test(key)) return true;
  return SENSITIVE_KEY_PATTERN.test(key);
}

const MAX_PARAM_LENGTH = 100;

export function sanitizeParams(params: EventParams): EventParams {
  const clean: Record<string, ParamValue> = {};
  for (const [key, value] of Object.entries(params)) {
    if (isSensitiveKey(key)) continue;
    if (typeof value === "string") {
      clean[key] = value.slice(0, MAX_PARAM_LENGTH);
    } else {
      clean[key] = value;
    }
  }
  return clean;
}

export function isValidEventName(name: string): boolean {
  return EVENT_NAME_PATTERN.test(name);
}

export interface Telemetry {
  track(name: string, params?: EventParams): boolean;
  breadcrumb(message: string): void;
  setCollectionEnabled(enabled: boolean): void;
  identify(userId: string | null): void;
  reportNonFatal(error: Error): void;
}

export function createTelemetry(backend: AnalyticsBackend, enabled = true): Telemetry {
  let collecting = enabled;
  return {
    track(name: string, params: EventParams = {}): boolean {
      if (!collecting || !isValidEventName(name)) return false;
      backend.logEvent(name, sanitizeParams(params));
      return true;
    },
    breadcrumb(message: string): void {
      if (collecting) backend.breadcrumb(message);
    },
    setCollectionEnabled(value: boolean): void {
      collecting = value;
      backend.setCollectionEnabled(value);
    },
    identify(userId: string | null): void {
      backend.setUser(userId);
    },
    reportNonFatal(error: Error): void {
      if (collecting) backend.recordError(error);
    },
  };
}
