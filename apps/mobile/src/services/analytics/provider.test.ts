import { describe, expect, it } from "vitest";
import { createTelemetry, isValidEventName, sanitizeParams, type AnalyticsBackend } from "./provider";

function fakeBackend(): AnalyticsBackend & {
  readonly events: { name: string; params: unknown }[];
  readonly breadcrumbs: string[];
  readonly errors: Error[];
  readonly users: (string | null)[];
  enabled: boolean;
} {
  const backend = {
    events: [] as { name: string; params: unknown }[],
    breadcrumbs: [] as string[],
    errors: [] as Error[],
    users: [] as (string | null)[],
    enabled: true,
    logEvent(name: string, params: unknown): void {
      backend.events.push({ name, params });
    },
    breadcrumb(message: string): void {
      backend.breadcrumbs.push(message);
    },
    setCollectionEnabled(value: boolean): void {
      backend.enabled = value;
    },
    setUser(userId: string | null): void {
      backend.users.push(userId);
    },
    recordError(error: Error): void {
      backend.errors.push(error);
    },
  };
  return backend;
}

describe("event names", () => {
  it("accepts Firebase-valid names and drops the rest loudly", () => {
    expect(isValidEventName("place_attempt")).toBe(true);
    expect(isValidEventName("screen_view")).toBe(true);
    expect(isValidEventName("9lives")).toBe(false);
    expect(isValidEventName("has space")).toBe(false);
    expect(isValidEventName("x".repeat(41))).toBe(false);

    const backend = fakeBackend();
    const telemetry = createTelemetry(backend);
    expect(telemetry.track("place_attempt", { total: 1 })).toBe(true);
    expect(telemetry.track("has space", {})).toBe(false);
    expect(backend.events).toHaveLength(1);
  });
});

describe("param scrubbing (DESIGN §14)", () => {
  it("drops pharmacy, patient, contact and location keys from a realistic payload", () => {
    const payload = sanitizeParams({
      order_id: "o1",
      total: 2500,
      drug_name: "Panadol Extra",
      item_name_ar: "بنادول",
      patient_id: "p9",
      prescription_id: "rx1",
      phone_number: "+201012345678",
      pickup_lat: 30.05,
      sealed: true,
    });
    expect(payload).toEqual({ order_id: "o1", total: 2500, sealed: true });
  });

  it("drops display names but keeps the reserved screen_name", () => {
    expect(sanitizeParams({ screen_name: "Checkout", vendor_name: "X", item_id: "i1" })).toEqual({
      screen_name: "Checkout",
      item_id: "i1",
    });
  });

  it("truncates long strings instead of dropping them", () => {
    const payload = sanitizeParams({ reason: "x".repeat(200) });
    expect(payload["reason"]).toHaveLength(100);
  });

  it("keeps numbers and booleans byte-identical", () => {
    expect(sanitizeParams({ count: 3, first: true })).toEqual({ count: 3, first: true });
  });
});

describe("telemetry gate", () => {
  it("stays silent when collection is off, including breadcrumbs and errors", () => {
    const backend = fakeBackend();
    const telemetry = createTelemetry(backend, false);
    expect(telemetry.track("place_attempt", {})).toBe(false);
    telemetry.breadcrumb("checkout opened");
    telemetry.reportNonFatal(new Error("boom"));
    expect(backend.events).toHaveLength(0);
    expect(backend.breadcrumbs).toHaveLength(0);
    expect(backend.errors).toHaveLength(0);
  });

  it("passes errors through — app errors carry codes, never names", () => {
    const backend = fakeBackend();
    const telemetry = createTelemetry(backend);
    const failure = new Error("ITEM_UNAVAILABLE: الصنف غير متاح");
    telemetry.reportNonFatal(failure);
    expect(backend.errors).toEqual([failure]);
  });

  it("identifies on sign-in and clears Analytics identity on sign-out", () => {
    const backend = fakeBackend();
    const telemetry = createTelemetry(backend);
    telemetry.identify("u1");
    telemetry.identify(null);
    expect(backend.users).toEqual(["u1", null]);
  });

  it("forwards the collection flag to the backend", () => {
    const backend = fakeBackend();
    const telemetry = createTelemetry(backend);
    telemetry.setCollectionEnabled(false);
    expect(backend.enabled).toBe(false);
    expect(telemetry.track("place_attempt", {})).toBe(false);
  });
});
