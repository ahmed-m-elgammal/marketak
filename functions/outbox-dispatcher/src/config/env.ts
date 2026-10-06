/**
 * `config/env` - reading and validating the Worker's secrets and vars.
 *
 * ## The three secrets, and why each is a secret
 *
 * | Secret | Grants | Why it cannot be a plain var |
 * |---|---|---|
 * | `SUPABASE_SERVICE_ROLE_KEY` | `BYPASSRLS` on every table | A `service_role` key in `wrangler.toml` is a committed secret. It bypasses every row-level policy this project spent `014_rls` and `022` building. |
 * | `FCM_SERVICE_ACCOUNT_JSON` | send as the Firebase admin | Carries a `private_key`. Firebase's legacy `key=` server-key auth is dead; HTTP v1 requires a signed JWT, so there is no unauthenticated send path. |
 * | `DRY_RUN` | a plain var, not a secret | `DRUN` is a typo of a real flag that stops real notifications being sent, and a typo'd flag would silently discard customer-facing messages. |
 *
 * ## The one thing that must not exist here
 *
 * **No default for the currency.** constitution rule 4 makes every money constant configuration, and the
 * currency is per-order data read from `orders.currency` by the claim RPC. A `CURRENCY = "EGP"` fallback
 * in a Worker would be the literal that rule forbids, and the one nobody would look for, because it sits
 * in a config module reading as plumbing.
 */

/** Google's OAuth2 token endpoint. Reached once per access token, not once per send. */
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";

/** FCM HTTP v1 send endpoint. */
export const FCM_SEND_URL = "https://fcm.googleapis.com/v1/projects";

/** The scope required to send via FCM HTTP v1. */
export const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

/**
 * A Google access token expires after 3600 seconds. Cached for 55 minutes rather than 60 because a token
 * fetched at the 59th minute and used immediately can expire mid-flight, and a send that fails on an
 * expired token is indistinguishable from a send that failed for any other reason.
 */
export const ACCESS_TOKEN_TTL_SECONDS = 3_300;

export type DryRunMode = "log" | "send";

export interface Env {
  readonly supabaseUrl: string;
  readonly supabaseServiceRoleKey: string;
  /** The parsed service account. Parsed once at the edge so no layer below handles raw JSON. */
  readonly fcm: {
    readonly projectId: string;
    readonly clientEmail: string;
    /** PEM, with newlines intact. Imported as a PKCS#8 key for WebCrypto. */
    readonly privateKey: string;
  };
  /**
   * `log` renders and marks without sending. `send` calls FCM.
   *
   * Default `log`, deliberately. A Worker deployed with a missing or misspelled flag must fail toward not
   * sending rather than toward sending: an undelivered notification is retried on the next tick, while a
   * wrongly-delivered one reaches a customer and cannot be recalled.
   */
  readonly dryRun: DryRunMode;
  /** Notifications claimed per invocation. The RPC clamps to 200 and floors at 1. */
  readonly batchSize: number;
}

/** The raw shape as it arrives from Wrangler, before validation. */
type RawEnv = Record<string, string | undefined>;

