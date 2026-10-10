import { describe, expect, it } from "vitest";
import { AppError } from "@marketak/shared";
import {
  myActiveCart,
  myCartItems,
  myOrders,
  getVendor,
  listAreas,
  listMenuItemSizes,
  orderHistory,
  riderAssignments,
  type ReadDeps,
  type TableClient,
  type TableQuery,
  type TableQueryResult,
} from "./reads";

interface Op {
  readonly op: string;
  readonly column: string;
  readonly value: unknown;
}

interface CannedTable {
  readonly rows: readonly unknown[] | null;
  readonly single: unknown;
  readonly hasSingle: boolean;
  readonly error: { message: string } | null;
}

const EMPTY_TABLE: CannedTable = { rows: [], single: null, hasSingle: false, error: null };

function fakeQuery(
  canned: CannedTable,
  calls: Op[],
  table: string,
  failOnce: () => boolean,
): TableQuery<unknown> {
  const track = (op: string, column: string, value: unknown): void => {
    calls.push({ op: `${table}.${op}`, column, value });
  };
  const transportOnce = (): boolean => failOnce();
  const query: TableQuery<unknown> = {
    eq(column: string, value: string | number | boolean): TableQuery<unknown> {
      track("eq", column, value);
      return query;
    },
    is(column: string, value: null): TableQuery<unknown> {
      track("is", column, value);
      return query;
    },
    in(column: string, values: readonly (string | number)[]): TableQuery<unknown> {
      track("in", column, [...values]);
      return query;
    },
    order(column: string, options?: { ascending?: boolean }): TableQuery<unknown> {
      track("order", column, options?.ascending ?? true);
      return query;
    },
    limit(count: number): TableQuery<unknown> {
      track("limit", "", count);
      return query;
    },
    then<TResult1 = TableQueryResult<unknown>, TResult2 = never>(
      onfulfilled?: ((value: TableQueryResult<unknown>) => TResult1 | PromiseLike<TResult1>) | null,
      onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
    ): PromiseLike<TResult1 | TResult2> {
      if (transportOnce()) return Promise.reject(new TypeError("fetch failed")).then(onfulfilled, onrejected);
      return Promise.resolve({ data: canned.rows, error: canned.error }).then(onfulfilled, onrejected);
    },
    maybeSingle(): PromiseLike<{ data: unknown; error: { message: string } | null }> {
      if (transportOnce()) return Promise.reject(new TypeError("fetch failed"));
      if (canned.error !== null) return Promise.resolve({ data: null, error: canned.error });
      return Promise.resolve({ data: canned.hasSingle ? canned.single : null, error: null });
    },
  };
  return query;
}

function fakeClient(
  canned: Readonly<Record<string, CannedTable>>,
  calls: Op[],
  failFirstTables: readonly string[] = [],
): TableClient {
  const failed = new Set<string>();
  const failOnce = (table: string): boolean => {
    if (!failFirstTables.includes(table) || failed.has(table)) return false;
    failed.add(table);
    return true;
  };
  return {
    from(table: string): { select(columns: string): TableQuery<unknown> } {
      calls.push({ op: "from", column: "", value: table });
      const query = fakeQuery(canned[table] ?? EMPTY_TABLE, calls, table, () => failOnce(table));
      return {
        select(columns: string): TableQuery<unknown> {
          calls.push({ op: `${table}.select`, column: "", value: columns });
          return query;
        },
      };
    },
  };
}

function deps(
  canned: Readonly<Record<string, CannedTable>>,
  calls: Op[],
  failFirstTables: readonly string[] = [],
): { deps: ReadDeps; calls: Op[] } {
  return { deps: { client: fakeClient(canned, calls, failFirstTables) }, calls };
}

const AREA = {
  id: "11111111-1111-4111-8111-111111111111",
  city_id: "22222222-2222-4222-8222-222222222222",
  slug: "zamalek",
  name: "Zamalek",
  name_ar: "الزمالك",
  geohash_prefix: "stq8",
  center_lat: 30.06,
  center_lng: 31.22,
  radius_km: 3,
  is_active: true,
};

