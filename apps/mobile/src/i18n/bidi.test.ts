import { describe, expect, it } from "vitest";
import { BIDI_CLOSE, BIDI_OPEN, isolateBidi } from "./bidi";

describe("bidi isolation", () => {
  it("wraps text in U+2066 LRI … U+2069 PDI", () => {
    expect(BIDI_OPEN.codePointAt(0)).toBe(0x2066);
    expect(BIDI_CLOSE.codePointAt(0)).toBe(0x2069);
  });

  it("preserves the payload byte-identically", () => {
    expect(isolateBidi("#ORD-9024")).toBe(`${BIDI_OPEN}#ORD-9024${BIDI_CLOSE}`);
    expect(isolateBidi("")).toBe(`${BIDI_OPEN}${BIDI_CLOSE}`);
  });
});
