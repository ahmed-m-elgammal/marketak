import { color } from "@/theme/tokens";
import * as NativeSplash from "expo-splash-screen";
import * as SystemUI from "expo-system-ui";
import { StatusBar } from "expo-status-bar";
import { Stack } from "expo-router";
import { useEffect } from "react";
import { useColorScheme } from "react-native";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { PanelUIProvider } from "panelui-native";

/**
 * Keep the native splash up until React has mounted and the artwork is ready to be drawn.
 *
 * Without this there is a frame of bare background between the native splash and the first React
 * paint, which on a device reads as a flicker. Called at module scope so the hold begins before the
 * first render rather than inside an effect, which would be too late. `void` because the promise is
 * deliberately not awaited at import time.
 */
void NativeSplash.preventAutoHideAsync();

/**
 * Paint the window behind the app from the same token the React tree uses.
 *
 * React Navigation draws an opaque background over every screen, and the OS window behind it is the
 * device default. On Android that shows as a band of the wrong colour in every gap the app is not
 * painting - behind the status bar, under the navigation bar, and in the gap a screen transition
 * opens. Driving it from `color.cream` (the 60% canvas) is what makes the brand reach the edges.
 *
 * The value comes from `src/theme/tokens.ts` rather than a `useCSSVariable` hook because this is a
 * native API taking a raw string, not a class utility - see the header of that file for why the two
 * token forms exist.
 */
function ThemedShell() {
  const scheme = useColorScheme();

  useEffect(() => {
    void SystemUI.setBackgroundColorAsync(color.cream);
  }, []);

  return (
    <>
      {/* Dark icons on the cream canvas. The scheme is the OS's, not an in-app toggle - there is
          no dark theme in this design system, so the bar style follows the OS so its own chrome
          stays legible while the app's canvas stays cream. */}
      <StatusBar style={scheme === "dark" ? "light" : "dark"} />
      <Stack
        screenOptions={{
          headerShown: false,
          // The navigation container paints its own background behind every screen. Left as the
          // default it is an opaque light grey that sits over the brand canvas and makes theme
          // work look like it is doing nothing.
          contentStyle: { backgroundColor: color.cream },
        }}
      />
    </>
  );
}

export default function RootLayout() {
  // One provider at the root, and only one: it owns the gesture root, the themed page background,
  // the portal host overlays render into, and the toast viewport. Nesting a second is a bug.
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <PanelUIProvider>
        <ThemedShell />
      </PanelUIProvider>
    </GestureHandlerRootView>
  );
}