describe("reads", () => {
  it("filters live areas and orders by name", async () => {
    const calls: Op[] = [];
    const rows = await listAreas(deps({ areas: { rows: [AREA], single: null, hasSingle: false, error: null } }, calls).deps);
    expect(rows).toHaveLength(1);
    expect(calls).toContainEqual({ op: "areas.eq", column: "is_active", value: true });
    expect(calls).toContainEqual({ op: "areas.order", column: "name", value: true });
  });

  it("returns null for a retired vendor instead of throwing", async () => {
    const calls: Op[] = [];
    const vendor = await getVendor("33333333-3333-4333-8333-333333333333", deps({ vendors: { rows: null, single: null, hasSingle: false, error: null } }, calls).deps);
    expect(vendor).toBeNull();
    expect(calls).toContainEqual({ op: "vendors.eq", column: "is_active", value: true });
    expect(calls).toContainEqual({ op: "vendors.eq", column: "is_approved", value: true });
  });

  it("narrows order history to the caller's user id in the where", async () => {
    const calls: Op[] = [];
    const uid = "44444444-4444-4444-8444-444444444444";
    await myOrders(uid, deps({ orders: { rows: [], single: null, hasSingle: false, error: null } }, calls).deps);
    expect(calls).toContainEqual({ op: "orders.eq", column: "user_id", value: uid });
    expect(calls).toContainEqual({ op: "orders.order", column: "placed_at", value: false });
  });

  it("reads the timeline ordered by creation", async () => {
    const calls: Op[] = [];
    await orderHistory("55555555-5555-4555-8555-555555555555", deps({ order_status_history: { rows: [], single: null, hasSingle: false, error: null } }, calls).deps);
    expect(calls).toContainEqual({ op: "order_status_history.order", column: "created_at", value: true });
  });

  it("fans out sizes with an in-filter", async () => {
    const calls: Op[] = [];
    const ids = ["66666666-6666-4666-8666-666666666666"];
    await listMenuItemSizes(ids, deps({ menu_item_sizes: { rows: [], single: null, hasSingle: false, error: null } }, calls).deps);
    expect(calls).toContainEqual({ op: "menu_item_sizes.in", column: "item_id", value: ids });
  });

  it("throws business errors without retrying", async () => {
    const calls: Op[] = [];
    const d = deps({ carts: { rows: null, single: null, hasSingle: false, error: { message: "AUTH_REQUIRED: sign in" } } }, calls).deps;
    const failure = await myActiveCart(d).then(
      () => null,
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(AppError);
    if (failure instanceof AppError) expect(failure.code).toBe("AUTH_REQUIRED");
    expect(calls.filter((c) => c.op === "from")).toHaveLength(1);
  });

  it("retries once on transport failure, then returns rows", async () => {
    const calls: Op[] = [];
    const d = deps({ cart_items: { rows: [], single: null, hasSingle: false, error: null } }, calls, ["cart_items"]).deps;
    const rows = await myCartItems("77777777-7777-4777-8777-777777777777", d);
    expect(rows).toEqual([]);
    expect(calls.filter((c) => c.op === "from")).toHaveLength(2);
  });

  it("does not retry single-row reads on transport failure", async () => {
    const calls: Op[] = [];
    const d = deps(
      { carts: { rows: null, single: null, hasSingle: false, error: null } },
      calls,
      ["carts"],
    ).deps;
    await expect(myActiveCart(d)).rejects.toBeInstanceOf(AppError);
    expect(calls.filter((c) => c.op === "from")).toHaveLength(1);
  });

  it("fails closed on corrupt money instead of rendering it", async () => {
    const calls: Op[] = [];
    const d = deps(
      {
        cart_items: {
          rows: [
            {
              id: "88888888-8888-4888-8888-888888888888",
              cart_id: "77777777-7777-4777-8777-777777777777",
              vendor_id: "99999999-9999-4999-8999-999999999999",
              menu_item_id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
              quantity: 1,
              selected_options: [],
              special_instructions: null,
              display_snapshot: {},
              cached_price: 12.5,
              cached_at: null,
              created_at: "2026-10-10T00:00:00Z",
              updated_at: "2026-10-10T00:00:00Z",
              selected_size_id: null,
              selected_size_name: null,
              selected_size_price: null,
            },
          ],
          single: null,
          hasSingle: false,
          error: null,
        },
      },
      calls,
    ).deps;
    await expect(myCartItems("77777777-7777-4777-8777-777777777777", d)).rejects.toBeInstanceOf(AppError);
  });

  it("scopes rider assignments to the caller's rider id in the where", async () => {
    const calls: Op[] = [];
    const riderId = "55555555-5555-4555-8555-555555555555";
    const d = deps(
      {
        delivery_assignments: {
          rows: [
            {
              id: "66666666-6666-4666-8666-666666666666",
              order_id: "77777777-7777-4777-8777-777777777777",
              sub_order_id: null,
              rider_id: riderId,
              status: "assigned",
              stop_sequence: [],
              assigned_by: "rider_claim",
              assigned_at: "2026-10-10T10:00:00Z",
              claimed_at: "2026-10-10T10:01:00Z",
              arrived_vendor_at: null,
              picked_up_at: null,
              arrived_at: null,
              delivered_at: null,
              distance_km: 1.5,
              eta_minutes: 20,
              rider_pay_base: 500,
              rider_pay_distance: 200,
              rider_pay_bonus: 0,
              rider_pay_total: 700,
              platform_revenue: 100,
              collected_amount: 0,
              collection_method: "none",
              collection_channel: null,
              collection_reference: null,
              proof_path: null,
              signature_path: null,
            },
          ],
          single: null,
          hasSingle: false,
          error: null,
        },
      },
      calls,
    ).deps;
    const rows = await riderAssignments(riderId, d);
    expect(rows).toHaveLength(1);
    expect(rows[0]?.rider_pay_total).toBe(700);
    expect(calls).toContainEqual({ op: "delivery_assignments.eq", column: "rider_id", value: riderId });
  });
});
