import { beforeEach, describe, expect, it } from "vitest";
import { getUiState, resetUi, setUiState } from "./ui";

describe("ui state", () => {
  beforeEach(() => {
    resetUi();
  });

  it("boots customer-first with nothing open", () => {
    expect(getUiState()).toEqual({ activeRole: "customer", sheetOpen: false, selectedTab: null, drafts: {} });
  });

  it("patches fields without touching the rest", () => {
    setUiState({ activeRole: "courier", sheetOpen: true });
    expect(getUiState()).toEqual({ activeRole: "courier", sheetOpen: true, selectedTab: null, drafts: {} });
  });

  it("replaces drafts wholesale, never merges stale keys", () => {
    setUiState({ drafts: { "address:label": "home" } });
    setUiState({ drafts: {} });
    expect(getUiState().drafts).toEqual({});
  });

  it("resets everything on sign-out", () => {
    setUiState({ activeRole: "courier", sheetOpen: true, selectedTab: "offers", drafts: { "a:b": "c" } });
    resetUi();
    expect(getUiState()).toEqual({ activeRole: "customer", sheetOpen: false, selectedTab: null, drafts: {} });
  });
});
