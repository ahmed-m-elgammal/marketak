import { afterEach, describe, expect, it } from "vitest";

import { SupabaseClient } from "../database/supabase.js";

/**
 * REGRESSION TESTS FOR THE TWO DEFECTS THE FIRST LIVE DRAIN FOUND.
 *
 * Both shipped, both deployed, both passed 63 unit tests, and both were caught only by running the Worker
 * against the real database. That is the same lesson as `038`, `038d` and `038e` on the SQL side, and it is
 * why these are written against the real query strings rather than a mocked `fetch`.
 *
 * | Defect | Symptom | Root cause |
 * |---|---|---|
 * | `deleted_at is null` on `device_tokens` | `400 42703 column device_tokens.deleted_at does not exist`, every notification failed | The column does not exist. The table has no soft-delete. A filter that cannot run is worse than no filter: it looks precise. |
 * | `JSON.stringify` on a `bigint[]` | `500 TypeError: Do not know how to serialize a BigInt` AFTER the work was done | `events.id` is `bigint` and JSON cannot represent a BigInt at all. |
 *
 * The suite asserts on the URLs the client actually builds, because the defect WAS the URL.
 */

/** Captures every fetch and returns a scripted response. */
function interceptFetch(
  handler: (url: string, init: RequestInit | undefined) => Response,
): { calls: string[]; restore: () => void } {
  const realFetch = globalThis.fetch;
  const calls: string[] = [];
  globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    // `Request` carries its URL on a real property rather than in `toString()`, so the three cases are
    // narrowed rather than stringified blindly - default `[object Object]` would have made every URL
    // assertion below pass or fail for the wrong reason.
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.href
          : input.url;
    calls.push(url);
    return Promise.resolve(handler(url, init));
  };
  return {
    calls,
    restore: () => {
      globalThis.fetch = realFetch;
    },
  };
}

function client(): SupabaseClient {
  return new SupabaseClient({
    baseUrl: "https://example.supabase.co",
    serviceRoleKey: "sb_secret_dummy",
  });
}

afterEach(() => {
  // Nothing to restore per-test; each test restores in its own `finally`. This exists so a test that throws
  // mid-way still cannot leave a stubbed `fetch` behind for the next one.
});

describe("getDeviceTokens", () => {
  it("does NOT filter on deleted_at, which the table does not have", async () => {
    // Verified against `information_schema.columns` on the live project. The nine columns are
    // `id, user_id, token, platform, app_role, app_version, language, last_seen_at, created_at` and the
    // constraints are the primary key, `UNIQUE (token)`, two CHECKs and the user FK. Nothing else.
    const intercept = interceptFetch(() => Response.json([]));

    try {
      await client().getDeviceTokens("user-1");
    } finally {
      intercept.restore();
    }

    const url = intercept.calls[0] ?? "";
    expect(url).not.toContain("deleted_at");
    expect(url).toContain("user_id=eq.user-1");
    // Commas are legal unescaped in a query value, and `URLSearchParams` would percent-encode them for
    // no benefit. Asserted as the literal the client builds.
    expect(url).toContain("select=id,token,platform,app_role,language");
  });

  it("returns tokens even when the response carries rows", async () => {
    const intercept = interceptFetch(() =>
      Response.json([
        {
          id: "11111111-1111-1111-1111-111111111111",
          token: "ExxxxReal",
          platform: "ios",
          app_role: "rider",
          language: "ar",
        },
      ]),
    );

    try {
      const tokens = await client().getDeviceTokens("user-1");
      expect(tokens).toHaveLength(1);
      expect(tokens[0]?.platform).toBe("ios");
      expect(tokens[0]?.language).toBe("ar");
    } finally {
      intercept.restore();
    }
  });

  it("drops a row with no token rather than sending an empty string to FCM", async () => {
    // `token` is NOT NULL in the schema, so this cannot happen from Postgres. It can happen from a cached
    // PostgREST response after a schema change, and an empty token produces a confusing FCM 400 rather
    // than an obvious local skip.
    const intercept = interceptFetch(() =>
      Response.json([
        { id: "1", token: "", platform: "android", app_role: "customer", language: "en" },
      ]),
    );

    try {
      expect(await client().getDeviceTokens("user-1")).toHaveLength(0);
    } finally {
      intercept.restore();
    }
  });
});

