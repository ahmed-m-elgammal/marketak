import { describe, expect, it } from "vitest";
import { BEHAVIOUR_CODES, parseAppError } from "@marketak/shared";
import { fieldFor, toBehaviour } from "./behaviour";

describe("toBehaviour", () => {
  it("maps the conflict codes to silent re-read", () => {
    for (const code of BEHAVIOUR_CODES.conflict) {
      expect(toBehaviour(code)).toBe("conflict");
    }
  });

  it("maps every invalid-input code, including the quote-path pair", () => {
    for (const code of BEHAVIOUR_CODES.invalidInput) {
      expect(toBehaviour(code)).toBe("invalid-input");
    }
    expect(toBehaviour("GROUPING_INVALID")).toBe("invalid-input");
    expect(toBehaviour("TIP_INVALID")).toBe("invalid-input");
  });

  it("sends authentication failures to sign-in", () => {
    expect(toBehaviour("NOT_AUTHORIZED")).toBe("sign-in");
    expect(toBehaviour("AUTH_REQUIRED")).toBe("sign-in");
  });

  it("gives retired and absent codes no branch", () => {
    // Payload discriminators and a contract listing with no live raiser
    // (tasks.mf Q7): branching on any of these is dead code.
    expect(toBehaviour("ITEM_PRICE_CHANGED")).toBe("business");
    expect(toBehaviour("DELIVERY_FEE_CHANGED")).toBe("business");
    expect(toBehaviour("OPTION_SELECTION_INVALID")).toBe("business");
    // Rejection data, never raised: OUT_OF_STOCK and VOUCHER_* arrive in
    // the quote rejections[], handled at checkout, not here.
    expect(toBehaviour("OUT_OF_STOCK")).toBe("business");
    expect(toBehaviour("VOUCHER_EXPIRED")).toBe("business");
    expect(toBehaviour("VOUCHER_UNKNOWN")).toBe("business");
    // Admin-path codes the app never receives: verbatim, no action.
    expect(toBehaviour("ACCOUNT_REQUIRED")).toBe("business");
    expect(toBehaviour("LEDGER_CONFLICT")).toBe("business");
    expect(toBehaviour("WALLET_CONFLICT")).toBe("business");
    expect(toBehaviour("OWNER_REQUIRED")).toBe("business");
  });

  it("defaults unknown codes to verbatim business", () => {
    expect(toBehaviour("SOMETHING_NEW_TOMORROW")).toBe("business");
    expect(toBehaviour("")).toBe("business");
  });

  it("keeps the server Arabic byte-identical through the layer", () => {
    const error = parseAppError({ message: "PRICE_CHANGED: تغير السعر" });
    expect(error.serverMessage).toBe("تغير السعر");
    expect(toBehaviour(error.code ?? "")).toBe("conflict");
  });
});

describe("fieldFor", () => {
  it.each([
    ["NAME_INVALID", "name"],
    ["PHONE_INVALID", "phone"],
    ["PHONE_IN_USE", "phone"],
    ["PHONE_IN_USE_BY_RIDER", "phone"],
    ["INVALID_PATCH", "profile"],
    ["INVALID_QUANTITY", "quantity"],
    ["INVALID_OPTIONS", "options"],
    ["OPTION_UNAVAILABLE", "options"],
    ["SIZE_REQUIRED", "size"],
    ["SIZE_UNAVAILABLE", "size"],
    ["SIZE_NOT_APPLICABLE", "size"],
    ["ITEM_SIZED_BUT_NO_SIZES", "size"],
    ["TIP_INVALID", "tip"],
    ["DELIVERY_TYPE_INVALID", "deliveryType"],
    ["GROUPING_INVALID", "grouping"],
    ["PAYMENT_METHOD_INVALID", "paymentMethod"],
    ["PAYMENT_CHANNEL_INVALID", "paymentChannel"],
    ["PAYMENT_CHANNEL_REQUIRED", "paymentChannel"],
    ["PAYMENT_CHANNEL_MISMATCH", "paymentChannel"],
    ["ADDRESS_REQUIRED", "address"],
    ["ADDRESS_COORDS_REQUIRED", "address"],
    ["ADDRESS_COORDS_INVALID", "address"],
    ["ADDRESS_LABEL_INVALID", "label"],
    ["AREA_REQUIRED", "area"],
    ["AREA_UNAVAILABLE", "area"],
    ["AMOUNT_INVALID", "amount"],
    ["RADIUS_INVALID", "radius"],
    ["CART_ITEM_RETIRED", "cartLine"],
    ["CART_ITEM_UNAVAILABLE", "cartLine"],
  ] as const)("attaches %s to its field", (code, field) => {
    expect(fieldFor(code)).toBe(field);
  });

  it("returns null where no field can fix it", () => {
    for (const code of [
      "TOKEN_REQUIRED",
      "TOKEN_TOO_LONG",
      "PLATFORM_INVALID",
      "APP_ROLE_INVALID",
      "UNKNOWN_KEY",
      "PATCH_EMPTY",
      "PROFILE_ALREADY_COMPLETE",
      "PRICE_CHANGED",
      "NOT_AUTHORIZED",
      "SOMETHING_NEW_TOMORROW",
    ] as const) {
      expect(fieldFor(code)).toBeNull();
    }
  });
});
