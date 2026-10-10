import { describe, expect, it } from "vitest";
import { AppError } from "@marketak/shared";
import type { RpcCall } from "../supabase/client";
import type { RpcDeps } from "./call";
import { readMismatch } from "./call";
import {
  cancelOrder,
  completeProfile,
  deleteAddress,
  getFlags,
  getProfileStatus,
  myAddresses,
  placeOrder,
  quoteOrder,
  registerDeviceToken,
  removeCartItem,
  riderProfile,
  searchCatalog,
  setDefaultAddress,
  updateProfile,
  upsertAddress,
  upsertCartItem,
  vendorFeed,
} from "./index";

interface Seen {
  method: string;
  args: Record<string, unknown>;
}

function fakeDeps(payload: unknown): { deps: RpcDeps; seen: Seen } {
  const seen: Seen = { method: "", args: {} };
  const call: RpcCall = {
    abortSignal(): RpcCall {
      return call;
    },
    single(): RpcCall {
      return call;
    },
    execute(): Promise<{ data: unknown; error: { message: string } | null }> {
      return Promise.resolve({ data: payload, error: null });
    },
  };
  return {
    deps: {
      call: (method, args) => {
        seen.method = method;
        seen.args = args;
        return call;
      },
    },
    seen,
  };
}

const UUID = "123e4567-e89b-12d3-a456-426614174000";

function fakeErrorDeps(message: string, thrown?: Error): { deps: RpcDeps; seen: Seen } {
  const seen: Seen = { method: "", args: {} };
  const call: RpcCall = {
    abortSignal(): RpcCall {
      return call;
    },
    single(): RpcCall {
      return call;
    },
    execute(): Promise<{ data: unknown; error: { message: string } | null }> {
      if (thrown !== undefined) throw thrown;
      return Promise.resolve({ data: null, error: { message } });
    },
  };
  return {
    deps: {
      call: (method, args) => {
        seen.method = method;
        seen.args = args;
        return call;
      },
    },
    seen,
  };
}

const PROFILE = {
  profile_completed_at: null,
  has_phone: true,
  has_address: false,
  can_browse: true,
  can_order: false,
  missing: ["address"],
};

const ADDRESS = {
  id: UUID,
  user_id: UUID,
  label: "home",
  area_id: null,
  geohash: "stq8abc",
  geohash_prefix: "stq8",
  latitude: 30.06,
  longitude: 31.22,
  area_name: "Zamalek",
  building: "12",
  floor: null,
  apartment: null,
  landmark: null,
  delivery_instructions: null,
  is_default: true,
  last_used_at: null,
  created_at: "2026-10-10T00:00:00Z",
  updated_at: "2026-10-10T00:00:00Z",
  deleted_at: null,
};

const QUOTE = {
  quote_id: UUID,
  expires_at: "2026-10-10T00:05:00Z",
  fingerprint: "md5:abc",
  fee_breakdown: {
    delivery_base_fee: 2500,
    vendor_count: 1,
    vendor_multiplier_bps: 10000,
    distance_km: 2.5,
    free_radius_km: 5,
    per_km_fee: 200,
    distance_charge: 0,
    delivery_fee: 2500,
    service_fee: 0,
    service_fee_enabled: false,
    rider_tip: 0,
    currency: "EGP ",
  },
  totals: {
    subtotal: 10000,
    discount_amount: 0,
    voucher_discount: 0,
    voucher_code: null,
    delivery_fee: 2500,
    service_fee: 0,
    rider_tip: 0,
    total: 12500,
  },
  per_vendor: [
    {
      vendor_id: UUID,
      subtotal: 10000,
      delivery_fee_share: 2500,
      service_fee_share: 0,
      discount_share: 0,
      commission_amount: 0,
      vendor_net_payout: 10000,
      prep_estimate_minutes: 20,
      ready_estimate_minutes: 18,
      meets_minimum: true,
      in_delivery_range: true,
    },
  ],
  limits: { vendor_count: 1, max_vendors_per_order: 3 },
  rejections: [],
  warnings: [],
};

