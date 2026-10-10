import { describe, expect, it } from "vitest";
import { labelTreatment } from "./labels";

describe("label treatment", () => {
  it("leaves Arabic labels untransformed with zero tracking", () => {
    expect(labelTreatment("ar")).toEqual({ textTransform: "none", letterSpacing: 0 });
  });

  it("uppercases Latin labels and leaves tracking to the token", () => {
    expect(labelTreatment("en")).toEqual({ textTransform: "uppercase", letterSpacing: undefined });
  });
});
