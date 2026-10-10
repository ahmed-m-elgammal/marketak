import { describe, expect, it } from "vitest";
import { arabicPluralCategory, fillCount, pluralKey } from "./plurals";

describe("arabic plurals", () => {
  it("covers all six CLDR categories", () => {
    expect(arabicPluralCategory(0)).toBe("zero");
    expect(arabicPluralCategory(1)).toBe("one");
    expect(arabicPluralCategory(2)).toBe("two");
    expect(arabicPluralCategory(3)).toBe("few");
    expect(arabicPluralCategory(11)).toBe("many");
    expect(arabicPluralCategory(100)).toBe("other");
  });

  it("builds the string-table key from the category", () => {
    expect(pluralKey("cart.lines", 0)).toBe("cart.lines.zero");
    expect(pluralKey("cart.lines", 1)).toBe("cart.lines.one");
    expect(pluralKey("cart.lines", 2)).toBe("cart.lines.two");
  });

  it("interpolates counts in the locale digit system", () => {
    expect(fillCount("{count} أصناف", 3, "ar")).toBe("٣ أصناف");
    expect(fillCount("{count} items", 3, "en")).toBe("3 items");
    expect(fillCount("لا أصناف", 0, "ar")).toBe("لا أصناف");
  });
});
