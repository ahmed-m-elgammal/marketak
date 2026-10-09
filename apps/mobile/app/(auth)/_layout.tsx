/** No header: each screen draws its own heading. No animation: an auth step is a state change. */

import { Stack } from "expo-router";
import { color } from "@/theme/tokens";

export default function AuthLayout() {
  return (
    <Stack
      screenOptions={{
        headerShown: false,
        animation: "none",
        contentStyle: { backgroundColor: color.cream },
      }}
    />
  );
}