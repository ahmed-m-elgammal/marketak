import { useEffect, useState } from "react";
import { Slot } from "expo-router";
import { TamaguiProvider } from "tamagui";
import { QueryClientProvider } from "@tanstack/react-query";
import * as SplashScreen from "expo-splash-screen";
import { I18nManager } from "react-native";
import * as Localization from "expo-localization";
import { config } from "../src/theme/tamagui.config";
import { useAppFonts } from "../src/theme/useAppFonts";
import { applyRtlPolicy, resolveLanguage } from "../src/i18n/index";
import { createQueryClient } from "../src/services/cache/queryClient";
import { AuthProvider } from "../src/features/shared/auth/provider";
import { PushRegistration } from "../src/features/shared/device/push-registration";
import "../src/theme/global.css";

void SplashScreen.preventAutoHideAsync();

/**
 * Composition root: provider shell only (mobile README §1). Mounts providers
 * and boot mounting (fonts, RTL policy, query client, the one session
 * subscriber, launch registration); holds no business logic. Gates consume
 * useSession/useRole.
 */
export default function RootLayout() {
  const [queryClient] = useState(() => createQueryClient());
  const [fontsLoaded, fontError] = useAppFonts();
  const lang = resolveLanguage(Localization.getLocales().map((locale) => locale.languageTag));

  useEffect(() => {
    applyRtlPolicy(lang, I18nManager);
  }, [lang]);

  useEffect(() => {
    if (fontsLoaded || fontError !== null) {
      void SplashScreen.hideAsync();
    }
  }, [fontsLoaded, fontError]);

  if (!fontsLoaded && fontError === null) return null;
  return (
    <QueryClientProvider client={queryClient}>
      <TamaguiProvider config={config} defaultTheme="dark">
        <AuthProvider>
          <PushRegistration />
          <Slot />
        </AuthProvider>
      </TamaguiProvider>
    </QueryClientProvider>
  );
}
