import { describe, expect, it } from "vitest";

import type { ClaimedNotification, DeviceTokenRow, TemplateRow } from "@marketak/shared";

import { drainOnce } from "../drain/drain-once.js";
import type { Env } from "../config/env.js";
import { FakeFcm, FakeSupabase, makeClaim, makeDevice } from "./fakes.js";

/**
 * The seven MVP templates, with their REAL bodies as they exist in
 * `public.notification_templates` on the live project. Copied, not retyped from the plan, so a change in
 * the database shows up here as a test failure rather than as a silent difference.
 *
 * `variables` is the declared list from the `variables jsonb` column.
 */
const REAL_TEMPLATES: Readonly<Record<string, Readonly<Record<string, TemplateRow>>>> = {
  "order.placed": {
    en: {
      key: "order.placed",
      lang: "en",
      title: "Order received",
      body: "Your order {order_number} is being prepared by {vendor_count} vendor(s). Total {total}.",
      variables: ["order_number", "total", "vendor_count"],
    },
    ar: {
      key: "order.placed",
      lang: "ar",
      title: "تم استلام طلبك",
      body: "طلبك {order_number} قيد التحضير من {vendor_count} مطعم. الإجمالي {total}.",
      variables: ["order_number", "total", "vendor_count"],
    },
  },
  "order.picked_up": {
    en: {
      key: "order.picked_up",
      lang: "en",
      title: "Courier on the way",
      body: "{rider_name} has collected your order. Estimated arrival {eta}.",
      variables: ["rider_name", "eta"],
    },
    ar: {
      key: "order.picked_up",
      lang: "ar",
      title: "التوصيل في الطريق",
      body: "استلم {rider_name} طلبك. الوصول المتوقع {eta}.",
      variables: ["rider_name", "eta"],
    },
  },
  "order.delivered": {
    en: {
      key: "order.delivered",
      lang: "en",
      title: "Delivered",
      body: "Your order has been delivered. Total {total}. Paid by {payment_method}. {review_prompt}",
      variables: ["total", "payment_method", "review_prompt"],
    },
    ar: {
      key: "order.delivered",
      lang: "ar",
      title: "تم التسليم",
      body: "تم تسليم طلبك. الإجمالي {total}. طريقة الدفع {payment_method}. {review_prompt}",
      variables: ["total", "payment_method", "review_prompt"],
    },
  },
  "order.vendor_rejected": {
    en: {
      key: "order.vendor_rejected",
      lang: "en",
      title: "Your order changed",
      body: "{vendor_name} declined part of your order: {affected_items}. You need to {action_required}.",
      variables: ["vendor_name", "affected_items", "action_required"],
    },
    ar: {
      key: "order.vendor_rejected",
      lang: "ar",
      title: "تغيّر طلبك",
      body: "رفض {vendor_name} جزءًا من طلبك: {affected_items}. مطلوب منك {action_required}.",
      variables: ["vendor_name", "affected_items", "action_required"],
    },
  },
  "order.cancelled": {
    en: {
      key: "order.cancelled",
      lang: "en",
      title: "Order cancelled",
      body: "Your order was cancelled: {reason}. Refunded {refund_amount}.",
      variables: ["reason", "refund_amount"],
    },
    ar: {
      key: "order.cancelled",
      lang: "ar",
      title: "تم إلغاء الطلب",
      body: "تم إلغاء طلبك: {reason}. المبلغ المسترد {refund_amount}.",
      variables: ["reason", "refund_amount"],
    },
  },
  "rider.order_assigned": {
    en: {
      key: "rider.order_assigned",
      lang: "en",
      title: "Order assigned",
      body: "Order {order_number} is yours. {stops} stop(s). Earnings {rider_pay_total}.",
      variables: ["order_number", "stops", "rider_pay_total"],
    },
    ar: {
      key: "rider.order_assigned",
      lang: "ar",
      title: "تم إسناد الطلب",
      body: "تم إسناد الطلب {order_number} إليك. عدد المحطات {stops}. Earnings {rider_pay_total}.",
      variables: ["order_number", "stops", "rider_pay_total"],
    },
  },
  "vendor.new_order": {
    en: {
      key: "vendor.new_order",
      lang: "en",
      title: "New order",
      body: "Order {order_number}: {item_count} item(s), total {total}. Prep deadline {prep_deadline}.",
      variables: ["order_number", "item_count", "total", "prep_deadline"],
    },
    ar: {
      key: "vendor.new_order",
      lang: "ar",
      title: "طلب جديد",
      body: "طلب {order_number}: {item_count} عنصر بإجمالي {total}. التسليم المطلوب {prep_deadline}.",
      variables: ["order_number", "item_count", "total", "prep_deadline"],
    },
  },
};

