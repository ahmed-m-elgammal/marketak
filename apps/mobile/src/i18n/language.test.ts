import { describe, expect, it } from "vitest";
import { applyRtlPolicy, resolveLanguage, type RtlManager } from "./language";

function fakeManager(isRTL: boolean): RtlManager & { calls: string[] } {
  const calls: string[] = [];
  return {
    isRTL,
    calls,
    allowRTL(value: boolean): void {
      calls.push(`allowRTL:${String(value)}`);
    },
    forceRTL(value: boolean): void {
      calls.push(`forceRTL:${String(value)}`);
    },
  };
}

describe("resolveLanguage", () => {
  it("matches the first recognized locale tag", () => {
    expect(resolveLanguage(["ar-EG"])).toBe("ar");
    expect(resolveLanguage(["en-US"])).toBe("en");
    expect(resolveLanguage(["fr-FR", "en-GB"])).toBe("en");
  });

  it("resolves unknown or absent locales to Arabic, the account default", () => {
    expect(resolveLanguage(["fr-FR"])).toBe("ar");
    expect(resolveLanguage([])).toBe("ar");
    expect(resolveLanguage(null)).toBe("ar");
    expect(resolveLanguage(undefined)).toBe("ar");
  });
});

describe("applyRtlPolicy", () => {
  it("always allows RTL and forces only on disagreement", () => {
    const agreeing = fakeManager(true);
    applyRtlPolicy("ar", agreeing);
    expect(agreeing.calls).toEqual(["allowRTL:true"]);

    const disagreeing = fakeManager(false);
    applyRtlPolicy("ar", disagreeing);
    expect(disagreeing.calls).toEqual(["allowRTL:true", "forceRTL:true"]);
  });
});
