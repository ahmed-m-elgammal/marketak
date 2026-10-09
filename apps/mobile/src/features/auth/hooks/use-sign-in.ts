/** Sign-in state. Three outcomes, because a dismissal must not read as a failure. */

import { useCallback, useState } from "react";
import {
  signInWithApple,
  signInWithGoogle,
  type SignInResult,
} from "@/features/auth/api/sign-in";
import { capture, reportError } from "@/services/analytics";
import type { ProviderBrand } from "@/components/ui/buttons/ProviderButton";

export type SignInPhase = "idle" | "pending" | "cancelled" | "failed";

export interface UseSignIn {
  readonly phase: SignInPhase;
  readonly pending: ProviderBrand | null;
  readonly start: (brand: ProviderBrand) => Promise<void>;
}

export function useSignIn(): UseSignIn {
  const [phase, setPhase] = useState<SignInPhase>("idle");
  const [pending, setPending] = useState<ProviderBrand | null>(null);

  const start = useCallback(async (brand: ProviderBrand) => {
    setPending(brand);
    setPhase("pending");

    // Optimistic: if the sheet never appears there is no event, which is the honest outcome.
    capture("sign_in_started", { provider: brand });

    const result: SignInResult =
      brand === "google" ? await signInWithGoogle() : await signInWithApple();

    setPending(null);

    if (result === "signed-in") {
      setPhase("idle");
      return;
    }

    if (result === "cancelled") {
      // Reporting a dismissal as a failure would make the cancel rate look like a bug rate.
      setPhase("cancelled");
      return;
    }

    setPhase("failed");
    // No cause attached: a failed exchange can carry a token fragment in its message.
    reportError("auth:sign_in_failed", new Error(`sign-in failed for ${brand}`));
  }, []);

  return { phase, pending, start };
}