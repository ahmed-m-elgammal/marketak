/**
 * Babel configuration.
 *
 * Two plugins, in this order. Order is the whole point:
 *
 * 1. `babel-preset-expo` - the SDK's transforms. First, because everything else
 *    compiles against its output.
 * 2. `react-native-worklets/plugin` - Reanimated 4's worklet transform. **Last,
 *    always.** The worklet transform has to see the final AST, and a plugin
 *    placed after it silently stops workletising functions that were created
 *    before it ran. The failure is a gesture that does nothing, with no error.
 *
 * This is why the ADR that replaced Uniwind mattered: Uniwind's Metro plugin is a
 * build step that does not touch Babel, so it does not enter this ordering. Adding
 * a NativeWind-style Babel preset here is what the original objection in open
 * question 3.9 was about, and it would go last, competing with the worklet plugin.
 */
module.exports = function babelConfig(api) {
  api.cache(true);
  return {
    presets: [["babel-preset-expo", { jsxRuntime: "automatic" }]],
    plugins: ["react-native-worklets/plugin"],
  };
};
