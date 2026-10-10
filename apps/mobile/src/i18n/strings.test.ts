import { describe, expect, it } from "vitest";
import ar from "./ar.json";
import en from "./en.json";
import { translate } from "./useT";

describe("string tables", () => {
  it("keeps both languages on identical key sets", () => {
    expect(Object.keys(ar).sort()).toEqual(Object.keys(en).sort());
  });

  it("leaves no key empty", () => {
    for (const value of [...Object.values(ar), ...Object.values(en)]) {
      expect(value.length).toBeGreaterThan(0);
    }
  });

  it("covers every Arabic plural form for cart lines", () => {
    for (const category of ["zero", "one", "two", "few", "many", "other"] as const) {
      expect(translate("ar", `cart.lines.${category}`)).not.toBe(`cart.lines.${category}`);
      expect(translate("en", `cart.lines.${category}`)).not.toBe(`cart.lines.${category}`);
    }
  });

  it("falls back requested → Arabic → key", () => {
    expect(translate("en", "common.ok")).toBe("OK");
    expect(translate("ar", "common.ok")).toBe("موافق");
    expect(translate("en", "missing.key")).toBe("missing.key");
  });
});