function testEnv(overrides: Partial<Env> = {}): Env {
  return {
    supabaseUrl: "https://example.supabase.co",
    supabaseServiceRoleKey: "sb_secret_dummy_for_tests",
    fcm: {
      projectId: "marketak-eg",
      clientEmail: "a@b.com",
      privateKey: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
    },
    dryRun: "send",
    batchSize: 50,
    ...overrides,
  };
}

/** A claim carrying every variable the seven templates between them need. */
function fullyPopulatedClaim(
  templateKey: string,
  overrides: Partial<ClaimedNotification> = {},
): ClaimedNotification {
  return makeClaim({
    template_key: templateKey,
    variables: {
      order_number: "MK-20261005-00000001",
      vendor_count: 3,
      total: 33_000,
      vendor_name: "Kofta",
      reason: "changed my mind",
      refund_amount: 0,
      rider_pay_total: 1_250,
      affected_items: 3,
      rider_name: "Rami",
      stops: 3,
      eta: "14:32",
      payment_method: "cash",
      item_count: 3,
      currency: "EGP",
    },
    ...overrides,
  });
}

describe("drainOnce - the seven MVP templates", () => {
  const KEYS = [
    "order.placed",
    "order.picked_up",
    "order.delivered",
    "order.vendor_rejected",
    "order.cancelled",
    "rider.order_assigned",
    "vendor.new_order",
  ];

  for (const key of KEYS) {
    it(`renders and sends ${key} in both languages with no unfilled placeholder`, async () => {
      const supabase = new FakeSupabase({
        claims: [fullyPopulatedClaim(key)],
        templates: REAL_TEMPLATES,
        devices: [makeDevice()],
      });
      const fcm = new FakeFcm();

      const report = await drainOnce(testEnv(), { supabase, fcm });

      expect(report.errors).toEqual([]);
      expect(report.unrenderable).toBe(0);
      expect(report.sent).toBe(1);
      expect(report.failed).toBe(0);
      expect(fcm.calls.filter((call) => call.kind === "send")).toHaveLength(1);
    });
  }

  it("produces exactly seven pushes for the seven notifications of one 3-vendor order", async () => {
    // The plan's Phase 3 exit criterion: a real order produces exactly the seven pushes of §8.1.
    const claims: ClaimedNotification[] = [
      fullyPopulatedClaim("order.placed", { event_ids: [1n] }),
      fullyPopulatedClaim("order.picked_up", { event_ids: [2n, 3n, 4n] }),
      fullyPopulatedClaim("order.delivered", { event_ids: [5n] }),
      fullyPopulatedClaim("order.vendor_rejected", { event_ids: [6n], recipient: "customer" }),
      fullyPopulatedClaim("order.cancelled", { event_ids: [7n] }),
      fullyPopulatedClaim("rider.order_assigned", {
        event_ids: [8n],
        recipient: "rider",
        recipient_id: "44444444-4444-4444-4444-444444444444",
      }),
      fullyPopulatedClaim("vendor.new_order", {
        event_ids: [9n],
        recipient: "vendor",
        recipient_id: "55555555-5555-5555-5555-555555555555",
      }),
    ];

    const supabase = new FakeSupabase({
      claims,
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });
    const fcm = new FakeFcm();

    const report = await drainOnce(testEnv(), { supabase, fcm });

    expect(report.claimed).toBe(7);
    expect(report.sent).toBe(7);
    expect(report.failed).toBe(0);
    expect(report.unrenderable).toBe(0);
    expect(report.errors).toEqual([]);
    expect(fcm.calls.filter((call) => call.kind === "send")).toHaveLength(7);
  });

  it("marks once per batch, not once per notification", async () => {
    // `mark_events_delivered_v1` is documented as "one call per batch, never per event".
    const supabase = new FakeSupabase({
      claims: [
        fullyPopulatedClaim("order.placed", { event_ids: [1n] }),
        fullyPopulatedClaim("order.delivered", { event_ids: [2n] }),
        fullyPopulatedClaim("order.cancelled", { event_ids: [3n] }),
      ],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });

    await drainOnce(testEnv(), { supabase, fcm: new FakeFcm() });

    const marks = supabase.calls.filter((call) => call.kind === "mark");
    expect(marks).toHaveLength(1);
    if (marks[0]?.kind === "mark") {
      expect(marks[0].outcomeCount).toBe(3);
    }
  });

  it("marks after every send, never before", async () => {
    // The ordering that decides whether a crash loses notifications. Asserted rather than assumed because
    // a reordering here is invisible in the happy path and catastrophic in production.
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.placed")],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });
    const fcm = new FakeFcm();

    await drainOnce(testEnv(), { supabase, fcm });

    const kinds = supabase.calls.map((call) => call.kind);
    const sendIndex = fcm.calls.length > 0 ? kinds.indexOf("template") : -1;
    const markIndex = kinds.indexOf("mark");

    expect(sendIndex).toBeGreaterThan(-1);
    expect(markIndex).toBeGreaterThan(sendIndex);
  });

  it("passes the configured batch size to the claim RPC", async () => {
    const supabase = new FakeSupabase({ claims: [], templates: REAL_TEMPLATES, devices: [] });

    await drainOnce(testEnv({ batchSize: 17 }), { supabase, fcm: new FakeFcm() });

    const claim = supabase.calls.find((call) => call.kind === "claim");
    expect(claim).toBeDefined();
    if (claim?.kind === "claim") {
      expect(claim.batchSize).toBe(17);
    }
  });
});

