/**
 * `messaging/fcm-client` - sending one rendered notification through FCM HTTP v1.
 *
 * ## Endpoint shape
 *
 * `POST https://fcm.googleapis.com/v1/projects/{project_id}/messages:send`
 *
 * with `Authorization: Bearer <access token>`. The legacy `?key=<server_key>` form is dead, which is the
 * reason this module exists rather than a bare `fetch`.
 *
 * ## The three error classes, handled differently
 *
 * | FCM says | Meaning | What happens to the events |
 * |---|---|---|
 * | 200 | delivered to FCM | marked delivered |
 * | 404 / `UNREGISTERED` | the token is dead | marked **failed**, `last_error` records why. The events stay open, so the group is retried and the stale token keeps costing quota until Phase 4 adds sign-out removal. |
 * | 401 / 403 | our token or key is wrong | the access-token cache is cleared so the next invocation re-signs. Marked failed: retrying immediately with the same bad credentials cannot succeed. |
 * | 429 / 5xx | transient | marked failed and retried on the next tick. At-least-once is the intended behaviour for push. |
 *
 * ## One collapsed notification is one HTTP request
 *
 * A collapsed row can target several devices. FCM HTTP v1 has no multicast endpoint - the old
 * `registration_ids` field was removed - so one request per device. The collapse already saved the
 * database work; this is where the network cost lands.
 */

import type { DeviceTokenRow, Language, RenderedNotification } from "@marketak/shared";

import { FCM_SEND_URL } from "../config/env.js";
import { clearTokenCache, getAccessToken, type SigningKey } from "../google/access-token.js";

/**
 * The FCM data payload. Every value must be a STRING.
 *
 * FCM HTTP v1 rejects a non-string value in `data` with `INVALID_ARGUMENT`, and it does so per message,
 * so one numeric `order_id` fails one device's notification while the rest deliver. The mapping is
 * therefore explicit rather than spread.
 */
export interface FcmData {
  readonly template_key: string;
  readonly order_id: string;
  readonly order_number: string;
  readonly recipient: string;
  readonly language: Language;
  readonly title: string;
  readonly body: string;
}

function toFcmData(
  rendered: RenderedNotification,
  meta: {
    readonly templateKey: string;
    readonly orderId: string;
    readonly orderNumber: string;
    readonly recipient: string;
    readonly language: Language;
  },
): FcmData {
  return {
    template_key: meta.templateKey,
    order_id: meta.orderId,
    order_number: meta.orderNumber,
    recipient: meta.recipient,
    language: meta.language,
    // Duplicated into `data` so a notification rendered from a cache, or inspected in a debug tool, carries
    // its own text. `notification` alone is not readable by anything but the OS.
    title: rendered.title,
    body: rendered.body,
  };
}

interface FcmSendResponse {
  readonly name?: unknown;
  readonly error?: unknown;
}

/** The outcome of one device's send, before it is folded into a group outcome. */
export interface DeviceResult {
  readonly token: string;
  readonly ok: boolean;
  readonly error?: string;
}

/** True when an FCM status means "retry later", as opposed to "this will never work". */
function isAuthFailure(status: number): boolean {
  return status === 401 || status === 403;
}

/** True when FCM says the token itself is dead. */
function isDeadToken(status: number, payload: FcmSendResponse): boolean {
  if (status === 404) {
    return true;
  }
  const error = payload.error;
  if (typeof error !== "object" || error === null) {
    return false;
  }
  const statusName = (error as { status?: unknown }).status;
  return statusName === "NOT_FOUND" || statusName === "UNREGISTERED";
}

/**
 * The narrow surface `drainOnce` needs from a sender. See the note on `NotificationSource`: an interface
 * rather than the concrete class, so a test double can satisfy it without implementing private fields.
 */
export interface NotificationSender {
  sendToDevice(
    device: DeviceTokenRow,
    rendered: RenderedNotification,
    meta: {
      readonly templateKey: string;
      readonly orderId: string;
      readonly orderNumber: string;
      readonly recipient: string;
      readonly language: Language;
    },
  ): Promise<DeviceResult>;
}

