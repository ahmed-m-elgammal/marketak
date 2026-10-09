/**
 * Welcome. A brand moment, not a form: the only decision here is "start".
 *
 * Arabic is the default locale, so `writingDirection` drives the layout. The Latin lines carry an
 * explicit ltr override: inside an RTL paragraph the bidi algorithm reorders a Latin run and it
 * drifts to the wrong edge.
 */

import { Image } from "expo-image";
import { useRouter } from "expo-router";
import { ScrollView, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { PrimaryButton } from "@/components/ui/buttons/PrimaryButton";
import { useCopy } from "@/lib/i18n";
// Four levels: screens -> auth -> features -> src -> apps/mobile. The `@/` alias maps only ./src/*,
// so assets are not reachable through it.
import wordmark from "../../../../assets/wordmark.png";

export function WelcomeScreen() {
  const t = useCopy();
  const router = useRouter();

  return (
    <SafeAreaView className="flex-1 bg-cream" edges={["top", "bottom"]}>
      <ScrollView
        contentContainerClassName="flex-1 justify-between px-6 py-8"
        showsVerticalScrollIndicator={false}
      >
        <View className="mt-8 items-center gap-8">
          <Image
            source={wordmark}
            style={{ width: 200, height: 64 }}
            contentFit="contain"
            accessibilityIgnoresInvertColors
            accessibilityRole="image"
            accessibilityLabel={t("welcomeWordmarkLabel")}
          />

          <View className="items-center gap-3">
            {(["welcomeLine1", "welcomeLine2"] as const).map((key) => (
              <Text
                key={key}
                className="text-center text-body text-ink-secondary"
                style={{ direction: "ltr" }}
              >
                {t(key)}
              </Text>
            ))}
          </View>
        </View>

        <View className="gap-3">
          <PrimaryButton
            label={t("welcomeContinue")}
            testID="welcome-continue"
            onPress={() => {
              router.push("/(auth)/sign-in");
            }}
          />
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}