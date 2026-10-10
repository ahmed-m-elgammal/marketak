/**
 * The app-wide query client (mobile README §6, DESIGN §11).
 *
 * Retry policy: transport collapses retry once (mirrors the `reads.ts`
 * retry-once rule); business failures never retry — `NOT_A_RIDER` must
 * resolve to customer-only, not spin. `staleTime` follows the §11 stale
 * trigger (no update for 10 s): data older than that renders with its age
 * (shared `formatRelativeInZone`), never as live.
 */
import { QueryClient } from "@tanstack/react-query";
import { AppError } from "@marketak/shared";

export function shouldRetry(failureCount: number, error: unknown): boolean {
  if (failureCount >= 1) return false;
  return error instanceof AppError && error.code === null && error.cause instanceof TypeError;
}

export function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: shouldRetry,
        staleTime: 10_000,
      },
    },
  });
}