export interface FcmClientOptions {
  readonly projectId: string;
  readonly signingKey: SigningKey;
}

export class FcmClient implements NotificationSender {
  readonly #endpoint: string;
  readonly #signingKey: SigningKey;

  public constructor(options: FcmClientOptions) {
    this.#endpoint = `${FCM_SEND_URL}/${options.projectId}/messages:send`;
    this.#signingKey = options.signingKey;
  }

  /**
   * Sends one rendered notification to one device.
   *
   * Never throws for an FCM-level failure. An exception here would abandon the remaining devices in the
   * batch, so every failure is returned as a `DeviceResult` and the caller decides.
   */
  public async sendToDevice(
    device: DeviceTokenRow,
    rendered: RenderedNotification,
    meta: {
      readonly templateKey: string;
      readonly orderId: string;
      readonly orderNumber: string;
      readonly recipient: string;
      readonly language: Language;
    },
  ): Promise<DeviceResult> {
    let accessToken: string;
    try {
      accessToken = await getAccessToken(this.#signingKey);
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      // The message is our own: `getAccessToken` includes Google's response body, which contains no key
      // material. The private key never appears, because no error path includes it.
      return { token: device.token, ok: false, error: `token: ${reason}` };
    }

    const payload = {
      message: {
        token: device.token,
        notification: {
          title: rendered.title,
          body: rendered.body,
        },
        data: toFcmData(rendered, meta),
        android: {
          // HIGH so a "your order was picked up" push wakes a sleeping handset. Without it Android may
          // batch the message into a doze window and deliver it minutes late, which for a delivery update
          // is indistinguishable from not working.
          priority: "high" as const,
          notification: {
            channel_id: "orders",
            // Both, so a handset that shows a notification and a wearable that does not are both covered.
            sound: "default",
          },
        },
        apns: {
          headers: {
            // 10 is FCM's "deliver immediately". The default drops the message if the device is in low
            // power mode, which for a rider accepting an order is worse than spending battery.
            "apns-priority": "10",
          },
          payload: {
            aps: {
              alert: { title: rendered.title, body: rendered.body },
              sound: "default",
              // A push with no deep link opens the app home screen, which is half a notification. Phase 4
              // owns the mapping from `template_key` to a screen; the field is populated so it exists when
              // that mapping lands.
              "thread-id": meta.orderId,
            },
          },
        },
      },
    };

    let response: Response;
    try {
      response = await fetch(this.#endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
      });
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      return { token: device.token, ok: false, error: `network: ${reason}` };
    }

    if (response.ok) {
      return { token: device.token, ok: true };
    }

    const text = await response.text();
    let body: FcmSendResponse;
    try {
      body = text.length > 0 ? (JSON.parse(text) as FcmSendResponse) : {};
    } catch {
      // Not JSON: keep the empty body and report the status. The text is still worth a truncated slice,
      // because an HTML error page from an edge proxy is a different problem from an FCM error.
      return {
        token: device.token,
        ok: false,
        error: `fcm ${String(response.status)}: ${text.slice(0, 200)}`,
      };
    }

    const detail =
      typeof body.error === "object" && body.error !== null
        ? ((body.error as { message?: unknown }).message ?? "unknown")
        : "unknown";
    const detailText = typeof detail === "string" ? detail : "unknown";

    if (isAuthFailure(response.status)) {
      // Our credentials, not the device. Clearing the cache means the next invocation signs a new token,
      // which is the only thing that can recover from an expired or revoked one.
      clearTokenCache();
      return { token: device.token, ok: false, error: `fcm auth ${String(response.status)}: ${detailText}` };
    }
    if (isDeadToken(response.status, body)) {
      return { token: device.token, ok: false, error: `dead token: ${detailText}` };
    }
    return { token: device.token, ok: false, error: `fcm ${String(response.status)}: ${detailText}` };
  }
}