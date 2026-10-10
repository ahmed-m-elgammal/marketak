/**
 * Babel configuration.
 *
 * Presets (run after plugins, in reverse order — NativeWind v4 documented
 * order for Expo):
 *
 * 1. `babel-preset-expo` - the SDK's transforms, with NativeWind's JSX
 *    runtime so `className` compiles on every component.
 * 2. `nativewind/babel` - the utility transform.
 *
 * Plugins:
 *
 * - `react-native-worklets/plugin` - Reanimated 4's worklet transform.
 *   **Last, always.** The worklet transform has to see the final AST, and a
 *   plugin placed after it silently stops workletising functions that were
 *   created before it ran. The failure is a gesture that does nothing, with
 *   no error.
 */
module.exports = function babelConfig(api) {
  api.cache(true);
  return {
    presets: [
      ["babel-preset-expo", { jsxRuntime: "automatic", jsxImportSource: "nativewind" }],
      "nativewind/babel",
    ],
    plugins: ["react-native-worklets/plugin"],
  };
};