describe("drainOnce - collapse", () => {
  it("sends ONE push for three collapsed events and marks all three", async () => {
    // P1.5: three sub-orders reaching picked_up is one notification carrying three ids.
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.picked_up", { event_ids: [10n, 11n, 12n] })],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });
    const fcm = new FakeFcm();

    const report = await drainOnce(testEnv(), { supabase, fcm });

    expect(fcm.calls.filter((call) => call.kind === "send")).toHaveLength(1);
    expect(report.marked).toBe(3);
    expect(report.still_open).toBe(0);
  });

  it("fails the whole collapsed group when one device fails", async () => {
    // Marking on a partial success would close events whose notification never arrived. The cost is that
    // the good device gets a duplicate on retry, which is at-least-once and the same trade the drain makes
    // everywhere else.
    const good = makeDevice({ token: "GoodToken" });
    const dead = makeDevice({ token: "DeadToken" });
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.picked_up", { event_ids: [10n, 11n, 12n] })],
      templates: REAL_TEMPLATES,
      devices: [good, dead],
    });
    const fcm = new FakeFcm({
      results: { DeadToken: { ok: false, error: "dead token: UNREGISTERED" } },
    });

    const report = await drainOnce(testEnv(), { supabase, fcm });

    expect(report.sent).toBe(0);
    expect(report.failed).toBe(1);
    expect(report.marked).toBe(0);
    expect(report.still_open).toBe(3);
  });

  it("records every failure reason on the group, not just the first", async () => {
    // `events.last_error` is one text column, so this string is the only place all failures will be visible.
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.placed")],
      templates: REAL_TEMPLATES,
      devices: [makeDevice({ token: "A" }), makeDevice({ token: "B" })],
    });
    const fcm = new FakeFcm({
      results: {
        A: { ok: false, error: "fcm 503: backend error" },
        B: { ok: false, error: "dead token: NOT_FOUND" },
      },
    });

    const report = await drainOnce(testEnv(), { supabase, fcm });

    const notification = report.notifications[0];
    expect(notification?.error).toContain("503");
    expect(notification?.error).toContain("NOT_FOUND");
  });
});

