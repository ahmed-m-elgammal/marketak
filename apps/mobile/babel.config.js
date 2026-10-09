// Expo's default preset, stated explicitly rather than inherited.
//
// It already wires the worklets plugin that Reanimated 4 needs, which is why PanelUI ships no
// babel.config.js of its own. Listed here so the fact is visible rather than assumed: if a future
// dependency needs a transform, this is the file that changes, and adding one is not a surprise.

module.exports = function (api) {
  api.cache(true);
  return {
    presets: ["babel-preset-expo"],
  };
};