describe("getTemplate", () => {
  it("DOES filter notification_templates on deleted_at, which that table DOES have", async () => {
    // The asymmetry with `device_tokens` is deliberate and both halves are asserted. A `deleted_at` filter
    // on a table without the column 400s; omitting one on a table with it silently returns soft-deleted
    // copy. Both were real bugs, in opposite directions.
    const intercept = interceptFetch(() => Response.json([]));

    try {
      await client().getTemplate("order.placed", "ar");
    } finally {
      intercept.restore();
    }

    const url = intercept.calls[0] ?? "";
    expect(url).toContain("deleted_at=is.null");
    expect(url).toContain("channel=eq.push");
    expect(url).toContain("is_active=eq.true");
  });

  it("returns null for an unknown template rather than throwing", async () => {
    // The drain treats null as a failure so the events stay countable, which is different from throwing.
    const intercept = interceptFetch(() => Response.json([]));

    try {
      expect(await client().getTemplate("nope", "en")).toBeNull();
    } finally {
      intercept.restore();
    }
  });
});

describe("event id deserialisation", () => {
  it("reads event_ids as strings, numbers and BigInt alike", async () => {
    // PostgREST returns a `bigint` as a JSON number when it fits in 2^53 and as a STRING beyond that. Both
    // shapes are real, and a day when ids cross the threshold must not silently return zero ids - which
    // would mark a group delivered without closing anything.
    for (const shape of [[1, 2, 3], ["4", "5", "6"]]) {
      const intercept = interceptFetch(() =>
        Response.json([
          {
            event_ids: shape,
            template_key: "order.placed",
            recipient: "customer",
            recipient_id: "11111111-1111-1111-1111-111111111111",
            order_id: "22222222-2222-2222-2222-222222222222",
            order_number: "MK-1",
            variables: { currency: "EGP" },
            language: "ar",
            oldest_event: "2026-10-05T10:00:00.000Z",
          },
        ]),
      );

      try {
        const claims = await client().claimEvents(50);
        expect(claims).toHaveLength(1);
        expect(claims[0]?.event_ids).toHaveLength(3);
        expect(claims[0]?.event_ids[0]).toBeTypeOf("bigint");
      } finally {
        intercept.restore();
      }
    }
  });

  it("reads an unrepresentable id exactly when PostgREST sends it as TEXT", async () => {
    // The safe path. `BigInt("9007199254740993")` is lossless, so a PostgREST configured to serialise
    // `bigint` as a string works with no guard at all.
    const body =
      '[{"event_ids":["9007199254740993"],"template_key":"order.placed","recipient":"customer",' +
      '"recipient_id":"11111111-1111-1111-1111-111111111111",' +
      '"order_id":"22222222-2222-2222-2222-222222222222","order_number":"MK-1",' +
      '"variables":{"currency":"EGP"},"language":"en","oldest_event":"2026-10-05T10:00:00.000Z"}]';

    const intercept = interceptFetch(() => new Response(body));

    try {
      const claims = await client().claimEvents(50);
      expect(claims[0]?.event_ids[0]?.toString()).toBe("9007199254740993");
    } finally {
      intercept.restore();
    }
  });

  it("REFUSES a bare number a double cannot represent, rather than rounding it", async () => {
    // The behaviour the first live drain's investigation produced. A bespoke JSON rewriter was written for
    // this and deleted; the honest answer is to stop with a reason rather than mark a group delivered under
    // an id one digit off.
    //
    // The body is raw TEXT on purpose: `Response.json({ event_ids: [9007199254740993] })` would pass the
    // value through `JSON.stringify` inside the test, losing the precision before the client ever sees it,
    // so a fixture built that way would pass a broken implementation.
    const body = '[{"event_ids":[9007199254740993],"recipient":"customer"}]';

    // The hazard, measured. This is why the guard exists at all.
    expect(JSON.parse('{"event_ids":[9007199254740993]}').event_ids[0]).toBe(9007199254740992);

    const intercept = interceptFetch(() => new Response(body));

    let message = "";
    try {
      await client().claimEvents(50);
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    } finally {
      intercept.restore();
    }

    expect(message).toContain("cannot represent exactly");
    // The message must say what to do, not just what went wrong.
    expect(message).toContain("bigint");
  });

  it("accepts ids inside the safe-integer range", async () => {
    const intercept = interceptFetch(() =>
      Response.json([
        { event_ids: [1, 2, 3], template_key: "k", recipient: "customer" },
      ]),
    );

    try {
      const claims = await client().claimEvents(50);
      expect(claims[0]?.event_ids).toHaveLength(3);
      expect(claims[0]?.event_ids[2]).toBe(3n);
    } finally {
      intercept.restore();
    }
  });

  it("skips a claim row whose recipient it does not recognise", async () => {
    // Guessing a recipient means sending to the wrong party. Skipping means the row stays claimable and the
    // backlog counts it.
    const intercept = interceptFetch(() =>
      Response.json([
        { event_ids: [1], template_key: "k", recipient: "admin", recipient_id: "x" },
      ]),
    );

    try {
      expect(await client().claimEvents(50)).toHaveLength(0);
    } finally {
      intercept.restore();
    }
  });
});