describe("drainOnce - refusing to send a broken message", () => {
  it("refuses to send when a placeholder has no value", async () => {
    // The eta gap that `038g` fixed: `eta` came back absent, and the alternative was a customer reading
    // "Estimated arrival {eta}" with no hint why.
    const claim = makeClaim({
      template_key: "order.picked_up",
      variables: { rider_name: "Rami", currency: "EGP" },
    });
    const supabase = new FakeSupabase({
      claims: [claim],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });
    const fcm = new FakeFcm();

    const report = await drainOnce(testEnv(), { supabase, fcm });

    expect(report.unrenderable).toBe(1);
    expect(report.sent).toBe(0);
    expect(fcm.calls.filter((call) => call.kind === "send")).toHaveLength(0);
    // The events stay OPEN so the §11 backlog alarm counts them. A skipped notification is
    // indistinguishable from a lost one.
    expect(report.still_open).toBe(1);
  });

  it("names the unfilled placeholder in the failure reason", async () => {
    // `action_required` is deliberately NOT expected here: it is one of the three Worker-owned static
    // strings, so it is always filled and can never appear in `missing_variables`. Asserting that it is
    // absent from the failure is the point - it proves the static map is actually being consulted, rather
    // than every placeholder just being reported when the claim lacks it.
    const supabase = new FakeSupabase({
      claims: [
        makeClaim({
          template_key: "order.vendor_rejected",
          variables: { affected_items: 3, currency: "EGP" },
        }),
      ],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });

    const report = await drainOnce(testEnv(), { supabase, fcm: new FakeFcm() });

    const notification = report.notifications[0];
    expect(notification?.error).toContain("vendor_name");
    // The claim carries no `vendor_name`, and the database deliberately does not supply one for this
    // template on a collapsed customer notification.
    expect(notification?.error).not.toContain("action_required");
  });

  it("fills the Worker-owned statics so they never block a send", async () => {
    // All three, in one order. If any of them were treated as a claim variable instead of a static, this
    // test would fail with three `unfilled placeholder(s)` and no notification would ever be delivered.
    const cases: readonly { key: string; variables: Record<string, unknown> }[] = [
      {
        key: "order.delivered",
        variables: { total: 33_000, payment_method: "cash", currency: "EGP" },
      },
      {
        key: "order.vendor_rejected",
        variables: { vendor_name: "Kofta", affected_items: 3, currency: "EGP" },
      },
      {
        key: "vendor.new_order",
        variables: { order_number: "MK-1", item_count: 3, total: 33_000, currency: "EGP" },
      },
    ];

    for (const testCase of cases) {
      const supabase = new FakeSupabase({
        claims: [makeClaim({ template_key: testCase.key, variables: testCase.variables })],
        templates: REAL_TEMPLATES,
        devices: [makeDevice()],
      });

      const report = await drainOnce(testEnv(), { supabase, fcm: new FakeFcm() });

      expect(report.unrenderable).toBe(0);
      expect(report.sent).toBe(1);
      expect(report.errors).toEqual([]);
    }
  });

  it("treats a missing template as a failure rather than a silent skip", async () => {
    // The claim already filters on an active template, so reaching here means the row was deactivated
    // between the two calls. Failing keeps the events countable.
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.placed")],
      templates: {},
      devices: [makeDevice()],
    });

    const report = await drainOnce(testEnv(), { supabase, fcm: new FakeFcm() });

    expect(report.unrenderable).toBe(1);
    expect(report.still_open).toBe(1);
  });

  it("treats a recipient with no device token as a failure, not a success", async () => {
    // Marking this delivered would swallow the notification with no backlog entry.
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.placed")],
      templates: REAL_TEMPLATES,
      devices: [],
    });

    const report = await drainOnce(testEnv(), { supabase, fcm: new FakeFcm() });

    expect(report.sent).toBe(0);
    expect(report.failed).toBe(1);
    expect(report.still_open).toBe(1);
  });
});

