/**
 * Sign in. Google and Apple, nothing else (constitution 18). No "other options" link: it would
 * advertise a path the product does not have.
 *
 * No navigation on success — the session provider owns the transition, because the destination
 * depends on the profile gate and two callers re-deriving it would eventually disagree.
 */

import { ScrollView, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useSignIn } from "@/features/auth/hooks/use-sign-in";
import { ProviderButtons } from "@/features/auth/widgets/ProviderButtons";
import { useCopy } from "@/lib/i18n";
import type { ProviderBrand } from "@/components/ui/buttons/ProviderButton";

export function SignInScreen() {
  const t = useCopy();
  const { phase, pending, start } = useSignIn();

  const onProvider = (brand: ProviderBrand): void => {
    void start(brand);
  };

  return (
    <SafeAreaView className="flex-1 bg-cream" edges={["top", "bottom"]}>
      <ScrollView
        contentContainerClassName="flex-1 justify-between px-6 py-8"
        showsVerticalScrollIndicator={false}
      >
        <View className="mt-8 gap-3">
          <Text className="text-h1 text-ink">{t("signInTitle")}</Text>
          <Text className="text-body text-ink-secondary">{t("signInSubtitle")}</Text>
        </View>

        <View className="gap-5">
          {/* Only when there is a message. A permanent error slot under a healthy screen teaches
              people to ignore errors. A dismissal is deliberately silent. */}
          {phase === "failed" ? (
            <Text
              testID="sign-in-error"
              accessibilityRole="alert"
              className="text-body-medium text-danger"
            >
              {t("signInFailed")}
            </Text>
          ) : null}

          <ProviderButtons pending={pending} onProvider={onProvider} />

          <Text className="text-caption text-ink-tertiary" style={{ direction: "ltr" }}>
            {t("signInTerms")}
          </Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}