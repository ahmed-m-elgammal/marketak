/**
 * Role probe hook (mobile README §6).
 *
 * One source: `get_my_rider_profile_v1` doubles as the probe — a row means
 * rider, `NOT_A_RIDER` (mapped to null at the barrel) means customer-only.
 * There is no self-registration: a rider never onboarded by
 * `admin_upsert_rider_v1` is permanently customer-only, and the rider tab
 * says "contact support", not "apply".
 *
 * `switchActiveRole` clears by namespace prefix and keeps the session: the
 * session query lives under `['session']`, outside both role namespaces.
 */
import { useQuery, type QueryClient } from "@tanstack/react-query";
import type { RiderProfile } from "@marketak/shared";
import { riderProfileKey } from "../../../services/cache/query-keys";
import { riderProfile } from "../../../services/rpc/index";
import type { ActiveRole } from "../../../state/ui";

export type RoleState = "pending" | "signed-out" | "customer-only" | "rider";

export function toRoleState(
  userId: string | null | undefined,
  profile: RiderProfile | null | undefined,
): RoleState {
  if (userId === null || userId === undefined) return "signed-out";
  if (profile === undefined) return "pending";
  if (profile === null) return "customer-only";
  return "rider";
}

export function useRole(userId: string | null | undefined): {
  readonly role: RoleState;
  readonly profile: RiderProfile | null | undefined;
} {
  const query = useQuery({
    queryKey: riderProfileKey(userId ?? "anonymous"),
    queryFn: () => riderProfile(),
    retry: false,
    enabled: userId !== null && userId !== undefined,
  });
  return { role: toRoleState(userId, query.data), profile: query.data };
}

export function switchActiveRole(queryClient: QueryClient, role: ActiveRole): void {
  queryClient.removeQueries({ queryKey: role === "customer" ? ["rider"] : ["customer"] });
}