describe("rpc barrel", () => {
  it("reads the profile gate through the typed wrapper", async () => {
    const { deps, seen } = fakeDeps(PROFILE);
    const status = await getProfileStatus(deps);
    expect(status.can_order).toBe(false);
    expect(seen.method).toBe("get_profile_status_v1");
  });

  it("passes profile args through untouched", async () => {
    const { deps, seen } = fakeDeps(PROFILE);
    await completeProfile({ p_first_name: "A", p_last_name: "B", p_phone: "+201001234567" }, deps);
    expect(seen.args).toEqual({ p_first_name: "A", p_last_name: "B", p_phone: "+201001234567" });
  });

  it("wraps patches as p_patch for updates", async () => {
    const { deps, seen } = fakeDeps(PROFILE);
    await updateProfile({ first_name: "A" }, deps);
    expect(seen.args).toEqual({ p_patch: { first_name: "A" } });
  });

  it("decodes address lists and defaults p_id to null on insert", async () => {
    const { deps, seen } = fakeDeps([ADDRESS]);
    const rows = await myAddresses(deps);
    expect(rows).toHaveLength(1);
    const one = await upsertAddress({ p_patch: { label: "home" } }, fakeDeps(ADDRESS).deps);
    expect(one.is_default).toBe(true);
    expect(seen.method).toBe("list_my_addresses_v1");
  });

  it("decodes set-default and delete results", async () => {
    const gone = await deleteAddress({ p_id: UUID }, fakeDeps(true).deps);
    expect(gone).toBe(true);
    await expect(deleteAddress({ p_id: UUID }, fakeDeps("yes").deps)).rejects.toBeInstanceOf(AppError);
    const current = await setDefaultAddress({ p_id: UUID }, fakeDeps(ADDRESS).deps);
    expect(current.id).toBe(UUID);
  });

  it("fails closed on corrupt cart money", async () => {
    const { deps } = fakeDeps({ cart_item_id: UUID, cart_id: UUID, quantity: 1, unit_price: 10.5, is_new: true });
    await expect(
      upsertCartItem({ p_menu_item_id: UUID, p_quantity: 1 }, deps),
    ).rejects.toBeInstanceOf(AppError);
  });

  it("decodes remove-cart counts", async () => {
    const left = await removeCartItem({ p_cart_item_id: UUID }, fakeDeps({ cart_id: UUID, remaining: 0 }).deps);
    expect(left.remaining).toBe(0);
  });

  it("decodes a full quote and trims bpchar currency", async () => {
    const { deps } = fakeDeps(QUOTE);
    const quote = await quoteOrder({ p_cart_id: UUID, p_address_id: UUID }, deps);
    expect(quote.totals.total).toBe(12500);
    expect(quote.fee_breakdown.currency).toBe("EGP");
    expect(quote.rejections).toEqual([]);
  });

  it("throws on an unknown rejection code instead of guessing a branch", async () => {
    const bad = {
      ...QUOTE,
      rejections: [{ vendor_id: null, code: "FUTURE_CODE", message_ar: "…" }],
    };
    await expect(quoteOrder({ p_cart_id: UUID, p_address_id: UUID }, fakeDeps(bad).deps)).rejects.toBeInstanceOf(
      AppError,
    );
    expect(typeof readMismatch("quote_order_v1")).toBe("string");
  });

  it("decodes place-order results", async () => {
    const placed = await placeOrder(
      { p_quote_id: UUID, p_payment_method: "cash", p_idempotency_key: "k" },
      fakeDeps({ order_id: UUID, order_number: "MK-1", sub_orders: [UUID], totals: QUOTE.totals }).deps,
    );
    expect(placed.order_number).toBe("MK-1");
  });

  it("returns unknown payloads unvalidated for unexecuted RPCs", async () => {
    const garbage = { whatever: [1, 2, { nested: true }] };
    expect(await cancelOrder({ p_order_id: UUID }, fakeDeps(garbage).deps)).toEqual(garbage);
    expect(await vendorFeed({}, fakeDeps(garbage).deps)).toEqual(garbage);
    expect(await searchCatalog({ p_query: "x" }, fakeDeps(garbage).deps)).toEqual(garbage);
  });

  it("decodes flags and device tokens strictly", async () => {    const flags = await getFlags({}, fakeDeps([{ flag_key: "k", value: { on: true } }]).deps);
    expect(flags).toHaveLength(1);
    const token = {
      id: UUID,
      user_id: UUID,
      token: "t",
      platform: "android",
      app_role: "customer",
      app_version: "0.1.0",
      language: "ar",
      last_seen_at: "2026-10-10T00:00:00Z",
      created_at: "2026-10-10T00:00:00Z",
    };
    const tokens = await registerDeviceToken(
      { p_token: "t", p_platform: "android", p_app_role: "customer", p_app_version: "0.1.0" },
      fakeDeps([token]).deps,
    );
    expect(tokens).toHaveLength(1);
    await expect(
      registerDeviceToken(
        { p_token: "t", p_platform: "android", p_app_role: "customer", p_app_version: "0.1.0" },
        fakeDeps([{ ...token, platform: "windows-phone" }]).deps,
      ),
    ).rejects.toBeInstanceOf(AppError);
  });

  it("probes the rider role with zero args: row means rider, NOT_A_RIDER means customer-only", async () => {
    const rider = {
      rider_id: UUID,
      first_name: "Karim",
      last_name: null,
      phone_number: "+201012345678",
      country_code: "EG",
      vehicle_type: "motorcycle",
      vehicle_plate: null,
      home_area_id: null,
      status: "available",
      is_online: true,
      is_active: true,
      is_verified: true,
      rating_avg: 4.8,
      rating_count: 120,
      completed_deliveries: 300,
      cancelled_deliveries: 2,
      cash_held: 0,
      effective_cash_limit: 50000,
      current_latitude: null,
      current_longitude: null,
      last_location_at: null,
      created_at: "2026-10-10T00:00:00Z",
    };
    const { deps, seen } = fakeDeps(rider);
    const profile = await riderProfile(deps);
    expect(profile?.rider_id).toBe(UUID);
    expect(profile?.effective_cash_limit).toBe(50000);
    expect(seen.method).toBe("get_my_rider_profile_v1");
    expect(seen.args).toEqual({});

    await expect(riderProfile(fakeErrorDeps("NOT_A_RIDER: لست سائقا").deps)).resolves.toBeNull();
    await expect(riderProfile(fakeErrorDeps("AUTH_REQUIRED: سجل الدخول").deps)).rejects.toBeInstanceOf(AppError);
    await expect(riderProfile(fakeErrorDeps("", new TypeError("fetch failed")).deps)).rejects.toBeInstanceOf(
      AppError,
    );
  });
});