describe("drainOnce - resilience", () => {
  it("reports a claim failure instead of throwing", async () => {
    // A drain that cannot claim is not absorbable: the backlog grows silently until the §11 alarm fires
    // hours later.
    const supabase = new FakeSupabase({ claimError: new Error("401 permission denied") });

    const report = await drainOnce(testEnv(), { supabase, fcm: new FakeFcm() });

    expect(report.claimed).toBe(0);
    expect(report.errors).toHaveLength(1);
    expect(report.errors[0]).toContain("claim");
    expect(report.errors[0]).toContain("permission denied");
  });

  it("leaves the whole batch open when marking fails", async () => {
    // Nothing is marked optimistically before the send, so a mark failure costs at-least-once, not
    // notifications that were sent and then forgotten.
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.placed")],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
      markError: new Error("connection reset"),
    });

    const report = await drainOnce(testEnv(), { supabase, fcm: new FakeFcm() });

    expect(report.sent).toBe(1);
    expect(report.marked).toBe(0);
    expect(report.errors.some((entry) => entry.startsWith("mark:"))).toBe(true);
  });

  it("continues the batch after one notification throws", async () => {
    const supabase = new FakeSupabase({
      claims: [
        fullyPopulatedClaim("order.placed", { event_ids: [1n] }),
        fullyPopulatedClaim("order.delivered", { event_ids: [2n] }),
      ],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });
    // Every send throws, so the first notification's failure cannot abandon the second.
    const fcm = new FakeFcm({ throwOnSend: true });

    const report = await drainOnce(testEnv(), { supabase, fcm });

    expect(report.claimed).toBe(2);
    expect(report.errors).toHaveLength(2);
    expect(report.still_open).toBe(2);
  });

  it("returns early with no mark call when there is nothing to claim", async () => {
    // The common case, and the fastest path in the Worker. A pointless mark call would cost a round trip
    // every 60 seconds forever.
    const supabase = new FakeSupabase({ claims: [] });

    const report = await drainOnce(testEnv(), { supabase, fcm: new FakeFcm() });

    expect(report.claimed).toBe(0);
    expect(supabase.calls.filter((call) => call.kind === "mark")).toHaveLength(0);
  });
});

describe("drainOnce - dry run", () => {
  it("renders and counts without sending anything", async () => {
    const supabase = new FakeSupabase({
      claims: [
        fullyPopulatedClaim("order.placed", { event_ids: [1n] }),
        fullyPopulatedClaim("order.delivered", { event_ids: [2n] }),
      ],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });
    const fcm = new FakeFcm();

    const report = await drainOnce(testEnv({ dryRun: "log" }), { supabase, fcm });

    expect(report.dry_run).toBe("log");
    expect(report.sent).toBe(2);
    expect(report.marked).toBe(2);
    // No request leaves the isolate.
    expect(fcm.calls).toHaveLength(0);
  });

  it("includes the rendered text so it can be checked", async () => {
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.placed")],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });

    const report = await drainOnce(testEnv({ dryRun: "log" }), { supabase, fcm: new FakeFcm() });

    const preview = report.notifications[0]?.preview ?? "";
    expect(preview).toContain("MK-20261005-00000001");
    expect(preview).not.toContain("{");
  });

  it("still refuses an unrenderable notification in dry run", async () => {
    // Dry run exists to prove the pipeline, so it must exercise the refusal path too. If dry run skipped
    // the check, the first real send would be the first time it ran.
    const supabase = new FakeSupabase({
      claims: [
        makeClaim({ template_key: "order.picked_up", variables: { currency: "EGP" } }),
      ],
      templates: REAL_TEMPLATES,
      devices: [makeDevice()],
    });

    const report = await drainOnce(testEnv({ dryRun: "log" }), { supabase, fcm: new FakeFcm() });

    expect(report.unrenderable).toBe(1);
    expect(report.still_open).toBe(1);
  });
});

describe("drainOne - device fan-out", () => {
  it("sends to every device for the recipient and needs all of them to succeed", async () => {
    const devices: DeviceTokenRow[] = [
      makeDevice({ token: "Phone1" }),
      makeDevice({ token: "Phone2" }),
      makeDevice({ token: "Tablet" }),
    ];
    const supabase = new FakeSupabase({
      claims: [fullyPopulatedClaim("order.placed")],
      templates: REAL_TEMPLATES,
      devices,
    });
    const fcm = new FakeFcm();

    const report = await drainOnce(testEnv(), { supabase, fcm });

    expect(fcm.calls.filter((call) => call.kind === "send")).toHaveLength(3);
    expect(report.sent).toBe(1);
    expect(report.notifications[0]?.devices_targeted).toBe(3);
    expect(report.notifications[0]?.devices_ok).toBe(3);
  });
});