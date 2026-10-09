import * as NativeSplash from "expo-splash-screen";
import { Image } from "expo-image";
import { useEffect } from "react";
import { View } from "react-native";

import splash from "../assets/splash.png";

/**
 * Boot splash.
 *
 * The artwork is the single asset here - it carries the mark, the Arabic wordmark, the Latin
 * wordmark, the tagline and the category rail, so nothing is composed on top of it. The screen is
 * a full-bleed `cover` fill on the brand cream.
 *
 * This is the ONLY screen in `app/` right now. `apps/mobile/README.md` holds the route map and the
 * rule that a route file never exceeds 20 lines and never fetches, maps or computes - this one does
 * none of the three. Everything from here on is built screen by screen against that contract.
 */
export default function SplashScreen() {
  useEffect(() => {
    // The native splash was held open at module scope in `_layout.tsx`. Release it now that React
    // has mounted, so the transition is artwork-to-artwork with no frame of bare background.
    void NativeSplash.hideAsync();
  }, []);

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