describe("error reporting", () => {
  it("names the RPC and the Postgres code when PostgREST rejects", async () => {
    // The first live drain returned `getDeviceTokens(...) failed: 400 42703 - column ...`. That message
    // pointed straight at the cause. A bare "request failed" would have cost an hour.
    const intercept = interceptFetch(() =>
      Response.json(
        {
          message: "column device_tokens.deleted_at does not exist",
          code: "42703",
          details: null,
          hint: null,
        },
        { status: 400 },
      ),
    );

    let message = "";
    try {
      await client().getDeviceTokens("user-1");
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    } finally {
      intercept.restore();
    }

    expect(message).toContain("getDeviceTokens");
    expect(message).toContain("42703");
    expect(message).toContain("deleted_at");
  });

  it("never puts the service-role key in the error message", async () => {
    const intercept = interceptFetch(() =>
      Response.json({ message: "boom", code: "XX000" }, { status: 500 }),
    );

    let message = "";
    try {
      await client().claimEvents(50);
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    } finally {
      intercept.restore();
    }

    expect(message).not.toContain("sb_secret_dummy");
  });

  it("sends the key as a header, never in the URL", async () => {
    // A key in a query string lands in access logs, Cloudflare's request log, and any error echoing the
    // request line.
    const intercept = interceptFetch(() => Response.json([]));

    try {
      await client().getDeviceTokens("user-1");
    } finally {
      intercept.restore();
    }

    expect(intercept.calls.length).toBeGreaterThan(0);
    for (const url of intercept.calls) {
      expect(url).not.toContain("sb_secret_dummy");
    }
  });
});

describe("BigInt and JSON", () => {
  it("JSON.stringify throws on a BigInt, which is why the report needs a replacer", () => {
    // Recorded as a test because it is a JavaScript language guarantee, not a behaviour of this code. The
    // live drain returned a 500 with an opaque body from exactly this.
    expect(() => JSON.stringify({ ids: [1n] })).toThrow(TypeError);

    const withReplacer = JSON.stringify(
      { ids: [1n, 2n] },
      (_key, value: unknown) => (typeof value === "bigint" ? value.toString() : value),
    );
    expect(withReplacer).toBe('{"ids":["1","2"]}');
  });
});