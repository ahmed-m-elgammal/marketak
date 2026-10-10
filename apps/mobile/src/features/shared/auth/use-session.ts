/**
 * Session hook + sign-out orchestration (mobile README §6).
 *
 * `useSession` reads the `['session']` query the provider's subscriber
 * keeps; it computes nothing. `gateState` is the guard vocabulary:
 * `pending` (unresolved), `signed-out` (null — routes to sign-in, never
 * loops: null is a state, not an error to retry), `authorized`.
 */
import { useQuery, type QueryClient } from "@tanstack/react-query";
import { fetchSession, type SessionInfo } from "../../../services/auth/session";
import { sessionKey } from "../../../services/cache/query-keys";
import { resetUi } from "../../../state/ui";

export type GateState = "pending" | "signed-out" | "authorized";

export function gateState(session: SessionInfo | null | undefined): GateState {
  if (session === undefined) return "pending";
  if (session === null) return "signed-out";
  return "authorized";
}

export function useSession(): {
  readonly gate: GateState;
  readonly session: SessionInfo | null | undefined;
} {
  const query = useQuery({ queryKey: sessionKey(), queryFn: () => fetchSession() });
  return { gate: gateState(query.data), session: query.data };
}

/**
 * Sign-out, in order: server first, then `queryClient.clear()` and the UI
 * reset. A failed server sign-out keeps cache and UI untouched — wiping
 * state the server still considers signed in strands the next launch.
 */
export async function signOutEverywhere(
  queryClient: QueryClient,
  signOut: () => Promise<void>,
  reset: () => void = resetUi,
): Promise<void> {
  await signOut();
  queryClient.clear();
  reset();
}
