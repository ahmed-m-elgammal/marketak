/**
 * UI-only state (mobile README §1, L7 leaf).
 *
 * Sheet open, selected tab, form drafts, and the active role for dual-role
 * holders. Server data never enters here (R5) — carts, orders and session
 * belong to TanStack Query. A `useSyncExternalStore` cell, not a store
 * library: the surface is four fields and a reset, and a dependency for
 * that is the speculative part.
 */
import { useSyncExternalStore } from "react";

export type ActiveRole = "customer" | "courier";

export interface UiState {
  readonly activeRole: ActiveRole;
  readonly sheetOpen: boolean;
  readonly selectedTab: string | null;
  readonly drafts: Readonly<Record<string, string>>;
}

const INITIAL_UI_STATE: UiState = {
  activeRole: "customer",
  sheetOpen: false,
  selectedTab: null,
  drafts: {},
};

let current: UiState = INITIAL_UI_STATE;
const listeners = new Set<() => void>();

function emit(): void {
  listeners.forEach((notify) => notify());
}

export function getUiState(): UiState {
  return current;
}

export function setUiState(patch: Partial<UiState>): void {
  current = { ...current, ...patch };
  emit();
}

/** Sign-out reset: role, sheet, tab and drafts back to boot. */
export function resetUi(): void {
  current = INITIAL_UI_STATE;
  emit();
}

function subscribeUi(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function useUi(): UiState {
  return useSyncExternalStore(subscribeUi, getUiState);
}
