import type {
  ClaimedNotification,
  DeviceTokenRow,
  Language,
  MarkResult,
  SendOutcome,
  TemplateRow,
} from "@marketak/shared";

import type {
  DeviceResult,
  NotificationSender,
} from "../messaging/fcm-client.js";
import type { NotificationSource } from "../database/supabase.js";

/**
 * `tests/fakes` - hand-written doubles for the drain's dependencies.
 *
 * ## Why these are hand-written and not a mocking library
 *
 * Every fake here records what it was asked, so a test can assert on the SEQUENCE rather than only the
 * result. A mock that returns a canned value cannot prove that `mark` was called after `send` rather than
 * before, and that ordering is the difference between a drain that works and one that loses notifications.
 *
 * The shapes implement the real interfaces, so if the interface changes and a fake stops satisfying it,
 * `tsc` fails. That is the point of typing them rather than returning `any`.
 */

/** Builds a claim row. Every field has a default so a test only states what it cares about. */
export function makeClaim(overrides: Partial<ClaimedNotification> = {}): ClaimedNotification {
  const base: ClaimedNotification = {
    event_ids: [1n],
    template_key: "order.placed",
    recipient: "customer",
    recipient_id: "11111111-1111-1111-1111-111111111111",
    order_id: "22222222-2222-2222-2222-222222222222",
    order_number: "MK-20261005-00000001",
    variables: {
      order_number: "MK-20261005-00000001",
      vendor_count: 1,
      total: 10_000,
      currency: "EGP",
    },
    language: "ar",
    oldest_event: "2026-10-05T10:00:00.000Z",
  };
  return { ...base, ...overrides };
}

export function makeDevice(overrides: Partial<DeviceTokenRow> = {}): DeviceTokenRow {
  const base: DeviceTokenRow = {
    id: "33333333-3333-3333-3333-333333333333",
    token: "ExxxxDeviceToken000000000000000000000000",
    platform: "android",
    app_role: "customer",
    language: "ar",
  };
  return { ...base, ...overrides };
}

/** Ordered log of every dependency call, so a test can assert the pipeline order. */
export type Call =
  | { readonly kind: "claim"; readonly batchSize: number }
  | { readonly kind: "template"; readonly key: string; readonly lang: Language }
  | { readonly kind: "tokens"; readonly userId: string }
  | { readonly kind: "send"; readonly token: string }
  | { readonly kind: "mark"; readonly outcomeCount: number };

export interface FakeSupabaseOptions {
  readonly claims?: readonly ClaimedNotification[];
  /** Keyed `template_key` then language. A missing key yields `null`, which the drain treats as a failure. */
  readonly templates?: Readonly<Record<string, Readonly<Record<string, TemplateRow>>>>;
  readonly devices?: readonly DeviceTokenRow[];
  /** Thrown by `claimEvents`, to test that path. */
  readonly claimError?: Error;
  /** Thrown by `markDelivered`, to test that the batch survives a mark failure. */
  readonly markError?: Error;
}

/**
 * A `NotificationSource` double.
 *
 * Typed as the INTERFACE rather than the concrete `SupabaseClient`, which holds private `#` fields a plain
 * object cannot satisfy. The effect is the same guarantee the interface was extracted for: if the drain
 * starts calling a method this fake does not implement, `tsc` fails.
 */
export class FakeSupabase implements NotificationSource {
  readonly calls: Call[] = [];
  readonly #claims: readonly ClaimedNotification[];
  readonly #templates: Readonly<Record<string, Readonly<Record<string, TemplateRow>>>>;
  readonly #devices: readonly DeviceTokenRow[];
  readonly #claimError: Error | undefined;
  readonly #markError: Error | undefined;

  public constructor(options: FakeSupabaseOptions = {}) {
    this.#claims = options.claims ?? [];
    this.#templates = options.templates ?? {};
    this.#devices = options.devices ?? [];
    this.#claimError = options.claimError;
    this.#markError = options.markError;
  }

  public claimEvents(batchSize: number): Promise<readonly ClaimedNotification[]> {
    this.calls.push({ kind: "claim", batchSize });
    if (this.#claimError !== undefined) {
      return Promise.reject(this.#claimError);
    }
    return Promise.resolve(this.#claims.slice(0, batchSize));
  }

  public getTemplate(key: string, lang: Language): Promise<TemplateRow | null> {
    this.calls.push({ kind: "template", key, lang });
    const byLang = this.#templates[key];
    if (byLang === undefined) {
      return Promise.resolve(null);
    }
    const row = byLang[lang];
    return Promise.resolve(row ?? null);
  }

  public getDeviceTokens(userId: string): Promise<readonly DeviceTokenRow[]> {
    this.calls.push({ kind: "tokens", userId });
    return Promise.resolve(this.#devices);
  }

  public markDelivered(outcomes: readonly SendOutcome[]): Promise<MarkResult> {
    this.calls.push({ kind: "mark", outcomeCount: outcomes.length });
    if (this.#markError !== undefined) {
      return Promise.reject(this.#markError);
    }
    const ids = outcomes.flatMap((outcome) => [...outcome.event_ids]);
    const markedIds = new Set(
      outcomes
        .filter((outcome) => outcome.ok)
        .flatMap((outcome) => [...outcome.event_ids])
        .map((id) => id.toString()),
    );
    return Promise.resolve({
      marked: markedIds.size,
      still_open: ids.length - markedIds.size,
    });
  }
}

export interface FakeFcmOptions {
  /** Per-token results. A token with no entry is treated as a success. */
  readonly results?: Readonly<Record<string, Omit<DeviceResult, "token">>>;
  readonly throwOnSend?: boolean;
}

/** An `FcmClient` double that records each send instead of making one. */
export class FakeFcm implements NotificationSender {
  readonly calls: Call[] = [];
  readonly #results: Readonly<Record<string, Omit<DeviceResult, "token">>>;
  readonly #throwOnSend: boolean;

  public constructor(options: FakeFcmOptions = {}) {
    this.#results = options.results ?? {};
    this.#throwOnSend = options.throwOnSend ?? false;
  }

  public sendToDevice(device: DeviceTokenRow): Promise<DeviceResult> {
    if (this.#throwOnSend) {
      throw new Error("fake fcm: forced send failure");
    }
    this.calls.push({ kind: "send", token: device.token });
    const configured = this.#results[device.token];
    if (configured === undefined) {
      return Promise.resolve({ token: device.token, ok: true });
    }
    return Promise.resolve({ token: device.token, ...configured });
  }
}