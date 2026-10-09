/**
 * Where the app is while the stored session is read. Releases the OS splash and replaces itself
 * with the destination. The ref guards the replace: the state settling and a re-render can both
 * arrive here, and two replaces race.
 */

import { Image } from "expo-image";
import { useRouter } from "expo-router";
import * as NativeSplash from "expo-splash-screen";
import { useEffect, useRef } from "react";
import { View } from "react-native";
import { useSession } from "@/features/auth";
// Relative, not `@/assets/...`: the tsconfig alias maps only ./src/*, so assets are not reachable
// through it. Metro resolves this relative to the importing file.
import splash from "../assets/splash.png";

export default function SplashRoute() {
  const router = useRouter();
  const { state, canOrder } = useSession();
  const redirected = useRef(false);

  useEffect(() => {
    // Nothing to decide until AsyncStorage has been read. The artwork below is already painting,
    // so releasing now is artwork-to-artwork with no bare frame.
    if (state.status === "loading") return;

    void NativeSplash.hideAsync();

    if (redirected.current) return;
    redirected.current = true;

    if (state.status === "signed-in") {
      router.replace(canOrder ? "/(customer)/home" : "/(auth)/complete-profile");
      return;
    }

    router.replace("/(auth)/welcome");
  }, [state, canOrder, router]);

  return (
    <View className="flex-1 bg-cream" testID="splash-screen">
      <Image
        source={splash}
        style={{ flex: 1 }}
        contentFit="cover"
        accessibilityIgnoresInvertColors
        testID="splash-artwork"
      />
    </View>
  );
}