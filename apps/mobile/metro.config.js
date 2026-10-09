// Metro config for apps/mobile.
//
// Uniwind compiles Tailwind classes at bundle time, so it has to wrap the Metro config. This is a
// Metro plugin only - there is NO Babel preset and no babel transform, which is the property that
// made ADR 25 reversible: open question 3.9 rejected a Tailwind engine on the grounds of "no Babel
// step", and Uniwind meets that condition exactly.
//
// See decisions.md ADR 25 and apps/mobile/README.md.

const { getDefaultConfig } = require("expo/metro-config");
const { withUniwindConfig } = require("uniwind/metro");

const config = getDefaultConfig(__dirname);

module.exports = withUniwindConfig(config, {
  cssEntryFile: "./src/global.css",
  dtsFile: "./uniwind-types.d.ts",
});