export class ConfigError extends Error {
  public constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

/**
 * The fields a Firebase service-account JSON must carry.
 *
 * Checked as an explicit allowlist rather than cast. The failure this prevents: a JSON file that parses
 * into an object missing `private_key`, spread into an `Env` that type-checks because the field is typed
 * `string`, and then throws deep inside WebCrypto 40 requests later with no hint that the cause was a
 * field name.
 */
interface ServiceAccountShape {
  readonly project_id?: unknown;
  readonly client_email?: unknown;
  readonly private_key?: unknown;
}

function parseServiceAccount(raw: string): Env["fcm"] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // The raw JSON is deliberately NOT included in the message. It holds a private key, and an exception
    // message is the single most likely place for a secret to end up in a log.
    throw new ConfigError("FCM_SERVICE_ACCOUNT_JSON is not valid JSON");
  }

  if (typeof parsed !== "object" || parsed === null) {
    throw new ConfigError("FCM_SERVICE_ACCOUNT_JSON must be a JSON object");
  }

  const shape = parsed as ServiceAccountShape;
  const missing = ["project_id", "client_email", "private_key"].filter(
    (key) => typeof shape[key as keyof ServiceAccountShape] !== "string",
  );
  if (missing.length > 0) {
    throw new ConfigError(
      `FCM_SERVICE_ACCOUNT_JSON is missing required field(s): ${missing.join(", ")}`,
    );
  }

  const privateKey = shape.private_key;
  const projectId = shape.project_id;
  const clientEmail = shape.client_email;
  if (
    typeof privateKey !== "string" ||
    typeof projectId !== "string" ||
    typeof clientEmail !== "string"
  ) {
    // Unreachable given the filter above, and stated rather than asserted so a future edit to the filter
    // does not silently produce an `Env` with undefined fields.
    throw new ConfigError("FCM_SERVICE_ACCOUNT_JSON failed validation");
  }

  if (!privateKey.includes("BEGIN PRIVATE KEY")) {
    // Detected here because WebCrypto's PKCS#8 import gives an opaque error for a key that is not a key.
    throw new ConfigError(
      "FCM_SERVICE_ACCOUNT_JSON private_key does not look like a PEM private key",
    );
  }

  return { projectId, clientEmail, privateKey };
}

/**
 * Validates the raw environment and returns a typed `Env`.
 *
 * Every failure is a `ConfigError` naming the missing variable and never its value. A message containing a
 * key would end up in a Worker log, a Cloudflare dashboard, and eventually a screenshot.
 */
export function readEnv(raw: RawEnv): Env {
  const supabaseUrl = raw["SUPABASE_URL"];
  const serviceRoleKey = raw["SUPABASE_SERVICE_ROLE_KEY"];
  const serviceAccountJson = raw["FCM_SERVICE_ACCOUNT_JSON"];

  const absent = [
    ["SUPABASE_URL", supabaseUrl],
    ["SUPABASE_SERVICE_ROLE_KEY", serviceRoleKey],
    ["FCM_SERVICE_ACCOUNT_JSON", serviceAccountJson],
  ]
    .filter(([, value]) => value === undefined || value === "")
    .map(([name]) => String(name));

  if (absent.length > 0) {
    throw new ConfigError(
      `missing required secret(s): ${absent.join(", ")}. Set them with \`wrangler secret put <NAME>\`.`,
    );
  }

  if (supabaseUrl === undefined || serviceRoleKey === undefined || serviceAccountJson === undefined) {
    // Narrowed by the check above. `exactOptionalPropertyTypes` plus `noUncheckedIndexedAccess` means the
    // compiler still cannot see it, so the invariant is stated once here instead of with `!` at each use.
    throw new ConfigError("unreachable: presence check and narrowing disagree");
  }

  const url = new URL(supabaseUrl);
  if (url.protocol !== "https:") {
    // A plaintext URL would put the service-role key on the wire in the clear. Supabase is always https.
    throw new ConfigError("SUPABASE_URL must use https");
  }

  const rawDryRun = raw["DRY_RUN"] ?? "log";
  if (rawDryRun !== "log" && rawDryRun !== "send") {
    throw new ConfigError(`DRY_RUN must be "log" or "send", received "${rawDryRun}"`);
  }

  const rawBatch = raw["BATCH_SIZE"];
  const parsedBatch = rawBatch === undefined ? 50 : Number(rawBatch);
  if (!Number.isInteger(parsedBatch) || parsedBatch < 1 || parsedBatch > 200) {
    // 200 is the RPC's own ceiling. Asking for more silently returns 200, and a config that appears to be
    // honoured but is not is worse than a config that refuses.
    throw new ConfigError(`BATCH_SIZE must be an integer from 1 to 200, received "${String(rawBatch)}"`);
  }

  return {
    supabaseUrl: url.origin,
    supabaseServiceRoleKey: serviceRoleKey,
    fcm: parseServiceAccount(serviceAccountJson),
    dryRun: rawDryRun,
    batchSize: parsedBatch,
  };
}