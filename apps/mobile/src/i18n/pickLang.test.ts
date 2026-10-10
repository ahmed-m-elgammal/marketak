import { describe, expect, it } from "vitest";
import { pickLang } from "./pickLang";

describe("pickLang", () => {
  it("picks the requested language", () => {
    expect(pickLang({ ar: "تم", en: "Done" }, "ar")).toBe("تم");
    expect(pickLang({ ar: "تم", en: "Done" }, "en")).toBe("Done");
  });

  it("falls back to Arabic, the account default, before English", () => {
    expect(pickLang({ ar: "تم" }, "en")).toBe("تم");
    expect(pickLang({ en: "Done" }, "ar")).toBe("Done");
  });

  it("treats an empty translation as missing", () => {
    expect(pickLang({ ar: "", en: "Done" }, "ar")).toBe("Done");
  });

  it("passes strings through and empties to nothing", () => {
    expect(pickLang("خام", "ar")).toBe("خام");
    expect(pickLang(null, "ar")).toBe("");
    expect(pickLang(undefined, "en")).toBe("");
    expect(pickLang({}, "ar")).toBe("");
  });
});
