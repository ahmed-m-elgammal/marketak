import { describe, expect, it } from "vitest";
import { routeForNotification } from "./routing";

describe("routeForNotification", () => {
  it("lands customer order pushes on the order, or the list without an id", () => {
    expect(routeForNotification({ templateKey: "order.delivered", orderId: "o1" }, "customer")).toBe(
      "/(customer)/orders/o1",
    );
    expect(routeForNotification({ templateKey: "order.cancelled" }, "customer")).toBe("/(customer)/orders");
  });

  it("lands rider pushes on the offer pool", () => {
    expect(routeForNotification({ templateKey: "rider.new_offer" }, "rider")).toBe("/(rider)/offers");
    expect(routeForNotification({ templateKey: "rider.order_assigned", orderId: "o1" }, "rider")).toBe(
      "/(rider)/offers",
    );
  });

  it("sends voucher pushes to the customer home", () => {
    expect(routeForNotification({ templateKey: "voucher.available" }, "customer")).toBe("/(customer)/home");
  });

  it("routes cross-role, vendor and unknown keys nowhere", () => {
    expect(routeForNotification({ templateKey: "order.delivered", orderId: "o1" }, "rider")).toBeNull();
    expect(routeForNotification({ templateKey: "rider.new_offer" }, "customer")).toBeNull();
    expect(routeForNotification({ templateKey: "vendor.new_order", orderId: "o1" }, "customer")).toBeNull();
    expect(routeForNotification({ templateKey: "vendor.new_order", orderId: "o1" }, "rider")).toBeNull();
    expect(routeForNotification({ templateKey: "something.new" }, "customer")).toBeNull();
  });

  it("carries ids only — a sealed pharmacy push has no name field to route on", () => {
    const sealed = { templateKey: "order.ready", orderId: "o1" };
    expect(Object.keys(sealed).sort()).toEqual(["orderId", "templateKey"]);
    expect(routeForNotification(sealed, "customer")).toBe("/(customer)/orders/o1");
  });
});
