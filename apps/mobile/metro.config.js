/**
 * Metro configuration.
 *
 * Nothing is customised here yet, and that is deliberate: the default Metro config
 * is the one Expo tests against, and every customisation is a thing that can break
 * on an SDK upgrade. When `packages/shared` needs to be resolved by the app it
 * happens through the workspace symlink, which Metro follows by default.
 *
 * `unstable_enablePackageExports` is on because `@supabase/supabase-js` and
 * `@tanstack/react-query` both ship `exports` maps with subpath entry points, and
 * Metro's legacy resolver ignores them and falls back to `main`, which resolves to
 * a build that assumes a bundler it is not running under.
 *
 * NativeWind v4 compiles `src/theme/global.css` at build time through
 * `withNativeWind` (documented Expo integration). The wrapper preserves the
 * resolver tweaks below - it composes the config, it does not replace it.
 */
const { getDefaultConfig } = require("expo/metro-config");
const { withNativeWind } = require("nativewind/metro");

/** @type {import('expo/metro-config').MetroConfig} */
const config = getDefaultConfig(__dirname);

config.resolver.unstable_enablePackageExports = true;

// Fonts and images are pulled in through `expo-font` and the asset registry, so
// they must not be treated as source. `ttf` is added for the bundled brand fonts.
config.resolver.assetExts.push("ttf", "otf");

module.exports = withNativeWind(config, { input: "./src/theme/global.css" });
